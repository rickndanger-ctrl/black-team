import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The app's brain with no window and no HTTP: the logic `lib/server.cjs` kept behind its
// routes and `main.cjs` behind its IPC channels. The Mac app calls it directly.
//
// Thread safety: every mutable field is guarded by `lock`, and long work runs in Tasks, so any
// method can be called from the main actor. Methods that wait (`status`, setup actions) are async.

private let MODES = ["fast", "balanced", "deep", "extended"]
private let projectNamePattern = #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}\z"#

/// What is installed on this Mac is looked up once; graphify, when present, gives Code a map of the workspace.
final class DiscoveryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var found: DiscoveryResult?
    private let discover: @Sendable () -> DiscoveryResult
    init(_ discover: @escaping @Sendable () -> DiscoveryResult) { self.discover = discover }
    func get() -> DiscoveryResult {
        lock.lock(); defer { lock.unlock() }
        if let found { return found }
        let result = discover()
        found = result
        return result
    }
}

public final class Backend: @unchecked Sendable {
    public let dataFolder: String
    public let version: String
    public let configStore: ConfigStore
    public let history: History
    public let savedModels: SavedModels
    public let memory: Memory
    public let integrations: Integrations
    public let images: ImageStore
    let runtime: BackendRuntime
    let engine: CodeEngine?
    let fetch: HTTPFetch
    let stream: HTTPStreamFetch
    let planner: ContextPlanning
    let discovery: DiscoveryCache
    let installer: RuntimeProviding
    let makeDownloader: @Sendable () -> FileDownloading
    let terminal: TerminalOpener
    let now: @Sendable () -> Date
    let cloudRules: CloudRules
    let capabilities: CloudCapabilities
    /// Starts Claude Code and Codex (`ProcessAgentLauncher` in the app; tests feed recorded output).
    let agentLauncher: AgentLauncher
    /// Copies of the workspace taken before each subscription-agent run, for rollback.
    let snapshots: AgentSnapshots
    let home: String
    let harness: HarnessRuntimeAdapter
    let hub = ChangeHub()
    let cpuSampler = CPUSampler()

    let lock = NSLock()
    var job: JobState?
    var abort: CancelSignal?
    var active: Task<Void, Never>?
    var cancelTask: Task<Void, Never>?
    var liveThread: ThreadRef?
    var closing = false
    var changing = false
    var lastActivity: Date
    var projects: [Project] = []
    var keeperLog: [KeeperEntry] = []
    var hardwareCache: HardwareSummary?
    var hardwareAt: Date = .distantPast
    var serverPid: Int?
    var serverPidAt: Date = .distantPast
    var keeperTask: Task<Void, Never>?
    var setupDownloads: [FileDownloading] = []
    /// Phone access (Phone/PhoneService.swift): made on first use, so a Backend that never uses it opens no socket.
    var phoneService: PhoneService?
    var phoneOptions = PhoneOptions()
    /// The team run in progress (App/BackendTeam.swift); nil when none is running.
    var teamControl: TeamControl?

    private var keeperFile: String { dataFolder + "/keeper.json" }
    private var projectsFile: String { dataFolder + "/projects.json" }

    /// Everything that touches the system can be replaced, as the JavaScript's `createBackend` allowed.
    public init(dataFolder: String = AppPaths.dataFolder(), version: String = "0.1.0-alpha.1",
                runtime customRuntime: BackendRuntime? = nil, engine customEngine: CodeEngine? = nil, memory customMemory: Memory? = nil,
                fetch: @escaping HTTPFetch = LocalHTTP.fetch, stream: @escaping HTTPStreamFetch = LocalHTTP.stream,
                contextPlanner: ContextPlanning? = nil,
                discover: @escaping @Sendable () -> DiscoveryResult = { discoverInstalled() },
                runtimeInstaller: RuntimeProviding? = nil, downloader: @escaping @Sendable () -> FileDownloading = { Downloader() },
                terminal: @escaping TerminalOpener = openInTerminal, now: @escaping @Sendable () -> Date = { Date() }, home: String = NSHomeDirectory(),
                keeperInterval: TimeInterval = 60, cloud: CloudRules = .standard, agents: AgentLauncher = ProcessAgentLauncher()) throws {
        self.dataFolder = dataFolder
        self.version = version
        self.cloudRules = cloud
        agentLauncher = agents
        snapshots = AgentSnapshots(dataFolder: dataFolder)
        capabilities = CloudCapabilities(dataFolder: dataFolder)
        try privateDirectory(dataFolder)
        configStore = try ConfigStore(stateDir: dataFolder, cloud: cloud)
        savedModels = try SavedModels(stateDir: dataFolder, cloud: cloud)
        // Someone who set up a model before the list existed sees it there from the start.
        if let current = try? configStore.read().model, savedModels.read().isEmpty,
           (current.source == "cloud" ? !current.id.isEmpty && !current.apiKey.isEmpty
            : current.source == "server" ? !current.id.isEmpty : (!current.file.isEmpty && !current.runtime.isEmpty)) {
            _ = try? savedModels.remember(current)
        }
        integrations = Integrations(stateDir: dataFolder)
        images = ImageStore(dataFolder: dataFolder)
        history = try History(stateDir: dataFolder)
        // The Black Team vault: what the local models remember. It lives in the private data folder only.
        memory = try customMemory ?? Memory(vault: dataFolder + "/vault")
        let cache = DiscoveryCache(discover)
        discovery = cache
        let backendRuntime = customRuntime ?? ModelRuntime(configStore: configStore)
        runtime = backendRuntime
        engine = try customEngine ?? Engine(stateDir: dataFolder, vault: memory, fetch: stream, graph: { cache.get().graph }, cloud: cloud)
        self.fetch = fetch
        self.stream = stream
        planner = contextPlanner ?? { messages, context, mode, endpoint, headers, signal in
            try await prepareContext(messages: messages, context: context, mode: mode, endpoint: endpoint, headers: headers, fetch: fetch, signal: signal)
        }
        installer = runtimeInstaller ?? RuntimeInstaller(dataFolder: URL(fileURLWithPath: dataFolder))
        makeDownloader = downloader
        self.terminal = terminal
        self.now = now
        self.home = home
        harness = HarnessRuntimeAdapter(backendRuntime)
        lastActivity = now()
        // The keeper's record of its upkeep, newest first, so memory housekeeping is visible.
        if let data = FileManager.default.contents(atPath: dataFolder + "/keeper.json"),
           let saved = try? JSONDecoder().decode([KeeperEntry].self, from: data) {
            keeperLog = Array(saved.filter { $0.at.isFinite }.prefix(40))
        }
        if let data = FileManager.default.contents(atPath: dataFolder + "/projects.json"),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = Array(saved.filter { History.validID($0.id) && $0.workspace.hasPrefix("/") }.prefix(200))
        }
        startKeeper(interval: keeperInterval)
    }

    // MARK: Observation

    /// Fires (coalesced) whenever a job, a conversation or the runtime changes. Read `status()` or the
    /// thread again when it does. The stream ends at `shutdown()`.
    public func changes() -> AsyncStream<Void> { hub.stream() }

    func changed() { hub.notify() }

    // MARK: Status

    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }

    /// Runs `body` holding the lock. Async code uses this rather than calling `lock()` itself.
    @discardableResult
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// Resolves when the running job (if any) has finished and been saved.
    public func waitForIdle() async {
        let (task, cancelling) = locked { (active, cancelTask) }
        await task?.value
        await cancelling?.value
    }

    private func modelMemory(_ config: Config, pid known: Int?) -> ProcessMemory? {
        var pid = known
        if pid == nil, config.model.source == "server" {
            lock.lock()
            if Date().timeIntervalSince(serverPidAt) > 15 {
                let port = URLComponents(string: config.model.endpoint)?.port
                serverPid = port.flatMap { SystemInfo.serverProcess($0) }
                serverPidAt = Date()
            }
            pid = serverPid
            lock.unlock()
        }
        return pid.flatMap { SystemInfo.processMemory($0) }
    }

    func setupComplete(_ config: Config) -> Bool {
        switch config.model.source {
        case "cloud": return !config.model.id.isEmpty && !config.model.endpoint.isEmpty && !config.model.apiKey.isEmpty
        case "server": return !config.model.id.isEmpty && !config.model.endpoint.isEmpty
        default: return !config.model.file.isEmpty && !config.model.runtime.isEmpty
        }
    }

    /// The same information `status('desktop')` returned.
    public func status() async throws -> BackendStatus {
        let config = try configStore.read()
        let state = await runtime.status()
        let pid = await runtime.modelPid()
        let (snapshot, projectRows) = locked { (job?.snapshot, projects) }
        let info = SystemInfo.memoryInfo()
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let performance = PerformanceSummary(
            cpu: cpuSampler.sample(), cores: ProcessInfo.processInfo.processorCount, load: loads[0],
            memory: PerformanceMemory(total: info.total, free: info.available, used: info.used, swapTotal: info.swapTotal, swapUsed: info.swapUsed),
            temperature: SystemInfo.cpuTemperature()?.celsius, model: modelMemory(config, pid: pid))
        let (cached, age) = locked { (hardwareCache, Date().timeIntervalSince(hardwareAt)) }
        var hardware: HardwareSummary
        if let cached, age <= 5 { hardware = cached } else {
            let report = await hardwareReport(stateDir: dataFolder)
            var warnings: [String] = []
            let size = CoreFS.stat(config.model.file)
            if size.error == 0, let warning = estimateMemory(size.size, totalBytes: report.memory.total, freeBytes: report.memory.free).warning { warnings.append(warning) }
            hardware = HardwareSummary(platform: report.platform, arch: report.arch, cpu: report.cpu, memory: report.memory, disk: report.disk,
                                       cores: report.cpu.cores, threads: report.cpu.threads, warnings: warnings)
            locked { hardwareCache = hardware; hardwareAt = Date() }
        }
        let model = config.model
        let cloudModel = model.source == "cloud"
        let host = cloudModel ? cloudHost(model.endpoint, rules: cloudRules) : ""
        // A cloud model has no process of its own: it is "ready" when it is set up, and busy while a reply is being written.
        let runtimeSummary = cloudModel
            ? RuntimeSummary(state: setupComplete(config) ? "ready" : "off", ready: setupComplete(config), busy: snapshot?.state == "running" && snapshot?.kind != "memory", name: model.name, error: nil, features: [], kind: "cloud", provider: host)
            : RuntimeSummary(state: state.state.rawValue, ready: state.ready, busy: state.busy, name: model.name, error: state.error, features: state.features)
        let listed = savedModels.list(active: model)
        let localAlternative = listed.first { !$0.isCloud }
        return BackendStatus(
            version: version, setupComplete: setupComplete(config),
            runtime: runtimeSummary,
            threads: history.list(), job: snapshot.map(JobSummary.init), agentEnabled: true,
            projects: projectRows.map(summary), memory: true, codeMap: !discovery.get().graph.isEmpty, performance: performance,
            config: PublicConfig(schemaVersion: config.schemaVersion, model: PublicModelConfig(
                source: model.source, endpoint: model.endpoint, id: model.id, name: model.name, file: model.file, runtime: model.runtime,
                context: model.context, gpuLayers: model.gpuLayers, threads: model.threads, mmproj: model.mmproj, draft: model.draft,
                kind: cloudModel ? "cloud" : "local", provider: host), workspace: config.workspace),
            models: listed, serverKeyConfigured: !model.apiKey.isEmpty,
            integrations: try? integrations.read(), hardware: hardware, downloadedRuntime: installer.installedRuntime(),
            vision: visionStatus(config.model),
            cloud: CloudStatus(selected: cloudModel, provider: host, modelName: cloudModel ? model.name : "", localModelName: localAlternative?.name ?? "", localModelKey: localAlternative?.key ?? ""))
    }

    // MARK: Conversations

    /// A conversation as the interface reads it. While it is being written this is the live copy.
    public func thread(_ id: String) -> JSONValue? {
        lock.lock(); let live = liveThread; lock.unlock()
        var found: JSONValue?
        if let live, live.value["id"]?.string == id { found = live.value } else { found = history.get(id) }
        guard let thread = found else { return nil }
        var view: JSONValue = ["id": thread["id"] ?? .null, "title": thread["title"] ?? .null, "updated": thread["updated"] ?? .null,
                               "kind": .string(thread["kind"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "chat"), "messages": thread["messages"] ?? [],
                               "privacy": .string(thread["privacy"]?.string == "cloud" ? "cloud" : "local")]
        // Where a cloud conversation went, and what it has used. The host name only: no address, no key.
        // Which subscription agent the conversation belongs to, so the interface can keep continuing it with that agent.
        if let engine = thread["engine"]?.string, !engine.isEmpty { view = view.setting("engine", .string(engine)) }
        if thread["privacy"]?.string == "cloud" {
            view = view.setting("provider", thread["provider"] ?? "")
            if let usage = thread["usage"] { view = view.setting("usage", usage) }
        }
        return view
    }

    public func threads() -> [ThreadSummary] { history.list() }

    /// A saved request: its conversation and how it ended.
    public func request(_ id: String) -> SubmitResult? {
        guard let saved = history.request(id), let threadId = saved["threadId"]?.string else { return nil }
        return SubmitResult(id: saved["id"]?.string ?? id, threadId: threadId, state: saved["state"]?.string ?? "")
    }

    /// Changes a conversation's title (up to 200 characters). Not while that conversation is being written.
    public func renameThread(_ id: String, title: String) throws {
        let name = EText.prefix(EText.trim(title).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression), 200)
        if name.isEmpty { throw BlackTeamError("Enter a title.") }
        lock.lock(); let running = active != nil && job?.threadId == id; lock.unlock()
        if running { throw BlackTeamError("Wait for the running task to finish, or stop it, before renaming this conversation.") }
        guard let thread = history.get(id) else { throw BlackTeamError("Conversation not found.") }
        try history.save(thread.setting("title", .string(name)))
        changed()
    }

    func persist(_ thread: JSONValue) throws {
        try history.save(thread)
        changed()
    }

    // MARK: Submit

    /// Starts one turn of Chat (`kind` "chat") or Code (`kind` "agent") and returns at once; the job
    /// runs in the background. A repeated `requestId` returns the saved outcome and starts nothing.
    @discardableResult
    public func submit(message rawMessage: String, kind: String = "chat", mode: String = "balanced", requestId: String,
                       threadId givenThread: String? = nil, project givenProject: String? = nil,
                       workspace workspaceOverride: String? = nil, images uploads: [ImageUpload] = [], from origin: SubmitOrigin = .mac,
                       useMemory: Bool = true) throws -> SubmitResult {
        if locked({ closing }) { throw BlackTeamError("Black Team is closing.") }
        // Images are Chat only, and an empty message with images asks for a description, as the daily app does.
        let kinds = try ImageRules.validate(uploads)
        if !uploads.isEmpty, kind == "agent" { throw BlackTeamError(ImageRules.codeRefusal) }
        let message = uploads.isEmpty || !EText.trim(rawMessage).isEmpty ? EText.trim(rawMessage) : ImageRules.defaultMessage
        if message.isEmpty || EText.length(message) > 16000 { throw BlackTeamError("Enter a message of up to 16,000 characters.") }
        if !["chat", "agent"].contains(kind) { throw BlackTeamError("Choose Chat or Agent work.") }
        if !MODES.contains(mode) { throw BlackTeamError("Choose a supported response length.") }
        if !History.validID(requestId) { throw BlackTeamError("A valid request ID is required.") }
        let threadId = givenThread.flatMap { $0.isEmpty ? nil : $0 }
        if let threadId, !History.validID(threadId) { throw BlackTeamError("Invalid conversation ID.") }
        if let givenProject, !History.validID(givenProject) { throw BlackTeamError("Invalid project.") }
        var parts: [JSONValue] = [threadId.map { .string($0) } ?? .null, .string(message), .string(mode)]
        if kind == "agent" { parts.append(.string(kind)) }
        if let givenProject { parts.append(.string(givenProject)) }
        if !uploads.isEmpty { parts.append(ImageRules.digest(uploads)) }
        let hash = SHA256.hash(data: Data(JSONValue.array(parts).text().utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = history.request(requestId) {
            if saved["hash"]?.string != hash { throw BlackTeamError("Request ID was already used for another message.") }
            return SubmitResult(id: saved["id"]?.string ?? requestId, threadId: saved["threadId"]?.string ?? "", state: saved["state"]?.string ?? "")
        }

        lock.lock(); defer { lock.unlock() }
        if active != nil { throw BlackTeamError("A response is already running. Wait or stop it before sending another.") }
        let config = try configStore.read()
        if !setupComplete(config) {
            throw BlackTeamError("Complete model setup in the desktop app first.")
        }
        let existing = threadId.flatMap { history.get($0) }
        if threadId != nil && existing == nil { throw BlackTeamError("Conversation not found.") }
        // A conversation with a subscription agent continues only with that agent (`submitAgentTask`), never through this path.
        if let existing, let agent = AgentService.forEngine(existing["engine"]?.string) {
            throw BlackTeamError(agentConversationRefusal(agent))
        }
        if let existing, (existing["kind"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "chat") != kind {
            throw BlackTeamError("Start a new conversation to change between Chat and Agent work.")
        }
        // A conversation started inside a project belongs to it, and its Code work happens in the project's folder.
        let wanted = existing != nil ? existing?["project"]?.string : givenProject
        let project = projects.first { $0.id == wanted }
        if existing == nil, givenProject != nil, project == nil { throw BlackTeamError("That project no longer exists.") }
        // Privacy travels with the work: a private conversation is never sent to a cloud model, a project that is local only
        // never uses one, and a phone never starts a cloud conversation. Decided here, whatever the interface did first.
        let privacy = privacyDecision(config: config, existing: existing, project: project, kind: kind, viaPhone: origin == .phone)
        if let refusal = privacy.refusal { throw BlackTeamError(refusal) }
        let cloudModel = config.model.source == "cloud"
        // Code runs on Black Team's own engine. Hermes conversations are not available on the Mac.
        var agentEngine: String?
        if kind == "agent" {
            agentEngine = existing.map { $0["engine"]?.string ?? ($0["hermesSession"] != nil ? "hermes" : "black-team") } ?? "black-team"
            if agentEngine == "hermes" {
                throw BlackTeamError("This conversation uses Hermes. Enable it in desktop Settings, or start a new Code conversation.")
            }
            if engine == nil { throw BlackTeamError("Code is unavailable in this build.") }
        }
        if !uploads.isEmpty, config.model.source == "gguf", config.model.mmproj.isEmpty { throw BlackTeamError(ImageRules.needsVisionFile) }
        var thread = existing ?? history.create(message)
        thread = thread.setting("kind", .string(kind))
        // The conversation's level is fixed by the model it is started with, and shown for as long as it exists.
        if existing == nil {
            thread = thread.setting("privacy", .string(cloudModel ? "cloud" : "local"))
            if cloudModel { thread = thread.setting("provider", .string(cloudHost(config.model.endpoint, rules: cloudRules))) }
        }
        if let agentEngine { thread = thread.setting("engine", .string(agentEngine)) }
        // A run that must not touch the memory vault (a team with a cloud member passes local members' results on): this conversation
        // gets no Core, no recalled notes, no memory tools and no journal entry, the same as a conversation that went to a cloud service.
        if !useMemory { thread = thread.setting("noMemory", .bool(true)) }
        if existing == nil, let project { thread = thread.setting("project", .string(project.id)) }
        // A folder given for this one turn (the command-line tool's --workspace) wins over the project and the setting.
        let workspace = try workspaceOverride.map { try ensureWorkspace($0) } ?? project?.workspace ?? config.workspace
        var messages = thread["messages"]?.array ?? []
        if messages.count >= 1000 || (try? JSONEncoder().encode(thread).count) ?? 0 > 5 * 1024 * 1024 {
            throw BlackTeamError("This conversation is full. Start a new conversation.")
        }
        let assistant: JSONValue = ["id": .string(UUID().uuidString.lowercased()), "role": "assistant", "content": "", "state": "writing", "model": .string(config.model.name)]
        // The files are written only now that every check has passed, so a refused message leaves none behind.
        let refs = uploads.isEmpty ? [] : try images.save(uploads, kinds: kinds, threadId: thread["id"]?.string ?? "")
        var userMessage: JSONValue = ["id": .string(UUID().uuidString.lowercased()), "role": "user", "content": .string(message), "state": "done"]
        if !refs.isEmpty { userMessage = userMessage.setting("images", .array(refs.map(\.json))) }
        messages.append(userMessage)
        messages.append(assistant)
        let request: JSONValue = ["id": .string(requestId), "hash": .string(hash), "state": "running"]
        var requests = thread["requests"]?.array ?? []
        requests.append(request)
        thread = thread.setting("messages", .array(messages)).setting("requests", .array(requests)).setting("updated", .string(EText.iso(now())))
        // Saved before the request is remembered, so a failed save leaves no trace and the ID can be retried.
        do { try history.save(thread) } catch { images.remove(refs, threadId: thread["id"]?.string ?? ""); throw error }
        history.remember(&thread, request)

        let current = JobState(id: requestId, threadId: thread["id"]?.string, kind: kind, state: "running",
                               progress: cloudModel ? "Contacting \(cloudHost(config.model.endpoint, rules: cloudRules))\u{2026}" : "Preparing local model\u{2026}")
        _ = current.observe { [hub] _ in hub.notify() }
        let signal = CancelSignal()
        let ref = ThreadRef(thread)
        job = current; abort = signal; liveThread = ref
        active = Task { [self] in
            await runJob(job: current, signal: signal, ref: ref, request: request, config: config, kind: kind, mode: mode, project: project, workspace: workspace)
        }
        hub.notify()
        return SubmitResult(id: requestId, threadId: thread["id"]?.string ?? "", state: "running")
    }

    private func runJob(job: JobState, signal: CancelSignal, ref: ThreadRef, request: JSONValue, config: Config, kind: String, mode: String,
                        project: Project?, workspace: String) async {
        var outcomeState = "done"
        var outcomeText = kind == "agent" ? "Agent task complete" : "Response complete"
        var failure: String?
        func check() throws { if signal.isCancelled { throw CancellationError() } }
        let cloudModel = config.model.source == "cloud"
        do {
            try check()
            let endpoint: String
            let headers: [String: String]
            if cloudModel {
                // A cloud model has no process to start. The address is checked again here, so the key goes only to its own host.
                endpoint = try cloudRules(config.model.endpoint).base
                headers = try cloudHeaders(config.model.apiKey)
            } else {
                endpoint = try await runtime.start()
                try check()
                try await runtime.setBusy(true)
                headers = try await runtime.requestHeaders()
            }
            if kind == "agent" {
                job.progress = "Starting Black Team Code\u{2026}"
                guard let engine else { throw BlackTeamError("Code is unavailable in this build.") }
                try await engine.run(thread: ref, config: config, runtime: StartedRuntimeHeaders(headers), endpoint: endpoint, job: job, signal: signal,
                                     save: { [weak self] thread in try self?.persist(thread) }, mode: mode, workspace: workspace)
                try check()
            } else {
                try await chatTurn(job: job, signal: signal, ref: ref, config: config, mode: mode, project: project, endpoint: endpoint, headers: headers)
            }
        } catch {
            let cancelled = signal.isCancelled
            outcomeState = cancelled ? "interrupted" : "error"
            // Whatever a service wrote back into an error, the key is not shown.
            let text = redactSecrets(messageOf(error), keys: [config.model.apiKey])
            failure = cancelled ? "Response stopped." : (text.isEmpty ? (cloudModel ? "The cloud response failed." : "The local response failed.") : text)
            outcomeText = failure!
        }
        if !cloudModel { try? await runtime.setBusy(false) }
        // The terminal state is announced only after the conversation is saved, so a reader that reacts to it sees the final text.
        var thread = ref.value
        var saved: JSONValue = request
        saved = saved.setting("state", .string(outcomeState))
        var messages = thread["messages"]?.array ?? []
        if !messages.isEmpty {
            var last = messages[messages.count - 1].object ?? [:]
            last["state"] = .string(outcomeState)
            if let failure { last["error"] = .string(failure) }
            messages[messages.count - 1] = .object(last)
        }
        thread = thread.setting("messages", .array(messages)).setting("updated", .string(EText.iso(now())))
        history.remember(&thread, saved)
        var finalState = outcomeState, finalText = outcomeText
        do { try history.save(thread) } catch { finalState = "error"; finalText = "Could not save this conversation. Check available disk space." }
        ref.value = thread
        job.state = finalState
        job.progress = finalText
        locked { abort = nil; active = nil; liveThread = nil; lastActivity = now() }
        sweepMemory()
        changed()
    }

    /// One Chat turn: memory core and lookup, context preparation, then the streamed reply.
    private func chatTurn(job: JobState, signal: CancelSignal, ref: ThreadRef, config: Config, mode: String, project: Project?,
                          endpoint: String, headers: [String: String]) async throws {
        func check() throws { if signal.isCancelled { throw CancellationError() } }
        if config.model.source == "cloud" {
            try await cloudChatTurn(job: job, signal: signal, ref: ref, config: config, mode: mode)
            return
        }
        // A conversation that went to a cloud service never gets the vault, even when a local model answers it now.
        let memoryAllowed = ref.value["privacy"]?.string != "cloud" && ref.value["noMemory"]?.bool != true
        // Core memory is fixed when the conversation starts, and what was recalled for a message stays attached to it,
        // so earlier turns are sent the same way every time and the model server's prompt cache keeps working.
        var thread = ref.value
        if memoryAllowed, thread["core"] == nil { thread = thread.setting("core", .string(memory.core())) }
        var messages = thread["messages"]?.array ?? []
        let askedAt = messages.count - 2
        if memoryAllowed, askedAt >= 0, messages[askedAt]["recalled"] == nil {
            let asked = messages[askedAt]["content"]?.string ?? ""
            let hits = (try? await memory.lookup(asked, project?.workspace)) ?? []
            messages[askedAt] = messages[askedAt].setting("recalled", JSONValue.encoded(hits))
        }
        thread = thread.setting("messages", .array(messages))
        ref.value = thread
        job.progress = "Reading conversation context\u{2026}"
        let chatMessages = ChatStream.messagesFor(thread, cloud: !memoryAllowed)
        let prepared: PreparedContext
        if config.model.source == "server" {
            prepared = try prepareServerContext(messages: chatMessages, context: config.model.context, mode: mode, endpoint: endpoint)
        } else {
            prepared = try await planner(chatMessages, config.model.context, mode, endpoint, headers, signal)
        }
        try check()
        ref.updateLast { $0["context"] = prepared.report.json }
        job.context = prepared.report.json
        job.progress = "Thinking\u{2026}"
        var body: [String: JSONValue] = [
            "model": .string(config.model.source == "server" ? config.model.id : "black-team-local"),
            "messages": .array(try modelMessages(prepared.messages, threadId: thread["id"]?.string ?? "")), "stream": true, "stream_options": ["include_usage": true], "max_tokens": .number(Double(prepared.maxTokens)), "temperature": 0.7,
        ]
        for (name, value) in thinkingOptions(mode) { body[name] = value }
        var urlRequest = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30 * 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = Data(JSONValue.object(body).text().utf8)
        let (response, lines) = try await stream(urlRequest)
        if !(200..<300).contains(response.statusCode) {
            let sawImages = (thread["messages"]?.array ?? []).contains { !($0["images"]?.array ?? []).isEmpty }
            throw BlackTeamError("Local model request failed (\(response.statusCode)). " + (sawImages ? ImageRules.visionRequired : "Check your model and context settings."))
        }
        try await readReply(lines, job: job, signal: signal, ref: ref, prepared: prepared, cloudHost: nil)
    }

    /// Reads a streamed reply into the conversation. `cloudHost` is set for a cloud service: its token usage is recorded
    /// (and no reading speed, which only means something for a local model).
    func readReply(_ lines: HTTPLines, job: JobState, signal: CancelSignal, ref: ThreadRef, prepared: PreparedContext, cloudHost: String?) async throws {
        func check() throws { if signal.isCancelled { throw CancellationError() } }
        var assistant = ref.value["messages"]?.array?.last?.object ?? [:]
        var content = assistant["content"]?.string ?? ""
        var contentLength = EText.length(content)
        var lastFlush = Date(), lastPublish = Date.distantPast
        var firstToken: Date?
        func publish() { assistant["content"] = .string(content); let copy = assistant; ref.updateLast { $0 = copy }; changed(); lastPublish = Date() }
        func filled(_ value: JSONValue?) -> Bool { if let text = value?.string { return !text.isEmpty }; return false }
        let result: ChatStream.Result
        do {
            result = try await ChatStream.readStream(lines, onDelta: { delta in
                let reasoning = delta["reasoning_content"]
                if firstToken == nil, filled(delta["content"]) || filled(reasoning) || filled(delta["reasoning"]) { firstToken = Date() }
                if let text = delta["content"]?.string {
                    let available = 256 * 1024 - contentLength
                    let piece = EText.prefix(text, available)
                    content += piece; contentLength += EText.length(piece)
                    job.progress = "Writing a reply\u{2026}"
                    if EText.length(text) > available {
                        publish()
                        throw BlackTeamError("Response reached the storage limit. Ask for a shorter answer.")
                    }
                } else if filled(reasoning) || filled(delta["reasoning"]) { job.progress = "Thinking\u{2026}" }
                if Date().timeIntervalSince(lastPublish) > 0.1 { publish() }
                if Date().timeIntervalSince(lastFlush) > 0.75 { publish(); try self.persist(ref.value); lastFlush = Date() }
            }, signal: signal, subject: cloudHost.map { "service (\($0))" } ?? "local model")
        } catch {
            publish()
            throw error
        }
        assistant["finishReason"] = result.finishReason.map { JSONValue.string($0) } ?? JSONValue.null
        if cloudHost != nil {
            // What the service says this reply used. Added to the conversation's running total; no speed meter for a cloud model.
            let used = CloudUsage(api: result.usage)
            assistant["usage"] = used.json
            ref.addUsage(used)
            publish()
            try check()
            if EText.trim(content).isEmpty { throw BlackTeamError("The model returned no visible answer. Try a larger response budget or a different model.") }
            return
        }
        // Measured speed for the gauge. llama.cpp reports it; for other servers the clock gives the writing speed.
        let timed = result.timings, written = result.usage?["completion_tokens"]?.double ?? 0
        let predicted = timed?["predicted_per_second"]?.double ?? 0
        var write = predicted > 0 ? predicted : 0
        if write == 0, written > 0, let firstToken { write = written / max(0.05, Date().timeIntervalSince(firstToken)) }
        if write > 0, write.isFinite {
            let report = prepared.report
            var meter = JobMeter(write: max(1, EText.round(write)), used: report.measuredInputTokens, budget: report.inputBudget, window: report.context)
            if (timed?["prompt_n"]?.double ?? 0) >= 200, let rate = timed?["prompt_per_second"]?.double, rate > 0 { meter.read = EText.round(rate) }
            assistant["meter"] = meter.json
            job.meter = meter
        }
        publish()
        try check()
        if EText.trim(content).isEmpty {
            throw BlackTeamError("The model returned no visible answer. Try a larger response budget or a different model.")
        }
    }

    // MARK: Cancel, approvals, undo

    /// Stops the running job. A model that is still starting is stopped too.
    @discardableResult
    public func cancel() -> CancelResult {
        lock.lock()
        guard let signal = abort else { lock.unlock(); return CancelResult(stopping: false) }
        job?.progress = "Stopping response\u{2026}"
        signal.cancel()
        let task = active
        cancelTask = Task { [runtime] in
            if await runtime.status().state == .starting { try? await runtime.stop(force: true) }
        }
        lock.unlock()
        task?.cancel()
        return CancelResult(stopping: true)
    }

    /// Answers a command the engine is waiting on: `choice` is "once" or "deny".
    public func approve(id: String, digest: String, choice: String) throws {
        lock.lock(); let current = job; lock.unlock()
        guard let current, current.approval != nil else { throw BlackTeamError("No active approval.") }
        do { try current.approve(id: id, digest: digest, choice: choice) }
        catch { throw BlackTeamError("No matching active approval.") }
    }

    /// Puts a file back as it was before one edit the engine made. Refused while a task runs.
    public func undo(_ id: String?) throws -> UndoResult {
        guard let engine else { throw BlackTeamError("Not found.") }
        if isBusy { throw BlackTeamError("Wait for the running task to finish, or stop it, before undoing an edit.") }
        return try engine.undo(id)
    }

    /// A file a Code turn published (`/api/file/<id>`): where it is and the name to save it under.
    public func artifactFile(_ id: String) throws -> ArtifactFile {
        let missing = BlackTeamError("File not found.")
        guard id.utf8.count == 32, id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { throw missing }
        let artifact = history.threads.flatMap { $0["messages"]?.array ?? [] }.flatMap { $0["artifacts"]?.array ?? [] }.first { $0["id"]?.string == id }
        guard let artifact else { throw missing }
        let file = dataFolder + "/artifacts/" + id
        let info = CoreFS.stat(file)
        if info.error != 0 || (info.mode & S_IFMT) != S_IFREG || CoreFS.isSymlink(file) { throw missing }
        return ArtifactFile(path: file, name: artifact["name"]?.string ?? id, size: info.size)
    }

    // MARK: Projects

    func summary(_ project: Project) -> ProjectSummary {
        ProjectSummary(id: project.id, name: project.name, workspace: project.workspace, exists: CoreFS.exists(project.workspace),
                       notes: "Projects/\((project.workspace as NSString).lastPathComponent)", cloudAllowed: project.cloudAllowed)
    }

    public func projectList() -> [ProjectSummary] { lock.lock(); defer { lock.unlock() }; return projects.map(summary) }

    /// A project is a name, a folder inside the workspace, and a folder of notes in memory.
    public func createProject(name given: String) throws -> ProjectSummary {
        let name = EText.trim(given)
        if name.range(of: projectNamePattern, options: .regularExpression) == nil {
            throw BlackTeamError("Name the project with letters, numbers, spaces, dots or dashes (up to 60 characters).")
        }
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        if slug.isEmpty { throw BlackTeamError("Name the project with letters or numbers.") }
        lock.lock(); defer { lock.unlock() }
        if projects.count >= 200 { throw BlackTeamError("Black Team keeps up to 200 projects.") }
        let base: String
        do {
            let workspace = try ensureWorkspace(try configStore.read().workspace)
            guard let resolved = realpath(workspace, nil) else { throw BlackTeamError("Choose an existing, readable and writable workspace directory.") }
            base = String(cString: resolved); free(resolved)
        } catch { throw BlackTeamError(messageOf(error)) }
        let workspace = base + "/" + slug
        if projects.contains(where: { $0.workspace == workspace || $0.name.lowercased() == name.lowercased() }) {
            throw BlackTeamError("A project with that name or folder already exists.")
        }
        let made = BlackTeamError("That project folder could not be created inside your workspace.")
        do {
            try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let resolved = realpath(workspace, nil) else { throw made }
            let real = String(cString: resolved); free(resolved)
            if real != workspace || (CoreFS.stat(workspace).mode & S_IFMT) != S_IFDIR { throw made }
        } catch { throw made }
        let project = Project(id: UUID().uuidString.lowercased(), name: name, workspace: workspace, created: EText.iso(now()))
        let next = projects + [project]
        try writeJSON(projectsFile, next)
        projects = next
        let folder = "Projects/\(slug)"
        if (try? memory.read("\(folder)/Overview")) == nil {
            // The project works without its overview note.
            _ = try? memory.write("\(folder)/Overview", "# \(name)\n\nFolder: `\(workspace)`\nCreated \(project.created.prefix(10)) in Black Team.\n\nWhat this project is for:\n\n\nSee its [[\(folder)/Journal|journal]] for work done so far.\n")
        }
        changed()
        return summary(project)
    }

    // MARK: Memory

    func keeperNote(_ actions: [String]) throws {
        if actions.isEmpty { return }
        let added = actions.map { KeeperEntry(text: EText.prefix($0, 400), at: (now().timeIntervalSince1970 * 1000).rounded()) }.reversed()
        lock.lock()
        let next = Array((Array(added) + keeperLog).prefix(40))
        keeperLog = next
        lock.unlock()
        try writeJSON(keeperFile, next)
    }

    func sweepMemory() {
        do { try keeperNote(try memory.sweep()) } catch {
            // A full disk must not take the app down.
            try? keeperNote(["Memory housekeeping could not finish. Check available disk space."])
        }
    }

    public func memoryOverview() throws -> MemoryOverview {
        lock.lock(); let log = Array(keeperLog.prefix(12)); lock.unlock()
        return MemoryOverview(notes: memory.notes().map { NoteSummary(id: $0.id, title: $0.title, folder: $0.folder, updated: $0.updated, size: $0.size, kind: $0.kind) },
                              graph: memory.graph(), coreWritten: !memory.core().isEmpty,
                              keeper: KeeperState(usage: memory.usage(), limits: memory.limits, actions: log))
    }

    public func memoryNote(_ id: String) throws -> NoteContent { try memory.read(id) }
    public func memorySearch(_ query: String) async throws -> [SearchHit] { try await memory.search(query, limit: 30) }

    @discardableResult
    public func memorySave(_ id: String, content: String) throws -> NoteContent {
        let note = try memory.write(id, content)
        changed()
        return note
    }

    public func memoryDelete(_ id: String) throws { try memory.remove(id); changed() }

    /// Saves a lasting fact as a note; in a project's folder when `project` names one.
    public func memoryRemember(title: String, text: String, project: String? = nil) throws -> String {
        lock.lock(); let workspace = projects.first { $0.id == project }?.workspace; lock.unlock()
        let id = try memory.remember(title, text, workspace)
        changed()
        return id
    }

    /// Housekeeping by hand: sweeps, then condenses one oversized note with the loaded model.
    public func memoryTidy() async -> String {
        if isBusy { return "A task is running. Tidy memory when it finishes." }
        sweepMemory()
        return await condenseMemory(again: true) ?? "Memory is within its limits."
    }

    /// One oversized note is rewritten shorter by the local model, only when it is already loaded and idle.
    /// The keeper never starts a model on its own.
    func condenseMemory(again: Bool = false) async -> String? {
        if locked({ active != nil || closing }) { return nil }
        guard !memory.usage().oversized.isEmpty else { return nil }
        // The notes would be sent to the model to be rewritten. They are never sent to a cloud service.
        if (try? configStore.read().model.source) == "cloud" { return "Memory is tidied with a local model, so nothing from it goes to a cloud service. Select a local model to condense notes." }
        let state = await runtime.status()
        if !state.ready || state.busy { return "Start your model, then tidy memory again to condense the notes that are over their limit." }
        return await startCondense(again: again)
    }

    // Sync, so it can hold the lock while it claims the single job slot.
    private func startCondense(again: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        if active != nil || closing { return nil }
        let current = JobState(threadId: nil, kind: "memory", state: "running", progress: "Tidying memory\u{2026}")
        _ = current.observe { [hub] _ in hub.notify() }
        let signal = CancelSignal()
        job = current; abort = signal
        active = Task { [self] in
            func check() throws { if signal.isCancelled { throw CancellationError() } }
            do {
                let endpoint = try await runtime.start()
                try check()
                try await runtime.setBusy(true)
                let config = try configStore.read()
                let headers = try await runtime.requestHeaders()
                let fetch = self.fetch
                let result = try await memory.condense({ item in
                    // A note that would not fit the model's window is left as it is.
                    if Double(EText.length(item.content)) / 3 > Double(config.model.context) * 0.5 { return "" }
                    var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 15 * 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                    let body: JSONValue = [
                        "model": .string(config.model.source == "server" ? config.model.id : "black-team-local"), "stream": false,
                        "max_tokens": .number(Double(min(1800, config.model.context / 4))), "temperature": 0.2,
                        "messages": [
                            ["role": "system", "content": "You maintain a notes file. Rewrite the note shorter. Keep every distinct fact, decision, name, path, number and date. Merge repeats. Drop only chatter and duplicates. Keep the newest version when two lines disagree. Output only the rewritten note in Markdown, starting with its # heading."],
                            ["role": "user", "content": .string("Note title: \(item.title)\nRewrite it in at most \(item.target) characters.\n\n\(item.content)")],
                        ],
                    ]
                    request.httpBody = Data(body.text().utf8)
                    let (data, reply) = try await fetch(request)
                    if !(200..<300).contains(reply.statusCode) { throw BlackTeamError("The model could not condense the note.") }
                    return (try? JSONValue.parse(data))?["choices"]?[0]?["message"]?["content"]?.string ?? ""
                }, again: again)
                if let result { try? keeperNote([result]) }
                current.state = "done"
                current.progress = result ?? "Memory is within its limits."
            } catch {
                current.state = signal.isCancelled ? "interrupted" : "error"
                current.progress = signal.isCancelled ? "Memory upkeep stopped." : "Memory upkeep could not finish. Nothing was changed."
            }
            try? await runtime.setBusy(false)
            locked { abort = nil; active = nil; lastActivity = now() }
            changed()
        }
        hub.notify()
        return "Condensing one note with your local model\u{2026}"
    }

    private func startKeeper(interval: TimeInterval) {
        keeperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.keeperTick()
            }
        }
    }

    /// Idle upkeep: after 15 quiet minutes, sweep and condense.
    func keeperTick() async {
        let quiet = locked { () -> Bool in
            let idle = active == nil && !closing && now().timeIntervalSince(lastActivity) > 15 * 60
            if idle { lastActivity = now() }
            return idle
        }
        if quiet { sweepMemory(); _ = await condenseMemory() }
    }

    // MARK: Shutdown

    /// Stops the job and the model, and ends every process Black Team started. Call before the app exits.
    public func shutdown() async {
        let timer = locked { () -> Task<Void, Never>? in closing = true; setupDownloads.forEach { $0.cancel() }; return keeperTask }
        timer?.cancel()
        stopPhoneAccess()
        installer.cancel()
        cancel()
        try? await runtime.dispose()
        await waitForIdle()
        await roomTeamSettle()
        ModelRuntime.terminateOwnedProcesses()
        hub.finish()
    }
}
