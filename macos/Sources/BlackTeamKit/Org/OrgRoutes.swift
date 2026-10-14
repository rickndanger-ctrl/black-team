import Foundation

// The organization's HTTP routes, behind the same loopback, Host, Origin and session checks as every other route (Desktop/DesktopRoutes.swift).
//
//   GET  /api/org?project=            the organization, its roles, tickets and ledger (desktop)
//   GET  /api/org/tickets?project=    the tickets list: titles, stages, what waits for the owner (desktop and phone, read only)
//   GET  /api/org/ticket?project=&id= one ticket with the text of its artifacts (desktop)
//   GET  /api/org/agreement?project=  what starting it would send, and where (desktop)
//   POST /api/org/create | remove | update | start | pause | resume | step | standup
//   GET  /api/org/board?project=      what the linked Obsidian board holds and who owns what (desktop)
//   POST /api/org/board/link | unlink | options | work   (desktop; Org/OrgBoard.swift)
//   POST /api/org/role/save | add | remove | roster
//   POST /api/org/routine/add | remove
//   POST /api/org/ticket/add          (a phone may add a ticket; one that may use paid roles waits for a yes from the computer)
//   POST /api/org/ticket/approve      (a phone may approve, except a gate that can only be answered on the computer)
//   POST /api/org/ticket/sendback | answer | retry | cancel   (desktop)

final class OrgRoutes: @unchecked Sendable {
    let backend: Backend
    init(_ backend: Backend) { self.backend = backend }

    static func owns(_ path: String) -> Bool { path == "/api/org" || path.hasPrefix("/api/org/") }

    private func json(_ head: HTTPHead, _ body: Data) throws -> [String: JSONValue] {
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { throw HTTPFailure("Send JSON.", 415) }
        guard let value = try? JSONValue.parse(body), let object = value.object else { throw HTTPFailure("Invalid JSON request.") }
        return object
    }

    private func state(_ project: String) throws -> HTTPResponse { .json(200, .encoded(try backend.orgState(projectId: project))) }

    /// What the phone sees of a ticket: enough to follow it and to answer a gate.
    static func summary(_ t: OrgTicket) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(t.id), "number": .number(Double(t.number)), "label": .string(t.label), "title": .string(t.title), "stage": .string(t.stage.rawValue),
                                      "stageTitle": .string(t.stage.title), "state": .string(t.state), "note": .string(t.note), "updated": .string(t.updated)]
        if let g = t.gate { o["gate"] = ["kind": .string(g.kind), "question": .string(g.question), "desktopOnly": .bool(g.kind == "privacy" || (g.stage == "intake" && t.artifacts.isEmpty))] }
        return .object(o)
    }

    func handle(_ head: HTTPHead, body: Data, who: DesktopAccess) async throws -> HTTPResponse {
        var query: [String: String] = [:]
        for key in ["project", "id"] { if let v = head.queryValue(key) { query[key] = v } }
        var input: [String: JSONValue] = [:]
        if head.method == "POST" { input = try json(head, body) }
        return .json(200, try await dispatch(head.method, head.path, query: query, input: input, who: who))
    }

    /// The routes without the HTTP: the command line uses this directly when no service is running.
    func dispatch(_ method: String, _ path: String, query: [String: String], input: [String: JSONValue], who: DesktopAccess) async throws -> JSONValue {
        let project = query["project"] ?? ""
        func state(_ project: String) throws -> JSONValue { .encoded(try backend.orgState(projectId: project)) }
        if method == "GET" {
            if path == "/api/org/tickets" {
                let tickets = try backend.orgState(projectId: project).tickets
                return ["tickets": .array(tickets.sorted { $0.number > $1.number }.map(Self.summary))]
            }
            try who.requireDesktopHTTP()
            switch path {
            case "/api/org": return try state(project)
            case "/api/org/agreement": return .encoded(try backend.orgAgreement(projectId: project))
            case "/api/org/board": return .encoded(try backend.orgBoardStatus(projectId: project))
            case "/api/org/ticket":
                let detail = try backend.ticketDetail(projectId: project, ticketId: query["id"] ?? "")
                return ["ticket": .encoded(detail.ticket), "artifacts": .object(detail.artifacts.mapValues { .string($0) })]
            default: throw HTTPFailure("Not found.", 404)
            }
        }
        guard method == "POST" else { throw HTTPFailure("Not found.", 404) }
        let pid = input["project"]?.string ?? ""
        func text(_ key: String) -> String { input[key]?.string ?? "" }
        func optional(_ key: String) -> String? { input[key]?.string }
        // The two things a phone may do.
        if path == "/api/org/ticket/add" {
            let source = who == .phone ? "phone" : (input["source"]?.string == "command" ? "command" : "person")
            return .encoded(try backend.ticketAdd(projectId: pid, title: text("title"), body: text("body"), source: source, ui: input["ui"]?.bool))
        }
        if path == "/api/org/ticket/approve" {
            if who == .phone, let t = try? backend.orgFindTicket(projectId: pid, text("id")),
               let g = t.gate, g.kind == "privacy" || (g.stage == "intake" && t.artifacts.isEmpty) {
                throw HTTPFailure("Answer this one on the computer: it may use paid agents, which a phone cannot start.", 403)
            }
            return .encoded(try backend.ticketApprove(projectId: pid, ticketId: try backend.orgFindTicket(projectId: pid, text("id")).id, note: text("note")))
        }
        try who.requireDesktopHTTP()
        func ticket() throws -> String { try backend.orgFindTicket(projectId: pid, text("id")).id }
        switch path {
        case "/api/org/create":
            return .encoded(try backend.orgCreate(projectId: pid, template: text("template"), name: optional("name"), local: optional("local"),
                                                  leadModel: optional("leadModel"), leadAgent: optional("leadAgent")))
        case "/api/org/remove": return .encoded(try backend.orgRemove(projectId: pid))
        case "/api/org/board/link":
            return .encoded(try backend.orgLink(projectId: pid, folder: text("folder"), repo: optional("repo"), takeBacklog: input["takeBacklog"]?.bool ?? false))
        case "/api/org/board/unlink": return .encoded(try backend.orgUnlink(projectId: pid))
        case "/api/org/board/options": return .encoded(try backend.orgBoardOptions(projectId: pid, takeBacklog: input["takeBacklog"]?.bool ?? false))
        case "/api/org/board/work": return .encoded(try backend.orgWork(projectId: pid, on: input["on"]?.bool ?? false, confirmPaid: input["confirmPaid"]?.bool ?? false))
        case "/api/org/update":
            var budget: OrgBudget?
            if let b = input["budget"], b.object != nil {
                budget = OrgBudget(paidTokensPerDay: b["paidTokensPerDay"]?.int, moneyPerDay: b["moneyPerDay"]?.double)
            }
            let gates = input["gates"]?.array?.compactMap { $0.string }
            return .encoded(try backend.orgUpdate(projectId: pid, name: optional("name"), gates: gates, budget: budget, standupAt: optional("standupAt")))
        case "/api/org/start": return .encoded(try backend.orgStart(projectId: pid, digest: text("digest"), from: .mac))
        case "/api/org/pause": return .encoded(try backend.orgPause(projectId: pid))
        case "/api/org/resume": return .encoded(try backend.orgResume(projectId: pid))
        case "/api/org/step":
            // A stage can take a long time on a local model: it runs in the background and the screen follows the ticket.
            let b = backend
            Task { _ = try? await b.orgStep(projectId: pid, force: true) }
            return try state(pid)
        case "/api/org/standup": return ["text": .string(try backend.orgStandupMake(projectId: pid))]
        case "/api/org/role/save":
            guard let role = input["role"], role.object != nil, let decoded = try? JSONDecoder().decode(OrgRole.self, from: Data(role.text().utf8)) else { throw BlackTeamError("That role could not be read.") }
            return .encoded(try backend.orgSaveRole(projectId: pid, role: decoded))
        case "/api/org/role/add": return .encoded(try backend.orgAddRole(projectId: pid, kind: text("kind"), name: optional("name")))
        case "/api/org/role/remove": return .encoded(try backend.orgRemoveRole(projectId: pid, roleId: text("roleId")))
        case "/api/org/role/roster": return ["agents": .encoded(try backend.orgSaveRoleToRoster(projectId: pid, roleId: text("roleId")))]
        case "/api/org/routine/add": return .encoded(try backend.orgAddRoutine(projectId: pid, title: text("title"), body: text("body"), when: text("when")))
        case "/api/org/routine/remove": return .encoded(try backend.orgRemoveRoutine(projectId: pid, routineId: text("routineId")))
        case "/api/org/ticket/sendback": return .encoded(try backend.ticketSendBack(projectId: pid, ticketId: try ticket(), note: text("note"), to: optional("to")))
        case "/api/org/ticket/answer": return .encoded(try backend.ticketAnswer(projectId: pid, ticketId: try ticket(), answer: text("answer")))
        case "/api/org/ticket/retry": return .encoded(try backend.ticketRetry(projectId: pid, ticketId: try ticket()))
        case "/api/org/ticket/cancel": return .encoded(try backend.ticketCancel(projectId: pid, ticketId: try ticket()))
        default: throw HTTPFailure("Not found.", 404)
        }
    }
}

extension Backend {
    /// The organization's routes for a command with its own engine (no background service is running). Same words, same checks.
    public func orgCall(_ method: String, _ path: String, query: [String: String] = [:], input: [String: JSONValue] = [:]) async throws -> JSONValue {
        do { return try await OrgRoutes(self).dispatch(method, path, query: query, input: input, who: .desktop) }
        catch let failure as HTTPFailure { throw BlackTeamError(failure.message) }
    }
}
