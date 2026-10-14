import Foundation

// Running an organization's tickets, one stage at a time.
//
//   Intake -> Spec -> Design (when the ticket touches the UI) -> Plan -> Build -> Review -> QA -> Ship
//
// A stage is a ROOM TASK run by the role's room member, through the room's own start path (`roomStartTask`), so the privacy gate, the one
// local model slot and the board all work exactly as they do for a task started by hand. Each stage saves an artifact (OrgArtifacts below),
// then either goes on, stops at a gate for the owner (OrgGates.swift), or sends the ticket back. Review and QA failures return to Build with
// their findings; a spec question goes to the person. Engineering work is on the ticket's own git branch (OrgWork below).

/// Why a stage stopped without finishing.
enum OrgHalt: Error {
    case gate(kind: String, question: String, artifact: String?, service: String?)
    case blocked(String)
    /// Try again later (something else held the model, or the organization was paused): the ticket goes back to waiting.
    case later
}

enum OrgDone { case finished, again, handled }

struct OrgRunResult {
    var text: String
    var changed: Int?
    var threadId: String
    var seconds: Int
}

extension Backend {
    // MARK: Picking and stepping

    /// Nothing else holds the model slot: no response, no optimizing, no team run.
    func orgIdle() -> Bool { !isBusy && !tuneState.running && locked { teamControl == nil } }

    /// The next ticket: one already furthest along first (finish before starting), then the oldest.
    func orgPick(_ projectId: String) -> OrgTicket? {
        // While the organization works for a board, only the tickets taken from it are worked on.
        let boardOnly = orgLoad(projectId)?.board?.working == true
        return orgTickets(projectId).filter { $0.state == "ready" && (!boardOnly || $0.boardId != nil) }.sorted { $0.stage.index != $1.stage.index ? $0.stage.index > $1.stage.index : $0.number < $1.number }.first
    }

    /// Runs the next stage of the next ticket, if the computer is idle. Returns true when a stage ran (finished or not).
    /// `force` runs it although continuous pickup is off (`black-team org step`); the privacy checks and the ceilings still apply.
    @discardableResult
    public func orgStep(projectId: String, force: Bool = false) async throws -> Bool {
        guard let org = orgLoad(projectId) else { return false }
        if org.paused || (!org.running && !force) { return false }
        guard orgIdle(), !locked({ closing }) else { return false }
        if orgEnforceCeiling(projectId) { return false }
        guard var ticket = orgPick(projectId), orgRuntime.begin(project: projectId, ticket: ticket.id, role: "") else { return false }
        defer { orgRuntime.end() }
        // A ticket from a board: the note is read again first (its text may have changed, someone may have taken it).
        if ticket.boardId != nil {
            guard let fresh = orgBoardStageStart(org, ticket) else { return false }
            ticket = fresh
        }
        let stage = ticket.stage
        try orgTicketMutate(projectId, ticket.id) { $0.state = "running"; $0.note = "" }
        do {
            let done = try await orgRun(org, ticket: ticket, stage: stage)
            // A ticket Black Team let go of while the stage ran (another owner took it) is not moved on.
            if ticket.boardId != nil, orgTicket(projectId, ticket.id)?.state == "cancelled" { return true }
            switch done {
            case .finished: try await orgComplete(org, ticketId: ticket.id, stage: stage)
            case .again: try orgTicketMutate(projectId, ticket.id) { $0.state = "ready"; $0.currentRole = nil }
            case .handled: break
            }
        } catch OrgHalt.later {
            _ = try? orgTicketMutate(projectId, ticket.id) { if $0.state == "running" { $0.state = "ready"; $0.currentRole = nil } }
        } catch OrgHalt.gate(let kind, let question, let artifact, let service) {
            orgRaiseGate(org, ticketId: ticket.id, stage: stage, kind: kind, question: question, artifact: artifact, service: service)
        } catch OrgHalt.blocked(let why) {
            _ = try? orgTicketMutate(projectId, ticket.id) { t in t.state = "blocked"; t.note = why; t.currentRole = nil; orgEvent(&t, stage: stage, "Stuck: \(why)") }
            orgInboxNote(org, title: "\(ticket.label) is stuck", text: why)
        } catch {
            let why = messageOf(error)
            _ = try? orgTicketMutate(projectId, ticket.id) { t in t.state = "blocked"; t.note = why; t.currentRole = nil; orgEvent(&t, stage: stage, "Stuck: \(why)") }
            orgInboxNote(org, title: "\(ticket.label) is stuck", text: why)
        }
        _ = orgEnforceCeiling(projectId)
        return true
    }

    /// A stage is done: the owner's gate if the organization has one there, otherwise on to the next stage.
    func orgComplete(_ org: Organization, ticketId: String, stage: OrgStage) async throws {
        guard let fresh = orgLoad(org.projectId), let ticket = orgTicket(org.projectId, ticketId) else { return }
        if fresh.gated(stage) {
            let question: String
            switch stage {
            case .spec: question = "Approve the spec for \(ticket.label) (\(ticket.title))?"
            case .ship: question = "Approve shipping \(ticket.label) (\(ticket.title))? Approving marks it ready for you to merge; nothing is merged for you."
            default: question = "Approve the \(stage.title.lowercased()) for \(ticket.label) (\(ticket.title))?"
            }
            let artifact: String? = {
                switch stage {
                case .spec: return orgLatest(ticket, "spec")?.name ?? orgLatest(ticket, "intake")?.name
                case .ship: return orgLatest(ticket, "release-notes")?.name
                case .design: return orgLatest(ticket, "design")?.name
                case .plan: return orgLatest(ticket, "plan")?.name
                case .build: return orgLatest(ticket, "build")?.name
                case .review: return orgLatest(ticket, "review")?.name
                case .qa: return orgLatest(ticket, "qa")?.name
                case .intake: return orgLatest(ticket, "intake")?.name
                }
            }()
            orgRaiseGate(fresh, ticketId: ticketId, stage: stage, kind: "approval", question: question, artifact: artifact)
        } else {
            try orgMoveOn(fresh, ticketId: ticketId, from: stage)
        }
    }

    func orgRun(_ org: Organization, ticket: OrgTicket, stage: OrgStage) async throws -> OrgDone {
        switch stage {
        case .intake: return try await orgIntake(org, ticket)
        case .spec: return try await orgSpec(org, ticket)
        case .design: return try await orgDesign(org, ticket)
        case .plan: return try await orgPlan(org, ticket)
        case .build: return try await orgBuild(org, ticket)
        case .review: return try await orgReview(org, ticket)
        case .qa: return try await orgQA(org, ticket)
        case .ship: return try await orgShip(org, ticket)
        }
    }

    // MARK: Running one role

    /// The room member that runs a role: an existing one with the same model or agent, otherwise a new one on the room's board.
    func orgMember(for role: OrgRole, projectId: String) throws -> RoomMember {
        roomLock.lock(); defer { roomLock.unlock() }
        let data = roomLoad(projectId)
        let want = role.agent == nil ? nil : role.access.agent.rawValue
        if let found = data.members.first(where: { m in
            role.modelKey != nil ? (m.modelKey == role.modelKey && m.work == role.work) : (m.agent == role.agent && m.permission == want)
        }) { return found }
        let name = role.modelKey.flatMap { savedModels.find($0)?.name } ?? role.service?.displayName ?? role.name
        if data.members.count >= RoomLimits.members {
            throw OrgHalt.blocked("The room already has \(RoomLimits.members) members, so this role cannot join it. Use the same model for more roles, or remove a member from the room.")
        }
        let state = try roomAddMember(projectId: projectId, name: EText.prefix(name, RoomLimits.name), role: EText.prefix("Organization: " + role.name, RoomLimits.role),
                                      modelKey: role.modelKey, agent: role.agent, permission: want, work: role.work)
        guard let made = state.members.last, let member = roomLoad(projectId).members.first(where: { $0.id == made.id }) else { throw OrgHalt.blocked("The role could not join the room.") }
        return member
    }

    func orgApprovalSeconds() -> Int { (service?.settings.read().approvalHours ?? 24) * 3600 }

    /// Waits for a stage's job to end, copying any question it asks (a command it wants to run) into the Inbox.
    private func orgWait(_ threadId: String?, org: Organization, ticket: OrgTicket, stage: OrgStage) async {
        var asked: String?
        let scheduleId = "org:" + ticket.id
        while teamRunning(threadId) {
            if orgRuntime.stopRequested || locked({ closing }) { cancel(); break }
            orgBoardKeepAlive(org.projectId, ticketId: ticket.id)
            if let snap = locked({ job?.threadId == threadId ? job?.snapshot : nil }) {
                if let ask = snap.approval, asked != ask.id {
                    asked = ask.id
                    let item = InboxItem(id: ask.id, scheduleId: scheduleId, scheduleName: "\(org.name) \u{00B7} \(ticket.label) \(stage.title)", threadId: threadId, project: org.projectId,
                                         command: ask.command, question: ask.description, digest: ask.digest, created: now().timeIntervalSince1970, expires: Double(ask.expires) / 1000,
                                         state: "waiting", answered: nil)
                    try? orgInbox().add(item)
                } else if snap.approval == nil, asked != nil {
                    try? orgInbox().settleAll(scheduleId: scheduleId, as: "answered", at: now()); asked = nil
                }
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        await waitForIdle()
        if asked != nil { try? orgInbox().settleAll(scheduleId: scheduleId, as: "ended", at: now()) }
    }

    /// One role runs one stage as a room task, in a new conversation. An error that is not a Stop is tried once more.
    func orgRunRole(_ org: Organization, ticket: OrgTicket, stage: OrgStage, role: OrgRole, prompt: String, write: Bool, workspace: String?) async throws -> OrgRunResult {
        let projectId = org.projectId
        let project = try roomProject(projectId)
        let view = roomView(orgScratchMember(role), project: project)
        guard role.isSetUp else { throw OrgHalt.blocked("\(role.name) has no model or agent yet.") }
        guard view.usable else { throw OrgHalt.blocked("\(role.name) cannot be used: \(view.reason)") }
        if write && role.access == .read { throw OrgHalt.blocked("\(role.name) can only read files, so it cannot do \(stage.title.lowercased()). Allow it to edit files in the project.") }
        let current = orgLoad(projectId) ?? org
        // What would newly leave this computer for a paid role is shown and needs a yes first.
        if view.kind == "cloud", !current.confirmed.contains(view.provider) {
            throw OrgHalt.gate(kind: "privacy", question: "\(ticket.label) would be sent to \(view.provider) for the \(stage.title) stage, run by \(role.name). That service has not been agreed to for this organization. Allow it?",
                               artifact: nil, service: view.provider)
        }
        let member = try orgMember(for: role, projectId: projectId)
        orgRuntime.setRole(role.id)
        _ = try? orgTicketMutate(projectId, ticket.id) { $0.currentRole = role.id }
        let memory = orgAgreementBuild(current, project: project).memoryUsed
        let policy: UnattendedPolicy? = member.modelKey != nil && member.work != "chat"
            ? UnattendedPolicy(permission: write ? role.access.unattended : .readOnly, approvalSeconds: orgApprovalSeconds()) : nil
        let title = EText.prefix("\(ticket.label) \(stage.title): \(ticket.title)", RoomLimits.title)
        var lastError = ""
        for attempt in 1...2 {
            if orgRuntime.stopRequested || locked({ closing }) { throw OrgHalt.later }
            await waitForIdle()
            let added: RoomTask
            do { added = try roomAddTask(projectId: projectId, title: title, detail: "Run by \(current.name) for the \(role.name) role.", assignee: member.id).tasks.last! }
            catch { throw OrgHalt.blocked(messageOf(error)) }
            let began = now()
            let started: RoomState
            do {
                started = try await roomStartTask(projectId: projectId, taskId: added.id, from: .mac, message: prompt, useMemory: memory, readOnly: member.agent != nil && !write,
                                                  workspace: workspace, unattended: policy)
            } catch {
                _ = try? roomDeleteTask(projectId: projectId, taskId: added.id)
                let text = messageOf(error)
                if text.hasPrefix("A response is already running") || text.hasPrefix("Black Team is optimizing") { throw OrgHalt.later }
                throw OrgHalt.blocked(text)
            }
            let threadId = started.tasks.first { $0.id == added.id }?.threadId
            await orgWait(threadId, org: current, ticket: ticket, stage: stage)
            await roomSettle()
            guard let board = try? room(projectId: projectId), let done = board.tasks.first(where: { $0.id == added.id }) else { throw OrgHalt.blocked("The task left the board.") }
            let seconds = Int(max(0, now().timeIntervalSince(began)))
            let paid = view.kind == "cloud"
            orgRecordUsage(current, ticket: ticket, stage: stage, role: role, member: member.name, paid: paid, threadId: threadId, seconds: seconds)
            if done.status == .review {
                _ = try? roomAccept(projectId: projectId, taskId: added.id, by: "The organization")
                return OrgRunResult(text: done.result, changed: done.changed, threadId: threadId ?? "", seconds: seconds)
            }
            if orgRuntime.stopRequested || locked({ closing }) { _ = try? roomDeleteTask(projectId: projectId, taskId: added.id); throw OrgHalt.later }
            lastError = done.note.isEmpty ? "The run did not finish." : done.note
            _ = try? orgTicketMutate(projectId, ticket.id) { orgEvent(&$0, stage: stage, role: role.name, "\(member.name) did not finish: \(EText.prefix(lastError, 200))" + (attempt == 1 ? " Trying once more." : "")) }
        }
        throw OrgHalt.blocked("\(role.name) could not finish the \(stage.title.lowercased()) stage: \(lastError)")
    }

    // MARK: Prompts

    func orgHead(_ org: Organization, _ project: Project, _ role: OrgRole, _ t: OrgTicket, _ stage: OrgStage) -> String {
        var head = "Stage: \(stage.title) \u{00B7} Ticket \(t.label)\nYou are the \(role.name) of \(org.name), a small team working for its owner on the project \(project.name). Your charter:\n\(role.charter)"
        if !role.skills.isEmpty { head += "\n\nGuidance you follow:\n" + role.skills.map { "- " + $0 }.joined(separator: "\n") }
        head += "\n\nTicket \(t.label): \(t.title)"
        if !t.body.isEmpty { head += "\n\(t.body)" }
        if !t.answers.isEmpty { head += "\n\nThe owner has said:\n" + t.answers.suffix(4).joined(separator: "\n") }
        return head
    }

    /// The text of the newest artifact for each name, in the order given, labelled.
    func orgEntries(_ t: OrgTicket, _ bases: [String]) -> [(label: String, body: String)] {
        var out: [(String, String)] = []
        for base in bases {
            guard let a = orgLatest(t, base), let text = OrgStore.readArtifact(dataFolder, t.projectId, t.id, name: a.name) else { continue }
            out.append((a.title, text))
        }
        return out
    }

    func orgPrompt(_ head: String, _ entries: [(label: String, body: String)], tail: String) -> String {
        TeamText.assemble(head: head, header: "Work on this ticket so far:", entries: entries, none: "(nothing yet)", tail: tail, limit: OrgLimits.message)
    }

    // MARK: Artifacts

    /// Saves an artifact for the ticket (the canonical copy in the data folder, and a copy in the project) and returns its file name.
    @discardableResult
    func orgSaveArtifact(_ org: Organization, ticketId: String, stage: OrgStage, role: OrgRole?, base: String, ext: String = "md", title: String, text raw: String) throws -> String {
        var text = raw
        if EText.length(text) > OrgLimits.artifact { text = EText.prefix(text, OrgLimits.artifact) + "\n\n[Clipped: the artifact is longer than \(EText.grouped(OrgLimits.artifact)) characters.]" }
        var name = ""
        try orgTicketMutate(org.projectId, ticketId) { t in
            let n = t.artifacts.filter { $0.name == "\(base).\(ext)" || $0.name.hasPrefix(base + "-") && $0.name.hasSuffix("." + ext) }.count
            name = n == 0 ? "\(base).\(ext)" : "\(base)-\(n + 1).\(ext)"
            t.artifacts.append(OrgArtifact(name: name, stage: stage.rawValue, title: title, created: roomNow(), bytes: text.utf8.count, role: role?.name ?? ""))
        }
        try OrgStore.writeArtifact(dataFolder, org.projectId, ticketId, name: name, text: text)
        if let t = orgTicket(org.projectId, ticketId) {
            orgMirror(t, name: name, text: text)
            if t.boardId != nil { orgBoardShare(t, stage: stage, name: name, title: title, text: text) }
        }
        return name
    }

    /// The folder the ticket's engineering happens in, when it has one yet; the project folder for a project without git.
    func orgMirrorRoot(_ t: OrgTicket) -> String? {
        if let work = t.work { return work + (t.prefix.map { $0.isEmpty ? "" : "/" + $0 } ?? "") }
        // A board's work is always in a git repository, in the ticket's own worktree.
        if t.boardId != nil { return nil }
        // A project without git is worked in directly; a git project's copy waits until the ticket has its own worktree.
        guard let project = try? roomProject(t.projectId) else { return nil }
        return orgIsGit(project) ? nil : project.workspace
    }

    /// A copy of the artifact in the project (on the ticket's branch), so it travels with the work. Failure here never fails a stage.
    func orgMirror(_ t: OrgTicket, name: String, text: String) {
        guard let root = orgMirrorRoot(t) else { return }
        let dir = root + "/.black-team/tickets/" + t.label
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/" + name), options: .atomic)
    }

    // MARK: The branch

    /// Where this stage works. Intake and Spec read the project folder; later stages work on the ticket's own branch in its own worktree, made now
    /// if it does not exist yet. A project that is not a git repository is worked in directly, which the agreement and the docs say.
    func orgWorkspace(_ org: Organization, _ t: OrgTicket, branch needed: Bool) throws -> String {
        let project = try roomProject(org.projectId)
        // A ticket from a board works in the repository the board was linked with, which is the project's folder unless another was chosen.
        let home = t.boardId != nil ? (org.board?.repo ?? project.workspace) : project.workspace
        guard needed else { return home }
        if let work = t.work { return work + (t.prefix.map { $0.isEmpty ? "" : "/" + $0 } ?? "") }
        guard let top = OrgGit.toplevel(home) else { return home }
        guard let head = OrgGit.head(top) else {
            throw OrgHalt.blocked("\(project.name) is a git repository with no commits yet. Make a first commit so Black Team can branch from it, then retry.")
        }
        let prefix = OrgGit.prefix(home)
        var branch = t.boardId.map { OrgGit.boardBranchName(id: $0, title: t.title) } ?? OrgGit.branchName(number: t.number, title: t.title)
        if OrgGit.run(["rev-parse", "--verify", "-q", "refs/heads/" + branch], in: top).ok { branch += "-" + String(t.id.prefix(4)) }
        // The working folder is inside the project, because the Code engine refuses to write in Black Team's own data folder. It is kept out
        // of the person's `git status` by the repository's local exclude file, which is never committed.
        let path = home + "/.black-team/work/" + String(t.id.prefix(8))
        do {
            try FileManager.default.createDirectory(atPath: home + "/.black-team/work", withIntermediateDirectories: true)
            OrgGit.exclude(repo: top, pattern: "/" + prefix + ".black-team/work/")
            try OrgGit.addWorktree(repo: top, path: path, branch: branch, base: head)
        } catch { throw OrgHalt.blocked(messageOf(error)) }
        let updated = try orgTicketMutate(org.projectId, t.id) { t2 in
            t2.branch = branch; t2.base = head; t2.baseBranch = OrgGit.currentBranch(top) ?? "(detached)"; t2.work = path; t2.prefix = prefix
            orgEvent(&t2, stage: t2.stage, "Made branch \(branch) from \(String(head.prefix(8))) in its own working folder. Your branch and folder are not touched.")
        }
        for a in updated.artifacts { if let text = OrgStore.readArtifact(dataFolder, org.projectId, t.id, name: a.name) { orgMirror(updated, name: a.name, text: text) } }
        return path + (prefix.isEmpty ? "" : "/" + prefix)
    }

    // MARK: Reading replies

    /// The value after `KEY:` on a line of its own, case-insensitive.
    static func orgField(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*#-_>`"))
            if trimmed.lowercased().hasPrefix(key.lowercased() + ":") { return EText.trim(String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`"))) }
        }
        return nil
    }

    static func orgGuessUI(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["screen", "page", "button", "layout", "css", "style", "window", "dialog", "form", "menu", "theme", "mockup", "interface", "dark mode", "icon", "sidebar", "tab ", "ui ", "ux"].contains { t.contains($0) }
    }

    // MARK: Intake

    private func orgIntake(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.intake, org: org) else { throw OrgHalt.blocked("The organization has no lead.") }
        let project = try roomProject(org.projectId)
        let tail = """
        You are reading a new ticket. Reply in exactly this form and nothing else:
        SUMMARY: one or two sentences.
        TOUCHES_UI: yes or no
        SIZE: small, normal or large (small is under an hour of work for one engineer; large should be split into smaller tickets)
        ACCEPTANCE CRITERIA:
        1. each one something a person could check by running the program
        If the request is too unclear to write criteria, write one line starting QUESTION: with ONE question for the owner instead.
        If SIZE is large, add a line SPLIT: followed by JSON {"tickets":[{"title":"...","body":"..."}]} with at most \(OrgLimits.split) smaller tickets.
        """
        let r = try await orgRunRole(org, ticket: t, stage: .intake, role: role, prompt: orgPrompt(orgHead(org, project, role, t, .intake), [], tail: tail), write: false,
                                     workspace: try orgWorkspace(org, t, branch: false))
        let name = try orgSaveArtifact(org, ticketId: t.id, stage: .intake, role: role, base: "intake", title: "Intake notes", text: r.text)
        if let question = Self.orgField("QUESTION", in: r.text), !question.isEmpty {
            throw OrgHalt.gate(kind: "question", question: question, artifact: name, service: nil)
        }
        let ui = t.ui ?? (Self.orgField("TOUCHES_UI", in: r.text).map { $0.lowercased().hasPrefix("y") } ?? Self.orgGuessUI(t.title + " " + t.body))
        let sizeText = (Self.orgField("SIZE", in: r.text) ?? "").lowercased()
        let size = sizeText.hasPrefix("small") ? "small" : sizeText.hasPrefix("large") ? "large" : "normal"
        _ = try orgTicketMutate(org.projectId, t.id) { x in
            x.ui = ui; x.size = size
            orgEvent(&x, stage: .intake, role: role.name, "Read the ticket: \(size), \(ui ? "touches the user interface" : "no user interface").")
        }
        if size == "large", let split = Self.orgSplit(r.text), !split.isEmpty {
            var made: [OrgTicket] = []
            for item in split.prefix(OrgLimits.split) { made.append(try orgCreateTicket(org, title: item.0, body: item.1, source: "lead", ui: nil, parent: t.id)) }
            _ = try orgTicketMutate(org.projectId, t.id) { x in
                x.children = made.map(\.id); x.state = "done"; x.currentRole = nil
                orgEvent(&x, stage: .intake, role: role.name, "Split into \(made.map(\.label).joined(separator: ", ")), each small enough to build on its own.")
            }
            return .handled
        }
        return .finished
    }

    static func orgSplit(_ text: String) -> [(String, String)]? {
        for object in TeamText.objects(in: text) {
            guard let list = object["tickets"]?.array else { continue }
            let items: [(String, String)] = list.compactMap { e in
                guard let title = e["title"]?.string, let clean = OrgStore.clean(EText.trim(title), max: OrgLimits.title) else { return nil }
                return (clean, OrgStore.clean(e["body"]?.string ?? "", max: OrgLimits.body, multiline: true, allowEmpty: true) ?? "")
            }
            if !items.isEmpty { return items }
        }
        return nil
    }

    // MARK: Spec

    private func orgSpec(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.spec, org: org) else { throw OrgHalt.blocked("The organization has no lead.") }
        let project = try roomProject(org.projectId)
        let tail = """
        Write the spec in Markdown with these headings: Goal, In scope, Out of scope, Acceptance criteria (numbered, each one checkable by running the program), Open questions.
        Keep it under one page. If the request is too unclear to write criteria, reply with ONE line starting QUESTION: and one question for the owner instead.
        """
        let r = try await orgRunRole(org, ticket: t, stage: .spec, role: role, prompt: orgPrompt(orgHead(org, project, role, t, .spec), orgEntries(t, ["intake"]), tail: tail), write: false,
                                     workspace: try orgWorkspace(org, t, branch: false))
        if let question = Self.orgField("QUESTION", in: r.text), !question.isEmpty, !r.text.lowercased().contains("acceptance criteria") {
            _ = try orgSaveArtifact(org, ticketId: t.id, stage: .spec, role: role, base: "spec", title: "Spec question", text: r.text)
            throw OrgHalt.gate(kind: "question", question: question, artifact: nil, service: nil)
        }
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .spec, role: role, base: "spec", title: "Spec", text: r.text)
        return .finished
    }

    // MARK: Design

    /// The text of the first fenced block of a language ("html", "css"), or nil.
    static func orgFence(_ language: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = [], inside = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside, trimmed.lowercased() == "```" + language { inside = true; continue }
            if inside { if trimmed.hasPrefix("```") { return out.joined(separator: "\n") }; out.append(line) }
        }
        return nil
    }

    private func orgDesign(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.design, org: org) else { return .finished }
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t, branch: true)
        let tail = """
        Design the user interface for this ticket. Reply with:
        1. A design spec in Markdown: who uses it, the screens or states, the behaviour, empty and error states, and the accessibility notes.
        2. ONE fenced ```html block with a complete, self-contained HTML and CSS mockup (no external files or scripts).
        3. ONE fenced ```css block with the design tokens (colours, spacing, type) as CSS custom properties on :root. Reuse the project's own tokens and theme if it has them.
        Black Team saves the two blocks as design/mockup.html and design/tokens.css in the ticket's branch.
        """
        let base = orgPrompt(orgHead(org, project, role, t, .design), orgEntries(t, ["spec", "intake"]), tail: tail)
        var reply = try await orgRunRole(org, ticket: t, stage: .design, role: role, prompt: base, write: false, workspace: workspace)
        var html = Self.orgFence("html", in: reply.text), css = Self.orgFence("css", in: reply.text)
        if html == nil {
            reply = try await orgRunRole(org, ticket: t, stage: .design, role: role,
                                         prompt: base + "\n\nYour last reply had no ```html block. Reply again with the design spec, the ```html mockup and the ```css tokens.", write: false, workspace: workspace)
            html = Self.orgFence("html", in: reply.text); css = Self.orgFence("css", in: reply.text)
        }
        guard let mockup = html else { throw OrgHalt.blocked("\(role.name) did not produce an HTML mockup. Retry, or give the designer a stronger model.") }
        let dir = workspace + "/design"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(mockup.utf8).write(to: URL(fileURLWithPath: dir + "/mockup.html"), options: .atomic)
        try? Data((css ?? "/* The designer sent no tokens. */").utf8).write(to: URL(fileURLWithPath: dir + "/tokens.css"), options: .atomic)
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .design, role: role, base: "design", title: "Design spec", text: reply.text)
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .design, role: role, base: "mockup", ext: "html", title: "Mockup (design/mockup.html)", text: mockup)
        if let css { _ = try orgSaveArtifact(org, ticketId: t.id, stage: .design, role: role, base: "tokens", ext: "css", title: "Design tokens (design/tokens.css)", text: css) }
        if t.branch != nil || orgTicket(org.projectId, t.id)?.branch != nil { OrgGit.commitAll(workspace, message: "\(t.label): design mockup and tokens") }
        if let note = await orgDesignReview(org, t, mockupPath: dir + "/mockup.html") {
            _ = try orgSaveArtifact(org, ticketId: t.id, stage: .design, role: role, base: "visual-review", title: "Design review", text: note)
        }
        return .finished
    }

    // MARK: Plan

    private func orgPlan(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.plan, org: org) else { return .finished }
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t, branch: true)
        let tail = "Break the spec into at most \(OrgLimits.buildTasks) engineering tasks, in the order they should be built. Read the code first. Each task is small, names the files it changes and how to know it is done. Reply with only JSON: {\"tasks\":[{\"title\":\"...\",\"detail\":\"...\"}]}"
        let r = try await orgRunRole(org, ticket: t, stage: .plan, role: role, prompt: orgPrompt(orgHead(org, project, role, t, .plan), orgEntries(t, ["spec", "intake", "design"]), tail: tail),
                                     write: false, workspace: workspace)
        var tasks: [OrgBuildTask] = []
        for object in TeamText.objects(in: r.text) {
            guard let list = object["tasks"]?.array else { continue }
            for e in list {
                guard let title = e["title"]?.string, let clean = OrgStore.clean(EText.trim(title), max: OrgLimits.title) else { continue }
                tasks.append(OrgBuildTask(title: clean, detail: OrgStore.clean(e["detail"]?.string ?? "", max: OrgLimits.body, multiline: true, allowEmpty: true) ?? "", done: false, result: "", role: nil))
            }
            if !tasks.isEmpty { break }
        }
        var notes = ""
        if tasks.isEmpty { tasks = [OrgBuildTask(title: t.title, detail: "Build the whole ticket from the spec.", done: false, result: "", role: nil)]; notes = "\n\n(The plan could not be read, so the ticket is built as one task.)" }
        tasks = Array(tasks.prefix(OrgLimits.buildTasks))
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .plan, role: role, base: "plan", title: "Plan",
                                text: "# Plan\n\n" + tasks.enumerated().map { "\($0.offset + 1). **\($0.element.title)**\n   \($0.element.detail)" }.joined(separator: "\n") + notes + "\n\n---\n\n" + r.text)
        _ = try orgTicketMutate(org.projectId, t.id) { $0.tasks = tasks }
        return .finished
    }

    // MARK: Build

    private func orgBuild(_ org: Organization, _ t0: OrgTicket) async throws -> OrgDone {
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t0, branch: true)
        var t = orgTicket(org.projectId, t0.id) ?? t0
        if t.tasks.isEmpty {
            let detail = t.findings.isEmpty ? "Build the whole ticket from the spec." : "Fix what review or QA found."
            t.tasks = [OrgBuildTask(title: t.title, detail: detail, done: false, result: "", role: nil)]
            _ = try orgTicketMutate(org.projectId, t.id) { $0.tasks = t.tasks }
        }
        guard let index = t.tasks.firstIndex(where: { !$0.done }) else { return try await orgFinishBuild(org, t, workspace: workspace) }
        let engineers = org.roles(of: OrgKind.engineer)
        guard let role = engineers.isEmpty ? orgStageRole(.build, org: org) : engineers[index % engineers.count] else { throw OrgHalt.blocked("The organization has no engineer.") }
        let task = t.tasks[index]
        var tail = "Your task (\(index + 1) of \(t.tasks.count)): \(task.title)\n\(task.detail)\n\nYou are working in this ticket's own branch\(t.branch.map { " (\($0))" } ?? ""). Change the files in the project folder, run the tests you can, and reply with what you changed, what you checked and anything not finished."
        if !t.findings.isEmpty { tail += "\n\nReview or QA sent this back with these findings. Fix them:\n\(t.findings)" }
        let r = try await orgRunRole(org, ticket: t, stage: .build, role: role, prompt: orgPrompt(orgHead(org, project, role, t, .build), orgEntries(t, ["spec", "intake", "design", "plan"]), tail: tail),
                                     write: true, workspace: workspace)
        if t.branch != nil || orgTicket(org.projectId, t.id)?.branch != nil { OrgGit.commitAll(workspace, message: "\(t.label) task \(index + 1): \(EText.prefix(task.title, 70))") }
        let after = try orgTicketMutate(org.projectId, t.id) { x in
            x.tasks[index].done = true; x.tasks[index].result = EText.prefix(r.text, 3000); x.tasks[index].role = role.id
            orgEvent(&x, stage: .build, role: role.name, "Finished task \(index + 1) of \(x.tasks.count): \(EText.prefix(task.title, 80))" + (r.changed.map { $0 > 0 ? " (\($0) file\($0 == 1 ? "" : "s") changed)" : "" } ?? ""))
        }
        return after.tasks.contains(where: { !$0.done }) ? .again : try await orgFinishBuild(org, after, workspace: workspace)
    }

    /// Every task is built: the build notes, and the diff against where the branch started.
    private func orgFinishBuild(_ org: Organization, _ t: OrgTicket, workspace: String) async throws -> OrgDone {
        var notes = "# Build notes for \(t.label)\n\n" + t.tasks.enumerated().map { "## Task \($0.offset + 1): \($0.element.title)\n\($0.element.result)" }.joined(separator: "\n\n")
        if let base = t.base, t.branch != nil {
            OrgGit.commitAll(workspace, message: "\(t.label): build notes")
            let stat = OrgGit.stat(workspace, base: base)
            notes += "\n\n## Files changed on \(t.branch ?? "")\n" + (stat.isEmpty ? "No files were changed." : "```\n\(stat)\n```")
            let diff = OrgGit.diff(workspace, base: base)
            _ = try orgSaveArtifact(org, ticketId: t.id, stage: .build, role: nil, base: "diff", ext: "patch", title: "Changes (git diff)", text: diff.isEmpty ? "(no changes)" : diff)
        } else {
            notes += "\n\nThis project is not a git repository, so the changes were made directly in the project folder and there is no diff to show."
        }
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .build, role: nil, base: "build", title: "Build notes", text: notes)
        _ = try orgTicketMutate(org.projectId, t.id) { $0.findings = ""; $0.tasks = [] }
        return .finished
    }

    // MARK: Review and QA

    /// Review or QA found a problem: back to Build with the findings, or, after too many rounds, to the owner.
    private func orgSendBack(_ org: Organization, _ t: OrgTicket, from stage: OrgStage, role: OrgRole, reason: String) throws -> OrgDone {
        let count = (t.sendBacks[stage.rawValue] ?? 0) + 1
        let text = reason.isEmpty ? "\(role.name) asked for changes." : reason
        if count > OrgLimits.sendBacks {
            throw OrgHalt.gate(kind: "escalation", question: "\(role.name) and the engineers have gone back and forth \(OrgLimits.sendBacks) times on \(t.label). Latest findings: \(EText.prefix(text, 400)) Approve to accept it as it is, or send it back with your own note.",
                               artifact: orgTicket(org.projectId, t.id).flatMap { orgLatest($0, stage == .review ? "review" : "qa")?.name }, service: nil)
        }
        _ = try orgTicketMutate(org.projectId, t.id) { x in
            x.sendBacks[stage.rawValue] = count; x.stage = .build; x.state = "ready"; x.findings = EText.prefix(text, OrgLimits.note * 3); x.currentRole = nil
            x.tasks = [OrgBuildTask(title: "Fix what \(role.name) found", detail: EText.prefix(text, OrgLimits.body), done: false, result: "", role: nil)]
            orgEvent(&x, stage: stage, role: role.name, "Sent back to Build (\(count) of \(OrgLimits.sendBacks)): \(EText.prefix(text, 240))")
        }
        return .handled
    }

    private func orgReview(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.review, org: org) else { return .finished }
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t, branch: true)
        let tail = "Review this change against the spec and the codebase's conventions. Look for bugs, missing cases, missing tests, files changed that should not have been, and style that does not match. Do not change any file. Reply with your review in a few lines, then ONE line of JSON in exactly this form: {\"verdict\":\"accept\" or \"revise\",\"reason\":\"what must change, file by file\"}"
        let r = try await orgRunRole(org, ticket: t, stage: .review, role: role,
                                     prompt: orgPrompt(orgHead(org, project, role, t, .review), orgEntries(t, ["spec", "intake", "design", "build", "diff"]), tail: tail), write: false, workspace: workspace)
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .review, role: role, base: "review", title: "Review notes", text: r.text)
        guard let verdict = TeamText.parseVerdict(r.text) else {
            _ = try orgTicketMutate(org.projectId, t.id) { orgEvent(&$0, stage: .review, role: role.name, "The review had no verdict, so it is treated as accepted. Read the review notes.") }
            return .finished
        }
        if verdict.accept { return .finished }
        return try orgSendBack(org, orgTicket(org.projectId, t.id) ?? t, from: .review, role: role, reason: verdict.reason)
    }

    /// QA's JSON verdict: "pass" or "fail".
    static func orgQAVerdict(_ text: String) -> (pass: Bool, reason: String)? {
        for object in TeamText.objects(in: text) {
            guard let v = object["verdict"]?.string.map({ EText.trim($0).lowercased() }), v == "pass" || v == "fail" else { continue }
            return (v == "pass", EText.trim(TeamStore.text(object["reason"]?.string ?? "", OrgLimits.note)))
        }
        return nil
    }

    private func orgQA(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.qa, org: org) else { return .finished }
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t, branch: true)
        let tail = "Check that this ticket really works. Run the project's tests, check each acceptance criterion one by one (met or not met, and how you know), and write the tests that are missing. Do not call anything working that you did not run. End with ONE line of JSON in exactly this form: {\"verdict\":\"pass\" or \"fail\",\"reason\":\"what failed\"}"
        let r = try await orgRunRole(org, ticket: t, stage: .qa, role: role,
                                     prompt: orgPrompt(orgHead(org, project, role, t, .qa), orgEntries(t, ["spec", "intake", "build", "review"]), tail: tail), write: role.access != .read, workspace: workspace)
        if t.branch != nil || orgTicket(org.projectId, t.id)?.branch != nil { OrgGit.commitAll(workspace, message: "\(t.label) QA: tests and report") }
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .qa, role: role, base: "qa", title: "Test report", text: r.text)
        guard let verdict = Self.orgQAVerdict(r.text) else {
            return try orgSendBack(org, orgTicket(org.projectId, t.id) ?? t, from: .qa, role: role, reason: "QA's report had no pass or fail verdict. Check that the tests were run and report the result.")
        }
        if verdict.pass { return .finished }
        return try orgSendBack(org, orgTicket(org.projectId, t.id) ?? t, from: .qa, role: role, reason: verdict.reason)
    }

    // MARK: Ship

    private func orgShip(_ org: Organization, _ t: OrgTicket) async throws -> OrgDone {
        guard let role = orgStageRole(.ship, org: org) else { return .finished }
        let project = try roomProject(org.projectId)
        let workspace = try orgWorkspace(org, t, branch: true)
        let fresh = orgTicket(org.projectId, t.id) ?? t
        if let docs = org.roles(of: OrgKind.docs).first, orgLatest(fresh, "docs") == nil {
            let tail = "Write the documentation for this change: what it is, how to use it, what to expect and what it does not do. Plain words for a non-technical reader, short sentences, the exact command or button. Reply with the Markdown."
            let r = try await orgRunRole(org, ticket: t, stage: .ship, role: docs, prompt: orgPrompt(orgHead(org, project, docs, t, .ship), orgEntries(t, ["spec", "intake", "design", "build", "review", "qa"]), tail: tail),
                                         write: false, workspace: workspace)
            _ = try orgSaveArtifact(org, ticketId: t.id, stage: .ship, role: docs, base: "docs", title: "Documentation", text: r.text)
        }
        var summary = ""
        if let base = fresh.base, let branch = fresh.branch {
            let stat = OrgGit.stat(workspace, base: base), log = OrgGit.log(workspace, base: base)
            summary = "Branch: \(branch)\nStarted from: \(String(base.prefix(8))) on \(fresh.baseBranch ?? "your branch")\nCommits:\n\(log.isEmpty ? "(none)" : log)\nFiles:\n\(stat.isEmpty ? "(no files changed)" : stat)"
        } else { summary = "This project is not a git repository: the changes are in the project folder itself." }
        let tail = "Prepare this change for the owner. Write release notes in Markdown: what changed for a person using the product, the acceptance criteria and how each was checked, what review and QA found, anything unfinished or risky first, and what to watch for. You never merge anything; merging is the owner's decision.\n\nBranch facts:\n\(summary)"
        let r = try await orgRunRole(org, ticket: t, stage: .ship, role: role, prompt: orgPrompt(orgHead(org, project, role, t, .ship), orgEntries(t, ["spec", "intake", "design", "build", "review", "qa", "docs"]), tail: tail),
                                     write: false, workspace: workspace)
        let merge = fresh.branch.map { "\n\n## To merge\n\nThe work is on branch `\($0)`, started from `\(fresh.baseBranch ?? "your branch")`. Black Team has not merged it. When you are happy:\n\n```\ngit merge \($0)\n```\n\nThe branch also holds a `.black-team/tickets/\(t.label)/` folder with this ticket's notes; delete it before merging if you do not want it in your history." } ?? ""
        _ = try orgSaveArtifact(org, ticketId: t.id, stage: .ship, role: role, base: "release-notes", title: "Release notes", text: r.text + "\n\n---\n\n" + summary + merge)
        if let latest = orgTicket(org.projectId, t.id), latest.branch != nil { OrgGit.commitAll(workspace, message: "\(t.label): ticket notes") }
        return .finished
    }
}
