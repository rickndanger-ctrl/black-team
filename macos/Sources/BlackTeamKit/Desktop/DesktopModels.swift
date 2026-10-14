import Foundation

// "Get a model" for the window: the ranked list, a Hugging Face search, one repository's files, and a download that reports as it goes. The
// control channel answers one line per request, so `model-get` starts the download and answers at once; its progress rides on every desktop
// `status` answer as `modelInstall`, with the result (the window says "Ready. Start chatting") when it ends.

/// Where the "Get a model" download stands.
final class ModelInstallState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var stage = ""
    private var fraction: Double?
    private var bytesPerSecond: Double = 0
    private var error = ""
    private var done = false
    /// Stopped by the person with the partial file kept, so pressing Download again carries on.
    private var paused = false
    private var result: JSONValue = .null
    private var task: Task<Void, Never>?
    private var partials: [String] = []
    private var stopping = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true; stage = "Starting\u{2026}"; fraction = nil; bytesPerSecond = 0; error = ""; done = false; paused = false; result = .null; stopping = false
        return true
    }
    func hold(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func report(_ progress: SetupProgress) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        stage = progress.stage; fraction = progress.fraction; bytesPerSecond = progress.bytesPerSecond
    }
    func finish(result value: ModelReadyResult) {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; bytesPerSecond = 0; error = ""; done = true; fraction = 1; paused = false; result = .encoded(value)
    }
    func finish(error message: String) {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; bytesPerSecond = 0; error = message; done = false; paused = false
    }
    /// A stop the person asked for: not an error.
    func finishStopped() {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; bytesPerSecond = 0; error = ""; done = false; paused = true
    }
    func wasStopRequested() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func stop() { lock.lock(); stopping = true; let held = task; lock.unlock(); held?.cancel() }
    func clearPause() { lock.lock(); paused = false; stage = ""; fraction = nil; lock.unlock() }
    func remember(partialFiles: [String]) { lock.lock(); partials = partialFiles; lock.unlock() }
    func partialFiles() -> [String] { lock.lock(); defer { lock.unlock() }; return partials }

    var json: JSONValue {
        lock.lock(); defer { lock.unlock() }
        var out: [String: JSONValue] = ["running": .bool(running), "stage": .string(stage), "bytesPerSecond": .number(bytesPerSecond),
                                        "error": .string(error), "done": .bool(done), "paused": .bool(paused), "result": result]
        if let fraction { out["fraction"] = .number(fraction) }
        return .object(out)
    }
}

extension DesktopControl {
    /// A `ModelChoice` from the window's input: `{source: "catalogue", id}` or `{source: "hub", repo, file}`, with `vision` and `draft` ticks.
    func modelChoice(_ input: [String: JSONValue]) throws -> ModelChoice {
        let vision = input["vision"]?.bool ?? false, draft = input["draft"]?.bool ?? false
        switch input["source"]?.string {
        case "catalogue":
            guard let id = input["id"]?.string, !id.isEmpty else { throw BlackTeamError("That model is not in the list.") }
            return .catalogue(id: id, vision: vision, draft: draft)
        case "hub":
            guard let repo = input["repo"]?.string, let file = input["file"]?.string, HuggingFaceHub.isValidRepo(repo), HuggingFaceHub.isValidPath(file) else {
                throw BlackTeamError("That is not a model file on Hugging Face.")
            }
            return .hub(repo: repo, path: file, vision: vision, draft: draft)
        default:
            throw BlackTeamError("Choose a model to download.")
        }
    }

    /// `model-get`: starts the download and saving. Whatever `getModel` refuses (a model that is running, no room on the disk, a repository
    /// that asks for sign-in) arrives as `modelInstall.error`, in its words.
    func modelStart(_ choice: ModelChoice, makeCurrent: Bool) -> JSONValue {
        guard backend.modelInstall.begin() else { return ["started": false, "running": true] }
        let state = backend.modelInstall, backend = backend
        let task = Task {
            do {
                let result = try await backend.getModel(choice, makeCurrent: makeCurrent) { state.report($0) }
                state.finish(result: result)
            } catch is CancellationError {
                state.finishStopped()
            } catch {
                state.finish(error: (error as? BlackTeamError)?.message ?? error.localizedDescription)
            }
        }
        state.hold(task)
        return ["started": true, "running": true]
    }

    /// `model-get-stop`: pauses (the partial file is kept) or, with `discard`, cancels (it is deleted).
    func modelStop(discard: Bool) async -> JSONValue {
        let state = backend.modelInstall
        state.stop(); backend.cancelSetUp()
        // Give the stopped download a moment to let go of its files.
        for _ in 0..<50 where state.json["running"]?.bool == true { try? await Task.sleep(nanoseconds: 20_000_000) }
        if discard { backend.discardModelDownload(); state.clearPause() }
        return ["stopped": true, "discarded": .bool(discard)]
    }
}
