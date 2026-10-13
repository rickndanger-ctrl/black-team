import Foundation

// Downloads for the window: a starter model, and a model's vision file. The control channel answers one line per request, so a
// download cannot report as it goes: `starter-install` and `vision-install` start one and answer at once, and its progress rides on
// every desktop `status` answer as `starterInstall` or `visionInstall`.

/// Where one kind of download stands. The engine keeps one for starter models and one for vision files.
final class VisionInstallState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var stage = ""
    private var fraction: Double?
    private var bytesPerSecond: Double = 0
    private var error = ""
    private var done = false
    private var task: Task<Void, Never>?

    /// False when a download is already running.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true; stage = "Starting\u{2026}"; fraction = nil; bytesPerSecond = 0; error = ""; done = false
        return true
    }
    func hold(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func report(_ progress: SetupProgress) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        stage = progress.stage; fraction = progress.fraction; bytesPerSecond = progress.bytesPerSecond
    }
    func finish(error message: String?) {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; bytesPerSecond = 0
        if let message { error = message; done = false } else { error = ""; done = true; fraction = 1 }
    }
    func cancel() { lock.lock(); let held = task; lock.unlock(); held?.cancel() }

    var json: JSONValue {
        lock.lock(); defer { lock.unlock() }
        var out: [String: JSONValue] = ["running": .bool(running), "stage": .string(stage), "bytesPerSecond": .number(bytesPerSecond),
                                        "error": .string(error), "done": .bool(done)]
        if let fraction { out["fraction"] = .number(fraction) }
        return .object(out)
    }
}

extension DesktopControl {
    /// `vision-install`: starts the download for the model in use. The checks `installVision` makes (a known vision file, nothing
    /// replying, no other setup running) fail into `visionInstall.error`, in its own words.
    func visionStart() -> JSONValue {
        guard vision.begin() else { return ["started": false, "running": true] }
        let state = vision, backend = backend
        let task = Task {
            do {
                _ = try await backend.installVision { state.report($0) }
                state.finish(error: nil)
            } catch is CancellationError {
                state.finish(error: "Stopped. What was downloaded is kept, so it carries on from there next time.")
            } catch {
                state.finish(error: (error as? BlackTeamError)?.message ?? error.localizedDescription)
            }
        }
        vision.hold(task)
        return ["started": true, "running": true]
    }

    /// `vision-cancel`: stops a running download; what arrived is kept.
    func visionStop() -> JSONValue {
        vision.cancel(); backend.cancelVisionInstall()
        return ["stopped": true]
    }

    /// `starter-list`: the starter models, which are downloaded, and the one recommended for this computer's memory.
    func starterList() -> JSONValue { .encoded(backend.starterModels()) }

    /// `starter-install {id}`: downloads llama.cpp if needed and the model, then saves it as the model in use. What `setUpStarter`
    /// refuses (an unknown id, a model that is running, another setup in progress) arrives as `starterInstall.error`, in its words.
    func starterStart(_ id: String) -> JSONValue {
        guard starter.begin() else { return ["started": false, "running": true] }
        let state = starter, backend = backend
        let task = Task {
            do {
                _ = try await backend.setUpStarter(modelID: id) { state.report($0) }
                state.finish(error: nil)
            } catch is CancellationError {
                state.finish(error: "Stopped. What was downloaded is kept, so it carries on from there next time.")
            } catch {
                state.finish(error: (error as? BlackTeamError)?.message ?? error.localizedDescription)
            }
        }
        starter.hold(task)
        return ["started": true, "running": true]
    }

    /// `starter-cancel`: stops a running starter download; what arrived is kept.
    func starterStop() -> JSONValue {
        starter.cancel(); backend.cancelSetUp()
        return ["stopped": true]
    }
}
