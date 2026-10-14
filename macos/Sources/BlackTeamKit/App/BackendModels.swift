import Foundation

// "Get a model": which models suit this computer, finding any GGUF on Hugging Face, and downloading one so that it is ready to chat.
//
// Window action            -> Backend method
//   models-recommend       -> modelRecommendations()
//   models-search          -> searchModels(_:)
//   models-repo            -> hubRepo(_:)
//   model-get              -> getModel(_:makeCurrent:progress:)   (progress rides on status.modelInstall)
//   model-get-stop         -> cancelSetUp()                       (and `discardModelDownload()` to throw the partial file away)
//
// Privacy: a search and a repository listing contact huggingface.co and only when the person asks; a download contacts huggingface.co and its
// download servers (and github.com for the llama.cpp program, when it is not installed yet). Nothing else is sent anywhere and nothing is
// signed in (no account, no token, no cookies).

/// What the person chose to download.
public enum ModelChoice: Sendable, Equatable {
    /// A model from `ModelCatalogue`, with the add-ons they ticked.
    case catalogue(id: String, vision: Bool = false, draft: Bool = false)
    /// A file from any Hugging Face repository.
    case hub(repo: String, path: String, vision: Bool = false, draft: Bool = false)
}

/// The answer to a finished download: enough for the window to say "Ready. Start chatting".
public struct ModelReadyResult: Codable, Equatable, Sendable {
    public var ready: Bool
    /// Plain words for the window: "Ready. Start chatting." or where to find a model that was added but not switched to.
    public var message: String
    public var modelName: String
    public var file: String
    /// The key of the model in the saved list (`model-switch` takes it).
    public var key: String
    public var runtime: String
    public var runtimeTag: String
    /// True when the model is the one chat will use now.
    public var inUse: Bool
    public var repo: String
    public var license: String
    /// The model is made by someone else and comes from Hugging Face; Black Team did not make it.
    public var thirdParty: Bool
    public var context: Int
    public var mmproj: String
    public var draft: String
    public var warning: String?
}

/// What an after-save step (speed tuning, harness setup) is told about the model that was just saved.
public struct ModelSavedEvent: Sendable, Equatable {
    public var model: ModelConfig
    /// The key of the model in the saved list.
    public var key: String
    /// True when it is now the model in use.
    public var inUse: Bool
    public var repo: String
    /// The size of the model file in bytes.
    public var bytes: Int64
}

extension Backend {
    // MARK: Hook

    /// HOOK: called once, after a downloaded model has been saved (and made the model in use when none was set up), and before the download
    /// reports "Ready". Steps that belong right after a model arrives are called from here: speed tuning for this computer, harness (Hermes)
    /// setup. It runs while the setup lock is held, so it must not call another setup action; it reports through `progress` and returns
    /// warnings (plain sentences) for the window to show. A failure here must not fail the download: catch inside and return a warning.
    /// Today there is nothing to do, so it returns no warnings.
    func afterModelSaved(_ event: ModelSavedEvent, progress: @Sendable (SetupProgress) -> Void) async -> [String] {
        _ = (event, progress)
        return []
    }

    // MARK: This computer and the ranking

    /// What this computer can run. A graphics card counts only when a GPU build of llama.cpp is in use (the person asked for GPU layers).
    public func hardwareProfile() -> HardwareProfile {
        if let hardwareOverride { return hardwareOverride }
        let gpuLayers = (try? configStore.read().model.gpuLayers) ?? 0
        return HardwareProfile.detect(dataFolder: dataFolder, gpuBuild: gpuLayers > 0)
    }

    /// The catalogue ranked for this computer: one "best", one "best for Code", and the "fastest" when it is another.
    public func modelRecommendations() -> ModelRecommendations {
        let hardware = hardwareProfile()
        let folder = URL(fileURLWithPath: dataFolder)
        var note: String?
        if let gpu = hardware.gpu, hardware.appleSilicon == false, !hardware.gpuUsable {
            note = (gpu.vramBytes ?? 0) > 0
                ? "A \(gpu.name) was found, but the llama.cpp Black Team downloads uses the processor only, so models are ranked for the processor. A GPU build of llama.cpp would run bigger models faster."
                : "A \(gpu.name) was found, but its memory could not be read, so models are ranked for the processor."
        }
        return ModelRecommender.recommend(hardware: hardware, installed: { $0.isInstalled(in: folder) }, runtime: installer.installedRuntime(), note: note)
    }

    // MARK: Hugging Face

    /// Searches Hugging Face for GGUF models. Contacts huggingface.co.
    public func searchModels(_ query: String) async throws -> [HubSearchResult] {
        try await HuggingFaceHub.search(query, fetch: hubFetch)
    }

    /// One repository's GGUF files with sizes, hashes and how each fits this computer. Contacts huggingface.co.
    public func hubRepo(_ repo: String) async throws -> HubRepo {
        try await HuggingFaceHub.repo(repo, hardware: hardwareProfile(), fetch: hubFetch)
    }

    // MARK: Download, save, ready

    /// A choice, resolved to the files to fetch. Everything here came from the catalogue or from the Hugging Face API, never from the window.
    struct DownloadPlan {
        var name: String
        var repo: String
        var license: String
        var mainLocalName: String
        var main: DownloadRequest
        var mainBytes: Int64
        var vision: DownloadRequest?
        var draft: DownloadRequest?
        /// Used when the file does not say how long a context it was trained for.
        var fallbackContext: Int
    }

    func plan(for choice: ModelChoice, folder: URL) async throws -> DownloadPlan {
        switch choice {
        case .catalogue(let id, let wantVision, let wantDraft):
            guard let model = ModelCatalogue.model(id: id) else { throw BlackTeamError("That model is not in the list.") }
            return DownloadPlan(name: model.name, repo: model.repo, license: model.license, mainLocalName: model.filename, main: model.downloadRequest(dataFolder: folder),
                                mainBytes: model.bytes, vision: wantVision ? model.vision?.downloadRequest(dataFolder: folder) : nil,
                                draft: wantDraft ? model.draft?.downloadRequest(dataFolder: folder) : nil, fallbackContext: model.contextSize)
        case .hub(let repo, let path, let wantVision, let wantDraft):
            guard HuggingFaceHub.isValidRepo(repo), HuggingFaceHub.isValidPath(path) else { throw BlackTeamError("That is not a model file on Hugging Face.") }
            // The size and hash are read again from the API now, so what is checked is what Hugging Face says today for exactly this file.
            let (info, files) = try await HuggingFaceHub.facts(repo, fetch: hubFetch)
            if info.gated { throw BlackTeamError("This repository asks you to accept its terms on huggingface.co first. Black Team does not sign in to Hugging Face, so it cannot download it.") }
            guard let file = files.first(where: { $0.path == path }), !HuggingFaceHub.isHelperFile(file.name) else { throw BlackTeamError("That file is not in the repository (any more).") }
            if file.split { throw BlackTeamError("That model is split into several parts, which Black Team cannot download yet.") }
            let described = HuggingFaceHub.describe(repo: repo, info: info, files: files, hardware: hardwareProfile())
            let job = HubDownload(repo: repo, file: file, vision: wantVision ? described.visionFile : nil, draft: wantDraft ? described.draftFile : nil, license: described.license)
            let models = folder.appendingPathComponent("models", isDirectory: true)
            let local = job.localName(in: models)
            guard let main = job.request(file, to: models.appendingPathComponent(local)) else { throw BlackTeamError("Hugging Face gave no checksum for that file, so Black Team could not check it.") }
            var vision: DownloadRequest?, draft: DownloadRequest?
            if let extra = job.vision { vision = job.request(extra, to: models.appendingPathComponent(HubDownload.companionName(model: local, kind: "mmproj"))) }
            if let extra = job.draft { draft = job.request(extra, to: models.appendingPathComponent(HubDownload.companionName(model: local, kind: "mtp"))) }
            return DownloadPlan(name: "", repo: repo, license: described.license, mainLocalName: local, main: main, mainBytes: file.bytes, vision: vision, draft: draft, fallbackContext: 4096)
        }
    }

    /// Downloads (resuming a partial file), checks the SHA-256 against the catalogue or the Hugging Face API, installs the llama.cpp runtime when
    /// none is installed, then saves the model as the "Model file" setup would: its name, a context that fits this computer, the downloaded
    /// `llama-server`, and the vision or speed-up file when asked for. The model becomes the model in use when none was set up (or when
    /// `makeCurrent` is true, which needs the model in use to be stopped); otherwise it joins the list. Then `afterModelSaved` runs.
    @discardableResult
    public func getModel(_ choice: ModelChoice, makeCurrent: Bool = false, progress: (@Sendable (SetupProgress) -> Void)? = nil) async throws -> ModelReadyResult {
        try await exclusive {
            let config = try configStore.read()
            let becomesCurrent = makeCurrent || !setupComplete(config)
            if becomesCurrent {
                let state = await runtime.status().state
                if isBusy || ![.off, .error].contains(state) { throw BlackTeamError("Stop the model before changing its configuration.") }
            }
            let report: @Sendable (SetupProgress) -> Void = { progress?($0) }
            let folder = URL(fileURLWithPath: dataFolder)
            report(SetupProgress(stage: "Checking the model\u{2026}"))
            let plan = try await self.plan(for: choice, folder: folder)

            // Room for everything still to come, before a byte moves.
            let wanted = [plan.main, plan.vision, plan.draft].compactMap { $0 }.filter { Downloader.fileSize($0.destination) != $0.expectedSize }
            let needed = wanted.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) - Downloader.fileSize(URL(fileURLWithPath: $1.destination.path + ".part")) }
            if needed > 0, let free = hardwareProfile().freeDisk, free < needed {
                throw BlackTeamError("Not enough free disk space: this needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free. Free up some space and try again.")
            }

            modelInstall.remember(partialFiles: wanted.map { $0.destination.path + ".part" })
            let downloader = makeDownloader()
            locked { setupDownloads = [downloader] }
            defer { locked { setupDownloads = [] } }
            return try await withTaskCancellationHandler {
                let runtimeInfo = try await ensureRuntime(report)
                if Task.isCancelled { throw CancellationError() }

                // Each file in turn; the bar covers all of them together.
                let total = Double(max(1, wanted.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }))
                var before = 0.0
                for request in wanted {
                    let label = (request.destination.lastPathComponent as NSString).deletingPathExtension
                    let size = Double(request.expectedSize ?? 0), start = before
                    report(SetupProgress(stage: "Downloading \(plan.name.isEmpty ? label : plan.name)", fraction: start / total))
                    _ = try await downloader.download(request) {
                        report(SetupProgress(stage: "Downloading \(plan.name.isEmpty ? label : plan.name)", fraction: min(1, (start + Double($0.bytesReceived)) / total), bytesPerSecond: $0.bytesPerSecond))
                    }
                    before = start + size
                    if Task.isCancelled { throw CancellationError() }
                }
                if wanted.isEmpty { report(SetupProgress(stage: "\(plan.name.isEmpty ? plan.mainLocalName : plan.name) is already downloaded", fraction: 1)) }

                report(SetupProgress(stage: "Saving the model setup\u{2026}"))
                let file = plan.main.destination.path
                // The file says what it is and how long a context it was trained for; the context is capped by this computer's memory.
                let memory = MemoryFigures(total: Int(clamping: hardwareProfile().totalMemory), free: Int(clamping: hardwareProfile().availableMemory))
                let described = describeFile(file, bytes: Int(plan.mainBytes), memory: memory)
                let name = plan.name.isEmpty ? described.name : plan.name
                let context = described.trainingContext == nil ? min(described.context, plan.fallbackContext) : described.context
                let threads = max(1, min(64, SystemInfo.cpuTopology().cores))
                let mmproj = plan.vision.map { $0.destination.path } ?? "", draft = plan.draft.map { $0.destination.path } ?? ""
                let model = ModelConfig(source: "gguf", name: name, file: file, runtime: runtimeInfo.executable, context: context, gpuLayers: 0, threads: threads,
                                        mmproj: mmproj, draft: draft)
                var warning: String?
                if becomesCurrent {
                    let form: JSONValue = ["model": ["source": "gguf", "name": .string(name), "file": .string(file), "runtime": .string(runtimeInfo.executable),
                                                     "context": .number(Double(context)), "gpuLayers": 0, "threads": .number(Double(threads)),
                                                     "mmproj": .string(mmproj), "draft": .string(draft)]]
                    warning = try await performSaveSetup(form).warning
                } else {
                    _ = try savedModels.remember(model)
                    changed()
                }
                let key = keyOf(model)
                let saved = ModelSavedEvent(model: model, key: key, inUse: becomesCurrent, repo: plan.repo, bytes: plan.mainBytes)
                let notes = await afterModelSaved(saved, progress: report)
                let warnings = ([warning] + notes.map { Optional($0) }).compactMap { $0 }
                report(SetupProgress(stage: "Ready", fraction: 1))
                return ModelReadyResult(ready: true,
                                        message: becomesCurrent ? "Ready. Start chatting." : "\(name) was added to your models. Choose it from the model menu to use it.",
                                        modelName: name, file: file, key: key, runtime: runtimeInfo.executable, runtimeTag: runtimeInfo.tag, inUse: becomesCurrent,
                                        repo: plan.repo, license: plan.license, thirdParty: true, context: context, mmproj: mmproj, draft: draft,
                                        warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
            } onCancel: {
                downloader.cancel()
                self.installer.cancel()
            }
        }
    }

    /// The downloaded llama.cpp runtime, installed first when there is none.
    private func ensureRuntime(_ report: @escaping @Sendable (SetupProgress) -> Void) async throws -> InstalledRuntime {
        if let existing = installer.installedRuntime() { return existing }
        report(SetupProgress(stage: "Looking for the llama.cpp runtime\u{2026}"))
        return try await installer.installLatest { event in
            switch event {
            case .checking: report(SetupProgress(stage: "Looking for the llama.cpp runtime\u{2026}"))
            case .downloading(let p): report(SetupProgress(stage: "Downloading the llama.cpp runtime", fraction: p.fraction, bytesPerSecond: p.bytesPerSecond))
            case .extracting: report(SetupProgress(stage: "Unpacking the llama.cpp runtime\u{2026}"))
            case .verifying: report(SetupProgress(stage: "Checking the llama.cpp runtime\u{2026}"))
            case .done: report(SetupProgress(stage: "The llama.cpp runtime is ready", fraction: 1))
            }
        }
    }

    /// Deletes the partly downloaded files of the model that was stopped, for "Cancel" (as against "Pause", which keeps them). Nothing happens
    /// while a download is running.
    public func discardModelDownload() {
        guard locked({ setupDownloads.isEmpty }) else { return }
        for path in modelInstall.partialFiles() { try? FileManager.default.removeItem(atPath: path) }
    }
}
