import Foundation

// Optimizing a model for this computer, as the window and the command line ask for it (Runtime/Tune.swift does the measuring).
// One optimization at a time. While it runs, other setup actions are refused (it holds the same claim they do) and so is a new
// message, because the model is stopped and started a few times. It never starts while a response is being written.

/// Where the optimization stands. Read by every desktop `status` answer as `optimize`.
final class TuneState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var key = "", name = "", server = false
    private var message = "", log: [String] = []
    private var started: Date?
    private var budget: Double = 0
    private var error = "", done = false, stopped = false, summary = ""
    private var task: Task<Void, Never>?

    var running: Bool { lock.lock(); defer { lock.unlock() }; return active }

    /// False when one is already running.
    func begin(key: String, name: String, server: Bool, budget: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active { return false }
        active = true; self.key = key; self.name = name; self.server = server; self.budget = budget
        message = "Starting\u{2026}"; log = []; started = Date(); error = ""; done = false; stopped = false; summary = ""
        return true
    }
    func hold(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func abandon() { lock.lock(); active = false; lock.unlock() }
    func report(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        message = text; log.append(text)
        if log.count > 12 { log.removeFirst(log.count - 12) }
    }
    func finish(error text: String?, stopped wasStopped: Bool = false, summary line: String = "") {
        lock.lock(); defer { lock.unlock() }
        active = false; task = nil
        error = text ?? ""; stopped = wasStopped; done = text == nil && !wasStopped; summary = line
        if let text { message = text } else if wasStopped { message = "Stopped." } else if !line.isEmpty { message = "Done." }
    }
    func cancel() { lock.lock(); let held = task; lock.unlock(); held?.cancel() }
    private func held() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return task }
    func wait() async { await held()?.value }

    var json: JSONValue {
        lock.lock(); defer { lock.unlock() }
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        return ["running": .bool(active), "key": .string(key), "name": .string(name), "server": .bool(server), "message": .string(message),
                "log": .array(log.map { .string($0) }), "elapsedSeconds": .number(active ? elapsed.rounded() : 0), "budgetSeconds": .number(budget),
                "error": .string(error), "done": .bool(done), "stopped": .bool(stopped), "summary": .string(summary)]
    }
}

/// What `optimize` did with a request. `text` is "started" or "skipped: <reason>".
public enum OptimizeStart: Equatable, Sendable {
    case started
    case skipped(String)

    public var text: String {
        switch self {
        case .started: return "started"
        case .skipped(let reason): return "skipped: \(reason)"
        }
    }
}

extension Backend {
    func makeTuner() -> ModelTuner {
        let trial = tuneTrial ?? { scratch, startupMs in ModelRuntime(configStore: scratch, fetch: LocalHTTP.fetch, startupTimeoutMs: startupMs) }
        let lock = engineLock
        return ModelTuner(main: runtime, configStore: configStore, store: tuning, trial: trial, fetch: fetch, environment: tuneEnvironment,
                          isBusy: { [weak self] in self?.isBusy ?? true },
                          preflight: { if let refusal = lock.refusalForLocalModel() { throw BlackTeamError(refusal) } })
    }

    /// Starts optimizing a saved model in the background and returns at once; read `optimizeStatus()` for how it goes.
    /// A model file Black Team starts itself is tuned (this stops the model for a few minutes and starts it again afterwards if it was
    /// running); a model on a server somebody else runs is only measured; a cloud model throws. Returns `.skipped("busy")` while a
    /// response is being written, or another setup action or optimization is running.
    @discardableResult
    public func optimize(key: String) async throws -> OptimizeStart {
        guard let model = savedModels.find(key) else { throw BlackTeamError("That model is not in your list.") }
        if model.source == "cloud" { throw BlackTeamError("A cloud model runs at its service, so there is nothing to optimize on \(Place.this).") }
        if model.source == "gguf" { _ = try validateModelFiles(model, cloud: cloudRules) }
        if locked({ closing }) { return .skipped("closing") }
        if isBusy { return .skipped("busy") }
        let server = model.source == "server"
        guard tuneState.begin(key: key, name: model.name, server: server, budget: TuneOptions().budgetSeconds) else { return .skipped("busy") }
        do { try claimSetup() } catch { tuneState.abandon(); return .skipped("busy") }
        let state = tuneState, tuner = makeTuner()
        let task = Task { [self] in
            defer { releaseSetup(); changed() }
            do {
                let entry: TuneEntry
                if server {
                    entry = try await tuner.measureServer(model, report: { state.report($0) })
                } else {
                    entry = try await tuner.optimize(model, report: { state.report($0) }, apply: { [self] entry in try applyTunedContext(entry, to: model) })
                }
                state.finish(error: nil, summary: entry.summary(draftFile: model.draft))
            } catch is CancellationError {
                state.finish(error: nil, stopped: true)
            } catch let skipped as TuneSkipped {
                state.finish(error: "Not started: \(skipped.reason).")
            } catch {
                state.finish(error: messageOf(error))
            }
        }
        state.hold(task)
        changed()
        return .started
    }

    /// Meant to be called right after a model is added or downloaded (the add and download flows): starts optimizing that model in the
    /// background if it is a model file Black Team starts itself. Safe to call at any time: it never waits for the work and never throws.
    /// Returns `.skipped("busy")` while a response is being written or an optimization or setup action is running, and a skip for a
    /// server or cloud model (nothing to restart there) or a model that cannot be started.
    @discardableResult
    public func optimizeAfterAdding(modelKey: String) async -> OptimizeStart {
        guard let model = savedModels.find(modelKey) else { return .skipped("not in your list") }
        if model.source != "gguf" { return .skipped("not a model file") }
        do { return try await optimize(key: modelKey) } catch { return .skipped(messageOf(error)) }
    }

    /// Stops a running optimization. The model is put back as it was.
    public func cancelOptimize() { tuneState.cancel() }

    /// Resolves when the running optimization (if any) has finished.
    public func waitForOptimize() async { await tuneState.wait() }

    /// How the optimization stands: `running`, `message`, `log`, `elapsedSeconds`, `budgetSeconds`, `error`, `done`, `stopped`, `summary`.
    public func optimizeStatus() -> JSONValue { tuneState.json }

    /// The context the tuner found is the model's context setting from now on, so the conversation budget matches the model that runs.
    func applyTunedContext(_ entry: TuneEntry, to model: ModelConfig) throws {
        guard let context = entry.settings?.context, context != model.context else { return }
        var updated = model
        updated.context = context
        try savedModels.replace(updated)
        if let active = try? configStore.read().model, keyOf(active) == entry.key {
            try configStore.save(["model": ["context": .number(Double(context))]])
        }
    }

    /// What the window shows for one saved model: `state` is "none", "optimized", "stale", "measured", "server" or "cloud".
    func tuningInfo(for model: ModelConfig) -> JSONValue {
        if model.source == "cloud" { return ["state": "cloud"] }
        let entry = tuning.entry(keyOf(model))
        var info: [String: JSONValue] = ["state": .string(model.source == "server" ? "server" : "none")]
        guard let entry else { return .object(info) }
        info["summary"] = .string(entry.summary(draftFile: model.draft))
        info["date"] = .string(entry.date)
        info["promptTokensPerSecond"] = .number(entry.speed.promptTokensPerSecond)
        info["generationTokensPerSecond"] = .number(entry.speed.generationTokensPerSecond)
        if let settings = entry.settings { info["settings"] = .encoded(settings) }
        if model.source == "server" { info["state"] = .string(entry.kind == "measured" ? "measured" : "server"); return .object(info) }
        guard entry.kind == "tuned", let stored = entry.fingerprint else { return .object(info) }
        let reasons = tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: tuneEnvironment.hardware()))
        info["state"] = .string(reasons.isEmpty ? "optimized" : "stale")
        if !reasons.isEmpty { info["reasons"] = .array(reasons.map { .string($0) }) }
        return .object(info)
    }
}
