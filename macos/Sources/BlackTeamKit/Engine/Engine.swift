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
    private let now: @Sendable () -> Date
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
    private let fetch: HTTPStreamFetch
    private let now: @Sendable () -> Date
    private let graph: @Sendable () -> String
    private let home: String
    private let useRtk: Bool
    private let cloudRules: CloudRules

    /// graph: returns the graphify executable when one is installed, so Code can ask a map of the workspace.
    public init(stateDir: String, vault: Memory? = nil, fetch: @escaping HTTPStreamFetch = LocalHTTP.stream,
                now: @escaping @Sendable () -> Date = { Date() }, graph: @escaping @Sendable () -> String = { "" },
                home: String = NSHomeDirectory(), useRtk: Bool = true, cloud: CloudRules = .standard) throws {
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
            for call in message["tool_calls"]?.array ?? [] where ["recall", "remember"].contains(call["function"]?["name"]?.string ?? "") {
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
        let stop = CancelSignal()
        let unobserve = signal?.observe { stop.cancel() }
        defer { unobserve?() }
        if signal?.isCancelled == true { stop.cancel() }
        try await withTaskCancellationHandler {
            try await self.perform(thread: thread, config: config, runtime: runtime, endpoint: endpoint, job: job, stop: stop, save: save, mode: mode, workspace: workspace ?? config.workspace)
        } onCancel: { stop.cancel() }
    }

    private func perform(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, stop: CancelSignal,
                         save: @escaping @Sendable (JSONValue) throws -> Void, mode: String, workspace: String) async throws {
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
        let started = now()
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
                    continuation.resume(returning: choice)
                }
                timer.task = Task {
                    try? await Task.sleep(nanoseconds: UInt64(approvalSeconds) * 1_000_000_000)
                    if Task.isCancelled { return }
                    if unattended != nil { ledger.expire() }
                    finish("deny")
                }
                gate.set { finish("deny") }
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
        if remembers { schemas += MEMORY_TOOLS.array ?? [] }
        // Core memory is read once per conversation and then left alone, so the cached prompt stays valid.
        if let vault, memory.core == nil { memory.core = vault.core() }
        var system = Engine.SYSTEM(workspace, cloud: cloud)
        if !mapper.isEmpty { system += "\nThe map tool knows this code: ask it which files and functions matter before reading many files. It answers with paths and line numbers." }
        if remembers {
            system += "\nYou have a memory that lasts across conversations. Use recall when a task refers to earlier work or to the user's preferences, and remember to save a lasting fact once you have verified it."
            if let core = memory.core, !core.isEmpty { system += "\n\nWhat you already know about the user:\n\(core)" }
        }
        let dispatch: (String, JSONValue) async -> ToolResult = { name, args in
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
        memory.messages.append(["role": "user", "content": .string(request)])
        note("Black Team engine", cloud
            ? "Ready \u{00B7} cloud model at \(cloudTarget?.host ?? "") \u{00B7} working budget \(EText.grouped(limits.working)) of \(EText.grouped(contextWindow)) tokens \u{00B7} memory is not used"
            : "Ready \u{00B7} reads about \(EText.round(memory.readSpeed)) tokens/s \u{00B7} working budget \(EText.grouped(limits.working)) of \(EText.grouped(contextWindow)) tokens")
        job.progress = "Reading the task\u{2026}"

        // Shown live beside the mode switch: measured speeds, and how full the working budget is.
        func gauge(_ used: Int) {
            job.meter = cloud ? JobMeter(used: used, budget: limits.working, window: contextWindow, trims: memory.trims)
                : JobMeter(read: EText.round(memory.readSpeed), write: EText.round(memory.writeSpeed), used: used, budget: limits.working, window: contextWindow, trims: memory.trims)
        }
        gauge(memory.promptTokens)
        let maxTokens = min(Engine.OUTPUT_TOKENS[mode] ?? 4096, contextWindow / 4)
        var finalText = "", unfinished = "", stuck = ""
        var repeats: [String: Int] = [:]
        do {
            var step = 0
            while true {
                step += 1
                try checkStopped()
                if step > Engine.MAX_STEPS {
                    unfinished = "I stopped at the limit of \(Engine.MAX_STEPS) steps for one turn, and the task is not finished. Send \"continue\" and I will pick up from my todo list."; break
                }
                if now().timeIntervalSince(started) - ledger.waited > Double(Engine.RUN_SECONDS) {
                    unfinished = "I stopped at the time limit for one turn, and the task is not finished. Send \"continue\" and I will pick up from my todo list."; break
                }
                let size = max(memory.promptTokens != 0 ? memory.promptTokens + Engine.estimate(Array(memory.messages.dropFirst(memory.counted ?? 0))) : 0, Engine.estimate(memory.messages) + 900)
                if size > limits.working {
                    memory.todo = tools.todo
                    if Engine.trim(&memory, limits.working) {
                        memory.promptTokens = 0; memory.counted = 0
                        job.progress = "Trimming earlier steps\u{2026}"
                        note("Context", "Trimmed earlier steps: about \(EText.grouped(size)) \u{2192} \(EText.grouped(Engine.estimate(memory.messages) + 900)) tokens. Work log and todo kept. No model call needed.")
                    }
                }
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
                if cloud, let usage = result.usage { thread.addUsage(CloudUsage(prompt: usage.promptTokens, completion: usage.completionTokens, cached: usage.cachedTokens)); try turn.persist() }
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
                    if result.finish == "length" { finalText += "\n\n(The reply reached its length limit. Send \"continue\" for the rest.)" }
                    break
                }
                for item in calls {
                    // Arguments that are not JSON, or are the JSON null, go back to the model as an error.
                    let parsed = try? JSONValue.parse(item.arguments)
                    let args = parsed == .null ? nil : parsed
                    let name = EText.prefix(item.name, 60)
                    turn.event(["type": "tool_use", "name": .string(name), "output": .string(EText.prefix(redact(args?.text() ?? item.arguments), 4000))])
                    job.progress = "Using \(name)\u{2026}"; try turn.persist(force: true)
                    var outcome = args == nil
                        ? ToolResult(output: "Error: the arguments were not valid JSON. Call the tool again with valid JSON.", log: nil, error: true)
                        : await dispatch(name, args!)
                    try checkStopped()
                    // A model that repeats a call and gets the same answer is stuck. Say so, then stop the turn.
                    let repeatKey = "\(name) \(item.arguments) \(outcome.output)"
                    let seen = (repeats[repeatKey] ?? 0) + 1
                    repeats[repeatKey] = seen
                    if seen == 3 { outcome.output += "\n\n[You have made this exact call three times with the same result. Repeating it will not help. Try a different approach, or tell the user what is blocking you.]" }
                    if seen >= 5 { stuck = "I stopped because I was repeating the same \(name) call without progress. The last result was: \(EText.prefix(String(outcome.output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""), 200))" }
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
                try saveMemory(threadId, memory); try turn.persist(force: true)
                if !stuck.isEmpty { unfinished = stuck; break }
            }
            // A turn that stopped early says so plainly; it never borrows an earlier sentence as its answer.
            let answer = EText.prefix(redact(!unfinished.isEmpty ? unfinished : !finalText.isEmpty ? finalText : "Done."), 256 * 1024)
            turn.set("content", .string(answer))
            if !unfinished.isEmpty { turn.set("note", "This turn stopped before the task was finished.") }
            if let meter = job.meter { turn.set("meter", meter.json) }
            // A journal entry is a convenience; the turn itself succeeded.
            // No journal entry for a cloud conversation: nothing is written to the vault from it.
            if let vault { _ = try? vault.journal(workspace, request: request, log: Array(memory.log.dropFirst(logStart)), outcome: answer) }
            try saveMemory(threadId, memory); if !cloud { try saveProfile(identity, memory) }
        } catch {
            try? saveMemory(threadId, memory) // The original failure is the one to report.
            if stop.isCancelled || Task.isCancelled || error is CancellationError { throw CancellationError() }
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
