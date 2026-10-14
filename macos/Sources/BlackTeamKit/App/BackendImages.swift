import Foundation

// Image attachments on the Backend: reading an image back, what the model is sent, and the vision file of a starter model.

extension Backend {
    /// A stored image of a conversation, for the interface to draw.
    public func image(threadId: String, imageId: String) throws -> (data: Data, mime: String) {
        try images.read(threadId: threadId, imageId: imageId)
    }

    /// The messages with each image reference replaced by its bytes: a message with images is sent as its text then one
    /// `image_url` data URL per image, and every earlier turn's images are sent again so the conversation stays consistent.
    func modelMessages(_ messages: [JSONValue], threadId: String) throws -> [JSONValue] {
        try messages.map { message in
            var object = message.object ?? [:]
            guard let references = object.removeValue(forKey: "images")?.array, !references.isEmpty else { return .object(object) }
            let urls = try references.compactMap { ImageRef($0) }.map { reference -> String in
                let file = try images.read(threadId: threadId, imageId: reference.id)
                return ImageRules.dataURL(file.data, mime: file.mime)
            }
            object["content"] = ImageRules.modelContent(text: object["content"]?.string ?? "", dataURLs: urls)
            return .object(object)
        }
    }

    // MARK: Vision file

    /// The starter model whose file is the one in use, if it is one.
    func starterModel(for model: ModelConfig) -> StarterModel? {
        guard model.source != "server", !model.file.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: dataFolder)
        return ModelCatalogue.model(file: model.file, dataFolder: folder)
    }

    /// Whether the model in use can read images: yes with a projector set, or on another server (where support is unknown and
    /// Black Team just tries); otherwise a starter model's own projector is offered, or nothing is known.
    public func visionStatus(_ model: ModelConfig) -> VisionStatus {
        if model.source == "server" { return VisionStatus(canSee: true, summary: "Images are sent as they are; whether this server reads them is not known.") }
        if !model.mmproj.isEmpty { return VisionStatus(canSee: true, summary: "Can read images.") }
        if let vision = starterModel(for: model)?.vision {
            return VisionStatus(canSee: false, needsFile: true, bytes: vision.bytes, summary: "Needs its vision file (\(visionSize(vision.bytes))).")
        }
        return VisionStatus(canSee: false, summary: "No vision file known.")
    }

    public func visionStatus() throws -> VisionStatus { visionStatus(try configStore.read().model) }

    func visionSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }

    /// Stops a running `installVision` download; what arrived is kept so it can resume.
    public func cancelVisionInstall() { cancelSetUp() }

    /// Downloads the current starter model's vision file with progress, sets it as `model.mmproj`, updates the saved model, and
    /// restarts the model server if it was running so the projector is loaded.
    @discardableResult
    public func installVision(progress: (@Sendable (SetupProgress) -> Void)? = nil) async throws -> VisionInstallResult {
        try await exclusive {
            let model = try configStore.read().model
            if isBusy { throw BlackTeamError("Wait for the response to finish, or stop it, before adding the vision file.") }
            guard model.mmproj.isEmpty, let starter = starterModel(for: model), let vision = starter.vision else {
                throw BlackTeamError(model.mmproj.isEmpty ? "No vision file is known for this model." : "This model already has its vision file.")
            }
            let report: @Sendable (SetupProgress) -> Void = { progress?($0) }
            let folder = URL(fileURLWithPath: dataFolder)
            let downloader = makeDownloader()
            locked { setupDownloads = [downloader] }
            defer { locked { setupDownloads = [] } }
            return try await withTaskCancellationHandler {
                if !vision.isInstalled(in: folder) {
                    report(SetupProgress(stage: "Downloading the vision file for \(starter.name)"))
                    try await downloader.download(vision.downloadRequest(dataFolder: folder)) {
                        report(SetupProgress(stage: "Downloading the vision file for \(starter.name)", fraction: $0.fraction, bytesPerSecond: $0.bytesPerSecond))
                    }
                } else {
                    report(SetupProgress(stage: "The vision file is already downloaded", fraction: 1))
                }
                if Task.isCancelled { throw CancellationError() }
                report(SetupProgress(stage: "Adding it to the model\u{2026}"))
                let state = await runtime.status().state
                let wasRunning = state == .ready || state == .starting
                if wasRunning { try await runtime.stop(force: false) }
                let file = vision.destination(in: folder).path
                _ = try await performSaveSetup(["model": ["mmproj": .string(file)]])
                if wasRunning {
                    report(SetupProgress(stage: "Restarting the model\u{2026}"))
                    Task { [self] in _ = try? await runtime.start(); changed() }
                }
                report(SetupProgress(stage: "Ready", fraction: 1))
                return VisionInstallResult(file: file, restarted: wasRunning)
            } onCancel: { downloader.cancel() }
        }
    }
}
