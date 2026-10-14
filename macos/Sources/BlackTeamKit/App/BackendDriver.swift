import Foundation

// A driven run (Room/RoomDriver.swift): a paid member works on the goal and hands pieces of it to the other members while it works.
//
// Nesting: ONE job is the foreground job (`active`, `job`): the driver's. Delegated member runs are CHILDREN of it, kept in the
// `DriverScope` and not in `active`, so the rest of Black Team still sees one job. Local models share one slot (`gate`): they run one at
// a time, the model that is loaded first, because switching stops it. A cloud model or a subscription agent may run beside a local one.
// Stop on the run stops the driver and every child.
//
// Privacy: the agreement (`teamPreviewBuild`) says that the local members' results go to the driver's service. Every child goes through
// `submitCore` / `submitAgentTask`, so the gate (BackendCloud.swift) decides each one. No memory vault is used when any member is cloud.

/// Lets one holder in at a time, in order, preferring a waiter that wants what the last holder had (the model already loaded).
final class FairGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var closed = false
    private var waiters: [(key: String, cont: CheckedContinuation<Bool, Never>)] = []
    private var lastKey: String?

    init(last: String? = nil) { lastKey = last }
    var last: String? { lock.lock(); defer { lock.unlock() }; return lastKey }
    /// The model that is loaded now, so a waiter that wants it goes first.
    func prefer(_ key: String?) { lock.lock(); lastKey = key; lock.unlock() }

    private func enter(_ key: String, _ cont: CheckedContinuation<Bool, Never>) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        if !held { held = true; return true }
        waiters.append((key, cont))
        return nil
    }

    /// False when the gate was closed (the run stopped) before this caller got in.
    func acquire(_ key: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if let answer = enter(key, cont) { cont.resume(returning: answer) }
        }
    }

    func release(_ key: String) {
        lock.lock()
        lastKey = key
        var next: CheckedContinuation<Bool, Never>?
        if waiters.isEmpty { held = false } else {
            let at = waiters.firstIndex { $0.key == key } ?? 0
            next = waiters.remove(at: at).cont
        }
        lock.unlock()
        next?.resume(returning: true)
    }

    func close() {
        lock.lock(); closed = true; let all = waiters; waiters = []; lock.unlock()
        all.forEach { $0.cont.resume(returning: false) }
    }
}

/// One delegated member run, under a driver.
final class ChildRun: @unchecked Sendable {
    let threadId: String
    let job: JobState
    let signal: CancelSignal
    let ref: ThreadRef
    let local: Bool
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    /// The id of the approval card shown on the driver's job on this child's behalf.
    var mirrored: String?
    init(threadId: String, job: JobState, signal: CancelSignal, ref: ThreadRef, local: Bool) {
        self.threadId = threadId; self.job = job; self.signal = signal; self.ref = ref; self.local = local
    }
    var task: Task<Void, Never>? { get { lock.lock(); defer { lock.unlock() }; return _task } set { lock.lock(); _task = newValue; lock.unlock() } }
}

/// How a subscription-agent driver reaches the tools: its own MCP server, started for this one launch.
struct AgentRoomLink: Sendable {
    var program: String
    var runFile: String
}

/// Everything about one driven run that the tools need. Also the object the tools talk to (`RoomToolHost`).
final class DriverScope: RoomToolHost, @unchecked Sendable {
    let context: TeamContext
    let cap: DriveCaps
    let gate: FairGate
    /// Held from choosing a member's model until its run has started, so two starts never fight over the selected model.
    let startGate = FairGate()
    let brief: String
    weak var backend: Backend?
    private let lock = NSLock()
    private var children: [String: ChildRun] = [:]
    /// Member runs that have ended, kept so a delegation that finds its run already over can still wait on it and read its end.
    private var ended: [String: ChildRun] = [:]
    private var list: [Delegation] = []
    private var used = 0
    private var _thread: String?
    private var _accepting = true
    private var _loaded: String?
    private var _link: AgentRoomLink?
    private var _capped: String?
    var started: Date

    init(context: TeamContext, cap: DriveCaps, loaded: String?, started: Date) {
        self.context = context; self.cap = cap; self.started = started
        gate = FairGate(last: loaded); _loaded = loaded
        brief = RoomTools.brief(goal: context.goal, driver: context.lead.name)
    }

    var runId: String { context.control.runId }
    var driver: RoomMember { context.lead }
    var others: [RoomMember] { context.members.filter { $0.id != context.lead.id } }
    var driverThread: String? { get { lock.lock(); defer { lock.unlock() }; return _thread } set { lock.lock(); _thread = newValue; lock.unlock() } }
    var loaded: String? { get { lock.lock(); defer { lock.unlock() }; return _loaded } set { lock.lock(); _loaded = newValue; lock.unlock() } }
    var link: AgentRoomLink? { get { lock.lock(); defer { lock.unlock() }; return _link } set { lock.lock(); _link = newValue; lock.unlock() } }
    /// Why the run must stop at a cap, once a tool call has seen one passed.
    var capped: String? { get { lock.lock(); defer { lock.unlock() }; return _capped } set { lock.lock(); _capped = newValue; lock.unlock() } }
    var accepting: Bool { lock.lock(); defer { lock.unlock() }; return _accepting }
    var delegations: [Delegation] { lock.lock(); defer { lock.unlock() }; return list }
    var delegationCount: Int { lock.lock(); defer { lock.unlock() }; return used }

    /// Takes one of the run's delegations; false at the cap.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used >= cap.delegations { return false }; used += 1; return true }

    func record(_ delegation: Delegation) {
        lock.lock()
        if let at = list.firstIndex(where: { $0.id == delegation.id }) { list[at] = delegation } else { list.append(delegation) }
        if list.count > DriveLimits.kept { list.removeFirst(list.count - DriveLimits.kept) }
        lock.unlock()
    }

    func add(_ child: ChildRun) { lock.lock(); children[child.threadId] = child; lock.unlock() }
    func remove(_ threadId: String) { lock.lock(); if let child = children.removeValue(forKey: threadId) { ended[threadId] = child }; lock.unlock() }
    func child(_ threadId: String) -> ChildRun? { lock.lock(); defer { lock.unlock() }; return children[threadId] ?? ended[threadId] }
    func runningChild(_ threadId: String) -> ChildRun? { lock.lock(); defer { lock.unlock() }; return children[threadId] }
    var running: [ChildRun] { lock.lock(); defer { lock.unlock() }; return Array(children.values) }

    /// Stop on the run: nothing new starts, waiting local members are turned away, and every child is cancelled.
    func stopAll() {
        lock.lock(); _accepting = false; let all = Array(children.values); lock.unlock()
        gate.close(); startGate.close()
        for child in all { child.signal.cancel(); child.task?.cancel() }
    }

    func callTool(_ name: String, _ arguments: JSONValue) async -> RoomToolReply {
        guard let backend else { return RoomToolReply("This run has ended.", isError: true) }
        return await backend.driverCall(self, name, arguments)
    }
}

/// The driven runs in progress, by run id.
final class DriverRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [String: DriverScope] = [:]
    func add(_ scope: DriverScope) { lock.lock(); scopes[scope.runId] = scope; lock.unlock() }
    func remove(_ runId: String) { lock.lock(); scopes[runId] = nil; lock.unlock() }
    func scope(_ runId: String) -> DriverScope? { lock.lock(); defer { lock.unlock() }; return scopes[runId] }
    func scope(driverThread id: String?) -> DriverScope? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return scopes.values.first { $0.driverThread == id }
    }
    func child(_ threadId: String) -> ChildRun? {
        lock.lock(); let all = Array(scopes.values); lock.unlock()
        return all.lazy.compactMap { $0.child(threadId) }.first
    }
    /// A member run that is still going.
    func runningChild(_ threadId: String) -> ChildRun? {
        lock.lock(); let all = Array(scopes.values); lock.unlock()
        return all.lazy.compactMap { $0.runningChild(threadId) }.first
    }
}

extension Backend {
    // MARK: Who can drive

    func canDrive(_ view: RoomMemberView) -> Bool {
        view.kind == "cloud" && (view.agent != nil || view.work == "code")
    }

    /// Whether this member would run as a driver: it is paid, can use tools, and has other members to hand work to.
    public func roomCanDrive(projectId: String, leadId: String?) -> Bool {
        guard let project = try? roomProject(projectId) else { return false }
        roomLock.lock(); defer { roomLock.unlock() }
        let data = roomLoad(projectId)
        guard data.members.count > 1, let lead = try? teamLead(data, leadId) else { return false }
        return canDrive(roomView(lead, project: project))
    }

    // MARK: The run

    func driveStart(_ c: TeamContext) {
        let scope = DriverScope(context: c, cap: driveCapsOverride ?? .standard, loaded: nil, started: now())
        scope.backend = self
        drivers.add(scope)
        c.control.task = Task { [self] in await driveMain(scope) }
    }

    /// The local model the runtime holds right now, when a local model is the one selected.
    private func driveLoadedKey() async -> String? {
        guard let model = try? configStore.read().model, model.source != "cloud" else { return nil }
        return await runtime.status().ready ? keyOf(model) : nil
    }

    private func driveMain(_ scope: DriverScope) async {
        let c = scope.context
        var phase = TeamPhase.done, message = "", text = ""
        let original = try? configStore.read().model
        let loaded = await driveLoadedKey()
        scope.loaded = loaded
        scope.gate.prefer(loaded)
        var bridge: RoomBridge?
        do {
            teamPhase(c, .working)
            if scope.driver.agent != nil {
                let started = try RoomBridge.start(dataFolder: dataFolder, host: scope, program: bridgeProgram())
                bridge = started
                scope.link = AgentRoomLink(program: started.program, runFile: started.runFile)
            }
            teamLog(c, member: scope.driver, kind: "system", taskId: nil, "\(scope.driver.name) is driving. It may hand work to: \(scope.others.map(\.name).joined(separator: ", ")).")
            let project = try roomProject(c.projectId)
            let send: (String) throws -> SubmitResult
            do {
                send = try await roomSender(member: scope.driver, message: scope.brief, threadId: nil, projectId: c.projectId, project: project, origin: c.origin,
                                            useMemory: false, readOnly: false, nested: nil, driving: scope)
            } catch { throw TeamEnd.failed(messageOf(error)) }
            let sent: SubmitResult
            do { sent = try send(UUID().uuidString.lowercased()) } catch { throw TeamEnd.failed(messageOf(error)) }
            scope.driverThread = sent.threadId
            c.control.thread = sent.threadId
            try await driveWait(scope, threadId: sent.threadId)
            let reply = teamReply(threadId: sent.threadId)
            if let answer = reply.text { text = answer } else { throw TeamEnd.failed("\(scope.driver.name) could not finish: \(reply.error)") }
        } catch let end as TeamEnd {
            switch end {
            case .stopped(let why): phase = .stopped; message = why
            case .failed(let why): phase = .failed; message = why
            }
        } catch { phase = .failed; message = messageOf(error) }
        // Whatever ended the driver, nothing runs beneath it afterwards.
        scope.stopAll()
        for child in scope.running { await child.task?.value }
        bridge?.stop()
        if phase == .done {
            for d in scope.delegations where d.status == .done { _ = try? roomAccept(projectId: c.projectId, taskId: d.taskId, by: "The driver") }
        }
        let ledger = driveLedger(scope)
        if phase == .done, text.isEmpty { text = "Done." }
        let report = phase == .done ? TeamStore.text(EText.prefix(text, TeamLimits.report - 600) + "\n\n" + ledger.summary, TeamLimits.report) : ""
        teamLog(c, member: nil, kind: "system", taskId: nil, (phase == .done ? "The driven run finished. " : message + " ") + ledger.summary)
        teamUpdate(c) { team in
            team.phase = phase; team.current = nil; team.message = TeamStore.text(message, TeamLimits.message); team.ledger = ledger
            team.delegations = scope.delegations
            if phase == .done { team.report = report }
        }
        await driveRestore(original, loaded: scope.loaded)
        drivers.remove(scope.runId)
        locked { teamControl = nil }
        changed()
    }

    /// Waits for the driver's own job while watching Stop, Black Team closing, the time cap and the paid-token cap.
    private func driveWait(_ scope: DriverScope, threadId: String) async throws {
        let c = scope.context
        var reason: String?
        while teamRunning(threadId) {
            if c.control.stopped { reason = "Stopped by you." }
            else if locked({ closing }) { reason = "Black Team was closed during this run." }
            else if now() >= c.deadline { reason = "Stopped at the time cap: a run is limited to \(TeamLimits.minutes) minutes." }
            else if let capped = scope.capped ?? driveCapReason(scope) { reason = capped }
            if reason != nil { cancel(); scope.stopAll(); break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForIdle()
        c.control.thread = nil
        // A cap the driver ran into while it was still working ends the run as stopped, however quickly it then finished.
        if reason == nil, let capped = scope.capped { reason = capped }
        if let reason { throw TeamEnd.stopped(reason) }
        if c.control.stopped { throw TeamEnd.stopped("Stopped by you.") }
    }

    private func driveCapReason(_ scope: DriverScope) -> String? {
        let paid = driveLedger(scope).paidTokens
        if paid > scope.cap.paidTokens {
            return "Stopped at the paid-token cap: a run is limited to \(EText.grouped(scope.cap.paidTokens)) tokens on paid services (\(EText.grouped(paid)) used)."
        }
        return nil
    }

    /// Puts the selected model back to what it was before the run.
    private func driveRestore(_ original: ModelConfig?, loaded: String?) async {
        guard let original, let current = try? configStore.read().model, keyOf(current) != keyOf(original),
              let saved = savedModels.find(keyOf(original)) else { return }
        if saved.source == "cloud" || keyOf(original) == loaded { try? configStore.save(["model": modelJSON(saved)]) }
        else { _ = try? await exclusive { try await switchModel(key: keyOf(original), saved: savedModels, configStore: configStore, stop: { try await self.runtime.stop(force: false) }, busy: { false }) } }
        changed()
    }

    func bridgeProgram() -> String { bridgeProgramOverride ?? RoomBridge.defaultProgram() }

    // MARK: Ledger

    /// Tokens and time per member and for the driver, from what the engines and tools reported. Anything unreported is not measured.
    func driveLedger(_ scope: DriverScope) -> RunLedger {
        let c = scope.context
        let seconds = Int(max(0, now().timeIntervalSince(scope.started)))
        var lines: [LedgerLine] = []
        func usage(_ thread: JSONValue?, paid: Bool) -> (Int?, Int?) {
            guard let thread, let raw = thread[paid ? "usage" : "localUsage"], raw.object != nil else { return (nil, nil) }
            let u = CloudUsage(json: raw)
            return (u.prompt, u.completion)
        }
        let driverThread = scope.driverThread
        let ref = locked { liveThread }
        let live: JSONValue? = driverThread.flatMap { id in ref?.value["id"]?.string == id ? ref?.value : history.get(id) }
        let d = usage(live, paid: true)
        lines.append(LedgerLine(name: scope.driver.name, role: "driver", paid: true, prompt: d.0, completion: d.1, seconds: seconds, runs: driverThread == nil ? 0 : 1))
        var order: [String] = []
        for delegation in scope.delegations where !order.contains(delegation.memberId) { order.append(delegation.memberId) }
        for id in order {
            let mine = scope.delegations.filter { $0.memberId == id }
            guard let first = mine.first else { continue }
            let measured = mine.allSatisfy { $0.promptTokens != nil && $0.completionTokens != nil }
            let role = c.members.first { $0.id == id }?.role ?? ""
            lines.append(LedgerLine(name: first.memberName, role: role, paid: first.paid,
                                    prompt: measured ? mine.reduce(0) { $0 + ($1.promptTokens ?? 0) } : nil,
                                    completion: measured ? mine.reduce(0) { $0 + ($1.completionTokens ?? 0) } : nil,
                                    seconds: mine.reduce(0) { $0 + $1.seconds }, runs: mine.count))
        }
        return RunLedger(lines: lines)
    }

    // MARK: Tools

    func driverCall(_ scope: DriverScope, _ name: String, _ args: JSONValue) async -> RoomToolReply {
        switch name {
        case "team": return RoomToolReply(driverTeam(scope))
        case "delegate": return await driverDelegate(scope, args)
        default: return RoomToolReply("Unknown tool \(name). Tools: team, delegate.", isError: true)
        }
    }

    private func speedIdentity(_ model: ModelConfig) -> String {
        let source = model.source.isEmpty ? "gguf" : model.source
        return "\(source):\(model.source == "server" || model.source == "cloud" ? model.id : (model.file as NSString).lastPathComponent)"
    }

    /// The other members, in the words the driver sizes its jobs by.
    func driverTeam(_ scope: DriverScope) -> String {
        guard let project = try? roomProject(scope.context.projectId) else { return "The project is gone." }
        var rows: [String] = []
        for member in scope.others {
            let view = roomView(member, project: project)
            var parts = [TeamText.planName(member, among: scope.others) + ":", member.role.isEmpty ? "no role set;" : "role \(member.role);"]
            parts.append(view.kind == "local" ? "runs on \(Place.this) (free, private);" : "paid, runs on \(view.provider);")
            parts.append(member.service != nil ? "does agent work with its own tools in the project folder;"
                : member.work == "chat" ? "chat work: answers in text, cannot read or change files;" : "code work: reads, searches and (if allowed) changes files in the project folder;")
            let tools = member.service != nil || member.work != "chat"
            var vision = "unknown"
            if let key = member.modelKey, let model = savedModels.find(key), model.source == "gguf" { vision = model.mmproj.isEmpty ? "no" : "yes" }
            if member.service != nil { vision = "unknown" }
            parts.append("tools: \(tools ? "yes" : "no"); vision: \(vision);")
            if view.kind == "local", let key = member.modelKey, let model = savedModels.find(key) {
                if let speed = engine?.measuredSpeeds(identity: speedIdentity(model)) {
                    parts.append("reads about \(EText.round(speed.read)) tokens/s (about \(EText.grouped(EText.round(speed.read * 300))) in 5 minutes), writes about \(EText.round(speed.write)) tokens/s;")
                } else { parts.append("speed not measured yet;") }
                parts.append(scope.loaded == key ? "loaded now." : "not loaded (starting it stops the loaded model).")
            }
            if !view.usable { parts.append("NOT AVAILABLE: \(view.reason)") }
            rows.append("- " + parts.joined(separator: " "))
        }
        let left = max(0, scope.cap.delegations - scope.delegationCount)
        return rows.joined(separator: "\n") + "\n\nDelegations left in this run: \(left). Local members share one model and run one at a time, the loaded model first; a paid member may run at the same time as a local one."
    }

    private func clean(_ value: JSONValue?) -> String { value?.string ?? "" }

    func driverDelegate(_ scope: DriverScope, _ args: JSONValue) async -> RoomToolReply {
        let c = scope.context
        func refuse(_ why: String) -> RoomToolReply { RoomToolReply(why, isError: true) }
        let task = EText.trim(clean(args["task"]))
        if EText.trim(clean(args["member"])).isEmpty || task.isEmpty { return refuse("delegate needs a member and a task.") }
        if EText.length(task) > DriveLimits.task || RoomStore.clean(.string(task), max: DriveLimits.task, multiline: true) == nil {
            return refuse("The task is up to \(EText.grouped(DriveLimits.task)) characters of plain text. Shorten it, and name files instead of pasting them.")
        }
        var files: [String] = []
        if let given = args["files"], given != .null {
            guard let list = given.array, list.count <= DriveLimits.files else { return refuse("files is a list of up to \(DriveLimits.files) paths.") }
            for item in list {
                guard let path = item.string, !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), !path.contains(".."),
                      RoomStore.clean(.string(path), max: 200) != nil else { return refuse("Each file must be a path inside the project folder, such as src/app.js.") }
                files.append(path)
            }
        }
        let write = args["may_change_files"]?.bool == true
        guard let member = TeamText.planMember(clean(args["member"]), members: scope.others) else {
            return refuse("No member called \u{201C}\(clean(args["member"]))\u{201D}. Call team to see the names.")
        }
        do { try driverCheckpoint(scope) } catch let end as TeamEnd { return refuse(driverWhy(end)) } catch { return refuse(messageOf(error)) }
        guard let project = try? roomProject(c.projectId) else { return refuse("The project is gone.") }
        let view = roomView(member, project: project)
        if !view.usable { return refuse("\(member.name) cannot be used: \(view.reason)") }
        if write && member.modelKey != nil && member.work == "chat" {
            return refuse("\(member.name) does chat work and cannot change files. Set may_change_files to false, or choose a member that does code work.")
        }
        if let capped = driveCapReason(scope) { scope.capped = capped; return refuse(capped + " The run is being stopped; do not delegate again.") }
        guard scope.take() else { return refuse("This run has used its \(scope.cap.delegations) delegations. Finish the goal with what you have, or report what is left.") }
        do { try teamCountRun(c) } catch { return refuse("This run has used its member runs (\(TeamLimits.runs)). Finish with what you have.") }

        let title = EText.prefix(String(task.split(whereSeparator: \.isNewline).first ?? Substring(task)), RoomLimits.title)
        let added: RoomTask
        do { added = try roomAddTask(projectId: c.projectId, title: title, detail: task, assignee: member.id).tasks.last! }
        catch { return refuse(messageOf(error)) }
        var delegation = Delegation(id: UUID().uuidString.lowercased(), memberId: member.id, memberName: member.name, taskId: added.id, title: title, write: write,
                                    status: .queued, started: roomNow(), finished: nil, changed: nil, result: "", error: "", paid: view.kind == "cloud",
                                    promptTokens: nil, completionTokens: nil, seconds: 0)
        func publish() {
            scope.record(delegation)
            teamUpdate(c) { $0.delegations = scope.delegations; $0.ledger = self.driveLedger(scope) }
        }
        publish()
        teamLog(c, member: member, kind: "delegate", taskId: added.id, "\(scope.driver.name) gave \(member.name): \(title)\(write ? "" : " (read-only)")")


        let began = now()
        func finish(_ requested: DelegationStatus, _ error: String, threadId: String? = nil) -> RoomToolReply {
            // Whatever went wrong after Stop is the Stop.
            let ended = c.control.stopped || !scope.accepting
            let status: DelegationStatus = ended && requested != .done ? .stopped : requested
            let error = status == .stopped && requested != .stopped ? "Stopped." : error
            delegation.status = status; delegation.error = error; delegation.finished = roomNow()
            delegation.seconds = Int(max(0, now().timeIntervalSince(began)))
            if let threadId, let thread = history.get(threadId) {
                let u = CloudUsage(json: thread[delegation.paid ? "usage" : "localUsage"])
                if thread[delegation.paid ? "usage" : "localUsage"]?.object != nil { delegation.promptTokens = u.prompt; delegation.completionTokens = u.completion }
            }
            publish()
            teamLog(c, member: member, kind: "delegate", taskId: added.id,
                    status == .done ? "\(member.name) finished: \(title)" + (delegation.changed.flatMap { $0 > 0 ? " \u{00B7} \($0) file\($0 == 1 ? "" : "s") changed" : nil } ?? "")
                                    : "\(member.name) did not finish: \(error)")
            if status == .done {
                let files = delegation.changed.map { $0 > 0 ? "\($0) file\($0 == 1 ? "" : "s") changed" : "no files changed" } ?? "file changes not known"
                let result = delegation.result
                return RoomToolReply("Result from \(member.name) (\(files)):\n\(result)")
            }
            return RoomToolReply("\(member.name) did not finish: \(error)", isError: true)
        }

        let key = member.modelKey.flatMap { savedModels.find($0) }.flatMap { $0.source == "cloud" ? nil : $0 }.map { keyOf($0) }
        var holdsGate = false
        if let key {
            guard await scope.gate.acquire(key) else { return finish(.stopped, "Stopped by you.") }
            holdsGate = true
        }
        defer { if holdsGate, let key { scope.gate.release(key) } }
        delegation.status = .running; publish()

        var message = task
        if !files.isEmpty { message += "\n\nFiles to look at (paths relative to the project folder):\n" + files.map { "- " + $0 }.joined(separator: "\n") }
        message += write ? "\n\nYou may change files in the project folder. Reply with what you changed and what you checked."
            : "\n\nThis is a read-only job: do not change any file. Reply with your findings."
        message += "\nReply with a result that can be used without asking you anything."

        let state: RoomState
        guard await scope.startGate.acquire("") else { return finish(.stopped, "Stopped by you.") }
        do {
            state = try await roomStartTask(projectId: c.projectId, taskId: added.id, from: c.origin, message: message, useMemory: c.useMemory, nested: scope, readOnly: !write)
        } catch {
            scope.startGate.release("")
            return finish(.failed, messageOf(error))
        }
        scope.startGate.release("")
        if key != nil { scope.loaded = key }
        guard let threadId = state.tasks.first(where: { $0.id == added.id })?.threadId, let child = scope.child(threadId) else {
            return finish(.failed, "The run could not be found after it started.")
        }
        await child.task?.value
        roomFinish(projectId: c.projectId, taskId: added.id, threadId: threadId)
        guard let board = try? room(projectId: c.projectId), let current = board.tasks.first(where: { $0.id == added.id }) else {
            return finish(.failed, "The task is no longer on the board.", threadId: threadId)
        }
        if c.control.stopped || !scope.accepting { return finish(.stopped, "Stopped by you.", threadId: threadId) }
        if current.status == .review {
            delegation.changed = current.changed
            let full = current.result.isEmpty ? "(no text)" : current.result
            let clipped = EText.length(full) > DriveLimits.result
                ? EText.prefix(full, DriveLimits.result) + "\n[Clipped: \(EText.grouped(EText.length(full) - DriveLimits.result)) more characters are on the room's board.]" : full
            delegation.result = EText.prefix(full, 1200)
            let reply = finish(.done, "", threadId: threadId)
            let files = current.changed.map { $0 > 0 ? "\($0) file\($0 == 1 ? "" : "s") changed" : "no files changed" } ?? "file changes not known"
            return RoomToolReply("Result from \(member.name) (\(files)):\n\(clipped)", isError: reply.isError)
        }
        return finish(.failed, current.note.isEmpty ? "The run did not finish." : current.note, threadId: threadId)
    }

    private func driverWhy(_ end: TeamEnd) -> String {
        switch end { case .stopped(let why), .failed(let why): return why }
    }

    private func driverCheckpoint(_ scope: DriverScope) throws {
        if !scope.accepting { throw TeamEnd.stopped("This run has been stopped.") }
        try teamCheckpoint(scope.context)
    }

    // MARK: Choosing the model for a child

    /// Makes `key` the selected model without the busy check (the driver's own job is running), stopping a different loaded local model.
    /// Called with the start gate held, so no other child chooses a model at the same time.
    func driverSelect(_ scope: DriverScope, key: String) async throws {
        let config = try configStore.read()
        if keyOf(config.model) == key { return }
        guard let model = savedModels.find(key) else { throw BlackTeamError("The model for this member is no longer in your list.") }
        if model.source == "cloud" || key == scope.loaded {
            try configStore.save(["model": modelJSON(model)])
            changed()
            return
        }
        _ = try await exclusive {
            try await switchModel(key: key, saved: savedModels, configStore: configStore, stop: { try await self.runtime.stop(force: false) }, busy: { false })
        }
        changed()
    }

    // MARK: Children of the foreground job

    /// Shows an approval a child needs on the driver's job, which is the one the person answers; the answer goes to the child.
    func driverMirror(_ child: ChildRun) {
        _ = child.job.observe { [weak self, weak child] snapshot in
            guard let self, let child, let primary = self.locked({ self.job }) else { return }
            if let approval = snapshot.approval {
                if primary.approval == nil {
                    child.mirrored = approval.id
                    primary.present(approval) { answer in try child.job.approve(answer) }
                }
            } else if let shown = child.mirrored, primary.approval?.id == shown {
                child.mirrored = nil
                primary.withdraw()
            }
        }
    }

    /// Stop on the foreground job also stops what runs beneath it.
    func driverStopChildren(ofThread id: String?) {
        drivers.scope(driverThread: id)?.stopAll()
    }
}
