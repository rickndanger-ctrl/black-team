import Foundation

// What `main.cjs` exposed over IPC to the desktop window, plus the Mac's own first-run setup.
//
// IPC channel -> Backend method
//   status              -> status()
//   server-discover     -> discoverServer(endpoint:apiKey:)
//   models-find         -> findMyModels()
//   model-inspect       -> inspectModelFile(_:)
//   installed-discover  -> discoverApps()
//   setup-help          -> helpLink(topic:)          (returns the URL; the interface opens it)
//   open-data           -> dataFolderPath()          (returns the folder; the interface opens it)
//   integrations-save   -> saveIntegrations(_:)
//   harness-launch      -> launch(harness:)
//   harness-connect     -> connect(harness:)
//   setup-save          -> saveSetup(_:)
//   models-add          -> add(models:)
//   models-ignore       -> ignore(key:)
//   model-switch        -> switchTo(key:)
//   model-forget        -> forget(key:)
//   runtime-start       -> startModel()
//   runtime-stop        -> stopModel()
//   black-team:pick     -> pickerRequest(_:)         (describes the chooser; the interface shows it)
//   not ported          -> hermes-inspect, phone-detect, phone-command, phone-save, phone-setup,
//                          phone-off, phone-connect, phone-disconnect (Hermes and the phone companion)

extension Backend {
    // MARK: One setup action at a time

    /// Setup actions never overlap: a second one is refused while the first still runs.
    func exclusive<T>(_ work: () async throws -> T) async throws -> T {
        try claimSetup()
        defer { releaseSetup() }
        return try await work()
    }

    func claimSetup() throws {
        lock.lock(); defer { lock.unlock() }
        if changing { throw BlackTeamError("Another setup action is still running.") }
        changing = true
    }

    func releaseSetup() { lock.lock(); changing = false; lock.unlock() }

    private func downloadedRuntimePath() -> String { installer.installedRuntime()?.executable ?? "" }

    // MARK: Model setup

    /// Saves the setup form (`{model, workspace}`), as the "Model file" and server paths do. A model file
    /// with no runtime chosen uses the downloaded llama.cpp. Every model that is set up joins the saved list.
    public func saveSetup(_ input: JSONValue) async throws -> SavedFlag {
        try await exclusive { try await performSaveSetup(input) }
    }

    func performSaveSetup(_ input: JSONValue) async throws -> SavedFlag {
        let state = await runtime.status().state
        if isBusy || ![.off, .error].contains(state) { throw BlackTeamError("Stop the model before changing its configuration.") }
        // Only the setup form's keys are accepted.
        guard let top = input.object, top.keys.allSatisfy({ ["model", "workspace"].contains($0) }) else {
            throw BlackTeamError("Unsupported setup setting.")
        }
        let previous = try configStore.read().model
        var merged = JSONValue.encoded(previous).object ?? [:]
        let given = top["model"]?.object ?? [:]
        for (key, value) in given { merged[key] = value }
        // A saved key belongs to the address it was entered for. When the address changes, or the kind of model does (a local server
        // key must never become a cloud key, nor the other way round), the key is cleared unless a new one is given.
        if let endpoint = merged["endpoint"]?.string, given["apiKey"] == nil {
            let nowCloud = merged["source"]?.string == "cloud", wasCloud = previous.source == "cloud"
            if nowCloud != wasCloud { merged["apiKey"] = "" }
            else if nowCloud { if cloudHost(endpoint, rules: cloudRules) != cloudHost(previous.endpoint, rules: cloudRules) { merged["apiKey"] = "" } }
            else if endpoint != previous.endpoint { merged["apiKey"] = "" }
        }
        if merged["source"]?.string == "gguf", (merged["runtime"]?.string ?? "").isEmpty {
            let path = downloadedRuntimePath()
            if !path.isEmpty { merged["runtime"] = .string(path) }
        }
        // A cloud model has no file, runtime or projector of its own; none carries over from the model before it.
        if merged["source"]?.string == "cloud" { for field in ["file", "runtime", "mmproj", "draft"] where given[field] == nil { merged[field] = "" } }
        let model: ModelConfig
        do { model = try JSONDecoder().decode(ModelConfig.self, from: Data(JSONValue.object(merged).text().utf8)) }
        catch { throw BlackTeamError("These model settings are not valid.") }
        _ = try validateModelFiles(model, cloud: cloudRules)
        var save = top
        save["model"] = .object(merged)
        let next = try configStore.save(.object(save))
        // Every model that is set up joins the list, so going back to it later is one choice.
        var warning: String?
        do { _ = try savedModels.remember(next.model) } catch { warning = "Model saved. \(messageOf(error))" }
        changed()
        return SavedFlag(saved: true, warning: warning)
    }

    /// Adds models the finder turned up. A model file with no runtime uses the downloaded llama.cpp.
    public func add(models items: [JSONValue]) async throws -> AddModelsResult {
        try await exclusive {
            let path = downloadedRuntimePath()
            let prepared = items.map { item -> JSONValue in
                if item["source"]?.string != "server", (item["runtime"]?.string ?? "").isEmpty, !path.isEmpty { return item.setting("runtime", .string(path)) }
                return item
            }
            let result = try addModels(items: prepared, saved: savedModels, configStore: configStore)
            changed()
            return result
        }
    }

    public func ignore(key: String) async throws -> Bool {
        try await exclusive { try savedModels.ignore(key) }
    }

    public func switchTo(key: String) async throws -> SwitchResult {
        try await exclusive {
            let result = try await BlackTeamKit.switchModel(key: key, saved: savedModels, configStore: configStore,
                                                            stop: { try await runtime.stop(force: false) }, busy: { isBusy })
            changed()
            return result
        }
    }

    public func forget(key: String) async throws {
        try await exclusive { try forgetModel(key: key, saved: savedModels, configStore: configStore); changed() }
    }

    /// Starts the selected model in the background; the answer is the state at this moment.
    @discardableResult
    public func startModel() async throws -> RuntimeSummary {
        // A cloud model has nothing to start on this Mac.
        if try configStore.read().model.source == "cloud" { return try await runtimeSummary() }
        _ = try await exclusive {
            Task { [self] in
                _ = try? await runtime.start()
                changed()
            }
        }
        changed()
        return try await runtimeSummary()
    }

    @discardableResult
    public func stopModel() async throws -> RuntimeSummary {
        try await exclusive {
            if isBusy { throw BlackTeamError("Stop the response before stopping the model.") }
            try await runtime.stop(force: false)
        }
        changed()
        return try await runtimeSummary()
    }

    /// Whether starting the selected model now would first need a yes to stop another model server that holds the memory.
    /// Nothing is stopped by asking. A cloud model, or one that is running, never needs it.
    public func startApproval() async throws -> StopApproval? {
        if try configStore.read().model.source == "cloud" { return nil }
        let question = try await runtime.startApproval()
        if question != nil { changed() }
        return question
    }

    /// The person said yes: stops that one model server (SIGTERM, then waits), then starts the selected model in the background.
    @discardableResult
    public func approveStop(pid: Int) async throws -> RuntimeSummary {
        _ = try await exclusive { try await runtime.approveStop(pid: pid) }
        changed()
        return try await startModel()
    }

    /// The person said no: the question goes away, and nothing was stopped or started.
    public func declineStop() async {
        await runtime.declineStop()
        changed()
    }

    func runtimeSummary() async throws -> RuntimeSummary {
        let config = try configStore.read()
        if config.model.source == "cloud" {
            return RuntimeSummary(state: setupComplete(config) ? "ready" : "off", ready: setupComplete(config), busy: isBusy, name: config.model.name, error: nil, features: [],
                                  kind: "cloud", provider: cloudHost(config.model.endpoint, rules: cloudRules))
        }
        let state = await runtime.status()
        return RuntimeSummary(state: state.state.rawValue, ready: state.ready, busy: state.busy, name: try configStore.read().model.name,
                              error: state.error, features: state.features, approval: state.approval)
    }

    // MARK: Finding models

    /// Asks a local server which models it offers. A saved key is used when the address is the saved one.
    public func discoverServer(endpoint: String, apiKey: String? = nil) async throws -> DiscoveredModels {
        let saved = try configStore.read().model
        return try await discoverModels(endpoint: endpoint, apiKey: apiKey ?? (endpoint == saved.endpoint ? saved.apiKey : ""), fetch: fetch)
    }

    /// Looks for running servers and model files. The downloaded llama.cpp is the runtime they would use.
    /// Once Black Team is set up, every found model that can run joins the list, so a model that turns up
    /// later works like the ones chosen at setup. One the person removed or passed over stays out.
    public func findMyModels() async -> FoundModelsReport {
        let downloaded = downloadedRuntimePath()
        let found = await findModels(home: home, fetch: fetch, runtime: downloaded.isEmpty ? discoveryRuntime() : downloaded, dataFolder: dataFolder)
        var report = await marked(found)
        report.added = await connect(report)
        return report.added.isEmpty ? report : await marked(found, added: report.added)
    }

    /// Adds what was found and is not in the list yet. Returns the names added.
    private func connect(_ report: FoundModelsReport) async -> [String] {
        guard let config = try? configStore.read(), setupComplete(config) else { return [] }
        let saved = savedModels.read()
        // llama.cpp names a served model by its file. So a saved server entry and that file are one model, and a
        // file Black Team is serving itself is the saved file, not somebody's server.
        let known = Set(saved.flatMap { [$0.file, $0.id] }.filter { $0.hasPrefix("/") })
        let own = await runtime.status().port.map { "http://127.0.0.1:\($0)/v1" }
        var items: [JSONValue] = []
        for item in report.servers where !item.saved && !item.ignored && item.server.endpoint != own && !known.contains(item.server.id) { items.append(item.server.json) }
        for item in report.files where !item.saved && !item.ignored && !item.file.runtime.isEmpty && !item.file.tooBig && !known.contains(item.file.file) { items.append(item.file.json) }
        // The list has a size limit; what does not fit stays an offer.
        items = Array(items.prefix(max(0, 24 - saved.count)))
        guard !items.isEmpty, let result = try? await add(models: items) else { return [] }
        return result.added
    }

    private func marked(_ found: FoundModels, added: [String] = []) async -> FoundModelsReport {
        let have = Set(savedModels.list().map(\.key)), passed = Set(savedModels.ignored())
        let served = Set(savedModels.read().filter { $0.source == "server" && $0.id.hasPrefix("/") }.map(\.id))
        let servers = found.servers.map { item -> MarkedServer in
            let key = keyOf(ModelConfig(source: "server", endpoint: item.endpoint, id: item.id))
            return MarkedServer(server: item, key: key, saved: have.contains(key), ignored: passed.contains(key))
        }
        let files = found.files.map { item -> MarkedFile in
            let key = keyOf(ModelConfig(source: "gguf", file: item.file))
            // A file a saved server entry serves is already in the list, under that entry.
            return MarkedFile(file: item, key: key, saved: have.contains(key) || served.contains(item.file), ignored: passed.contains(key))
        }
        return FoundModelsReport(servers: servers, files: files, runtime: found.runtime, looked: .init(ports: found.looked.ports, folders: found.looked.folders), added: added)
    }

    private func discoveryRuntime() -> String { discovery.get().runtime }

    /// A chosen model file, read for its name, a context that fits, and the files that belong beside it.
    public func inspectModelFile(_ file: String) throws -> ModelInspection {
        let info = try inspectModel(file)
        let described = describeFile(file, bytes: info.bytes)
        let beside = companionsFor(file)
        return ModelInspection(name: described.name, trainingContext: described.trainingContext, context: described.context,
                               bytes: info.bytes, mmproj: beside.mmproj, draft: beside.draft)
    }

    // MARK: Agent apps

    public func discoverApps() -> DiscoveryResult { discoverInstalled() }

    @discardableResult
    public func saveIntegrations(_ value: JSONValue) async throws -> SavedFlag {
        try await exclusive {
            if isBusy { throw BlackTeamError("Wait for the current task before changing integrations.") }
            _ = try integrations.save(value)
            changed()
            return SavedFlag(saved: true)
        }
    }

    public func connect(harness id: String) async throws -> ConnectResult {
        try await exclusive {
            if isBusy { throw BlackTeamError("Wait for the current task before changing integrations.") }
            return try connectHarness(id: id, store: integrations, found: discoverInstalled())
        }
    }

    /// Starts the model if needed and opens the app in a terminal, pointed at it.
    public func launch(harness id: String) async throws -> LaunchResult {
        // Agent apps are pointed at the local model; none is launched against a cloud one for now.
        if try configStore.read().model.source == "cloud" { throw BlackTeamError(cloudHarnessRefusal) }
        return try await exclusive {
            if isBusy { throw BlackTeamError("Wait for the current task before launching another harness.") }
            return try await launchHarness(id: id, store: integrations, config: try configStore.read(), runtime: harness, stateDir: dataFolder, open: terminal)
        }
    }

    // MARK: Things the interface opens or shows

    /// The page that explains how to install something Black Team can connect to.
    public func helpLink(topic: String) throws -> String {
        let links = ["ollama": "https://ollama.com/download/mac", "lmstudio": "https://lmstudio.ai/download",
                     "tailscale": "https://tailscale.com/download/mac", "hermes": "https://github.com/NousResearch/hermes-agent#installation"]
        guard let link = links[topic] else { throw BlackTeamError("Unsupported setup help.") }
        return link
    }

    /// The application data folder, for "Open data folder".
    public func dataFolderPath() throws -> String {
        guard CoreFS.exists(dataFolder) else { throw BlackTeamError("Could not open the application data folder.") }
        return dataFolder
    }

    /// What a file or folder chooser should offer for a kind of choice.
    public func pickerRequest(_ kind: String) throws -> PickerRequest {
        switch kind {
        case "model": return PickerRequest(title: "Choose a local GGUF model", directory: false, extensions: ["gguf"])
        case "runtime": return PickerRequest(title: "Choose llama-server from its extracted release", directory: false, extensions: [])
        case "executable": return PickerRequest(title: "Choose the application executable", directory: false, extensions: [])
        case "workspace": return PickerRequest(title: "Choose your workspace", directory: true, extensions: [])
        default: throw BlackTeamError("Unsupported chooser.")
        }
    }

    // MARK: Starter models (new on the Mac)

    /// The starter catalogue, with what is installed and the recommendation for this Mac.
    public func starterModels(memoryBytes: Int64? = nil) -> StarterCatalogue {
        let memory = memoryBytes ?? Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        let recommended = StarterModels.recommended(forMemoryBytes: memory)
        let folder = URL(fileURLWithPath: dataFolder)
        let entries = StarterModels.all.map {
            StarterEntry(model: $0, installed: $0.isInstalled(in: folder), recommended: $0.id == recommended.id, fits: $0.minimumMemoryBytes <= memory / 10 * 6)
        }
        return StarterCatalogue(models: entries, recommendedID: recommended.id, memoryBytes: memory, runtime: installer.installedRuntime())
    }

    /// The llama.cpp runtime Black Team downloaded, if one is installed.
    public func installedRuntime() -> InstalledRuntime? { installer.installedRuntime() }

    /// Stops a running `setUpStarter` download; what was downloaded is kept so it can resume.
    public func cancelSetUp() {
        installer.cancel()
        let downloads = locked { setupDownloads }
        downloads.forEach { $0.cancel() }
    }

    /// The downloaded llama.cpp program, if one is installed.
    public func downloadedRuntime() -> InstalledRuntime? { installer.installedRuntime() }

    /// Downloads and installs the llama.cpp runtime on its own (no model), unless one is installed already.
    @discardableResult
    public func installRuntime(progress: (@Sendable (SetupProgress) -> Void)? = nil) async throws -> InstalledRuntime {
        if let existing = installer.installedRuntime() { return existing }
        let report: @Sendable (SetupProgress) -> Void = { progress?($0) }
        return try await installer.installLatest { event in
            switch event {
            case .checking: report(SetupProgress(stage: "Looking for the llama.cpp runtime\u{2026}"))
            case .downloading(let p): report(SetupProgress(stage: "Downloading the llama.cpp runtime", fraction: p.fraction, bytesPerSecond: p.bytesPerSecond))
            case .extracting: report(SetupProgress(stage: "Unpacking the llama.cpp runtime\u{2026}"))
            case .verifying: report(SetupProgress(stage: "Checking the llama.cpp runtime\u{2026}"))
            case .done: break
            }
        }
    }

    /// Downloads the llama.cpp runtime if none is installed, downloads the chosen model, then saves the model
    /// as the "Model file" setup would (source file, the downloaded `llama-server`, the model's recommended
    /// context, its name) and remembers it, so the next message starts it.
    @discardableResult
    public func setUpStarter(modelID: String, progress: (@Sendable (SetupProgress) -> Void)? = nil) async throws -> StarterSetupResult {
        guard let model = StarterModels.model(id: modelID) else { throw BlackTeamError("That starter model is not in the list.") }
        return try await exclusive {
            let state = await runtime.status().state
            if isBusy || ![.off, .error].contains(state) { throw BlackTeamError("Stop the model before changing its configuration.") }
            let report: @Sendable (SetupProgress) -> Void = { progress?($0) }
            let folder = URL(fileURLWithPath: dataFolder)
            let downloader = makeDownloader()
            locked { setupDownloads = [downloader] }
            defer { locked { setupDownloads = [] } }
            return try await withTaskCancellationHandler {
                var runtimeInfo = installer.installedRuntime()
                if runtimeInfo == nil {
                    report(SetupProgress(stage: "Looking for the llama.cpp runtime\u{2026}"))
                    runtimeInfo = try await installer.installLatest { event in
                        switch event {
                        case .checking: report(SetupProgress(stage: "Looking for the llama.cpp runtime\u{2026}"))
                        case .downloading(let p): report(SetupProgress(stage: "Downloading the llama.cpp runtime", fraction: p.fraction, bytesPerSecond: p.bytesPerSecond))
                        case .extracting: report(SetupProgress(stage: "Unpacking the llama.cpp runtime\u{2026}"))
                        case .verifying: report(SetupProgress(stage: "Checking the llama.cpp runtime\u{2026}"))
                        case .done: report(SetupProgress(stage: "The llama.cpp runtime is ready", fraction: 1))
                        }
                    }
                }
                guard let runtimeInfo else { throw BlackTeamError("The llama.cpp runtime could not be installed.") }
                if Task.isCancelled { throw CancellationError() }
                if !model.isInstalled(in: folder) {
                    report(SetupProgress(stage: "Downloading \(model.name)"))
                    try await StarterModels.install(model, dataFolder: folder, downloader: downloader) {
                        report(SetupProgress(stage: "Downloading \(model.name)", fraction: $0.fraction, bytesPerSecond: $0.bytesPerSecond))
                    }
                } else {
                    report(SetupProgress(stage: "\(model.name) is already downloaded", fraction: 1))
                }
                if Task.isCancelled { throw CancellationError() }
                report(SetupProgress(stage: "Saving the model setup\u{2026}"))
                let file = model.destination(in: folder).path
                let threads = max(1, min(64, SystemInfo.cpuTopology().cores))
                let form: JSONValue = ["model": ["source": "gguf", "name": .string(model.name), "file": .string(file), "runtime": .string(runtimeInfo.executable),
                                                 "context": .number(Double(model.contextSize)), "gpuLayers": 0, "threads": .number(Double(threads)),
                                                 "mmproj": "", "draft": ""]]
                let saved = try await performSaveSetup(form)
                report(SetupProgress(stage: "Ready", fraction: 1))
                return StarterSetupResult(modelName: model.name, file: file, runtime: runtimeInfo.executable, runtimeTag: runtimeInfo.tag, warning: saved.warning)
            } onCancel: {
                downloader.cancel()
                self.installer.cancel()
            }
        }
    }
}
