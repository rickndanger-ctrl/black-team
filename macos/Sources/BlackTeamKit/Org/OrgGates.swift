import Foundation

// The owner's side of an organization: a gate holds a ticket until the person approves it, sends it back with a note, or answers its question.
// A gate is a ticket state AND an item in the background service's Inbox (Service/Inbox.swift), so it shows in the window, on the phone and in
// `black-team inbox`, with the artifact to read. Either place can answer it; answering one settles the other.

extension Backend {
    // MARK: The Inbox

    @discardableResult
    func orgInboxGate(_ org: Organization, ticket: OrgTicket, stage: OrgStage, kind: String, question: String, artifact: String?, desktopOnly: Bool = false) -> (id: String, question: String) {
        let item = InboxItem(id: UUID().uuidString.lowercased(), scheduleId: "org:" + ticket.id, scheduleName: "\(org.name) \u{00B7} \(ticket.label) \(stage.title)",
                             threadId: nil, project: org.projectId, command: "", question: question, digest: "", created: now().timeIntervalSince1970, expires: 0,
                             state: "waiting", answered: nil, kind: "gate", orgProject: org.projectId, ticketId: ticket.id, stage: stage.rawValue, gateKind: kind,
                             artifact: artifact, desktopOnly: desktopOnly ? true : nil)
        try? orgInbox().add(item)
        changed()
        return (item.id, question)
    }

    func orgInboxNote(_ org: Organization, title: String, text: String, artifact: String? = nil) {
        let item = InboxItem(id: UUID().uuidString.lowercased(), scheduleId: "org-note:" + org.projectId, scheduleName: title, threadId: nil, project: org.projectId,
                             command: "", question: text, digest: "", created: now().timeIntervalSince1970, expires: 0, state: "waiting", answered: nil,
                             kind: "note", orgProject: org.projectId, ticketId: nil, stage: nil, gateKind: nil, artifact: artifact, desktopOnly: nil)
        try? orgInbox().add(item)
        changed()
    }

    /// Called by the Inbox when the person answers a gate or clears a note there.
    func orgAnswerInbox(_ item: InboxItem, approve: Bool) throws {
        let store = orgInbox()
        if item.kind == "note" { _ = try store.settle(item.id, as: "answered", at: now()); changed(); return }
        guard let project = item.orgProject, let ticketId = item.ticketId else { throw BlackTeamError("That question is not waiting any more.") }
        if item.gateKind == "question" && approve { throw BlackTeamError("This ticket asked you a question. Write your answer on the Tickets page.") }
        if approve { try ticketApprove(projectId: project, ticketId: ticketId) }
        else if item.gateKind == "privacy" { try ticketCancelPrivacy(projectId: project, ticketId: ticketId) }
        else { try ticketSendBack(projectId: project, ticketId: ticketId, note: "The owner did not approve this. Do it again with that in mind.") }
    }

    private func orgSettleGate(_ gate: OrgGate?, as state: String) {
        guard let gate else { return }
        _ = try? orgInbox().settle(gate.inboxId, as: state, at: now())
    }

    // MARK: Raising a gate

    func orgRaiseGate(_ org: Organization, ticketId: String, stage: OrgStage, kind: String, question: String, artifact: String?, service: String? = nil) {
        guard let ticket = orgTicket(org.projectId, ticketId) else { return }
        let desktopOnly = kind == "privacy"
        let made = orgInboxGate(org, ticket: ticket, stage: stage, kind: kind, question: question, artifact: artifact, desktopOnly: desktopOnly)
        _ = try? orgTicketMutate(org.projectId, ticketId) { t in
            t.state = "gate"; t.currentRole = nil
            t.gate = OrgGate(stage: stage.rawValue, kind: kind, question: question, artifact: artifact, inboxId: made.id, created: roomNow(), service: service)
            orgEvent(&t, stage: stage, "Waiting for you: \(EText.prefix(question, 160))")
        }
    }

    // MARK: The owner's actions

    /// Approve a gate: the ticket goes on.
    @discardableResult
    public func ticketApprove(projectId: String, ticketId: String, note: String = "") throws -> OrgState {
        let org = try orgRequire(projectId)
        guard let ticket = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        guard ticket.state == "gate", let gate = ticket.gate else { throw BlackTeamError("\(ticket.label) is not waiting for you.") }
        if gate.kind == "question" { throw BlackTeamError("\(ticket.label) asked you a question. Answer it instead of approving.") }
        let stage = OrgStage(rawValue: gate.stage) ?? ticket.stage
        orgSettleGate(gate, as: "approved")
        switch gate.kind {
        case "privacy":
            if let service = gate.service {
                try orgMutate(projectId) { if !$0.confirmed.contains(service) { $0.confirmed.append(service) } }
            }
            try orgTicketMutate(projectId, ticketId) { t in
                t.gate = nil; t.state = "ready"; t.stage = stage
                orgEvent(&t, stage: stage, "You agreed that \(t.label) may go to \(gate.service ?? "that service").")
            }
        case "approval" where stage == .intake && ticket.artifacts.isEmpty:
            // A ticket from the phone, started from the computer.
            try orgTicketMutate(projectId, ticketId) { t in t.gate = nil; t.state = "ready"; orgEvent(&t, stage: stage, "You started it.") }
        default:
            try orgTicketMutate(projectId, ticketId) { t in
                t.gate = nil
                orgEvent(&t, stage: stage, "You approved \(stage.title.lowercased())." + (EText.trim(note).isEmpty ? "" : " Note: " + EText.prefix(EText.trim(note), 300)))
                if !EText.trim(note).isEmpty { t.answers.append("Owner's note on \(stage.title.lowercased()): " + EText.prefix(EText.trim(note), 600)) }
            }
            try orgMoveOn(org, ticketId: ticketId, from: stage)
        }
        return try orgState(projectId: projectId)
    }

    /// Send a ticket back with a note. From a gate it re-runs that stage (a shipped or finished ticket, and a stuck review or QA, go back to Build).
    @discardableResult
    public func ticketSendBack(projectId: String, ticketId: String, note: String, to: String? = nil) throws -> OrgState {
        let org = try orgRequire(projectId)
        guard let ticket = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        let text = EText.trim(note)
        guard let clean = OrgStore.clean(text, max: OrgLimits.note, multiline: true) else { throw BlackTeamError("Write a note of up to \(OrgLimits.note) characters saying what to change.") }
        guard ["gate", "blocked", "done"].contains(ticket.state) else { throw BlackTeamError("\(ticket.label) can be sent back when it waits for you, is stuck, or is finished.") }
        var target = ticket.stage
        if let gate = ticket.gate, let s = OrgStage(rawValue: gate.stage) {
            target = (s == .ship || gate.kind == "escalation") ? .build : s
        } else if ticket.state == "done" { target = .build }
        if let to {
            guard let s = OrgStage(rawValue: to), s != .intake || ticket.state != "done" else { throw BlackTeamError("Choose a stage: \(OrgStage.allCases.map(\.rawValue).joined(separator: ", ")).") }
            target = s
        }
        orgSettleGate(ticket.gate, as: "denied")
        try orgTicketMutate(projectId, ticketId) { t in
            t.gate = nil; t.state = "ready"; t.stage = target; t.note = ""
            t.findings = clean
            if target == .build { t.tasks = [OrgBuildTask(title: "Fix what the owner asked for", detail: clean, done: false, result: "", role: nil)] }
            if target == .review || target == .qa { t.sendBacks[target.rawValue] = 0 }
            orgEvent(&t, stage: target, "You sent it back to \(target.title): \(EText.prefix(clean, 200))")
        }
        _ = org
        return try orgState(projectId: projectId)
    }

    /// The owner's answer to a question a ticket asked.
    @discardableResult
    public func ticketAnswer(projectId: String, ticketId: String, answer: String) throws -> OrgState {
        _ = try orgRequire(projectId)
        guard let ticket = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        guard ticket.state == "gate", let gate = ticket.gate, gate.kind == "question" else { throw BlackTeamError("\(ticket.label) has no question waiting for you.") }
        guard let clean = OrgStore.clean(EText.trim(answer), max: OrgLimits.note, multiline: true) else { throw BlackTeamError("Write an answer of up to \(OrgLimits.note) characters.") }
        orgSettleGate(gate, as: "answered")
        try orgTicketMutate(projectId, ticketId) { t in
            t.gate = nil; t.state = "ready"; t.stage = OrgStage(rawValue: gate.stage) ?? t.stage
            t.answers.append("Question: \(gate.question)\nOwner's answer: \(clean)")
            orgEvent(&t, stage: t.stage, "You answered: \(EText.prefix(clean, 200))")
        }
        return try orgState(projectId: projectId)
    }

    /// A refused privacy gate: the ticket stays where it is and is blocked, saying why.
    func ticketCancelPrivacy(projectId: String, ticketId: String) throws {
        guard let ticket = orgTicket(projectId, ticketId), let gate = ticket.gate else { return }
        orgSettleGate(gate, as: "denied")
        try orgTicketMutate(projectId, ticketId) { t in
            t.gate = nil; t.state = "blocked"
            t.note = "You did not allow \(t.label) to go to \(gate.service ?? "that service"). Change the role or allow it, then retry."
            orgEvent(&t, stage: t.stage, t.note)
        }
    }

    @discardableResult
    public func ticketRetry(projectId: String, ticketId: String) throws -> OrgState {
        _ = try orgRequire(projectId)
        guard let ticket = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        guard ticket.state == "blocked" else { throw BlackTeamError("\(ticket.label) is not stuck.") }
        try orgTicketMutate(projectId, ticketId) { t in t.state = "ready"; t.note = ""; orgEvent(&t, stage: t.stage, "You asked for another try.") }
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func ticketCancel(projectId: String, ticketId: String) throws -> OrgState {
        _ = try orgRequire(projectId)
        guard let ticket = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        if ticket.state == "running" { throw BlackTeamError("\(ticket.label) is being worked on. Pause the organization first.") }
        if ticket.finished { throw BlackTeamError("\(ticket.label) is already finished.") }
        orgSettleGate(ticket.gate, as: "ended")
        try orgTicketMutate(projectId, ticketId) { t in t.state = "cancelled"; t.gate = nil; orgEvent(&t, "You cancelled it.") }
        return try orgState(projectId: projectId)
    }

    // MARK: Moving a ticket on

    func orgStageRole(_ stage: OrgStage, org: Organization) -> OrgRole? {
        let lead = org.roles(of: OrgKind.lead).first
        switch stage {
        case .intake: return lead
        case .spec: return org.roles(of: OrgKind.product).first ?? lead
        case .design: return org.roles(of: OrgKind.designer).first
        case .plan: return org.roles(of: OrgKind.architect).first ?? lead
        case .build: return org.roles(of: OrgKind.engineer).first ?? lead
        case .review: return org.roles(of: OrgKind.reviewer).first
        case .qa: return org.roles(of: OrgKind.qa).first
        case .ship: return org.roles(of: OrgKind.release).first ?? lead
        }
    }

    /// Whether a ticket goes through a stage, and why not.
    func orgShouldRun(_ stage: OrgStage, ticket: OrgTicket, org: Organization) -> (run: Bool, why: String) {
        switch stage {
        case .intake, .build: return (true, "")
        case .spec: return org.roles(of: OrgKind.product).isEmpty ? (false, "the lead wrote the acceptance criteria at intake") : (true, "")
        case .design:
            if ticket.ui != true { return (false, "it does not touch the user interface") }
            return org.roles(of: OrgKind.designer).isEmpty ? (false, "there is no designer") : (true, "")
        case .plan: return ticket.size == "small" ? (false, "it is small enough to build in one piece") : (true, "")
        case .review: return org.roles(of: OrgKind.reviewer).isEmpty ? (false, "there is no reviewer") : (true, "")
        case .qa: return org.roles(of: OrgKind.qa).isEmpty ? (false, "there is no QA role") : (true, "")
        case .ship: return (true, "")
        }
    }

    /// After a stage (and its gate): the next stage that applies, or done.
    func orgMoveOn(_ org: Organization, ticketId: String, from stage: OrgStage) throws {
        let projectId = org.projectId
        guard let ticket = orgTicket(projectId, ticketId) else { return }
        var next = OrgStage.allCases.first { $0.index == stage.index + 1 }
        while let n = next {
            let decision = orgShouldRun(n, ticket: ticket, org: org)
            if decision.run {
                try orgTicketMutate(projectId, ticketId) { t in t.stage = n; t.state = "ready"; t.currentRole = nil }
                return
            }
            try orgTicketMutate(projectId, ticketId) { orgEvent(&$0, stage: n, "\(n.title) skipped: \(decision.why).") }
            // The owner still approves the spec when the lead wrote it at intake.
            if n == .spec, org.gated(.spec) {
                try orgTicketMutate(projectId, ticketId) { $0.stage = .spec }
                orgRaiseGate(org, ticketId: ticketId, stage: .spec, kind: "approval", question: "Approve the spec for \(ticket.label)?", artifact: orgLatest(ticket, "intake")?.name)
                return
            }
            next = OrgStage.allCases.first { $0.index == n.index + 1 }
        }
        try orgTicketMutate(projectId, ticketId) { t in
            t.state = "done"; t.currentRole = nil; t.gate = nil
            if let branch = t.branch {
                orgEvent(&t, stage: .ship, "Done. The work is on branch \(branch); merging it is up to you: git merge \(branch)")
            } else { orgEvent(&t, stage: .ship, "Done. The changes are in your project folder.") }
        }
        orgPruneBoard(projectId)
    }

    /// The newest artifact of a kind ("spec" finds spec.md and spec-2.md).
    func orgLatest(_ ticket: OrgTicket, _ base: String) -> OrgArtifact? {
        ticket.artifacts.last { $0.name == base + ".md" || $0.name.hasPrefix(base + "-") || $0.name == base + ".patch" }
    }

    /// The room's board keeps up to 200 tasks; finished stage tasks of old tickets are removed so a long-running organization never fills it.
    func orgPruneBoard(_ projectId: String) {
        _ = try? roomMutate(projectId) { data in
            guard data.tasks.count > RoomLimits.tasks - 40 else { return }
            var drop = data.tasks.count - (RoomLimits.tasks - 80)
            data.tasks.removeAll { t in
                if drop > 0, t.status == .done, t.title.hasPrefix("T-") { drop -= 1; return true }
                return false
            }
        }
    }
}
