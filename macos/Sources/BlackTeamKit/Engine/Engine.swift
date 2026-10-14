import Foundation

/// What the engine reads from the model runtime: the headers that authorise requests to the
/// local server. (The JavaScript reads nothing else from `runtime`.)
public protocol EngineRuntime {
    func requestHeaders() -> [String: String]
}

/// A runtime with fixed headers, for tests and servers that need none.
public struct FixedHeadersRuntime: EngineRuntime {
    public var headers: [String: String]
    public init(_ headers: [String: String] = [:]) { self.headers = headers }
    public func requestHeaders() -> [String: String] { headers }
}

/// The reply being written, kept as a working copy and mirrored into the conversation after each change.
final class TurnState: @unchecked Sendable {
    private let lock = NSLock()
    private let thread: ThreadRef
    private let saveThread: @Sendable (JSONValue) throws -> Void
    let now: @Sendable () -> Date
    private var assistant: [String: JSONValue]
    private var lastSave: Int64 = 0

    init(thread: ThreadRef, save: @escaping @Sendable (JSONValue) throws -> Void, now: @escaping @Sendable () -> Date) {
        self.thread = thread; self.saveThread = save; self.now = now
        assistant = thread.value["messages"]?.array?.last?.object ?? [:]
    }

    private func sync() { thread.setLast(.object(assistant)) }

    func reset() {
        lock.lock(); assistant["events"] = []; assistant["artifacts"] = []; sync(); lock.unlock()
    }

    func event(_ item: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        var events = assistant["events"]?.array ?? []
        events.append(item)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        assistant["events"] = .array(events); sync()
    }

    func set(_ key: String, _ value: JSONValue) {
        lock.lock(); assistant[key] = value; sync(); lock.unlock()
    }

    var artifactCount: Int { lock.lock(); defer { lock.unlock() }; return assistant["artifacts"]?.array?.count ?? 0 }

    func addArtifact(_ item: JSONValue) {
        lock.lock(); var list = assistant["artifacts"]?.array ?? []; list.append(item); assistant["artifacts"] = .array(list); sync(); lock.unlock()
    }

    func persist(force: Bool = false) throws {
        let ms = EText.millis(now())
        lock.lock(); let due = force || ms - lastSave > 700; lock.unlock()
        guard due else { return }
        try saveThread(thread.value)
        lock.lock(); lastSave = EText.millis(now()); lock.unlock()
    }
}

/// Lets the stop signal answer a waiting approval with "deny".
private final class ApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (@Sendable () -> Void)?
    func set(_ value: (@Sendable () -> Void)?) { lock.lock(); cancel = value; lock.unlock() }
    func stop() { lock.lock(); let current = cancel; lock.unlock(); current?() }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

private final class TimerBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// Seconds spent waiting for a person's answer and whether an unattended run's question ran out of time. Waiting does not count against
/// the turn's time budget: a question left overnight must not use up the run.
private final class WaitLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0, expired = false
    func add(_ value: Double) { lock.lock(); seconds += max(0, value); lock.unlock() }
    func expire() { lock.lock(); expired = true; lock.unlock() }
    var waited: Double { lock.lock(); defer { lock.unlock() }; return seconds }
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

/// Black Team Code's agent loop, written for local models. See the notes at the top of engine.cjs:
/// the model's real speed sizes the budgets, history is only ever appended to so the server's prompt
/// cache stays valid, and trimming needs no model call.
public final class Engine: @unchecked Sendable {
    public let stateDir: String
    public let undoDir: String
    let dir: String, artifacts: String
    private let vault: Memory?
    let fetch: HTTPStreamFetch
    let now: @Sendable () -> Date
    private let graph: @Sendable () -> String
    private let home: String
    private let useRtk: Bool
    private let cloudRules: CloudRules
    private let skillStore: SkillStore?
    let codeSettings: CodeSettingsStore

    /// graph: returns the graphify executable when one is installed, so Code can ask a map of the workspace.
    public init(stateDir: String, vault: Memory? = nil, fetch: @escaping HTTPStreamFetch = LocalHTTP.stream,
                now: @escaping @Sendable () -> Date = { Date() }, graph: @escaping @Sendable () -> String = { "" },
                home: String = NSHomeDirectory(), useRtk: Bool = true, cloud: CloudRules = .standard, skills: SkillStore? = nil) throws {
        self.skillStore = skills; self.codeSettings = skills?.settings ?? CodeSettingsStore(dataFolder: stateDir)
        self.stateDir = stateDir; self.vault = vault; self.fetch = fetch; self.now = now; self.graph = graph; self.home = home; self.useRtk = useRtk
        self.cloudRules = cloud
        dir = stateDir + "/engine"; undoDir = dir + "/undo"; artifacts = stateDir + "/artifacts"
        try privateDirectory(dir); try privateDirectory(undoDir); try privateDirectory(artifacts)
    }

    /// Puts a file back as it was before one edit.
    public func undo(_ id: String?) throws -> UndoResult { try Tools.undoChange(undoDir, id) }

    /// What a cloud model has learned to refuse, kept in the private state folder.
    var capabilities: CloudCapabilities { CloudCapabilities(dataFolder: stateDir) }

    /// Before a local Code conversation is sent to a cloud service: takes the vault out of what the engine would send.
    /// Core memory goes, the results of `recall` go, and so do the work-log lines that name recalled or saved notes.
    public func scrubForCloud(_ threadId: String) throws {
        guard !threadId.contains("/"), let data = FileManager.default.contents(atPath: memoryFile(threadId)), let saved = try? JSONValue.parse(data), var object = saved.object else { return }
        var recalledCalls = Set<String>()
        for message in object["messages"]?.array ?? [] {
            for call in message["tool_calls"]?.array ?? [] where ["recall", "remember", "skill", "save_skill"].contains(call["function"]?["name"]?.string ?? "") {
                if let id = call["id"]?.string { recalledCalls.insert(id) }
            }
        }
        object["messages"] = .array((object["messages"]?.array ?? []).map { message in
            guard message["role"]?.string == "tool", let id = message["tool_call_id"]?.string, recalledCalls.contains(id) else { return message }
            return message.setting("content", "[Memory result removed: memory is not used in cloud conversations.]")
        })
        object["log"] = .array((object["log"]?.array ?? []).filter { !($0.string ?? "").hasPrefix("recall ") && !($0.string ?? "").hasPrefix("remember ") })
        object["core"] = nil
        try writeJSON(memoryFile(threadId), JSONValue.object(object))
    }

    private func memoryFile(_ threadId: String) -> String { "\(dir)/\(threadId).json" }
    // Each model's measured speed is remembered, so a new conversation starts calibrated.
    private var profileFile: String { dir + "/models.json" }
    private func profiles() -> [String: JSONValue] {
        guard let data = FileManager.default.contents(atPath: profileFile), let value = try? JSONValue.parse(data) else { return [:] }
        return value.object ?? [:]
    }

    func loadMemory(_ threadId: String, _ model: String) -> EngineMemory {
        let known = profiles()[model]
        let readSpeed = (known?["readSpeed"]?.double ?? 0) > 0 ? known!["readSpeed"]!.double! : 40
        let writeSpeed = (known?["writeSpeed"]?.double ?? 0) > 0 ? known!["writeSpeed"]!.double! : 12
        if let data = FileManager.default.contents(atPath: memoryFile(threadId)), let saved = try? JSONValue.parse(data), saved.object != nil {
            return EngineMemory(json: saved, readSpeed: readSpeed, writeSpeed: writeSpeed)
        }
        return EngineMemory(readSpeed: readSpeed, writeSpeed: writeSpeed)
    }

    private func saveMemory(_ threadId: String, _ memory: EngineMemory) throws { try writeJSON(memoryFile(threadId), memory.json) }

    private func saveProfile(_ model: String, _ memory: EngineMemory) throws {
        func tenth(_ value: Double) -> JSONValue { .number(((value * 10) + 0.5).rounded(.down) / 10) }
        var all = profiles()
        all[model] = ["readSpeed": tenth(memory.readSpeed), "writeSpeed": tenth(memory.writeSpeed), "measured": .string(EText.iso(now()))]
        try writeJSON(profileFile, JSONValue.object(all))
    }

    /// One Code turn. The conversation's last message is the reply being written and the one before it
    /// is the request; both are updated in `thread` as the turn goes, and `save` is called with the
    /// whole conversation now and then (and whenever a tool has run). `job` shows progress and
    /// carries any approval the person must answer. Stopping, by `signal` or by cancelling the task,
    /// throws `CancellationError`; any other failure is a `BlackTeamError` with the key redacted.
    public func run(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, signal: CancelSignal? = nil,
                    save: @escaping @Sendable (JSONValue) throws -> Void, mode: String = "balanced", workspace: String? = nil) async throws {
        try await runDriven(thread: thread, config: config, runtime: runtime, endpoint: endpoint, job: job, signal: signal, save: save, mode: mode,
                            workspace: workspace, room: nil)
    }

    /// The speeds this engine measured for a local model (`Engine` keeps them in `models.json`).
    public func measuredSpeeds(identity: String) -> (read: Double, write: Double)? {
        guard let known = profiles()[identity], let read = known["readSpeed"]?.double, let write = known["writeSpeed"]?.double, read > 0, write > 0 else { return nil }
        return (read, write)
    }

    /// `run` for the driver of a room: `room` adds the tools `team` and `delegate`, answered by the room, and lengthens the turn to the
    /// team's own time cap, because the driver spends most of it waiting for its members.
    public func runDriven(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, signal: CancelSignal? = nil,
                   save: @escaping @Sendable (JSONValue) throws -> Void, mode: String = "balanced", workspace: String? = nil, room: RoomToolHost?) async throws {
        let stop = CancelSignal()
        let unobserve = signal?.observe { stop.cancel() }
        defer { unobserve?() }
        if signal?.isCancelled == true { stop.cancel() }
        try await withTaskCancellationHandler {
            try await self.perform(thread: thread, config: config, runtime: runtime, endpoint: endpoint, job: job, stop: stop, save: save, mode: mode,
                                   workspace: workspace ?? config.workspace, room: room)
        } onCancel: { stop.cancel() }
    }

    private func perform(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, stop: CancelSignal,
                         save: @escaping @Sendable (JSONValue) throws -> Void, mode: String, workspace: String, room: RoomToolHost?) async throws {
        let contextWindow = config.model.context
        if contextWindow < Engine.MIN_CONTEXT {
            throw BlackTeamError("Code needs a context window of at least \(EText.grouped(Engine.MIN_CONTEXT)) tokens. Raise it in Settings, and in your model server if you use one.")
        }
        try ensureWorkspace(workspace)
        let isServer = config.model.source == "server"
        let cloud = config.model.source == "cloud"
        // A conversation that has been sent to a cloud service never gets memory from the vault, whatever model runs it now.
        // So does a conversation marked `noMemory` (a team run with a cloud member passes local members' results on).
        let cloudThread = cloud || thread.value["privacy"]?.string == "cloud" || thread.value["noMemory"]?.bool == true
        let model = isServer || cloud ? config.model.id : "black-team-local"
        let source = config.model.source.isEmpty ? "gguf" : config.model.source
        let identity = "\(source):\(isServer || cloud ? config.model.id : (config.model.file as NSString).lastPathComponent)"
        let headers = runtime.requestHeaders()
        let key = headers["Authorization"].map { String($0.dropFirst(7)) } ?? ""
        let redact: @Sendable (String) -> String = { value in redactSecrets(value, keys: [key]) }
        // The address was checked when the model was saved and is checked again here, so the key goes only to a cloud host.
        let cloudTarget: CloudEndpoint?
        if cloud { cloudTarget = try cloudRules(endpoint) } else { cloudTarget = nil }
        let now = self.now

        let threadValue = thread.value
        guard let threadId = threadValue["id"]?.string, !threadId.isEmpty, !threadId.contains("/") else { throw BlackTeamError("This conversation has no valid id.") }
        let turn = TurnState(thread: thread, save: save, now: now)
        turn.reset()
        var started = now()
        // Where the run is, shown live and saved with the reply; the settings are read again at each step so a change takes effect at once.
        let hostName = cloudTarget?.host ?? "", modelId = config.model.id, settingsStore = codeSettings
        let prefs: @Sendable () -> CodeEffective = { settingsStore.effective(thread: threadId, cloud: cloud, host: hostName, model: modelId) }
        let tracker = RunTracker(job: job, now: now) { record in
            var shown = record.json
            if let spent = record.cost(prefs().price) { shown = shown.setting("cost", .number(spent)) }
            turn.set("run", shown)
        }
        let ledger = WaitLedger()
        // A scheduled run says how long its question may wait; a run with a person at the window keeps the five minutes.
        let unattended = job.unattended
        let approvalSeconds = unattended?.approvalSeconds ?? Engine.APPROVAL_SECONDS
        let note: (String, String) -> Void = { name, output in turn.event(["type": "status", "name": .string(name), "output": .string(output)]) }
        func checkStopped() throws {
            if stop.isCancelled || Task.isCancelled { throw CancellationError() }
            // An unattended run whose question nobody answered in time ends here, as "not approved".
            if ledger.didExpire { throw BlackTeamError(Engine.notApprovedMessage) }
        }

        // Approval card: resolves when the person answers in the app, or denies itself after five minutes.
        let gate = ApprovalGate()
        let ask: Tools.Ask = { request in
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                let id = UUID().uuidString.lowercased()
                let digest = SHA256.hash(data: Data(request.command.utf8)).map { String(format: "%02x", $0) }.joined()
                let once = Once(), timer = TimerBox()
                let askedAt = now()
                let finish: @Sendable (String) -> Void = { choice in
                    guard once.take() else { return }
                    timer.task?.cancel(); gate.set(nil); job.withdraw()
                    ledger.add(now().timeIntervalSince(askedAt))
                    tracker.answered()
                    continuation.resume(returning: choice)
                }
                timer.task = Task {
                    try? await Task.sleep(nanoseconds: UInt64(approvalSeconds) * 1_000_000_000)
                    if Task.isCancelled { return }
                    if unattended != nil { ledger.expire() }
                    finish("deny")
                }
                gate.set { finish("deny") }
                tracker.waiting()
                job.present(PendingApproval(id: id, digest: digest, command: EText.prefix(redact(request.command), 8000), description: request.description,
                                            expires: EText.millis(now()) + Int64(approvalSeconds) * 1000)) { answer in
                    guard answer.id == id, answer.digest == digest, ["once", "deny"].contains(answer.choice) else { throw BlackTeamError("No matching active approval.") }
                    job.progress = answer.choice == "once" ? "Approved. Continuing\u{2026}" : "Declined. Continuing\u{2026}"
                    finish(answer.choice)
                }
                if stop.isCancelled { finish("deny"); return }
                job.progress = "Waiting for your approval"
                try? turn.persist(force: true)
            }
        }
        let unobserveStop = stop.observe { gate.stop() }
        defer { unobserveStop(); job.withdraw() }

        var memory = loadMemory(threadId, identity)
        if cloudThread { memory.core = nil }
        // A run found unfinished was cut off (Black Team closed, or a tool was stopped): carry on from the saved state.
        let interrupted = memory.run.phase.isUnfinished
        let repaired = Engine.repairDangling(memory.messages)
        if repaired.count != memory.messages.count { memory.messages = repaired; memory.promptTokens = 0; memory.counted = 0 }
        tracker.load(memory.run)
        var limits = Engine.budgets(memory.readSpeed, contextWindow, cloud: cloud)
        let resultLimit = LimitBox(limits.resultChars)
        let mapper = graph()
        let tools = try Tools(workspace: workspace, artifacts: artifacts, undoDir: undoDir, home: home, deny: [stateDir], limit: { resultLimit.value }, ask: ask,
                              signal: stop, useRtk: useRtk, graph: mapper, graphDir: mapper.isEmpty ? "" : stateDir + "/graphs", unattended: unattended?.permission)
        // The todo list belongs to the tools; a saved one is put back through the todo tool.
        if !memory.todo.isEmpty { _ = await tools.call("todo", ["items": .array(memory.todo.map { ["text": .string($0.text), "done": .bool($0.done)] })]) }
        let vault = cloudThread ? nil : self.vault
        let remembers = vault != nil
        var schemas = tools.schemas.array ?? []
        // A member run that must not change files (a driver's read-only delegation) is not offered, and cannot call, the tools that do.
        // A read-only scheduled run is held to the same rule, which also covers saving a skill.
        let readOnly = thread.value["readOnly"]?.bool == true || unattended?.permission == .readOnly
        let changing: Set<String> = ["edit", "write", "run", "publish", "save_skill"]
        if readOnly { schemas = schemas.filter { !changing.contains($0["function"]?["name"]?.string ?? "") } }
        if room != nil { schemas += RoomTools.schemas }
        if remembers { schemas += MEMORY_TOOLS.array ?? [] }
        // Skills, like the vault, are not used in a conversation that is sent to a cloud service.
        let skills = cloudThread ? nil : skillStore
        if skills != nil { schemas += SkillTools.schemas.filter { !(readOnly && changing.contains($0["function"]?["name"]?.string ?? "")) } }
        // Core memory is read once per conversation and then left alone, so the cached prompt stays valid.
        if let vault, memory.core == nil { memory.core = vault.core() }
        var system = Engine.SYSTEM(workspace, cloud: cloud)
        if !mapper.isEmpty { system += "\nThe map tool knows this code: ask it which files and functions matter before reading many files. It answers with paths and line numbers." }
        if remembers {
            system += "\nYou have a memory that lasts across conversations. Use recall when a task refers to earlier work or to the user's preferences, and remember to save a lasting fact once you have verified it."
            if let core = memory.core, !core.isEmpty { system += "\n\nWhat you already know about the user:\n\(core)" }
        }
        // The list of skills is read once per conversation, so the cached prompt stays valid; a skill saved later is found with `skill`.
        if let skills {
            if memory.skills == nil { memory.skills = skills.index(workspace: workspace)?.text ?? "" }
            if let text = memory.skills, !text.isEmpty { system += "\n\n" + text }
        }
        let offered = schemas
        let dispatch: (String, JSONValue) async -> ToolResult = { name, given in
            let args = ToolArguments.coerced(name, given, in: offered)
            if readOnly, changing.contains(name) { return ToolResult(output: "Error: this job is read-only, so \(name) is not available.", log: nil, error: true) }
            if let room, RoomTools.names.contains(name) {
                let reply = await room.callTool(name, args)
                return ToolResult(output: reply.text, log: "\(name) \(EText.prefix(args["member"]?.string ?? "", 40))", error: reply.isError)
            }
            if let skills, SkillTools.names.contains(name) { return await SkillRunner.call(name, args, store: skills, workspace: workspace, limit: resultLimit.value, ask: ask) }
            if vault != nil, name == "remember" || name == "recall", let refusal = ToolArguments.refusal(name, args, in: MEMORY_TOOLS.array ?? []) {
                return ToolResult(output: refusal, log: nil, error: true)
            }
            guard let vault, name == "remember" || name == "recall" else { return await tools.call(name, args) }
            do {
                if name == "recall" {
                    let note = args["note"]?.string, query = args["query"]?.string
                    let shown = (note.map { !$0.isEmpty } == true ? note : query) ?? "undefined"
                    return ToolResult(output: try await vault.recall(query, note, workspace), log: "recall \(JSONValue.string(EText.prefix(shown, 60)).text())")
                }
                let id = try vault.remember(args["title"]?.string ?? "", args["text"]?.string ?? "", args["project"]?.bool == true ? workspace : nil)
                return ToolResult(output: "Saved to memory as [[\(id)]].", log: "remember \(id)")
            } catch {
                return ToolResult(output: "Error: \(error.localizedDescription)", log: nil, error: true)
            }
        }
        let logStart = memory.log.count
        guard let messages = threadValue["messages"]?.array, messages.count >= 2, let request = messages[messages.count - 2]["content"]?.string else {
            throw BlackTeamError("This conversation has no request to answer.")
        }
        memory.requests.append(request)
        memory.messages.append(["role": "user", "content": .string(interrupted ? request + Engine.resumeNote(memory.run) : request)])
        let skillTokens = (memory.skills ?? "").isEmpty ? 0 : Int((Double(memory.skills!.count) / Engine.CHARS_PER_TOKEN).rounded(.up))
        note("Black Team engine", cloud
            ? "Ready \u{00B7} cloud model at \(cloudTarget?.host ?? "") \u{00B7} working budget \(EText.grouped(limits.working)) of \(EText.grouped(contextWindow)) tokens \u{00B7} memory is not used"
            : "Ready \u{00B7} reads about \(EText.round(memory.readSpeed)) tokens/s \u{00B7} working budget \(EText.grouped(limits.working)) of \(EText.grouped(contextWindow)) tokens")
        if skillTokens > 0 { note("Skills", "\(skills?.list(workspace: workspace).filter(\.enabled).count ?? 0) saved skills listed \u{00B7} about \(EText.grouped(skillTokens)) tokens added to the instructions") }
        if interrupted {
            let run = memory.run
            note("Continuing", "The last run stopped at step \(run.steps)\(run.tool.map { " while using \($0)" } ?? ""). Carrying on from the saved todo list (\(tools.todo.filter(\.done).count) of \(tools.todo.count) done).")
        }
        tracker.update { run in
            run.phase = (interrupted || run.steps > 0 || !tools.todo.isEmpty) ? .working : .planning
            run.checks = 0; run.reason = nil; run.todo = tools.todo
        }
        job.progress = "Reading the task\u{2026}"

        // Shown live beside the mode switch: measured speeds, and how full the working budget is.
        func gauge(_ used: Int) {
            job.meter = cloud ? JobMeter(used: used, budget: limits.working, window: contextWindow, trims: memory.trims)
                : JobMeter(read: EText.round(memory.readSpeed), write: EText.round(memory.writeSpeed), used: used, budget: limits.working, window: contextWindow, trims: memory.trims)
        }
        gauge(memory.promptTokens)
        let maxTokens = min(Engine.OUTPUT_TOKENS[mode] ?? 4096, contextWindow / 4)
        var finalText = "", unfinished = "", stuck = ""
        var loopGuard = LoopGuard()
        var reviewing = false, changed = false
        do {
            var step = 0
            while true {
                step += 1
                try checkStopped()
                // Pause takes effect here, between steps, never in the middle of a tool.
                if job.pauseControl.isRequested {
                    let before = tracker.current.phase, pausedAt = now()
                    tracker.phase(.paused); job.progress = "Paused. Resume when you are ready."
                    memory.todo = tools.todo; memory.run = tracker.current
                    try saveMemory(threadId, memory); try turn.persist(force: true)
                    while job.pauseControl.isRequested { try checkStopped(); try await Task.sleep(nanoseconds: 100_000_000) }
                    started = started.addingTimeInterval(now().timeIntervalSince(pausedAt))
                    tracker.phase(before); job.progress = "Continuing\u{2026}"
                }
                let chosen = prefs()
                if let reason = RunCeilings(tokens: chosen.tokenCeiling, money: chosen.moneyCeiling, price: chosen.price, model: config.model.name).reached(tracker.current) {
                    unfinished = reason; break
                }
                if step > Engine.MAX_STEPS {
                    unfinished = "I stopped at the limit of \(Engine.MAX_STEPS) steps for one turn, and the task is not finished. Send \"continue\" and I will pick up from my todo list."; break
                }
                if now().timeIntervalSince(started) - ledger.waited > Double(room == nil ? Engine.RUN_SECONDS : TeamLimits.minutes * 60) {
                    unfinished = "I stopped at the time limit for one turn, and the task is not finished. Send \"continue\" and I will pick up from my todo list."; break
                }
                let size = max(memory.promptTokens != 0 ? memory.promptTokens + Engine.estimate(Array(memory.messages.dropFirst(memory.counted ?? 0))) : 0, Engine.estimate(memory.messages) + 900)
                if size > limits.working {
                    memory.todo = tools.todo
                    // Trimming needs no model call. A summary of the trimmed part is written only for a cloud model, or when the person asks.
                    var written: String?
                    let cut = Engine.cutPoint(memory.messages, limits.working)
                    if cut >= 1, prefs().summarize {
                        job.progress = "Summarizing earlier steps\u{2026}"
                        if let made = await summarize(dropped: Array(memory.messages[0..<cut]), previous: memory.summary, model: model, endpoint: endpoint, headers: headers,
                                                      cloudTarget: cloudTarget, stop: stop, idleMs: cloud ? 300_000 : 900_000) {
                            memory.summary = made.text; written = made.text
                            if let usage = made.usage {
                                tracker.update { $0.promptTokens += usage.promptTokens; $0.completionTokens += usage.completionTokens }
                                if cloud { thread.addUsage(CloudUsage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens)) }
                            }
                        }
                    }
                    if Engine.trim(&memory, limits.working) {
                        memory.promptTokens = 0; memory.counted = 0
                        job.progress = "Trimming earlier steps\u{2026}"
                        note("Context", "Trimmed earlier steps: about \(EText.grouped(size)) \u{2192} \(EText.grouped(Engine.estimate(memory.messages) + 900)) tokens. Work log and todo kept. \(written == nil ? "No model call needed." : "A summary was written.")")
                        if let written { note("Summary of trimmed steps", written) }
                    }
                }
                tracker.update { $0.steps += 1; $0.todo = tools.todo }
                let expected = Engine.estimate(memory.messages) + 900
                // Allow for a cold read of everything at half the measured speed, plus slack.
                // A cloud service answers at its own pace; five silent minutes is stuck.
                let idleMs = cloud ? 300_000 : EText.round(max(180, min(180 + Double(expected) / max(5, memory.readSpeed / 2), 2700)) * 1000)
                let sending = [["role": "system", "content": .string(system)]] + memory.messages
                var result: Completion
                do {
                    var learned = 0
                    while true {
                        // A cloud request carries the standard fields only, shaped by what this model has refused before.
                        let body: JSONValue
                        if let cloudTarget {
                            body = CloudRequest.body(model: model, messages: sending, tools: schemas, maxTokens: maxTokens, mode: mode, caps: capabilities.caps(host: cloudTarget.host, model: model))
                        } else {
                            var local: [String: JSONValue] = [
                                "model": .string(model), "messages": .array(sending), "tools": .array(schemas),
                                "stream": true, "stream_options": ["include_usage": true], "max_tokens": .number(Double(maxTokens)), "temperature": 0.7,
                            ]
                            for (name, value) in thinkingOptions(mode) { local[name] = value }
                            body = .object(local)
                        }
                        do {
                            result = try await Engine.complete(endpoint: cloudTarget?.base ?? endpoint, headers: headers, body: body, signal: stop, idleMs: idleMs, fetch: fetch, onText: { text in
                                turn.set("content", .string(redact(text))); job.progress = "Writing a reply\u{2026}"; try turn.persist()
                            }, now: now)
                            break
                        } catch let failure as ModelRequestError {
                            // The service said which field it refuses: leave it out, remember that, and ask again.
                            if let cloudTarget, learned < 4, let next = CloudRequest.learn(status: failure.status, message: failure.detail, param: failure.param,
                                                                                            from: capabilities.caps(host: cloudTarget.host, model: model)) {
                                capabilities.record(host: cloudTarget.host, model: model, next)
                                learned += 1
                                continue
                            }
                            throw failure
                        }
                    }
                } catch {
                    // The server's count is exact and ours is an estimate; if it says too long, trim harder once.
                    if let failure = error as? ModelRequestError, failure.overflow, Engine.trim(&memory, limits.working / 2) {
                        memory.promptTokens = 0; memory.counted = 0
                        note("Context", "The model reported its window was full. Trimmed further and retried.")
                        continue
                    }
                    throw error
                }
                // Tokens are counted from what the service reports; Black Team estimates only when it reports none.
                let reportedUsage = result.usage.flatMap { $0.promptTokens + $0.completionTokens > 0 ? $0 : nil }
                let promptNow = reportedUsage?.promptTokens ?? Engine.estimate(sending)
                let completionNow = reportedUsage?.completionTokens ?? Int((Double(EText.length(result.text) + result.calls.reduce(0) { $0 + EText.length($1.arguments) }) / Engine.CHARS_PER_TOKEN).rounded(.up))
                tracker.update { $0.promptTokens += promptNow; $0.completionTokens += completionNow; if reportedUsage == nil { $0.estimated = true } }
                if cloud, let usage = result.usage { thread.addUsage(CloudUsage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens)); try turn.persist() }
                if !cloud, let usage = result.usage { thread.addLocalUsage(prompt: usage.promptTokens, completion: usage.completionTokens) }
                if !cloud, let timings = result.timings {
                    if timings.promptN >= 300 && timings.promptPerSecond > 0 { memory.readSpeed = memory.readSpeed * 0.5 + timings.promptPerSecond * 0.5 }
                    if timings.predictedN >= 20 && timings.predictedPerSecond > 0 { memory.writeSpeed = memory.writeSpeed * 0.5 + timings.predictedPerSecond * 0.5 }
                }
                limits = Engine.budgets(memory.readSpeed, contextWindow, cloud: cloud)
                resultLimit.value = limits.resultChars
                let reported = result.usage.flatMap { $0.promptTokens != 0 ? $0.promptTokens + $0.completionTokens : nil }
                gauge(reported ?? expected)
                var message: [String: JSONValue] = ["role": "assistant", "content": .string(result.text)]
                var calls: [ToolCallPart] = []
                if !result.calls.isEmpty {
                    calls = result.calls.map { ToolCallPart(id: $0.id.isEmpty ? EText.hex(8) : $0.id, name: $0.name, arguments: $0.arguments.isEmpty ? "{}" : $0.arguments) }
                    message["tool_calls"] = .array(calls.map { ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]] })
                }
                memory.messages.append(.object(message))
                if let reported { memory.promptTokens = reported; memory.counted = memory.messages.count }
                if !EText.trim(result.text).isEmpty { finalText = EText.trim(result.text) }
                if calls.isEmpty {
                    if result.finish == "length" { finalText += "\n\n(The reply reached its length limit. Send \"continue\" for the rest.)"; break }
                    // The model says it is done: when checking is on, one short review turn compares the work with the request (at most twice).
                    if !reviewing, prefs().check, tracker.current.checks < Engine.CHECK_ROUNDS, changed || tools.todo.contains(where: { !$0.done }) {
                        reviewing = true
                        tracker.update { $0.checks += 1; $0.phase = .checking; $0.todo = tools.todo }
                        job.progress = "Checking the work\u{2026}"
                        note("Check", "Checking the work against the request and the todo list (round \(tracker.current.checks) of \(Engine.CHECK_ROUNDS)).")
                        memory.messages.append(["role": "user", "content": .string(Engine.reviewPrompt(request: request, todo: tools.todo, round: tracker.current.checks))])
                        continue
                    }
                    break
                }
                if reviewing { reviewing = false; tracker.phase(.working) }
                for item in calls {
                    // Arguments that are not JSON, or are the JSON null, go back to the model as an error.
                    let parsed = try? JSONValue.parse(item.arguments)
                    let args = parsed == .null ? nil : parsed
                    let name = EText.prefix(item.name, 60)
                    if tracker.current.phase == .planning, name != "todo" { tracker.phase(.working) }
                    if ["edit", "write", "run", "publish"].contains(name) { changed = true }
                    tracker.update { $0.tool = name; $0.toolStatus = "running" }
                    turn.event(["type": "tool_use", "name": .string(name), "output": .string(EText.prefix(redact(args?.text() ?? item.arguments), 4000))])
                    job.progress = "Using \(name)\u{2026}"; try turn.persist(force: true)
                    var outcome = args == nil
                        ? ToolResult(output: "Error: the arguments were not valid JSON. Call the tool again with valid JSON.", log: nil, error: true)
                        : await dispatch(name, args!)
                    try checkStopped()
                    // The same call with the same arguments and the same result three times in a row is a loop. Say so, and stop the run.
                    if loopGuard.note(name: name, arguments: item.arguments, output: outcome.output) {
                        stuck = "I stopped because I was repeating the same \(name) call three times in a row and getting the same result, so I was going in circles. The last result was: \(EText.prefix(String(outcome.output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""), 200))"
                    }
                    let declined = outcome.log?.contains(" declined") == true
                    tracker.update {
                        $0.toolStatus = outcome.error ? (declined ? "declined" : "failed") : "done"
                        $0.todo = tools.todo
                        if name != "todo" { $0.addRecent(redact(outcome.log ?? "\(name) \(outcome.error ? "failed" : "done")")) }
                    }
                    if let artifact = outcome.artifact, turn.artifactCount < 100 { turn.addArtifact(artifact.json) }
                    if let log = outcome.log, !log.isEmpty { memory.log.append(log) }
                    memory.todo = tools.todo
                    memory.messages.append(["role": "tool", "tool_call_id": .string(item.id), "content": .string(outcome.output)])
                    var done: [String: JSONValue] = ["type": "tool_result", "name": .string(name), "output": .string(EText.prefix(redact(outcome.output), 4000)), "error": .bool(outcome.error)]
                    if let change = outcome.change {
                        var shown = change.json.object ?? [:]
                        shown["diff"] = .string(redact(change.diff))
                        done["change"] = .object(shown)
                    }
                    turn.event(.object(done))
                    job.progress = "Finished \(name)"
                }
                memory.run = tracker.current
                try saveMemory(threadId, memory); try turn.persist(force: true)
                if !stuck.isEmpty { unfinished = stuck; break }
            }
            // A turn that stopped early says so plainly; it never borrows an earlier sentence as its answer.
            tracker.update { $0.phase = unfinished.isEmpty ? .done : .stopped; $0.reason = unfinished.isEmpty ? nil : EText.prefix(redact(unfinished), 400); $0.todo = tools.todo }
            memory.run = tracker.current
            let answer = EText.prefix(redact(!unfinished.isEmpty ? unfinished : !finalText.isEmpty ? finalText : "Done."), 256 * 1024)
            turn.set("content", .string(answer))
            if !unfinished.isEmpty { turn.set("note", "This turn stopped before the task was finished.") }
            if let meter = job.meter { turn.set("meter", meter.json) }
            // A journal entry is a convenience; the turn itself succeeded.
            // No journal entry for a cloud conversation: nothing is written to the vault from it.
            if let vault { _ = try? vault.journal(workspace, request: request, log: Array(memory.log.dropFirst(logStart)), outcome: answer) }
            try saveMemory(threadId, memory); if !cloud { try saveProfile(identity, memory) }
        } catch {
            let cancelled = stop.isCancelled || Task.isCancelled || error is CancellationError
            tracker.update { $0.phase = cancelled ? .stopped : .failed; $0.reason = cancelled ? "Stopped." : EText.prefix(redact(error.localizedDescription), 300); $0.todo = tools.todo }
            memory.run = tracker.current
            try? saveMemory(threadId, memory) // The original failure is the one to report.
            try? turn.persist(force: true)
            if cancelled { throw CancellationError() }
            let text = error.localizedDescription
            throw BlackTeamError(redact(text.isEmpty ? "The agent ended unexpectedly." : text))
        }
    }
}

private final class LimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    init(_ value: Int) { stored = value }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
