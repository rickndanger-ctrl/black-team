import Foundation
import BlackTeamKit

// `black-team org ...` and `black-team ticket ...`: an organization of agents working on a project, and its tickets.
// With the background service running these go to it (it is the one that picks tickets up); otherwise they use an engine of their own,
// the same way `room` does. Nothing here decides anything the window does not: the same routes (Org/OrgRoutes.swift) answer both.

enum OrgTransport {
    case remote(ServiceClient)
    case local(Backend)

    func call(_ method: String, _ path: String, query: [String: String] = [:], input: [String: JSONValue] = [:]) async throws -> JSONValue {
        switch self {
        case .remote(let client):
            if method == "GET" {
                let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
                return try await client.get(path + (q.isEmpty ? "" : "?" + q))
            }
            return try await client.post(path, .object(input))
        case .local(let backend): return try await backend.orgCall(method, path, query: query, input: input)
        }
    }

    func projects() async throws -> [(id: String, name: String)] {
        switch self {
        case .remote(let client):
            return try await client.get("/api/schedules")["projects"]?.array?.compactMap { p in p["id"]?.string.flatMap { id in p["name"]?.string.map { (id, $0) } } } ?? []
        case .local(let backend): return backend.projectList().map { ($0.id, $0.name) }
        }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.text().utf8))
}

private func orgSay(_ text: String = "") { print(text) }

@MainActor private func projectId(_ transport: OrgTransport) async throws -> String {
    guard !arguments.isEmpty else { fail("Name the project.\n\n\(usage)", code: 2) }
    let given = arguments.removeFirst()
    let all = try await transport.projects()
    if let hit = all.first(where: { $0.id == given }) ?? all.first(where: { $0.name.lowercased() == given.lowercased() }) { return hit.id }
    let prefixed = all.filter { $0.id.hasPrefix(given.lowercased()) && given.count >= 4 }
    if prefixed.count == 1 { return prefixed[0].id }
    fail("No project \"\(given)\". Projects: \(all.map(\.name).joined(separator: ", "))")
}

private func money(_ value: Double) -> String { String(format: "%.2f", value) }

private func roleLine(_ n: Int, _ v: OrgRoleView) -> String {
    let where_ = v.kind == "none" ? "not set up" : v.kind == "cloud" ? "paid, \(v.provider)" : "on this computer"
    var line = "  \(n). \(v.role.name) [\(v.role.kind)] - \(where_) - \(v.role.access.title) - \(v.status)\(v.ticket.map { " (\($0))" } ?? "")"
    if !v.usable, !v.reason.isEmpty { line += "\n       \(v.reason)" }
    return line
}

private func printOrg(_ s: OrgState) {
    guard let org = s.organization else {
        orgSay("\(s.projectName) has no organization. Make one: black-team org create \(s.projectName) --template software|studio|small --local <model key>")
        return
    }
    let status = !org.running ? "not started" : org.paused ? "paused: \(org.pausedReason)" : "running"
    orgSay("\(org.name) - \(status)")
    orgSay("Roles:")
    for (i, v) in s.roles.enumerated() { orgSay(roleLine(i + 1, v)) }
    orgSay("Owner approves after: \(org.gates.isEmpty ? "nothing" : org.gates.joined(separator: ", "))")
    var ceilings: [String] = []
    if let t = org.budget.paidTokensPerDay { ceilings.append("\(t) paid tokens a day") }
    if let m = org.budget.moneyPerDay { ceilings.append("\(money(m)) a day") }
    orgSay("Ceilings: " + (ceilings.isEmpty ? "none" : ceilings.joined(separator: ", ")) + ". Stand-up: \(org.standupAt.isEmpty ? "off" : org.standupAt).")
    let open = s.tickets.filter { !$0.finished }
    orgSay("Tickets: \(open.count) open, \(s.tickets.count - open.count) finished. black-team ticket list \(s.projectName)")
    orgSay(s.ledger.summary)
}

@MainActor private func pickRole(_ s: OrgState, _ given: String) -> OrgRole {
    let roles = s.organization?.roles ?? []
    if let n = Int(given), n >= 1, n <= roles.count { return roles[n - 1] }
    let hits = roles.filter { $0.id == given || $0.name.lowercased() == given.lowercased() || (given.count >= 4 && $0.id.hasPrefix(given.lowercased())) }
    if hits.count == 1 { return hits[0] }
    fail("No role \"\(given)\" (use its number from `org show`, or its name).")
}

@MainActor func runOrgCommand(_ command: String, _ transport: OrgTransport) async -> Int32 {
    do {
        return command == "org" ? try await runOrg(transport) : try await runTicket(transport)
    } catch {
        FileHandle.standardError.write(Data((describe(error) + "\n").utf8))
        return 1
    }
}

@MainActor private func state(_ t: OrgTransport, _ pid: String) async throws -> OrgState {
    try decode(OrgState.self, try await t.call("GET", "/api/org", query: ["project": pid]))
}

@MainActor private func runOrg(_ t: OrgTransport) async throws -> Int32 {
    guard !arguments.isEmpty else { fail(commandHelp["org"] ?? usage, code: 2) }
    let action = arguments.removeFirst()
    switch action {
    case "create":
        let template = option("--template") ?? "software", name = option("--name"), local = option("--local")
        let leadModel = option("--lead-model"), leadAgent = option("--lead-agent")
        let pid = try await projectId(t)
        var input: [String: JSONValue] = ["project": .string(pid), "template": .string(template)]
        if let name { input["name"] = .string(name) }
        if let local { input["local"] = .string(local) }
        if let leadModel { input["leadModel"] = .string(leadModel) }
        if let leadAgent { input["leadAgent"] = .string(leadAgent == "claude" ? "claude-code" : leadAgent) }
        let made = try decode(OrgState.self, try await t.call("POST", "/api/org/create", input: input))
        if asJSON { printJSON(made) } else { printOrg(made); if local == nil { orgSay("\nEvery role needs a model or an agent: black-team org role <project> set <role> --model <key>") } }
    case "show":
        let s = try await state(t, try await projectId(t))
        if asJSON { printJSON(s) } else { printOrg(s) }
    case "role":
        let pid = try await projectId(t)
        let sub = arguments.isEmpty ? "list" : arguments.removeFirst()
        let s = try await state(t, pid)
        switch sub {
        case "list":
            if asJSON { printJSON(s.roles) } else { for (i, v) in s.roles.enumerated() { orgSay(roleLine(i + 1, v)); orgSay("       " + v.role.charter) } }
        case "add":
            guard !arguments.isEmpty else { fail("org role add takes a kind: lead, product, designer, architect, engineer, reviewer, qa, docs, release or custom.", code: 2) }
            let kind = arguments.removeFirst(), name = option("--name")
            var input: [String: JSONValue] = ["project": .string(pid), "kind": .string(kind)]
            if let name { input["name"] = .string(name) }
            printOrg(try decode(OrgState.self, try await t.call("POST", "/api/org/role/add", input: input)))
        case "remove":
            guard arguments.count == 1 else { fail("org role remove takes a role.", code: 2) }
            let role = pickRole(s, arguments[0])
            printOrg(try decode(OrgState.self, try await t.call("POST", "/api/org/role/remove", input: ["project": .string(pid), "roleId": .string(role.id)])))
        case "set":
            guard !arguments.isEmpty else { fail("org role set takes a role and what to change.", code: 2) }
            let given = arguments.removeFirst()
            var role = pickRole(s, given)
            if let model = option("--model") { role.modelKey = model; role.agent = nil; role.work = role.work ?? "code" }
            if let agent = option("--agent") { role.agent = agent == "claude" ? "claude-code" : agent; role.modelKey = nil; role.work = nil }
            if let work = option("--work") { role.work = work }
            if let access = option("--access") { guard let a = OrgAccess(rawValue: access) else { fail("Access is read, ask, edit or auto.", code: 2) }; role.access = a }
            if let name = option("--name") { role.name = name }
            if let charter = option("--charter") { role.charter = charter }
            if let skill = option("--skill") { role.skills.append(skill) }
            if let priceIn = option("--price-in"), let out = option("--price-out"), let a = Double(priceIn), let b = Double(out) { role.price = OrgPrice(inPerMillion: a, outPerMillion: b) }
            let tokens = option("--tokens-per-day"), cost = option("--money-per-day")
            if tokens != nil || cost != nil { role.budget = OrgBudget(paidTokensPerDay: tokens.flatMap { Int($0) }, moneyPerDay: cost.flatMap { Double($0) }) }
            let saved = try decode(OrgState.self, try await t.call("POST", "/api/org/role/save", input: ["project": .string(pid), "role": try JSONValue.parse(JSONEncoder().encode(role))]))
            printOrg(saved)
        default: fail("org role takes list, add, remove or set.\n\n\(commandHelp["org"] ?? "")", code: 2)
        }
    case "set":
        let name = option("--name"), gates = option("--gates"), tokens = option("--tokens-per-day"), cost = option("--money-per-day"), standup = option("--standup")
        let pid = try await projectId(t)
        var input: [String: JSONValue] = ["project": .string(pid)]
        if let name { input["name"] = .string(name) }
        if let gates { input["gates"] = .array(gates.split(separator: ",").map { .string(String($0).trimmingCharacters(in: .whitespaces)) }) }
        if let standup { input["standupAt"] = .string(standup == "off" ? "" : standup) }
        if tokens != nil || cost != nil {
            var b: [String: JSONValue] = [:]
            if let tokens, let n = Int(tokens) { b["paidTokensPerDay"] = .number(Double(n)) }
            if let cost, let m = Double(cost) { b["moneyPerDay"] = .number(m) }
            input["budget"] = .object(b)
        }
        printOrg(try decode(OrgState.self, try await t.call("POST", "/api/org/update", input: input)))
    case "start":
        let confirmed = arguments.contains("--yes")
        arguments.removeAll { $0 == "--yes" }
        let pid = try await projectId(t)
        let a = try decode(OrgAgreement.self, try await t.call("GET", "/api/org/agreement", query: ["project": pid]))
        if asJSON { printJSON(a) } else {
            orgSay(a.text)
            for p in a.problems { orgSay("  Cannot start yet: \(p)") }
        }
        guard confirmed, a.problems.isEmpty else {
            if !asJSON, a.problems.isEmpty { orgSay("\nNothing was started. Add --yes to start the organization.") }
            return a.problems.isEmpty ? 0 : 1
        }
        printOrg(try decode(OrgState.self, try await t.call("POST", "/api/org/start", input: ["project": .string(pid), "digest": .string(a.digest)])))
        if case .local(let backend) = t {
            // Without the background service this command is the organization's engine, so it stays to do the work, and ends when every
            // open ticket waits for you, is blocked, or is finished. Ctrl-C stops it; the next `org start` carries on.
            orgSay("\nWorking while this command runs (Ctrl-C stops it). For work that carries on with nothing open: black-team service install")
            backend.orgHousekeeping(pid)
            var last = ""
            while true {
                let now = try await state(t, pid)
                let open = now.tickets.filter { !["done", "cancelled"].contains($0.state) }
                let line = open.map { "T-\($0.number) \($0.stage.title): \($0.state)" }.joined(separator: " · ")
                if line != last { orgSay(line.isEmpty ? "No open tickets." : line); last = line }
                if now.organization?.paused == true || !open.contains(where: { ["ready", "running"].contains($0.state) }) { break }
                if !open.contains(where: { $0.state == "running" }) { _ = try? await backend.orgStep(projectId: pid) }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            printOrg(try await state(t, pid))
        }
    case "link":
        let board = option("--board"), repo = option("--repo")
        let backlog = arguments.contains("--backlog")
        arguments.removeAll { $0 == "--backlog" }
        let pid = try await projectId(t)
        guard let board else { fail("org link takes --board <folder>: the Board folder of your Obsidian vault (it holds Tickets/).", code: 2) }
        var input: [String: JSONValue] = ["project": .string(pid), "folder": .string(board), "takeBacklog": .bool(backlog)]
        if let repo { input["repo"] = .string(repo) }
        let linked = try decode(OrgState.self, try await t.call("POST", "/api/org/board/link", input: input))
        if asJSON { printJSON(linked) } else if let b = linked.board {
            orgSay("Linked \(linked.projectName) to the board \(b.folder)\nWork happens in \(b.repo), each ticket on its own branch (org/T-<n>-...). Nothing is merged or pushed.")
            orgSay("Black Team writes into that folder (ticket notes and an Artifacts folder). Nothing leaves this computer.")
            orgSay("To put your local models to work: black-team org work \(linked.projectName) on")
        }
    case "unlink":
        let pid = try await projectId(t)
        _ = try await t.call("POST", "/api/org/board/unlink", input: ["project": .string(pid)])
        orgSay("The board was unlinked. Tickets Black Team gave back stay on the board.")
    case "work":
        let confirmed = arguments.contains("--yes")
        arguments.removeAll { $0 == "--yes" }
        let pid = try await projectId(t)
        guard arguments.count == 1, ["on", "off"].contains(arguments[0]) else { fail("org work takes a project and on or off.", code: 2) }
        let on = arguments[0] == "on"
        let s = try decode(OrgState.self, try await t.call("POST", "/api/org/board/work", input: ["project": .string(pid), "on": .bool(on), "confirmPaid": .bool(confirmed)]))
        if asJSON { printJSON(s) } else { orgSay(s.board?.statusText ?? "") }
        if on, case .local(let backend) = t {
            // Without the background service this command is the engine, so it stays to do the work. Ctrl-C stops it and gives the tickets back.
            orgSay("\nWorking while this command runs (Ctrl-C stops it). For work that carries on with nothing open: black-team service install")
            var last = ""
            while true {
                await backend.orgTickAll()
                let now = try await state(t, pid)
                let line = now.board?.statusText ?? ""
                if line != last { orgSay(line); last = line }
                if now.organization?.paused == true || now.board?.working != true { break }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    case "board":
        let pid = try await projectId(t)
        let status = try decode(OrgBoardStatus.self, try await t.call("GET", "/api/org/board", query: ["project": pid]))
        if asJSON { printJSON(status); return 0 }
        let info = status.info
        orgSay("Board: \(info.folder)\nRepository: \(info.repo)\nWorking: \(info.working ? "yes" : "no") (\(info.statusText))\nBlack Team writes as: \(info.owner)")
        if !info.reachable { orgSay("Problem: \(info.problem)") }
        for row in status.rows {
            let who = row.holder == "free" ? "free" : "\(row.owner) until \(row.leaseUntil)" + (row.holder == "mine" ? " (Black Team)" : "")
            orgSay("  \(row.id.padding(toLength: 6, withPad: " ", startingAt: 0)) \(row.status.padding(toLength: 11, withPad: " ", startingAt: 0)) \(row.stage.padding(toLength: 7, withPad: " ", startingAt: 0)) \(row.priority.padding(toLength: 3, withPad: " ", startingAt: 0)) \(row.title)  [\(who)]")
        }
        if status.rows.isEmpty { orgSay("  No tickets on the board.") }
        if !status.ignored.isEmpty { orgSay("Ignored (no usable front matter):"); for item in status.ignored { orgSay("  \(item)") } }
    case "pause", "resume":
        let pid = try await projectId(t)
        printOrg(try decode(OrgState.self, try await t.call("POST", "/api/org/\(action)", input: ["project": .string(pid)])))
    case "step":
        let pid = try await projectId(t)
        guard case .local(let backend) = t else { fail("The background service picks tickets up by itself. Add a ticket, or resume the organization.", code: 2) }
        let ran = try await backend.orgStep(projectId: pid, force: true)
        orgSay(ran ? "Ran one stage." : "Nothing to run: no ticket is waiting, or the computer is busy, or the organization is paused.")
        printOrg(try await state(t, pid))
    case "standup":
        let pid = try await projectId(t)
        orgSay(try await t.call("POST", "/api/org/standup", input: ["project": .string(pid)])["text"]?.string ?? "")
    case "routine":
        let pid = try await projectId(t)
        let sub = arguments.isEmpty ? "" : arguments.removeFirst()
        if sub == "add" {
            let when = option("--when"), detail = option("--detail")
            guard arguments.count == 1, let when else { fail("org routine add takes a title and --when \"weekdays at 9:00\".", code: 2) }
            _ = try await t.call("POST", "/api/org/routine/add", input: ["project": .string(pid), "title": .string(arguments[0]), "body": .string(detail ?? ""), "when": .string(when)])
            printOrg(try await state(t, pid))
        } else if sub == "remove" {
            guard arguments.count == 1 else { fail("org routine remove takes a number.", code: 2) }
            let s = try await state(t, pid)
            guard let n = Int(arguments[0]), let routines = s.organization?.routines, n >= 1, n <= routines.count else { fail("No such routine.") }
            _ = try await t.call("POST", "/api/org/routine/remove", input: ["project": .string(pid), "routineId": .string(routines[n - 1].id)])
        } else {
            let s = try await state(t, pid)
            let routines = s.organization?.routines ?? []
            if routines.isEmpty { orgSay("No routines. Add one: org routine <project> add \"<title>\" --when \"weekdays at 9:00\"") }
            for (i, r) in routines.enumerated() { orgSay("  \(i + 1). \(r.title) - \(r.whenText)") }
        }
    case "remove":
        let pid = try await projectId(t)
        _ = try await t.call("POST", "/api/org/remove", input: ["project": .string(pid)])
        orgSay("The organization was removed. Branches it made are still in your repository.")
    default:
        fail("org takes create, show, role, set, start, link, unlink, work, board, pause, resume, step, standup, routine or remove.\n\n\(commandHelp["org"] ?? "")", code: 2)
    }
    return 0
}

@MainActor private func pickTicket(_ s: OrgState, _ given: String) -> OrgTicket {
    let text = given.lowercased().hasPrefix("t-") ? String(given.dropFirst(2)) : given
    if let n = Int(text), let t = s.tickets.first(where: { $0.number == n }) { return t }
    let hits = s.tickets.filter { $0.id == given || (given.count >= 4 && $0.id.hasPrefix(given.lowercased())) }
    if hits.count == 1 { return hits[0] }
    fail("No ticket \"\(given)\" (use its number from `ticket list`, such as 3 or T-3).")
}

private func ticketLine(_ t: OrgTicket) -> String {
    var line = "  \(t.label)  \(t.stage.title.padding(toLength: 7, withPad: " ", startingAt: 0)) \(t.state.padding(toLength: 9, withPad: " ", startingAt: 0)) \(t.title)"
    if let g = t.gate { line += "\n         waiting for you: \(g.question)" }
    else if t.state == "blocked" { line += "\n         stuck: \(t.note)" }
    return line
}

@MainActor private func runTicket(_ t: OrgTransport) async throws -> Int32 {
    guard !arguments.isEmpty else { fail(commandHelp["ticket"] ?? usage, code: 2) }
    let action = arguments.removeFirst()
    switch action {
    case "add":
        let detail = option("--detail"), ui = option("--ui")
        let pid = try await projectId(t)
        guard arguments.count == 1 else { fail("ticket add takes a project and a title in quotes.\n\n\(commandHelp["ticket"] ?? "")", code: 2) }
        var input: [String: JSONValue] = ["project": .string(pid), "title": .string(arguments[0]), "body": .string(detail ?? ""), "source": "command"]
        if let ui { input["ui"] = .bool(ui == "yes") }
        let s = try decode(OrgState.self, try await t.call("POST", "/api/org/ticket/add", input: input))
        if asJSON { printJSON(s.tickets.last) } else if let last = s.tickets.max(by: { $0.number < $1.number }) { orgSay("Added \(last.label): \(last.title)") }
    case "list":
        let s = try await state(t, try await projectId(t))
        if asJSON { printJSON(s.tickets); return 0 }
        if s.tickets.isEmpty { orgSay("No tickets. Add one: black-team ticket add \(s.projectName) \"<title>\"") }
        for ticket in s.tickets.sorted(by: { $0.number < $1.number }) { orgSay(ticketLine(ticket)) }
    case "show":
        let artifact = option("--artifact")
        let pid = try await projectId(t)
        guard arguments.count == 1 else { fail("ticket show takes a project and a ticket.", code: 2) }
        let ticket = pickTicket(try await state(t, pid), arguments[0])
        let detail = try await t.call("GET", "/api/org/ticket", query: ["project": pid, "id": ticket.id])
        let full = try decode(OrgTicket.self, detail["ticket"] ?? .null)
        let texts = detail["artifacts"]?.object ?? [:]
        if let artifact {
            guard let text = texts[artifact]?.string else { fail("This ticket has no artifact \"\(artifact)\". It has: \(full.artifacts.map(\.name).joined(separator: ", ")).") }
            orgSay(text); return 0
        }
        if asJSON { printJSON(full); return 0 }
        orgSay("\(full.label)  \(full.title)\nStage: \(full.stage.title)   State: \(full.state)")
        if !full.body.isEmpty { orgSay("\n\(full.body)") }
        if let g = full.gate { orgSay("\nWaiting for you (\(g.kind)): \(g.question)\n  black-team ticket approve \(pid.prefix(8)) \(full.number)    or    send-back --note \"...\"") }
        if full.state == "blocked" { orgSay("\nStuck: \(full.note)\n  black-team ticket retry ...") }
        if let b = full.branch { orgSay("\nBranch: \(b) (from \(full.baseBranch ?? "your branch"), \(String((full.base ?? "").prefix(8)))). Merging it is your decision: git merge \(b)") }
        orgSay("\nArtifacts (black-team ticket show <project> \(full.number) --artifact <name>):")
        for a in full.artifacts { orgSay("  \(a.name)  \(a.title)  \(a.role.isEmpty ? "" : "by \(a.role)")") }
        if !full.sendBacks.isEmpty { orgSay("\nSent back: " + full.sendBacks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)x" }.joined(separator: ", ")) }
        orgSay("\nHistory:")
        for e in full.history { orgSay("  \(e.at.prefix(16)) \(e.text)") }
    case "approve", "send-back", "sendback", "answer", "retry", "cancel":
        let note = option("--note"), to = option("--to")
        let pid = try await projectId(t)
        guard !arguments.isEmpty else { fail("Name the ticket.", code: 2) }
        let ticket = pickTicket(try await state(t, pid), arguments.removeFirst())
        var input: [String: JSONValue] = ["project": .string(pid), "id": .string(ticket.id)]
        switch action {
        case "approve": if let note { input["note"] = .string(note) }
        case "answer":
            guard arguments.count == 1 else { fail("ticket answer takes a project, a ticket and your answer in quotes.", code: 2) }
            input["answer"] = .string(arguments[0])
        case "send-back", "sendback":
            guard let note else { fail("ticket send-back needs --note saying what to change.", code: 2) }
            input["note"] = .string(note)
            if let to { input["to"] = .string(to) }
        default: break
        }
        let path = action == "sendback" ? "send-back" : action
        let s = try decode(OrgState.self, try await t.call("POST", "/api/org/ticket/\(path == "send-back" ? "sendback" : path)", input: input))
        if let updated = s.tickets.first(where: { $0.id == ticket.id }) { orgSay(ticketLine(updated)) }
    default:
        fail("ticket takes add, list, show, approve, send-back, answer, retry or cancel.\n\n\(commandHelp["ticket"] ?? "")", code: 2)
    }
    return 0
}
