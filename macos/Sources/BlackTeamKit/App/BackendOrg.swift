import Foundation

// The organization's control surface on the Backend: make one for a project, edit its roles, read its state, show and confirm what leaves this
// computer, start, pause and resume it, and add tickets. The running of tickets is Org/OrgRunner.swift; the gates are Org/OrgGates.swift.
//
// Per project, not across projects: the Room, the board, the git repository, the cloud setting and the memory notes are all per project, so one
// organization per project keeps every existing rule (what leaves the computer, which branch) meaning what it already means. Agents are shared
// the way they always were, through the roster.

/// What the organization needs to remember between ticks, in memory only.
final class OrgRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var _stepping = false
    private var _stop = false
    private var _loop: Task<Void, Never>?
    private var _inbox: InboxStore?
    private var _current: (project: String, ticket: String, role: String)?

    var stepping: Bool { lock.lock(); defer { lock.unlock() }; return _stepping }
    /// Takes the one step slot; false when a step is already going.
    func begin(project: String, ticket: String, role: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _stepping { return false }
        _stepping = true; _stop = false; _current = (project, ticket, role)
        return true
    }
    func end() { lock.lock(); _stepping = false; _current = nil; lock.unlock() }
    var stopRequested: Bool { get { lock.lock(); defer { lock.unlock() }; return _stop } set { lock.lock(); _stop = newValue; lock.unlock() } }
    var current: (project: String, ticket: String, role: String)? { lock.lock(); defer { lock.unlock() }; return _current }
    func setRole(_ role: String) { lock.lock(); if let c = _current { _current = (c.project, c.ticket, role) }; lock.unlock() }
    var loop: Task<Void, Never>? { get { lock.lock(); defer { lock.unlock() }; return _loop } set { lock.lock(); _loop = newValue; lock.unlock() } }
    func inbox(_ dataFolder: String) -> InboxStore {
        lock.lock(); defer { lock.unlock() }
        if let _inbox { return _inbox }
        let made = InboxStore(dataFolder: dataFolder); _inbox = made; return made
    }
}

extension Backend {
    func orgInbox() -> InboxStore { service?.inbox ?? orgRuntime.inbox(dataFolder) }

    func orgCheckProject(_ projectId: String) throws -> Project { try roomProject(projectId) }

    func orgLoad(_ projectId: String) -> Organization? { orgLock.lock(); defer { orgLock.unlock() }; return OrgStore.load(dataFolder, projectId) }

    func orgRequire(_ projectId: String) throws -> Organization {
        _ = try roomProject(projectId)
        guard let org = orgLoad(projectId) else { throw BlackTeamError("This project has no organization yet. Make one first.") }
        return org
    }

    /// Changes the organization under the lock and saves it.
    @discardableResult
    func orgMutate(_ projectId: String, _ body: (inout Organization) throws -> Void) throws -> Organization {
        _ = try roomProject(projectId)
        orgLock.lock(); defer { orgLock.unlock() }
        guard var org = OrgStore.load(dataFolder, projectId) else { throw BlackTeamError("This project has no organization yet. Make one first.") }
        try body(&org)
        try OrgStore.save(org, dataFolder)
        changed()
        return org
    }

    func orgTickets(_ projectId: String) -> [OrgTicket] { orgLock.lock(); defer { orgLock.unlock() }; return OrgStore.tickets(dataFolder, projectId) }

    func orgTicket(_ projectId: String, _ id: String) -> OrgTicket? { orgTickets(projectId).first { $0.id == id } }

    /// Changes one ticket under the lock (read again first, so a change made in between is never overwritten) and saves.
    @discardableResult
    func orgTicketMutate(_ projectId: String, _ id: String, _ body: (inout OrgTicket) throws -> Void) throws -> OrgTicket {
        orgLock.lock(); defer { orgLock.unlock() }
        var all = OrgStore.tickets(dataFolder, projectId)
        guard let at = all.firstIndex(where: { $0.id == id }) else { throw BlackTeamError("That ticket is not in this organization.") }
        try body(&all[at])
        all[at].updated = roomNow()
        if all[at].history.count > OrgLimits.history { all[at].history.removeFirst(all[at].history.count - OrgLimits.history) }
        try OrgStore.saveTickets(all, dataFolder, projectId)
        changed()
        return all[at]
    }

    func orgEvent(_ t: inout OrgTicket, stage: OrgStage? = nil, role: String? = nil, _ text: String) {
        t.history.append(OrgEvent(at: roomNow(), stage: stage?.rawValue, role: role, text: TeamStore.text(text, 600)))
    }

    // MARK: Reading

    func orgChoices() -> [OrgChoice] {
        var out: [OrgChoice] = []
        for m in savedModels.list() { out.append(OrgChoice(kind: "model", key: m.key, name: m.name, cloud: m.kind == "cloud", provider: m.provider)) }
        for s in AgentService.allCases where agentInstalled(s) { out.append(OrgChoice(kind: "agent", key: s.engine, name: s.displayName, cloud: true, provider: s.provider)) }
        return out
    }

    func orgRoleView(_ role: OrgRole, org: Organization, project: Project, tickets: [OrgTicket], usage: [OrgUsageEntry]) -> OrgRoleView {
        var view = OrgRoleView(role: role, kind: "none", provider: "", usable: false, reason: "", status: "not set up", ticket: nil,
                               spentToday: orgSpend(usage.filter { $0.roleId == role.id && $0.day == orgDay() }))
        guard role.isSetUp else { view.reason = "Choose a model or an agent for this role."; return view }
        let m = roomView(orgScratchMember(role), project: project)
        view.kind = m.kind; view.provider = m.provider; view.usable = m.usable; view.reason = m.reason
        if !m.usable { view.status = "not set up"; return view }
        if let c = orgRuntime.current, c.project == project.id, c.role == role.id, let t = tickets.first(where: { $0.id == c.ticket }) {
            view.status = "working"; view.ticket = t.label; return view
        }
        // A role whose stage is held at a gate for the owner is waiting for them.
        if let t = tickets.first(where: { $0.state == "gate" && orgStageRole(OrgStage(rawValue: $0.gate?.stage ?? "") ?? $0.stage, org: org)?.id == role.id }) {
            view.status = "waiting"; view.ticket = t.label; return view
        }
        view.status = org.paused ? "paused" : "idle"
        return view
    }

    /// A room member standing in for a role, only to ask the Room how usable it is.
    func orgScratchMember(_ role: OrgRole) -> RoomMember {
        RoomMember(id: role.id, name: role.name, role: EText.prefix(role.name, RoomLimits.role), modelKey: role.modelKey, agent: role.agent,
                   permission: role.agent == nil ? nil : role.access.agent.rawValue, work: role.work)
    }

    func orgIsGit(_ project: Project) -> Bool { OrgGit.toplevel(project.workspace) != nil }

    public func orgState(projectId: String) throws -> OrgState {
        let project = try roomProject(projectId)
        let org = orgLoad(projectId)
        let tickets = orgTickets(projectId)
        let usage = OrgStore.usage(dataFolder, projectId)
        return OrgState(projectId: projectId, projectName: project.name, cloudAllowed: project.cloudAllowed, git: orgIsGit(project), organization: org,
                        roles: org.map { o in o.roles.map { orgRoleView($0, org: o, project: project, tickets: tickets, usage: usage) } } ?? [],
                        tickets: tickets, ledger: orgLedger(usage: usage, day: orgDay()), templates: OrgTemplates.list, choices: orgChoices(),
                        busy: isBusy || orgRuntime.stepping, stages: OrgStage.allCases.map(\.rawValue))
    }

    // MARK: Making and editing

    private func orgCheckRole(_ input: OrgRole) throws -> OrgRole {
        guard let role = OrgStore.cleanRole(input) else { throw BlackTeamError("Give the role a name of up to \(OrgLimits.name) characters, a charter of up to \(EText.grouped(OrgLimits.charter)) and short guidance notes.") }
        if let key = role.modelKey, savedModels.find(key) == nil { throw BlackTeamError("That model is not in your list.") }
        return role
    }

    /// Makes the organization of a project from a template. Roles come without models; `local` (a saved model's key) fills every role except
    /// the lead, and `leadModel` or `leadAgent` fills the lead (the local model when neither is given). The person changes any of it afterwards.
    @discardableResult
    public func orgCreate(projectId: String, template: String, name: String? = nil, local: String? = nil, leadModel: String? = nil,
                          leadAgent: String? = nil) throws -> OrgState {
        let project = try roomProject(projectId)
        guard let t = OrgTemplates.template(template) else { throw BlackTeamError("Choose Software company, Design studio or Small team.") }
        orgLock.lock(); defer { orgLock.unlock() }
        if OrgStore.load(dataFolder, projectId) != nil { throw BlackTeamError("This project already has an organization. Change its roles instead, or remove it first.") }
        let title = EText.trim(name ?? "") .isEmpty ? "\(project.name) \(t.name.lowercased())" : EText.trim(name ?? "")
        guard let orgName = OrgStore.clean(title, max: OrgLimits.name) else { throw BlackTeamError("Give the organization a name of up to \(OrgLimits.name) characters.") }
        // With no model named, every role starts on the local model in use, so a new organization can work at once.
        let inUse = (try? configStore.read().model).flatMap { $0.source == "cloud" ? nil : keyOf($0) }
        let local = local ?? inUse.flatMap { savedModels.find($0) == nil ? nil : $0 }
        for key in [local, leadModel].compactMap({ $0 }) where savedModels.find(key) == nil { throw BlackTeamError("That model is not in your list.") }
        if let leadAgent, AgentService.forEngine(leadAgent) == nil { throw BlackTeamError("The agent is claude-code or codex.") }
        var roles: [OrgRole] = []
        for kind in t.kinds {
            var role = OrgTemplates.role(kind)
            if kind == OrgKind.lead {
                if let leadAgent, let s = AgentService.forEngine(leadAgent) { role.agent = s.engine; role.access = .read }
                else if let key = leadModel ?? local { role.modelKey = key; role.work = OrgTemplates.defaults(kind).work }
            } else if let local {
                role.modelKey = local; role.work = OrgTemplates.defaults(kind).work
            }
            roles.append(role)
        }
        let org = Organization(projectId: projectId, name: orgName, template: t.id, roles: roles, gates: [OrgStage.spec.rawValue, OrgStage.ship.rawValue],
                               running: false, paused: false, pausedReason: "", confirmed: [], agreement: "", budget: OrgBudget(), standupAt: "daily at 9:00",
                               standupLast: "", nextNumber: 1, created: roomNow())
        try OrgStore.save(org, dataFolder)
        changed()
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func orgRemove(projectId: String) throws -> OrgState {
        let org = try orgRequire(projectId)
        if org.running { throw BlackTeamError("Pause the organization before removing it.") }
        orgLock.lock(); defer { orgLock.unlock() }
        // The tickets, artifacts and usage go; the branches already made in the repository stay, and are the person's to delete.
        try? FileManager.default.removeItem(atPath: OrgStore.folder(dataFolder, projectId))
        changed()
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func orgSaveRole(projectId: String, role input: OrgRole) throws -> OrgState {
        let role = try orgCheckRole(input)
        try orgMutate(projectId) { org in
            if let at = org.roles.firstIndex(where: { $0.id == role.id }) { org.roles[at] = role }
            else {
                if org.roles.count >= OrgLimits.roles { throw BlackTeamError("An organization has up to \(OrgLimits.roles) roles.") }
                org.roles.append(role)
            }
            orgReviewServices(&org, project: try roomProject(projectId))
        }
        return try orgState(projectId: projectId)
    }

    /// A new role of a built-in kind (or a custom one), with its default charter.
    @discardableResult
    public func orgAddRole(projectId: String, kind: String, name: String? = nil) throws -> OrgState {
        var role = OrgTemplates.role([OrgKind.lead, OrgKind.product, OrgKind.designer, OrgKind.architect, OrgKind.engineer, OrgKind.reviewer, OrgKind.qa, OrgKind.docs, OrgKind.release].contains(kind) ? kind : OrgKind.custom)
        if let name, !EText.trim(name).isEmpty { role.name = EText.trim(name) }
        // A new role takes the same model as the last role, which is the common case for another engineer.
        if let org = orgLoad(projectId), let like = org.roles.last(where: { $0.kind == role.kind }) ?? org.roles.last(where: { $0.agent == nil && $0.modelKey != nil }) {
            if like.agent == nil { role.modelKey = like.modelKey; role.work = like.work }
        }
        return try orgSaveRole(projectId: projectId, role: role)
    }

    @discardableResult
    public func orgRemoveRole(projectId: String, roleId: String) throws -> OrgState {
        try orgMutate(projectId) { org in
            guard let at = org.roles.firstIndex(where: { $0.id == roleId }) else { throw BlackTeamError("That role is not in this organization.") }
            if org.roles[at].kind == OrgKind.lead { throw BlackTeamError("An organization needs its lead. Change the lead instead of removing it.") }
            if orgRuntime.current?.role == roleId { throw BlackTeamError("Wait for \(org.roles[at].name) to finish what it is doing.") }
            org.roles.remove(at: at)
        }
        return try orgState(projectId: projectId)
    }

    /// Saves a role's model or agent to the roster, so it can be added to a room elsewhere.
    @discardableResult
    public func orgSaveRoleToRoster(projectId: String, roleId: String) throws -> [RosterEntryView] {
        let org = try orgRequire(projectId)
        guard let role = org.role(roleId), role.isSetUp else { throw BlackTeamError("Choose a model or an agent for that role first.") }
        return try rosterCreate(name: role.name, role: EText.prefix(role.name, RoomLimits.role), modelKey: role.modelKey, agent: role.agent,
                                permission: role.agent == nil ? nil : role.access.agent.rawValue, work: role.work)
    }

    /// Name, gates, ceilings, the stand-up time and pause/resume text. Everything optional; what is nil is left alone.
    @discardableResult
    public func orgUpdate(projectId: String, name: String? = nil, gates: [String]? = nil, budget: OrgBudget? = nil, standupAt: String? = nil) throws -> OrgState {
        try orgMutate(projectId) { org in
            if let name {
                guard let clean = OrgStore.clean(EText.trim(name), max: OrgLimits.name) else { throw BlackTeamError("Give the organization a name of up to \(OrgLimits.name) characters.") }
                org.name = clean
            }
            if let gates {
                guard gates.allSatisfy({ OrgStage(rawValue: $0) != nil }) else { throw BlackTeamError("A gate is one of: \(OrgStage.allCases.map(\.rawValue).joined(separator: ", ")).") }
                org.gates = OrgStage.allCases.map(\.rawValue).filter { gates.contains($0) }
            }
            if let budget {
                if let t = budget.paidTokensPerDay, t < 0 { throw BlackTeamError("A token ceiling is zero or more.") }
                if let m = budget.moneyPerDay, !(m >= 0) { throw BlackTeamError("A money ceiling is zero or more.") }
                org.budget = budget
            }
            if let standupAt {
                let words = EText.trim(standupAt)
                if !words.isEmpty { _ = try ScheduleWhen.parse(words, now: now()) }
                org.standupAt = words
            }
        }
        return try orgState(projectId: projectId)
    }

    /// If a role now reaches a service the owner has not agreed to, continuous pickup stops until the agreement is read again.
    func orgReviewServices(_ org: inout Organization, project: Project) {
        guard org.running else { return }
        let services = Set(orgServices(org, project: project))
        if !services.isSubset(of: Set(org.confirmed)) {
            org.running = false
            org.pausedReason = "A role now uses a service you have not agreed to. Read the agreement and start the organization again."
        }
    }

    // MARK: What leaves this computer

    /// The services (hosts) the roles run on, each once, in role order.
    func orgServices(_ org: Organization, project: Project) -> [String] {
        var out: [String] = []
        for role in org.roles where role.isSetUp {
            let v = roomView(orgScratchMember(role), project: project)
            if v.kind == "cloud", !v.provider.isEmpty, !out.contains(v.provider) { out.append(v.provider) }
        }
        return out
    }

    public func orgAgreement(projectId: String) throws -> OrgAgreement {
        let project = try roomProject(projectId)
        let org = try orgRequire(projectId)
        return orgAgreementBuild(org, project: project)
    }

    func orgAgreementBuild(_ org: Organization, project: Project) -> OrgAgreement {
        var problems: [String] = []
        var paid: [(role: OrgRole, provider: String)] = [], local: [OrgRole] = []
        if org.roles(of: OrgKind.lead).isEmpty { problems.append("An organization needs a lead.") }
        for role in org.roles {
            guard role.isSetUp else { problems.append("\(role.name) has no model or agent yet."); continue }
            let v = roomView(orgScratchMember(role), project: project)
            if !v.usable { problems.append("\(role.name): \(v.reason)") }
            if v.kind == "cloud" { paid.append((role, v.provider)) } else { local.append(role) }
            if role.modelKey != nil, role.work == "chat", [OrgKind.engineer, OrgKind.qa].contains(role.kind) {
                problems.append("\(role.name) does chat work and cannot read or change files. Choose a model that does Code work.")
            }
            if [OrgKind.engineer, OrgKind.qa].contains(role.kind), role.access == .read {
                problems.append("\(role.name) can only read files, so it cannot build. Allow it to edit files in the project.")
            }
        }
        let services = orgServices(org, project: project)
        var text = "Starting \(org.name) lets it work on its tickets in \(project.name) without you at the window, one stage at a time. "
        text += "For each ticket, the ticket's words and the work the earlier stages produced (spec, design, plan, the code changes, review and test notes) are given to the role that runs the next stage. "
        if paid.isEmpty {
            text += "Every role runs on \(Place.this), so nothing leaves it."
        } else {
            let list = paid.map { "\($0.role.name) (\($0.provider))" }.joined(separator: ", ")
            text += "These roles run on a paid service: \(list). Whatever they are given is sent to that service, including results from roles on \(Place.this), the files they read in your project, and the output of commands they run. "
            if !local.isEmpty { text += "\(local.map(\.name).joined(separator: ", ")) run on \(Place.this)" + " and their results reach the paid roles when a later stage needs them. " }
            text += "Your memory is not used by any role of this organization."
        }
        text += " Engineering work happens on its own branch for each ticket, in a separate working folder; your own branch and folder are never changed, and nothing is merged unless you do it."
        var limits: [String] = []
        if let t = org.budget.paidTokensPerDay { limits.append("\(EText.grouped(t)) tokens a day on paid services") }
        if let m = org.budget.moneyPerDay { limits.append("\(orgMoney(m)) a day") }
        text += limits.isEmpty ? " No daily ceiling on paid work is set." : " Daily ceilings: \(limits.joined(separator: " and ")); reaching one pauses the organization."
        if !project.cloudAllowed, !paid.isEmpty { problems.append("\(project.name) is local only, so paid roles cannot be used in it. Allow cloud models for the project first.") }
        let basis = JSONValue.array([.string(org.projectId), .array(org.roles.map { .array([.string($0.id), .string($0.kind), .string($0.modelKey ?? ""), .string($0.agent ?? ""),
                                                                                   .string($0.access.rawValue), .string($0.work ?? "")]) }),
                                     .array(services.map { .string($0) }), .bool(project.cloudAllowed)])
        let digest = SHA256.hash(data: Data(basis.text().utf8)).map { String(format: "%02x", $0) }.joined()
        return OrgAgreement(projectId: org.projectId, text: text, services: services, leavesThisMac: !paid.isEmpty, memoryUsed: paid.isEmpty, problems: problems, digest: digest)
    }

    /// Turns continuous pickup on, after the agreement. Refused unless `digest` is the current agreement's, and while any problem remains.
    @discardableResult
    public func orgStart(projectId: String, digest: String, from origin: SubmitOrigin = .mac) throws -> OrgState {
        if origin == .phone { throw BlackTeamError("The organization is started from the computer, because it may use paid agents.") }
        let project = try roomProject(projectId)
        let org = try orgRequire(projectId)
        let agreement = orgAgreementBuild(org, project: project)
        guard agreement.digest == digest else { throw BlackTeamError("The roles have changed since you read the agreement. Read it again before starting.") }
        if let first = agreement.problems.first { throw BlackTeamError(first) }
        try orgMutate(projectId) { o in
            o.running = true; o.paused = false; o.pausedReason = ""; o.confirmed = agreement.services; o.agreement = agreement.digest
        }
        orgStartLoop()
        return try orgState(projectId: projectId)
    }

    /// Stops picking up tickets, and stops the stage that is running (its ticket goes back to waiting).
    @discardableResult
    public func orgPause(projectId: String, reason: String = "Paused by you.") throws -> OrgState {
        try orgMutate(projectId) { $0.paused = true; $0.pausedReason = reason }
        if let c = orgRuntime.current, c.project == projectId { orgRuntime.stopRequested = true; cancel() }
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func orgResume(projectId: String) throws -> OrgState {
        let org = try orgRequire(projectId)
        if !org.running { throw BlackTeamError("Start the organization first: read what it sends and confirm.") }
        let usage = OrgStore.usage(dataFolder, projectId)
        if let why = orgCeiling(org, usage: usage, day: orgDay()) { throw BlackTeamError(why + " Raise the ceiling or wait until tomorrow.") }
        try orgMutate(projectId) { $0.paused = false; $0.pausedReason = "" }
        orgStartLoop()
        return try orgState(projectId: projectId)
    }

    // MARK: Tickets

    @discardableResult
    public func ticketAdd(projectId: String, title: String, body: String = "", source: String = "person", ui: Bool? = nil) throws -> OrgState {
        let org = try orgRequire(projectId)
        let title = EText.trim(title)
        guard EText.length(title) <= OrgLimits.title, let cleanTitle = OrgStore.clean(title, max: OrgLimits.title) else { throw BlackTeamError("Give the ticket a title of up to \(OrgLimits.title) characters.") }
        guard EText.length(body) <= OrgLimits.body, let cleanBody = OrgStore.clean(body, max: OrgLimits.body, multiline: true, allowEmpty: true) else { throw BlackTeamError("A ticket's details are up to \(EText.grouped(OrgLimits.body)) characters.") }
        guard ["person", "phone", "schedule", "lead", "command"].contains(source) else { throw BlackTeamError("Invalid ticket source.") }
        try orgCreateTicket(org, title: cleanTitle, body: cleanBody, source: source, ui: ui, parent: nil)
        return try orgState(projectId: projectId)
    }

    @discardableResult
    func orgCreateTicket(_ org: Organization, title: String, body: String, source: String, ui: Bool?, parent: String?) throws -> OrgTicket {
        orgLock.lock(); defer { orgLock.unlock() }
        var all = OrgStore.tickets(dataFolder, org.projectId)
        if all.count >= OrgLimits.tickets {
            // Finished tickets make room: the oldest goes first.
            if let at = all.firstIndex(where: { $0.finished }) { all.remove(at: at) } else { throw BlackTeamError("An organization holds up to \(OrgLimits.tickets) tickets. Finish or cancel some first.") }
        }
        guard var current = OrgStore.load(dataFolder, org.projectId) else { throw BlackTeamError("This project has no organization yet. Make one first.") }
        let stamp = roomNow()
        var t = OrgTicket(id: UUID().uuidString.lowercased(), projectId: org.projectId, number: current.nextNumber, title: title, body: body, source: source, created: stamp, updated: stamp,
                          stage: .intake, state: "ready", gate: nil, note: "", ui: ui, size: nil, branch: nil, base: nil, baseBranch: nil, work: nil, prefix: nil,
                          artifacts: [], history: [], sendBacks: [:], findings: "", tasks: [], answers: [], parent: parent, children: [], currentRole: nil)
        current.nextNumber += 1
        orgEvent(&t, stage: .intake, "Ticket added (\(source)).")
        // A ticket that comes from the phone may use paid roles; a phone cannot start those, so it waits for a yes from the computer.
        if source == "phone", !org.confirmed.isEmpty {
            t.state = "gate"
            let item = orgInboxGate(org, ticket: t, stage: .intake, kind: "approval", question: "A ticket from your phone: \(title). It may use paid agents (\(org.confirmed.joined(separator: ", "))), which a phone cannot start. Start it?",
                                    artifact: nil, desktopOnly: true)
            t.gate = OrgGate(stage: OrgStage.intake.rawValue, kind: "approval", question: item.question, artifact: nil, inboxId: item.id, created: stamp)
        }
        all.append(t)
        try OrgStore.save(current, dataFolder)
        try OrgStore.saveTickets(all, dataFolder, org.projectId)
        changed()
        return t
    }

    /// Finds a ticket by its number ("3", "T-3") or id.
    public func orgFindTicket(projectId: String, _ given: String) throws -> OrgTicket {
        let all = orgTickets(projectId)
        let text = EText.trim(given)
        let digits = text.lowercased().hasPrefix("t-") ? String(text.dropFirst(2)) : text
        if let n = Int(digits), let t = all.first(where: { $0.number == n }) { return t }
        if let t = all.first(where: { $0.id == text }) ?? all.first(where: { text.count >= 6 && $0.id.hasPrefix(text.lowercased()) }) { return t }
        throw BlackTeamError("There is no ticket \"\(given)\".")
    }

    /// A ticket with the text of its artifacts, for the screens.
    public func ticketDetail(projectId: String, ticketId: String) throws -> (ticket: OrgTicket, artifacts: [String: String]) {
        _ = try roomProject(projectId)
        guard let t = orgTicket(projectId, ticketId) else { throw BlackTeamError("That ticket is not in this organization.") }
        var texts: [String: String] = [:]
        for a in t.artifacts { texts[a.name] = OrgStore.readArtifact(dataFolder, projectId, t.id, name: a.name) ?? "" }
        return (t, texts)
    }
}
