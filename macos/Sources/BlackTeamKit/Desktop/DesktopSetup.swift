import Foundation

// "Set up your agents" for the window. `setup-plan` answers with the plan and whether to offer it; `setup-apply` starts the approved
// steps and answers at once, and its progress rides on every desktop `status` answer as `setupRun` (the control channel answers one
// line per request, so a run cannot report as it goes: the same way a starter model download does). `setup-dismiss` remembers
// "Not now"; `setup-cancel` stops a running setup, keeping what was downloaded.

/// Where a setup run stands: one row per approved step.
final class SetupRunState: @unchecked Sendable {
    struct Row {
        var id: String
        var status = "waiting"
        var stage = ""
        var fraction: Double?
        var bytesPerSecond: Double = 0
    }

    private let lock = NSLock()
    private var running = false
    private var done = false
    private var error = ""
    private var rows: [Row] = []
    private var results: [SetupStepResult] = []
    private var task: Task<Void, Never>?

    /// False when a run is already going.
    func begin(ids: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true; done = false; error = ""; results = []
        rows = ids.map { Row(id: $0) }
        return true
    }
    func hold(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func report(_ event: SetupEvent) {
        lock.lock(); defer { lock.unlock() }
        guard running, let index = rows.firstIndex(where: { $0.id == event.stepID }) else { return }
        rows[index].status = event.status; rows[index].stage = event.stage
        rows[index].fraction = event.fraction; rows[index].bytesPerSecond = event.bytesPerSecond
    }
    func finish(_ finished: [SetupStepResult]) {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; done = true; results = finished
        for result in finished {
            if let index = rows.firstIndex(where: { $0.id == result.id }) { rows[index].status = result.status; rows[index].stage = result.message; rows[index].bytesPerSecond = 0 }
        }
    }
    /// The run could not start at all (another task is running, say).
    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        running = false; task = nil; error = message
    }
    func cancel() { lock.lock(); let held = task; lock.unlock(); held?.cancel() }

    var json: JSONValue {
        lock.lock(); defer { lock.unlock() }
        let steps = rows.map { row -> JSONValue in
            var out: [String: JSONValue] = ["id": .string(row.id), "status": .string(row.status), "stage": .string(row.stage), "bytesPerSecond": .number(row.bytesPerSecond)]
            if let fraction = row.fraction { out["fraction"] = .number(fraction) }
            return .object(out)
        }
        return .object(["running": .bool(running), "done": .bool(done), "error": .string(error), "steps": .array(steps), "results": .encoded(results)])
    }
}

extension DesktopControl {
    /// `setup-plan {reason}`: the plan, and whether to put it in front of the person. Looks at files only.
    func setupPlanJSON(_ input: [String: JSONValue]) throws -> JSONValue {
        let reason = input["reason"]?.string ?? "asked"
        guard ["model-ready", "found-something-new", "asked"].contains(reason) else { throw BlackTeamError("Unsupported setup setting.") }
        return backend.offerSetup(reason: reason).json
    }

    /// `setup-apply {ids}`: starts the approved steps. Whatever stops the run (another task running, say) arrives as `setupRun.error`.
    func setupStart(_ input: [String: JSONValue]) throws -> JSONValue {
        guard let ids = input["ids"]?.array?.compactMap(\.string), !ids.isEmpty, ids.count <= 40, Set(ids).count == ids.count else {
            throw BlackTeamError("Choose at least one step to set up.")
        }
        guard backend.setupRun.begin(ids: ids) else { return ["started": false, "running": true] }
        let state = backend.setupRun, backend = backend
        let task = Task {
            do {
                state.finish(try await backend.applySetup(approved: ids) { state.report($0) })
            } catch is CancellationError {
                state.fail("Stopped. What was downloaded is kept, so it carries on from there next time.")
            } catch {
                state.fail((error as? BlackTeamError)?.message ?? error.localizedDescription)
            }
        }
        state.hold(task)
        return ["started": true, "running": true]
    }

    /// `setup-cancel`: stops a running setup; what was downloaded is kept.
    func setupStop() -> JSONValue {
        backend.setupRun.cancel(); backend.cancelSetUp()
        return ["stopped": true]
    }
}
