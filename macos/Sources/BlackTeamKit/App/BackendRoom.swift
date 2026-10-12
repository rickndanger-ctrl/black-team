import Foundation

// The room: a task board per project. The lead adds tasks, assigns each to a member (a local model, a cloud model, Claude Code
// or Codex), starts it, reviews the result, and hands work from one member to another with a button.
//
// Privacy: starting a task goes through `submit` / `submitAgentTask`, so the gate (BackendCloud.swift) decides every time.
// The only way one member's output reaches another is `roomHandOff`, after the lead has seen the exact text (`roomHandOffPreview`).

/// One lock for every room file, so reading, reconciling and writing never interleave.
let roomLock = NSRecursiveLock()

/// The tasks waiting for a run to end.
final class RoomWatchers: @unchecked Sendable {
    static let shared = RoomWatchers()
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    func add(_ make: (UUID) -> Task<Void, Never>) { let id = UUID(); lock.lock(); tasks[id] = make(id); lock.unlock() }
    func done(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func all() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return Array(tasks.values) }
}

private let fileChangeTools: Set<String> = ["edit", "write", "multiedit", "notebookedit", "file change", "write_file", "edit_file", "apply_patch"]

extension Backend {
    // MARK: Reading

    func roomProject(_ id: String) throws -> Project {
        guard History.validID(id) else { throw BlackTeamError("Invalid project.") }
        guard let project = locked({ projects.first { $0.id == id } }) else { throw BlackTeamError("That project no longer exists.") }
        return project
    }

    func roomNow() -> String { EText.iso(now()) }

    /// Loads the room, settling any task left `doing` with no job behind it, and saves when that changed something.
    func roomLoad(_ projectId: String) -> RoomData {
        var data = RoomStore.load(dataFolder: dataFolder, projectId: projectId)
        let tasks = roomReconcile(&data)
        let team = teamReconcile(&data)
        if tasks || team { try? RoomStore.save(data, dataFolder: dataFolder, projectId: projectId) }
        return data
    }

    func roomMutate(_ projectId: String, _ body: (inout RoomData) throws -> Void) throws -> RoomState {
        let project = try roomProject(projectId)
        roomLock.lock(); defer { roomLock.unlock() }
        var data = roomLoad(projectId)
        try body(&data)
        try RoomStore.save(data, dataFolder: dataFolder, projectId: projectId)
        changed()
        return roomState(project, data)
    }

    private func roomRunning(threadId: String?) -> Bool {
        guard let threadId else { return false }
        return locked { active != nil && job?.threadId == threadId }
    }

    /// What a finished (or abandoned) conversation says about a task: its reply, or why it did not finish.
    func roomOutcome(threadId: String?) -> (result: String, changed: Int?, error: String?) {
        guard let threadId, let thread = history.get(threadId), let last = thread["messages"]?.array?.last, last["role"]?.string == "assistant" else {
            return ("", nil, "The conversation for this task could not be found.")
        }
        switch last["state"]?.string {
        case "done":
            let events = last["events"]?.array
            let count = events.map { list in list.filter { $0["type"]?.string == "tool_use" && fileChangeTools.contains(($0["name"]?.string ?? "").lowercased()) }.count }
            return (RoomStore.clipUnits(last["content"]?.string ?? "", RoomLimits.result), count, nil)
        case "writing":
            return ("", nil, "Black Team closed before this task finished.")
        case "interrupted":
            return ("", nil, "Stopped.")
        default:
            return ("", nil, last["error"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "The run did not finish.")
        }
    }

    private func roomApply(_ data: inout RoomData, index i: Int) {
        let outcome = roomOutcome(threadId: data.tasks[i].threadId)
        let name = data.members.first { $0.id == data.tasks[i].assignee }?.name ?? "A member"
        let title = data.tasks[i].title
        data.tasks[i].updated = roomNow()
        if let error = outcome.error {
            data.tasks[i].status = .todo
            data.tasks[i].note = RoomStore.clipUnits(error, RoomLimits.note)
            data.tasks[i].failed = true
            roomLog(&data, "\(name) did not finish \u{201C}\(title)\u{201D} \u{00B7} \(EText.prefix(error, 120))")
        } else {
            data.tasks[i].status = .review
            data.tasks[i].result = outcome.result
            data.tasks[i].changed = outcome.changed
            data.tasks[i].failed = false
            let files = outcome.changed.flatMap { $0 > 0 ? " \u{00B7} \($0) file\($0 == 1 ? "" : "s") changed" : nil } ?? ""
            roomLog(&data, "\(name) finished \u{201C}\(title)\u{201D}\(files)")
        }
    }

    private func roomReconcile(_ data: inout RoomData) -> Bool {
        var any = false
        for i in data.tasks.indices where data.tasks[i].status == .doing && !roomRunning(threadId: data.tasks[i].threadId) {
            roomApply(&data, index: i); any = true
        }
        return any
    }

    func roomLog(_ data: inout RoomData, _ text: String) {
        data.notes.insert(RoomNote(at: roomNow(), text: EText.prefix(text, 300)), at: 0)
        if data.notes.count > RoomLimits.notes { data.notes.removeLast(data.notes.count - RoomLimits.notes) }
    }

    func roomView(_ m: RoomMember, project: Project) -> RoomMemberView {
        var view = RoomMemberView(id: m.id, name: m.name, role: m.role, modelKey: m.modelKey, agent: m.agent, permission: m.permission, work: m.work,
                                  kind: "local", provider: "", usable: true, reason: "")
        let localOnly = "The project \(project.name) is local only, so cloud members are not used in it."
        if let key = m.modelKey {
            guard let model = savedModels.find(key) else {
                view.usable = false; view.reason = "This model is no longer in your list."; return view
            }
            if model.source == "cloud" { view.kind = "cloud"; view.provider = cloudHost(model.endpoint, rules: cloudRules) }
            if view.kind == "cloud", !project.cloudAllowed { view.usable = false; view.reason = localOnly; return view }
            do { _ = try validateModelFiles(model, cloud: cloudRules) }
            catch { view.usable = false; view.reason = "\(model.name) cannot be used right now: \(messageOf(error))" }
        } else if let service = m.service {
            view.kind = "cloud"; view.provider = service.provider
            if !project.cloudAllowed { view.usable = false; view.reason = localOnly }
            else if !agentInstalled(service) { view.usable = false; view.reason = "\(service.displayName) is not installed on this Mac." }
        }
        return view
    }

    private func roomState(_ project: Project, _ data: RoomData) -> RoomState {
        RoomState(projectId: project.id, projectName: project.name, cloudAllowed: project.cloudAllowed, busy: isBusy,
                  members: data.members.map { roomView($0, project: project) }, tasks: data.tasks, notes: data.notes, team: data.team)
    }

    /// The room for a project. A task left `doing` by a Black Team that quit is settled here from its conversation.
    public func room(projectId: String) throws -> RoomState {
        let project = try roomProject(projectId)
        roomLock.lock(); defer { roomLock.unlock() }
        return roomState(project, roomLoad(projectId))
    }

    /// Resolves once every task waiting for its run to end has been settled (for the command line and tests).
    public func roomSettle() async {
        for watcher in RoomWatchers.shared.all() { await watcher.value }
    }

    // MARK: Members

    private func roomCheckName(_ name: String) throws -> String {
        let text = EText.trim(name)
        if text.isEmpty || EText.length(text) > RoomLimits.name || RoomStore.clean(.string(text), max: RoomLimits.name) == nil {
            throw BlackTeamError("Give the member a name of up to \(RoomLimits.name) characters.")
        }
        return text
    }

    private func roomCheckRole(_ role: String) throws -> String {
        let text = EText.trim(role)
        if EText.length(text) > RoomLimits.role || RoomStore.clean(.string(text), max: RoomLimits.role, allowEmpty: true) == nil {
            throw BlackTeamError("A role is up to \(RoomLimits.role) characters.")
        }
        return text
    }

    @discardableResult
    public func roomAddMember(projectId: String, name: String, role: String = "", modelKey: String? = nil, agent: String? = nil,
                              permission: String? = nil, work: String? = nil) throws -> RoomState {
        let name = try roomCheckName(name), role = try roomCheckRole(role)
        if (modelKey == nil) == (agent == nil) { throw BlackTeamError("Choose a model or an agent for this member, not both.") }
        var member = RoomMember(id: UUID().uuidString.lowercased(), name: name, role: role, modelKey: nil, agent: nil, permission: nil, work: nil)
        if let agent {
            guard let service = AgentService.forEngine(agent) else { throw BlackTeamError("The agent is claude-code or codex.") }
            if let permission, AgentPermission(rawValue: permission) == nil { throw BlackTeamError("Permission is ask, edit or auto.") }
            member.agent = service.engine; member.permission = permission ?? "edit"
        } else if let modelKey {
            guard savedModels.find(modelKey) != nil else { throw BlackTeamError("That model is not in your list.") }
            if let work, !["chat", "code"].contains(work) { throw BlackTeamError("Work is chat or code.") }
            member.modelKey = modelKey; member.work = work ?? "code"
        }
        return try roomMutate(projectId) { data in
            if data.members.count >= RoomLimits.members { throw BlackTeamError("A room has up to \(RoomLimits.members) members.") }
            data.members.append(member)
            roomLog(&data, "\(member.name) joined the room")
        }
    }

    @discardableResult
    public func roomUpdateMember(projectId: String, memberId: String, name: String? = nil, role: String? = nil, modelKey: String? = nil,
                                 permission: String? = nil, work: String? = nil) throws -> RoomState {
        let newName = try name.map(roomCheckName), newRole = try role.map(roomCheckRole)
        return try roomMutate(projectId) { data in
            guard let i = data.members.firstIndex(where: { $0.id == memberId }) else { throw BlackTeamError("That member is not in this room.") }
            if data.tasks.contains(where: { $0.assignee == memberId && $0.status == .doing }) {
                throw BlackTeamError("Wait for \(data.members[i].name) to finish the task in progress.")
            }
            if let newName { data.members[i].name = newName }
            if let newRole { data.members[i].role = newRole }
            if let modelKey {
                guard data.members[i].modelKey != nil else { throw BlackTeamError("This member is an agent, not a model.") }
                guard savedModels.find(modelKey) != nil else { throw BlackTeamError("That model is not in your list.") }
                data.members[i].modelKey = modelKey
            }
            if let permission {
                guard data.members[i].agent != nil else { throw BlackTeamError("Permission applies to agents only.") }
                guard AgentPermission(rawValue: permission) != nil else { throw BlackTeamError("Permission is ask, edit or auto.") }
                data.members[i].permission = permission
            }
            if let work {
                guard data.members[i].modelKey != nil else { throw BlackTeamError("Work applies to models only.") }
                guard ["chat", "code"].contains(work) else { throw BlackTeamError("Work is chat or code.") }
                data.members[i].work = work
            }
        }
    }

    @discardableResult
    public func roomRemoveMember(projectId: String, memberId: String) throws -> RoomState {
        try roomMutate(projectId) { data in
            guard let i = data.members.firstIndex(where: { $0.id == memberId }) else { throw BlackTeamError("That member is not in this room.") }
            if data.tasks.contains(where: { $0.assignee == memberId && $0.status == .doing }) {
                throw BlackTeamError("Wait for \(data.members[i].name) to finish the task in progress.")
            }
            let name = data.members[i].name
            data.members.remove(at: i)
            for t in data.tasks.indices where data.tasks[t].assignee == memberId && data.tasks[t].status == .todo {
                data.tasks[t].assignee = nil; data.tasks[t].threadId = nil
            }
            roomLog(&data, "\(name) left the room")
        }
    }

    // MARK: Tasks

    private func roomCheckTitle(_ text: String) throws -> String {
        let title = EText.trim(text)
        if title.isEmpty || EText.length(title) > RoomLimits.title || RoomStore.clean(.string(title), max: RoomLimits.title) == nil {
            throw BlackTeamError("Give the task a title of up to \(RoomLimits.title) characters.")
        }
        return title
    }

    private func roomCheckDetail(_ text: String) throws -> String {
        if EText.length(text) > RoomLimits.detail || RoomStore.clean(.string(text), max: RoomLimits.detail, multiline: true, allowEmpty: true) == nil {
            throw BlackTeamError("Task details are up to \(RoomLimits.detail) characters.")
        }
        return text
    }

    @discardableResult
    public func roomAddTask(projectId: String, title: String, detail: String = "", assignee: String? = nil) throws -> RoomState {
        let title = try roomCheckTitle(title), detail = try roomCheckDetail(detail)
        return try roomMutate(projectId) { data in
            if data.tasks.count >= RoomLimits.tasks { throw BlackTeamError("A room holds up to \(RoomLimits.tasks) tasks. Delete finished ones first.") }
            if let assignee, !data.members.contains(where: { $0.id == assignee }) { throw BlackTeamError("That member is not in this room.") }
            let stamp = roomNow()
            data.tasks.append(RoomTask(id: UUID().uuidString.lowercased(), title: title, detail: detail, status: .todo, assignee: assignee, threadId: nil,
                                       result: "", changed: nil, from: nil, note: "", failed: false, inherited: "", created: stamp, updated: stamp))
        }
    }

    /// Title, details and assignee, while the task is `todo`. `assignee: .some(nil)` clears it.
    @discardableResult
    public func roomUpdateTask(projectId: String, taskId: String, title: String? = nil, detail: String? = nil, assignee: String?? = nil) throws -> RoomState {
        let newTitle = try title.map(roomCheckTitle), newDetail = try detail.map(roomCheckDetail)
        return try roomMutate(projectId) { data in
            guard let i = data.tasks.firstIndex(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
            guard data.tasks[i].status == .todo else { throw BlackTeamError("A task can be edited only while it is waiting to start.") }
            if let newTitle { data.tasks[i].title = newTitle }
            if let newDetail { data.tasks[i].detail = newDetail }
            if let assignee {
                if let member = assignee, !data.members.contains(where: { $0.id == member }) { throw BlackTeamError("That member is not in this room.") }
                // Another member starts its own conversation.
                if assignee != data.tasks[i].assignee { data.tasks[i].threadId = nil; data.tasks[i].failed = false }
                data.tasks[i].assignee = assignee
            }
            data.tasks[i].updated = roomNow()
        }
    }

    @discardableResult
    public func roomDeleteTask(projectId: String, taskId: String) throws -> RoomState {
        try roomMutate(projectId) { data in
            guard let i = data.tasks.firstIndex(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
            if data.tasks[i].status == .doing { throw BlackTeamError("Stop the running task before deleting it.") }
            data.tasks.remove(at: i)
        }
    }

    @discardableResult
    public func roomAccept(projectId: String, taskId: String) throws -> RoomState { try roomAccept(projectId: projectId, taskId: taskId, by: "You") }

    /// `by` names who accepted it in the room's log: the lead ("You"), or "The team" during a team run.
    @discardableResult
    func roomAccept(projectId: String, taskId: String, by: String) throws -> RoomState {
        try roomMutate(projectId) { data in
            guard let i = data.tasks.firstIndex(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
            guard data.tasks[i].status == .review else { throw BlackTeamError("Only a task waiting for review can be accepted.") }
            data.tasks[i].status = .done; data.tasks[i].updated = roomNow()
            roomLog(&data, "\(by) accepted \u{201C}\(data.tasks[i].title)\u{201D}")
        }
    }

    /// Back to `todo` with the lead's note. The assignee and conversation are kept, so the next start continues it.
    @discardableResult
    public func roomSendBack(projectId: String, taskId: String, note: String) throws -> RoomState {
        let text = EText.trim(note)
        if text.isEmpty || EText.length(text) > RoomLimits.note || RoomStore.clean(.string(text), max: RoomLimits.note, multiline: true) == nil {
            throw BlackTeamError("Write a note of up to \(RoomLimits.note) characters saying what to change.")
        }
        return try roomMutate(projectId) { data in
            guard let i = data.tasks.firstIndex(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
            guard data.tasks[i].status == .review else { throw BlackTeamError("Only a task waiting for review can be sent back.") }
            data.tasks[i].status = .todo; data.tasks[i].note = text; data.tasks[i].failed = false; data.tasks[i].updated = roomNow()
            roomLog(&data, "You sent back \u{201C}\(data.tasks[i].title)\u{201D}")
        }
    }

    // MARK: Starting

    /// Starts a `todo` task with its assignee and returns at once; the task moves to `review` (or back to `todo` with the error) when
    /// the job ends. The privacy gate decides exactly as it does for the same message sent by hand, and a refusal leaves the task `todo`.
    @discardableResult
    public func roomStart(projectId: String, taskId: String, from origin: SubmitOrigin = .mac) async throws -> RoomState {
        try await roomStartTask(projectId: projectId, taskId: taskId, from: origin, message: nil, useMemory: true)
    }

    /// `roomStart`, with the message given (a team run builds its own) and a switch that keeps the memory vault out of the run.
    func roomStartTask(projectId: String, taskId: String, from origin: SubmitOrigin, message override: String?, useMemory: Bool) async throws -> RoomState {
        let project = try roomProject(projectId)
        if isBusy { throw BlackTeamError("A response is already running. Wait or stop it before starting a task.") }
        let (member, task) = try roomStartable(projectId: projectId, taskId: taskId)
        let sentBack = task.failed ? nil : (task.note.isEmpty ? nil : task.note)
        let message = override ?? roomMessage(title: task.title, detail: task.detail, inherited: task.inherited, sentBack: sentBack)
        let send = try await roomSender(member: member, message: message, threadId: task.threadId, projectId: projectId, project: project, origin: origin,
                                        useMemory: useMemory, readOnly: false)
        return try roomLaunch(projectId: projectId, taskId: taskId, project: project, send)
    }

    /// Gets a member ready to receive `message` and returns the call that sends it. The privacy gate is asked BEFORE the model is
    /// switched, so a refusal changes nothing; `submit` / `submitAgentTask` ask it again when the message is sent.
    /// `readOnly` is for a step that must not change files (a team's plan, review and report): models answer as Chat and agents run in Ask.
    func roomSender(member: RoomMember, message: String, threadId: String?, projectId: String, project: Project, origin: SubmitOrigin,
                    useMemory: Bool, readOnly: Bool) async throws -> (String) throws -> SubmitResult {
        let existing = threadId.flatMap { history.get($0) }
        if let key = member.modelKey {
            guard let saved = savedModels.find(key) else { throw BlackTeamError("The model for \(member.name) is no longer in your list.") }
            let kind = member.work == "chat" || readOnly ? "chat" : "agent"
            if saved.source == "cloud" {
                let check = cloudDecision(destination: .model(host: cloudHost(saved.endpoint, rules: cloudRules), name: saved.name), alternative: nil,
                                          existing: existing, project: project, kind: kind, viaPhone: origin == .phone)
                if let refusal = check.refusal { throw BlackTeamError(refusal) }
            }
            if keyOf(try configStore.read().model) != key { _ = try await switchTo(key: key) }
            return { requestId in
                try self.submit(message: message, kind: kind, requestId: requestId, threadId: threadId, project: projectId, from: origin, useMemory: useMemory)
            }
        }
        guard let service = member.service else { throw BlackTeamError("\(member.name) has nothing to run.") }
        let level = readOnly ? AgentPermission.ask : (member.permission.flatMap { AgentPermission(rawValue: $0) } ?? .edit)
        return { requestId in
            try self.submitAgentTask(service: service, message: message, requestId: requestId, threadId: threadId, project: projectId, permission: level, from: origin)
        }
    }

    private func roomStartable(projectId: String, taskId: String) throws -> (RoomMember, RoomTask) {
        roomLock.lock(); defer { roomLock.unlock() }
        let data = roomLoad(projectId)
        guard let task = data.tasks.first(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
        guard task.status == .todo else { throw BlackTeamError("Only a task that is waiting to start can be started.") }
        guard let assignee = task.assignee, let member = data.members.first(where: { $0.id == assignee }) else {
            throw BlackTeamError("Assign this task to a member before starting it.")
        }
        return (member, task)
    }

    private func roomLaunch(projectId: String, taskId: String, project: Project, _ send: (String) throws -> SubmitResult) throws -> RoomState {
        roomLock.lock(); defer { roomLock.unlock() }
        var data = roomLoad(projectId)
        // Checked again under the lock: the task may have changed while the model was switching.
        guard let i = data.tasks.firstIndex(where: { $0.id == taskId }), data.tasks[i].status == .todo, data.tasks[i].assignee != nil else {
            throw BlackTeamError("That task changed. Try again.")
        }
        let sent = try send(UUID().uuidString.lowercased())
        data.tasks[i].status = .doing; data.tasks[i].threadId = sent.threadId; data.tasks[i].updated = roomNow()
        let name = data.members.first { $0.id == data.tasks[i].assignee }?.name ?? "A member"
        roomLog(&data, "\(name) started \u{201C}\(data.tasks[i].title)\u{201D}")
        try RoomStore.save(data, dataFolder: dataFolder, projectId: projectId)
        changed()
        let threadId = sent.threadId
        RoomWatchers.shared.add { token in
            Task { [self] in
                await waitForIdle()
                roomFinish(projectId: projectId, taskId: taskId, threadId: threadId)
                RoomWatchers.shared.done(token)
            }
        }
        return roomState(project, data)
    }

    private func roomFinish(projectId: String, taskId: String, threadId: String) {
        roomLock.lock(); defer { roomLock.unlock() }
        var data = RoomStore.load(dataFolder: dataFolder, projectId: projectId)
        guard let i = data.tasks.firstIndex(where: { $0.id == taskId }), data.tasks[i].status == .doing, data.tasks[i].threadId == threadId,
              !roomRunning(threadId: threadId) else { return }
        roomApply(&data, index: i)
        try? RoomStore.save(data, dataFolder: dataFolder, projectId: projectId)
        changed()
    }

    // MARK: Hand-off

    private func roomReceiver(_ data: RoomData, _ id: String) throws -> RoomMember {
        guard let member = data.members.first(where: { $0.id == id }) else { throw BlackTeamError("That member is not in this room.") }
        return member
    }

    private func roomDestination(_ member: RoomMember) -> (leaves: Bool, provider: String) {
        if let service = member.service { return (true, service.provider) }
        if let key = member.modelKey, let model = savedModels.find(key), model.source == "cloud" {
            return (true, cloudHost(model.endpoint, rules: cloudRules))
        }
        return (false, "")
    }

    private func roomPreview(_ data: RoomData, taskId: String, to: String, title: String?, detail: String?, includeResult: Bool) throws -> HandOffPreview {
        guard let task = data.tasks.first(where: { $0.id == taskId }) else { throw BlackTeamError("That task is not in this room.") }
        guard task.status == .review || task.status == .done else { throw BlackTeamError("Only a finished task can be handed on.") }
        let receiver = try roomReceiver(data, to)
        let newTitle = try roomCheckTitle(title ?? task.title)
        let newDetail = try roomCheckDetail(detail ?? task.detail)
        var inherited = ""
        if includeResult {
            if EText.trim(task.result).isEmpty { throw BlackTeamError("This task has no result to hand on.") }
            let giver = task.assignee.flatMap { id in data.members.first { $0.id == id }?.name } ?? "a former member"
            inherited = "Result from \(giver):\n\(task.result)"
        }
        let text = roomMessage(title: newTitle, detail: newDetail, inherited: inherited, sentBack: nil)
        let destination = roomDestination(receiver)
        return HandOffPreview(taskId: taskId, receiverId: receiver.id, receiverName: receiver.name, title: newTitle, detail: newDetail,
                              includesResult: includeResult, text: text, leavesThisMac: destination.leaves, provider: destination.provider,
                              digest: roomDigest(text: text, receiver: receiver.id))
    }

    /// Exactly what the receiving member would be given. The lead may edit `title` and `detail` first; ask again after each edit.
    public func roomHandOffPreview(projectId: String, taskId: String, to: String, title: String? = nil, detail: String? = nil,
                                   includeResult: Bool = true) throws -> HandOffPreview {
        _ = try roomProject(projectId)
        roomLock.lock(); defer { roomLock.unlock() }
        return try roomPreview(roomLoad(projectId), taskId: taskId, to: to, title: title, detail: detail, includeResult: includeResult)
    }

    /// Creates a `todo` task for the receiver whose message is the previewed text. The text is rebuilt here from the arguments and the
    /// call is refused unless `digest` matches, so what is sent is what the lead saw. The receiver starts a NEW conversation.
    @discardableResult
    public func roomHandOff(projectId: String, taskId: String, to: String, title: String, detail: String, includeResult: Bool = true,
                            digest: String) throws -> RoomState {
        try roomMutate(projectId) { data in
            let preview = try roomPreview(data, taskId: taskId, to: to, title: title, detail: detail, includeResult: includeResult)
            guard preview.digest == digest else { throw BlackTeamError("What would be sent has changed since you reviewed it. Review the hand-off again.") }
            if data.tasks.count >= RoomLimits.tasks { throw BlackTeamError("A room holds up to \(RoomLimits.tasks) tasks. Delete finished ones first.") }
            let source = data.tasks.first { $0.id == taskId }!
            let giver = source.assignee.flatMap { id in data.members.first { $0.id == id }?.name } ?? "a former member"
            let stamp = roomNow()
            data.tasks.append(RoomTask(id: UUID().uuidString.lowercased(), title: preview.title, detail: preview.detail, status: .todo, assignee: to,
                                       threadId: nil, result: "", changed: nil, from: taskId, note: "", failed: false,
                                       inherited: includeResult ? "Result from \(giver):\n\(source.result)" : "", created: stamp, updated: stamp))
            roomLog(&data, "Handed to \(preview.receiverName) by you")
        }
    }
}
