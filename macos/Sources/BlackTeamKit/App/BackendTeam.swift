import Foundation
import CryptoKit

// A team run: Rick gives ONE goal and the room's members do the rest, one at a time.
//
//   1. Plan    the lead is told the goal and the members and answers with a JSON list of small tasks
//   2. Work    each task is put on the board, assigned, and run with its member (the room's own start path)
//   3. Review  the reviewer, if there is one, accepts the result or sends it back once
//   4. Report  the lead writes the final report
//
// Privacy: every member run goes through `submit` / `submitAgentTask`, so the gate (BackendCloud.swift) decides each one. What is new is
// that members' results are passed to each other without Rick pressing a button. So the run starts only after he has seen the agreement
// (`roomTeamPreview`), and `roomTeamRun` refuses unless its digest still matches the room. When any member is cloud, the LOCAL members
// run without the memory vault as well (no Core, no recalled notes, no memory tools, no journal entry), because what they write is
// passed on to a cloud member. Every member works in a NEW conversation made for the run's tasks; no existing conversation is passed on.

/// Why a run ended early. `stopped` is a cap, a Stop, or Black Team closing; `failed` is an error.
enum TeamEnd: Error {
    case stopped(String)
    case failed(String)
}

/// The run in progress: its Stop flag, the conversation it is waiting for, and how many member runs it has used.
final class TeamControl: @unchecked Sendable {
    let projectId: String
    let runId: String
    private let lock = NSLock()
    private var _stopped = false
    private var _thread: String?
    private var _runs = 0
    private var _task: Task<Void, Never>?

    init(projectId: String, runId: String) { self.projectId = projectId; self.runId = runId }

    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    func stop() { lock.lock(); _stopped = true; lock.unlock() }
    var thread: String? { get { lock.lock(); defer { lock.unlock() }; return _thread } set { lock.lock(); _thread = newValue; lock.unlock() } }
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
    func addRun() -> Int { lock.lock(); defer { lock.unlock() }; _runs += 1; return _runs }
    var task: Task<Void, Never>? { get { lock.lock(); defer { lock.unlock() }; return _task } set { lock.lock(); _task = newValue; lock.unlock() } }
}

struct TeamContext: Sendable {
    let control: TeamControl
    let projectId: String
    let goal: String
    let lead: RoomMember
    let reviewer: RoomMember?
    let members: [RoomMember]
    /// False when any member is cloud: local members then run without the memory vault.
    let useMemory: Bool
    let origin: SubmitOrigin
    let deadline: Date
}

struct PlannedTask: Equatable {
    var title: String
    var detail: String
    var memberId: String
}

/// What a finished task contributed, for the next members and for the report.
struct TeamItem {
    var title: String
    var member: String
    var result: String
    var outcome: String
}

/// The pure text work of a team run: the prompts, reading the lead's and reviewer's JSON, and keeping messages short.
enum TeamText {
    static func workLabel(_ m: RoomMember) -> String {
        if let service = m.service { return "agent work (\(service.displayName) works in the project folder with its own tools)" }
        return m.work == "chat" ? "chat work (answers in text, cannot change files)" : "code work (reads and changes files in the project folder)"
    }

    /// The prompt for the lead's planning step.
    static func planPrompt(goal: String, members: [RoomMember]) -> String {
        let list = members.map { "- \($0.name) (\($0.role.isEmpty ? "no role set" : $0.role)): \(workLabel($0))" }.joined(separator: "\n")
        return "You lead a small team. The person you work for gave the team this goal:\n\n\(goal)\n\nThe team members:\n\(list)\n\n"
            + "Plan the work as at most \(TeamLimits.tasks) tasks. Each task must be small and concrete, and assigned to one member by role, using the member's exact name. "
            + "Do not do the work yourself in this step and do not change any file. "
            + "Reply with only JSON in exactly this form: {\"tasks\":[{\"title\":\"...\",\"detail\":\"...\",\"member\":\"<member name>\"}]}"
    }

    static func reviewPrompt(goal: String, member: String, title: String, detail: String, result: String) -> String {
        "You are the reviewer on a small team working toward this goal:\n\n\(goal)\n\n\(member) was given this task:\n\n\(title)"
            + (detail.isEmpty ? "" : "\n\(detail)") + "\n\nThis is what \(member) reported:\n\n\(result.isEmpty ? "(nothing)" : result)\n\n"
            + "Judge only whether THIS task was done as it was given. Other parts of the goal belong to other tasks and other members; "
            + "do not ask for them here. Decide whether the task is done well enough to accept. Do not do the work yourself and do not change any file. "
            + "Reply with only JSON in exactly this form: {\"verdict\":\"accept\" or \"revise\",\"reason\":\"...\"}"
    }

    static let reportTail = "You are the lead. Write the final report for the person you work for: what was done, what changed, what is left or uncertain. "
        + "Be brief and plain. Do not change any file."

    // MARK: Reading JSON out of a reply

    /// Every balanced `{...}` in the text that reads as a JSON object, in order. Code fences and prose around it do not matter.
    static func objects(in text: String) -> [JSONValue] {
        let scalars = Array(String(text.prefix(60_000)).unicodeScalars)
        var found: [JSONValue] = []
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, end: Int?
            var j = i
            while j < scalars.count {
                let c = scalars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { end = j; break } }
                j += 1
            }
            if let end {
                var view = String.UnicodeScalarView(); view.append(contentsOf: scalars[i...end])
                if let value = try? JSONValue.parse(Data(String(view).utf8)), value.object != nil { found.append(value); i = end + 1; continue }
            }
            i += 1
        }
        return found
    }

    /// The tasks in the lead's reply. Unknown members are dropped, fields are clipped, and at most `TeamLimits.tasks` are kept.
    /// `problem` says in plain words why nothing usable came back.
    static func parsePlan(_ reply: String, members: [RoomMember]) -> (tasks: [PlannedTask], problem: String?, notes: [String]) {
        let candidates = objects(in: reply)
        guard !candidates.isEmpty else { return ([], "No JSON object was found in the reply.", []) }
        guard let list = candidates.compactMap({ $0["tasks"]?.array }).first else { return ([], "The JSON has no \"tasks\" list.", []) }
        var tasks: [PlannedTask] = [], unknown = 0
        for entry in list {
            guard entry.object != nil else { continue }
            let title = EText.prefix(EText.trim(TeamStore.text(entry["title"]?.string ?? "", 10_000, multiline: false)), RoomLimits.title)
            if title.isEmpty { continue }
            let wanted = EText.trim(entry["member"]?.string ?? "").lowercased()
            guard !wanted.isEmpty, let member = members.first(where: { $0.name.lowercased() == wanted }) ?? members.first(where: { $0.id == wanted }) else {
                unknown += 1; continue
            }
            let detail = EText.trim(TeamStore.text(entry["detail"]?.string ?? "", RoomLimits.detail))
            tasks.append(PlannedTask(title: title, detail: detail, memberId: member.id))
        }
        var notes: [String] = []
        if unknown > 0 { notes.append("Left out \(unknown) task\(unknown == 1 ? "" : "s") that named a member who is not on the team.") }
        if tasks.count > TeamLimits.tasks {
            notes.append("The plan had \(tasks.count) tasks; the first \(TeamLimits.tasks) are used (the cap is \(TeamLimits.tasks)).")
            tasks = Array(tasks.prefix(TeamLimits.tasks))
        }
        if tasks.isEmpty {
            let names = members.map(\.name).joined(separator: ", ")
            let why = list.isEmpty ? "The \"tasks\" list is empty."
                : unknown > 0 ? "No task named a member of the team. Use exactly these names: \(names)."
                : "No task had both a title and a member."
            return ([], why, notes)
        }
        return (tasks, nil, notes)
    }

    /// The reviewer's verdict, or nil when the reply has none.
    static func parseVerdict(_ reply: String) -> (accept: Bool, reason: String)? {
        for object in objects(in: reply) {
            guard let verdict = object["verdict"]?.string?.lowercased() else { continue }
            let trimmed = EText.trim(verdict)
            guard trimmed == "accept" || trimmed == "revise" else { continue }
            return (trimmed == "accept", EText.trim(TeamStore.text(object["reason"]?.string ?? "", RoomLimits.note)))
        }
        return nil
    }

    // MARK: Keeping a message short

    /// `head`, then `header`, then the numbered entries, then `tail`. When the whole is over `limit` UTF-16 units, the OLDEST entries'
    /// text is clipped first, and an entry cut to nothing says it was left out.
    static func assemble(head: String, header: String, entries: [(label: String, body: String)], none: String, tail: String,
                         limit: Int = TeamLimits.memberMessage) -> String {
        func render(_ bodies: [String]) -> String {
            let list = entries.isEmpty ? none : entries.enumerated().map { "\($0.offset + 1). \($0.element.label)\n\(bodies[$0.offset])" }.joined(separator: "\n\n")
            return head + "\n\n" + header + "\n" + list + (tail.isEmpty ? "" : "\n\n" + tail)
        }
        var bodies = entries.map(\.body)
        var excess = render(bodies).utf16.count - limit
        if excess > 0 {
            for i in bodies.indices where excess > 0 {
                let before = bodies[i].utf16.count
                if before == 0 { continue }
                let keep = before - excess - 1          // one unit is the ellipsis
                let clipped = keep > 0 ? EText.prefix(bodies[i], keep) + "\u{2026}" : (before >= 10 ? "(left out)" : "")
                excess -= before - clipped.utf16.count
                bodies[i] = clipped
            }
        }
        return render(bodies)
    }

    static func workMessage(goal: String, title: String, detail: String, earlier: [TeamItem]) -> String {
        assemble(head: "The team's goal:\n\(goal)\n\nYour task: \(title)" + (detail.isEmpty ? "" : "\n\(detail)"),
                 header: "Results so far from the team:",
                 entries: earlier.map { ("\($0.title) (\($0.member))", $0.result.isEmpty ? "(no result)" : $0.result) }, none: "(nothing yet)", tail: "")
    }

    static func reviseMessage(title: String, reason: String) -> String {
        "The reviewer sent your work on this task back.\n\nTask: \(title)\nWhat to change: \(reason)\n\nDo it again with that in mind and reply with your updated result."
    }

    static func reportMessage(goal: String, items: [TeamItem]) -> String {
        assemble(head: "You led a small team working on this goal:\n\(goal)", header: "What each task produced:",
                 entries: items.map { ("\($0.title) - \($0.member) - review: \($0.outcome)", $0.result.isEmpty ? "(no result)" : $0.result) },
                 none: "(no tasks were run)", tail: reportTail)
    }
}

extension Backend {
    // MARK: Preview

    private func teamLead(_ data: RoomData, _ given: String?) throws -> RoomMember {
        if let given {
            guard let member = data.members.first(where: { $0.id == given }) else { throw BlackTeamError("The lead is not a member of this room.") }
            return member
        }
        return data.members.first { $0.agent == "claude-code" } ?? data.members[0]
    }

    func teamPreviewBuild(project: Project, data: RoomData, goal rawGoal: String, leadId: String?, reviewerId: String?) throws -> TeamPreview {
        let goal = EText.trim(rawGoal)
        if goal.isEmpty || EText.length(goal) > TeamLimits.goal || RoomStore.clean(.string(goal), max: TeamLimits.goal, multiline: true) == nil {
            throw BlackTeamError("Give the team a goal of up to \(EText.grouped(TeamLimits.goal)) characters.")
        }
        guard !data.members.isEmpty else { throw BlackTeamError("Add members to the room before starting a team run.") }
        let lead = try teamLead(data, leadId)
        var reviewer: RoomMember?
        if let reviewerId {
            guard let member = data.members.first(where: { $0.id == reviewerId }) else { throw BlackTeamError("The reviewer is not a member of this room.") }
            reviewer = member
        }
        let views = data.members.map { roomView($0, project: project) }
        let previews = views.map { v in
            TeamMemberPreview(id: v.id, name: v.name, role: v.role, kind: v.kind, provider: v.provider, usable: v.usable, reason: v.reason,
                              lead: v.id == lead.id, reviewer: v.id == reviewer?.id)
        }
        let cloud = previews.filter { $0.kind == "cloud" }
        var agreement = "This run shares your goal and each member's results with every member of this team: \(previews.map(\.name).joined(separator: ", ")). "
        if cloud.isEmpty {
            agreement += "Every member runs on this Mac, so nothing leaves it."
        } else {
            var providers: [String] = []
            for p in cloud where !providers.contains(p.provider) { providers.append(p.provider) }
            agreement += "\(cloud.map(\.name).joined(separator: ", ")) are cloud: what is shared with them is sent to \(providers.joined(separator: ", ")). "
                + "Your memory is not used in a team run that has a cloud member."
        }
        let basis: JSONValue = .array([.string(goal), .array(previews.map { .string($0.id) }),
                                       .array(previews.map { .array([.string($0.kind), .string($0.provider)]) }),
                                       .string(lead.id), reviewer.map { .string($0.id) } ?? .null])
        let digest = SHA256.hash(data: Data(basis.text().utf8)).map { String(format: "%02x", $0) }.joined()
        return TeamPreview(projectId: project.id, goal: goal, leadId: lead.id, reviewerId: reviewer?.id, members: previews, leavesThisMac: !cloud.isEmpty,
                           memoryUsed: cloud.isEmpty, agreement: agreement, digest: digest)
    }

    /// What a team run would share and where it would go. Show `agreement` as it is, then pass `digest` to `roomTeamRun`.
    public func roomTeamPreview(projectId: String, goal: String, leadId: String? = nil, reviewerId: String? = nil) throws -> TeamPreview {
        let project = try roomProject(projectId)
        roomLock.lock(); defer { roomLock.unlock() }
        return try teamPreviewBuild(project: project, data: roomLoad(projectId), goal: goal, leadId: leadId, reviewerId: reviewerId)
    }

    // MARK: Starting

    /// Starts a team run and returns at once (phase `planning`); the work goes on in the background. Refused unless `digest` is the
    /// current preview's, from a phone when any member is cloud, when the project does not allow cloud models and a member is cloud,
    /// when a member cannot be used, and while any job or another team run is going.
    @discardableResult
    public func roomTeamRun(projectId: String, goal: String, leadId: String? = nil, reviewerId: String? = nil, digest: String,
                            from origin: SubmitOrigin = .mac) throws -> TeamRun {
        let project = try roomProject(projectId)
        let preview: TeamPreview
        let members: [RoomMember]
        do {
            roomLock.lock(); defer { roomLock.unlock() }
            let data = roomLoad(projectId)
            preview = try teamPreviewBuild(project: project, data: data, goal: goal, leadId: leadId, reviewerId: reviewerId)
            members = data.members
        }
        guard preview.digest == digest else {
            throw BlackTeamError("The team or the plan has changed since you reviewed the agreement. Review it again before starting.")
        }
        // The gate, up front, with its own words: a project that is local only, and a phone, never start a cloud conversation.
        for member in members {
            guard let destination = teamDestination(member) else { continue }
            let check = cloudDecision(destination: destination, alternative: nil, existing: nil, project: project, kind: "chat", viaPhone: origin == .phone)
            if let refusal = check.refusal { throw BlackTeamError(refusal) }
        }
        if let blocked = preview.members.first(where: { !$0.usable }) {
            throw BlackTeamError("\(blocked.name) cannot take part: \(blocked.reason)")
        }
        let lead = members.first { $0.id == preview.leadId }!
        let reviewer = preview.reviewerId.flatMap { id in members.first { $0.id == id } }
        let runId = UUID().uuidString.lowercased()
        let control = TeamControl(projectId: projectId, runId: runId)
        lock.lock()
        if teamControl != nil { lock.unlock(); throw BlackTeamError("A team run is already going. Stop it or wait for it to finish.") }
        if active != nil { lock.unlock(); throw BlackTeamError("A response is already running. Wait or stop it before starting a team run.") }
        if closing { lock.unlock(); throw BlackTeamError("Black Team is closing.") }
        teamControl = control
        lock.unlock()
        let stamp = roomNow()
        let first = TeamRun(id: runId, goal: preview.goal, leadId: lead.id, reviewerId: reviewer?.id, phase: .planning, current: nil, runs: 0, started: stamp,
                            updated: stamp, report: "", message: "", log: [])
        do {
            _ = try roomMutate(projectId) { data in data.team = first }
        } catch {
            locked { teamControl = nil }
            throw error
        }
        let context = TeamContext(control: control, projectId: projectId, goal: preview.goal, lead: lead, reviewer: reviewer, members: members,
                                  useMemory: preview.memoryUsed, origin: origin, deadline: now().addingTimeInterval(Double(TeamLimits.minutes) * 60))
        teamLog(context, member: nil, kind: "system", taskId: nil,
                "Team run started with \(members.count) member\(members.count == 1 ? "" : "s"). Lead: \(lead.name)."
                + (reviewer.map { " Reviewer: \($0.name)." } ?? " No reviewer.")
                + (preview.memoryUsed ? "" : " Memory is not used in this run."))
        control.task = Task { [self] in await teamMain(context) }
        return (try? room(projectId: projectId).team) ?? first
    }

    private func teamDestination(_ member: RoomMember) -> CloudDestination? {
        if let service = member.service { return .agent(service) }
        if let key = member.modelKey, let model = savedModels.find(key), model.source == "cloud" {
            return .model(host: cloudHost(model.endpoint, rules: cloudRules), name: model.name)
        }
        return nil
    }

    /// Stops the team run of this project: the running job is cancelled and the run ends `stopped`. Tasks keep the state they reached.
    @discardableResult
    public func roomTeamStop(projectId: String) throws -> RoomState {
        _ = try roomProject(projectId)
        let control = locked { teamControl }
        if let control, control.projectId == projectId {
            control.stop()
            // Only the team's own job is cancelled, never one somebody else started in between.
            let ours = locked { active != nil && job?.threadId != nil && job?.threadId == control.thread }
            if ours { cancel() }
        }
        return try room(projectId: projectId)
    }

    /// Resolves once the team run in progress has ended (for the command line and tests).
    public func roomTeamSettle() async {
        let task = locked { teamControl?.task }
        await task?.value
    }

    /// A run left unfinished by a Black Team that quit is marked `stopped` on the next read. It is not resumed.
    func teamReconcile(_ data: inout RoomData) -> Bool {
        guard var team = data.team, !team.phase.finished, locked({ teamControl == nil }) else { return false }
        let stamp = roomNow()
        team.phase = .stopped; team.current = nil; team.updated = stamp
        team.message = "Black Team was closed during this run."
        team.log.append(TeamLogEntry(at: stamp, memberId: nil, memberName: "", kind: "system", taskId: nil, text: team.message))
        if team.log.count > TeamLimits.log { team.log.removeFirst(team.log.count - TeamLimits.log) }
        data.team = team
        return true
    }

    // MARK: Recording

    private func teamUpdate(_ c: TeamContext, _ body: (inout TeamRun) -> Void) {
        _ = try? roomMutate(c.projectId) { data in
            guard var team = data.team, team.id == c.control.runId else { return }
            body(&team)
            team.updated = roomNow()
            data.team = team
        }
    }

    func teamLog(_ c: TeamContext, member: RoomMember?, kind: String, taskId: String?, _ text: String) {
        let entry = TeamLogEntry(at: roomNow(), memberId: member?.id, memberName: member?.name ?? "", kind: kind, taskId: taskId,
                                 text: TeamStore.text(text, TeamLimits.logText))
        teamUpdate(c) { team in
            team.log.append(entry)
            if team.log.count > TeamLimits.log { team.log.removeFirst(team.log.count - TeamLimits.log) }
        }
    }

    private func teamPhase(_ c: TeamContext, _ phase: TeamPhase, current: String? = nil) {
        teamUpdate(c) { $0.phase = phase; $0.current = current }
    }

    private func teamCheckpoint(_ c: TeamContext) throws {
        if c.control.stopped { throw TeamEnd.stopped("Stopped by you.") }
        if locked({ closing }) { throw TeamEnd.stopped("Black Team was closed during this run.") }
        if now() >= c.deadline { throw TeamEnd.stopped("Stopped at the time cap: a team run is limited to \(TeamLimits.minutes) minutes.") }
    }

    private func teamCountRun(_ c: TeamContext) throws {
        if c.control.runs >= TeamLimits.runs {
            throw TeamEnd.stopped("Stopped at the run cap: a team run is limited to \(TeamLimits.runs) member runs.")
        }
        let used = c.control.addRun()
        teamUpdate(c) { $0.runs = used }
    }

    // MARK: The run

    private func teamMain(_ c: TeamContext) async {
        var phase = TeamPhase.done, message = ""
        do {
            try await teamExecute(c)
        } catch let end as TeamEnd {
            switch end {
            case .stopped(let why): phase = .stopped; message = why
            case .failed(let why): phase = .failed; message = why
            }
        } catch {
            phase = .failed; message = messageOf(error)
        }
        if phase != .done { teamLog(c, member: nil, kind: "system", taskId: nil, message) }
        else { teamLog(c, member: nil, kind: "system", taskId: nil, "The team run finished.") }
        let text = TeamStore.text(message, TeamLimits.message)
        teamUpdate(c) { $0.phase = phase; $0.current = nil; $0.message = text }
        locked { teamControl = nil }
        changed()
    }

    private func teamExecute(_ c: TeamContext) async throws {
        let planned = try await teamPlan(c)
        var items: [TeamItem] = []
        for step in planned {
            try teamCheckpoint(c)
            guard let member = c.members.first(where: { $0.id == step.memberId }) else { throw TeamEnd.failed("A member left the room during the run.") }
            let added: RoomTask
            do { added = try roomAddTask(projectId: c.projectId, title: step.title, detail: step.detail, assignee: member.id).tasks.last! }
            catch { throw TeamEnd.failed(messageOf(error)) }
            teamPhase(c, .working, current: added.id)
            teamLog(c, member: member, kind: "system", taskId: added.id, "Task added for \(member.name): \(step.title)")
            var result = try await teamWork(c, member: member, task: added,
                                            message: TeamText.workMessage(goal: c.goal, title: step.title, detail: step.detail, earlier: items))
            var outcome = "accepted without review"
            if let reviewer = c.reviewer, reviewer.id != member.id {
                teamPhase(c, .reviewing, current: added.id)
                var verdict = try await teamReview(c, reviewer: reviewer, member: member, task: added, result: result)
                if verdict.accept {
                    outcome = "accepted by \(reviewer.name)"
                } else {
                    let reason = verdict.reason.isEmpty ? "The reviewer asked for changes." : verdict.reason
                    do { _ = try roomSendBack(projectId: c.projectId, taskId: added.id, note: reason) } catch { throw TeamEnd.failed(messageOf(error)) }
                    teamPhase(c, .working, current: added.id)
                    teamLog(c, member: member, kind: "system", taskId: added.id, "\(reviewer.name) sent the task back: \(reason)")
                    result = try await teamWork(c, member: member, task: added, message: TeamText.reviseMessage(title: step.title, reason: reason))
                    teamPhase(c, .reviewing, current: added.id)
                    verdict = try await teamReview(c, reviewer: reviewer, member: member, task: added, result: result)
                    if verdict.accept {
                        outcome = "revised once, then accepted by \(reviewer.name)"
                    } else {
                        let still = verdict.reason.isEmpty ? "the reviewer still wanted changes" : verdict.reason
                        outcome = "accepted after one revision although \(reviewer.name) still asked for changes: \(still)"
                        teamLog(c, member: reviewer, kind: "review", taskId: added.id,
                                "Revision limit reached (\(TeamLimits.revisions)): the task is accepted whatever the reviewer says.")
                    }
                }
            } else if c.reviewer != nil {
                outcome = "accepted without review (\(member.name) is the reviewer)"
            }
            do { _ = try roomAccept(projectId: c.projectId, taskId: added.id, by: "The team") } catch { throw TeamEnd.failed(messageOf(error)) }
            teamLog(c, member: nil, kind: "system", taskId: added.id, "Task accepted: \(step.title) (\(outcome))")
            items.append(TeamItem(title: step.title, member: member.name, result: result, outcome: outcome))
        }
        teamPhase(c, .reporting)
        let report = try await teamAsk(c, member: c.lead, message: TeamText.reportMessage(goal: c.goal, items: items), kind: "report", taskId: nil)
        let text = EText.trim(report)
        teamUpdate(c) { $0.report = TeamStore.text(text, TeamLimits.report) }
    }

    private func teamPlan(_ c: TeamContext) async throws -> [PlannedTask] {
        teamPhase(c, .planning)
        let prompt = TeamText.planPrompt(goal: c.goal, members: c.members)
        var problem = ""
        for attempt in 0..<2 {
            let message = attempt == 0 ? prompt : prompt + "\n\nYour previous reply could not be used: \(problem) Reply again with only the JSON."
            let reply = try await teamAsk(c, member: c.lead, message: message, kind: "plan", taskId: nil)
            let parsed = TeamText.parsePlan(reply, members: c.members)
            for note in parsed.notes { teamLog(c, member: nil, kind: "system", taskId: nil, note) }
            if parsed.problem == nil {
                teamLog(c, member: nil, kind: "system", taskId: nil, "Plan: \(parsed.tasks.count) task\(parsed.tasks.count == 1 ? "" : "s").")
                return parsed.tasks
            }
            problem = parsed.problem ?? ""
            teamLog(c, member: nil, kind: "system", taskId: nil, "The plan could not be used: \(problem)" + (attempt == 0 ? " Asking once more." : ""))
        }
        throw TeamEnd.failed("\(c.lead.name) did not send a plan the team could use: \(problem)")
    }

    /// Runs one board task with its member through the room's own start path; a run that errors is retried once.
    private func teamWork(_ c: TeamContext, member: RoomMember, task: RoomTask, message: String) async throws -> String {
        var lastError = ""
        for attempt in 1...2 {
            try teamCheckpoint(c)
            try teamCountRun(c)
            await waitForIdle()
            teamLog(c, member: member, kind: "work", taskId: task.id, attempt == 1 ? "\(member.name) started: \(task.title)" : "\(member.name) is trying again: \(task.title)")
            let started: RoomState
            do {
                started = try await roomStartTask(projectId: c.projectId, taskId: task.id, from: c.origin, message: message, useMemory: c.useMemory)
            } catch {
                // A refusal by the privacy gate (or anything else that stops the start) ends the run with its own words.
                throw TeamEnd.failed(messageOf(error))
            }
            let threadId = started.tasks.first { $0.id == task.id }?.threadId
            try await teamWait(c, threadId: threadId)
            await roomSettle()
            let now = try room(projectId: c.projectId)
            guard let current = now.tasks.first(where: { $0.id == task.id }) else { throw TeamEnd.failed("The task \u{201C}\(task.title)\u{201D} is no longer on the board.") }
            if current.status == .review {
                teamLog(c, member: member, kind: "work", taskId: task.id, current.result.isEmpty ? "\(member.name) finished with no text." : current.result)
                return current.result
            }
            lastError = current.note.isEmpty ? "The run did not finish." : current.note
            teamLog(c, member: member, kind: "system", taskId: task.id, "\(member.name) did not finish: \(lastError)" + (attempt == 1 ? " Trying once more." : ""))
        }
        throw TeamEnd.failed("\(member.name) could not finish \u{201C}\(task.title)\u{201D}: \(lastError)")
    }

    private func teamReview(_ c: TeamContext, reviewer: RoomMember, member: RoomMember, task: RoomTask, result: String) async throws -> (accept: Bool, reason: String) {
        let message = TeamText.reviewPrompt(goal: c.goal, member: member.name, title: task.title, detail: task.detail, result: result)
        let reply = try await teamAsk(c, member: reviewer, message: message, kind: "review", taskId: task.id)
        if let verdict = TeamText.parseVerdict(reply) { return verdict }
        teamLog(c, member: nil, kind: "system", taskId: task.id, "\(reviewer.name)'s reply had no verdict, so the task is accepted.")
        return (true, "")
    }

    /// One read-only step (plan, review, report): the member answers in a NEW conversation; an error is retried once.
    private func teamAsk(_ c: TeamContext, member: RoomMember, message: String, kind: String, taskId: String?) async throws -> String {
        var lastError = ""
        for attempt in 1...2 {
            try teamCheckpoint(c)
            try teamCountRun(c)
            await waitForIdle()
            let sent: SubmitResult
            do {
                let project = try roomProject(c.projectId)
                let send = try await roomSender(member: member, message: message, threadId: nil, projectId: c.projectId, project: project, origin: c.origin,
                                                useMemory: c.useMemory, readOnly: true)
                sent = try send(UUID().uuidString.lowercased())
            } catch {
                throw TeamEnd.failed(messageOf(error))
            }
            try await teamWait(c, threadId: sent.threadId)
            let outcome = teamReply(threadId: sent.threadId)
            if let text = outcome.text {
                teamLog(c, member: member, kind: kind, taskId: taskId, text)
                return text
            }
            lastError = outcome.error
            teamLog(c, member: member, kind: "system", taskId: taskId, "\(member.name) did not finish: \(lastError)" + (attempt == 1 ? " Trying once more." : ""))
        }
        throw TeamEnd.failed("\(member.name) could not finish: \(lastError)")
    }

    /// The final reply of a conversation, or why there is none.
    private func teamReply(threadId: String) -> (text: String?, error: String) {
        guard let thread = history.get(threadId), let last = thread["messages"]?.array?.last, last["role"]?.string == "assistant" else {
            return (nil, "The conversation could not be found.")
        }
        switch last["state"]?.string {
        case "done": return (EText.prefix(last["content"]?.string ?? "", 20_000), "")
        case "interrupted": return (nil, "Stopped.")
        default: return (nil, last["error"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "The run did not finish.")
        }
    }

    private func teamRunning(_ threadId: String?) -> Bool {
        guard let threadId else { return false }
        return locked { active != nil && job?.threadId == threadId }
    }

    /// Waits for the member's job to end. Stop, Black Team closing and the time cap cancel it. A job that needs Rick's approval
    /// simply keeps running, and the wait counts toward the time cap.
    private func teamWait(_ c: TeamContext, threadId: String?) async throws {
        c.control.thread = threadId
        var capped = false
        while teamRunning(threadId) {
            let stop = c.control.stopped, closed = locked { closing }, late = now() >= c.deadline
            if stop || closed || late {
                capped = late && !stop && !closed
                cancel()
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForIdle()
        c.control.thread = nil
        if c.control.stopped { throw TeamEnd.stopped("Stopped by you.") }
        if locked({ closing }) { throw TeamEnd.stopped("Black Team was closed during this run.") }
        if capped { throw TeamEnd.stopped("Stopped at the time cap: a team run is limited to \(TeamLimits.minutes) minutes.") }
    }
}
