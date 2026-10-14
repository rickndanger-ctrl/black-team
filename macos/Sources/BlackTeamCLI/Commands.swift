import Foundation
import BlackTeamKit

// The commands that run once and print: status, chat, code, agent, room, memory, phone and the rest. Each is driven through Backend.
// (Moved out of main.swift unchanged except for the program name in its messages; flags and output are as before.)

// MARK: Turns

/// Runs one subscription-agent task (Claude Code or Codex) and prints its steps and text as they arrive. Returns the exit status.
/// The gate is the Backend's: a refusal prints its message, with the command-line choices, and exits non-zero.
@MainActor func runAgentTask(_ backend: Backend, service: AgentService, message: String, thread: String?, workspace: String?, allowCloud: Bool,
                                     permission: AgentPermission? = nil, approve: String = "deny") async -> Int32 {
    let check = backend.agentPrivacyCheck(service: service, threadId: thread, project: nil)
    if allowCloud, thread != nil, check.outcome == .needsChoice {
        do { try backend.convertToCloud(threadId: thread!, confirmingProvider: check.provider, agent: service) } catch { fail(describe(error)) }
        if !asJSON { print("[cloud] This conversation was sent to \(check.provider) because --allow-cloud was given.") }
    }
    if thread == nil, !asJSON { FileHandle.standardError.write(Data((check.message + "\n").utf8)) }
    let sent: SubmitResult
    do { sent = try backend.submitAgentTask(service: service, message: message, requestId: UUID().uuidString.lowercased(), threadId: thread, workspace: workspace, permission: permission) }
    catch {
        var text = describe(error)
        if backend.agentPrivacyCheck(service: service, threadId: thread, project: nil).outcome == .needsChoice {
            text += "\nOn the command line: add --allow-cloud to send this conversation, omit --thread to start a new one."
        }
        fail(text)
    }
    var printed = ""
    var steps = 0
    func show() {
        guard let view = backend.thread(sent.threadId), let reply = view["messages"]?.array?.last else { return }
        let content = reply["content"]?.string ?? ""
        let events = reply["events"]?.array ?? []
        while steps < events.count {
            let event = events[steps]; steps += 1
            let name = event["name"]?.string ?? "", output = (event["output"]?.string ?? "").replacingOccurrences(of: "\n", with: " ")
            switch event["type"]?.string {
            case "tool_use": if !asJSON { print("[\(name)] \(String(output.prefix(160)))") }
            case "tool_result": if !asJSON { print("  -> \(String(output.prefix(160)))") }
            default: break
            }
        }
        if !asJSON, content.hasPrefix(printed), content.count > printed.count {
            print(String(content.dropFirst(printed.count)), terminator: "")
            printed = content
        }
        fflush(stdout)
    }
    var answered = Set<String>()
    while backend.isBusy {
        // Ask's questions are answered with --approve, as `code` does; the default is to deny.
        if let approval = (try? await backend.status())?.job?.approval, !answered.contains(approval.id) {
            answered.insert(approval.id)
            if !asJSON { print("[approval] \(approval.description): \(approval.command) -> \(approve == "once" ? "allowed once" : "denied")") }
            try? backend.approve(id: approval.id, digest: approval.digest, choice: approve)
        }
        show(); try? await Task.sleep(nanoseconds: 80_000_000)
    }
    await backend.waitForIdle()
    show()
    let finalThread = backend.thread(sent.threadId)
    let reply = finalThread?["messages"]?.array?.last
    let state = reply?["state"]?.string ?? "error"
    let rollbackReady = reply?["rollback"]?.bool == true
    if asJSON {
        var out: [String: JSONValue] = ["threadId": .string(sent.threadId), "runId": .string(sent.id), "state": .string(state),
                                         "reply": .string(reply?["content"]?.string ?? "")]
        if let error = reply?["error"]?.string { out["error"] = .string(error) }
        if let needs = reply?["needsSignIn"]?.string { out["needsSignIn"] = .string(needs) }
        print(JSONValue.object(out).text(pretty: true))
    } else {
        print("\n")
        print("thread: \(sent.threadId)")
        print("run: \(sent.id)")
        print("state: \(state)")
        if rollbackReady { print("rollback: black-team agent rollback \(sent.threadId) \(sent.id)") }
        if let note = reply?["rollbackNote"]?.string { print("rollback: \(note)") }
        print("privacy: leaves \(Place.this), sent to \(service.provider) under your \(service.displayName) subscription")
        if let error = reply?["error"]?.string { FileHandle.standardError.write(Data(("error: " + error + "\n").utf8)) }
        if reply?["needsSignIn"] != nil { print("sign in: black-team agent signin \(service.program)") }
    }
    return state == "done" ? 0 : 1
}

/// Runs one Chat or Code turn and prints it. Returns the exit status.
/// `allowCloud` answers the one question the Backend asks before a private conversation goes to a cloud service.
@MainActor func runTurn(_ backend: Backend, message: String, kind: String, mode: String, thread: String?, workspace: String?, approve: String, images: [ImageUpload] = [],
                        allowCloud: Bool = false, stopOther: Bool = false) async -> Int32 {
    // A model that would not fit beside another model server waits for a yes; --stop-other is that yes given beforehand.
    if let question = try? await backend.startApproval() {
        guard stopOther else { fail(question.question + "\nNothing was stopped or sent. Add --stop-other to stop it and go on.") }
        do { try await backend.approveStop(pid: question.pid) } catch { fail(describe(error)) }
    }
    if allowCloud, let thread {
        let check = backend.privacyCheck(threadId: thread, project: nil, kind: kind)
        if check.outcome == .needsChoice {
            do { try backend.convertToCloud(threadId: thread, confirmingProvider: check.provider) } catch { fail(describe(error)) }
            if !asJSON { print("[cloud] This conversation was sent to \(check.provider) because --allow-cloud was given.") }
        }
    }
    let sent: SubmitResult
    do { sent = try backend.submit(message: message, kind: kind, mode: mode, requestId: UUID().uuidString.lowercased(), threadId: thread, workspace: workspace, images: images) }
    catch {
        var text = describe(error)
        if backend.privacyCheck(threadId: thread, project: nil, kind: kind).outcome == .needsChoice {
            text += "\nOn the command line: add --allow-cloud to send this conversation, omit --thread to start a new one, or run `black-team use <key>` to select a local model."
        }
        fail(text)
    }
    var printed = ""
    var steps = 0
    var lastPhase = ""
    var answered = Set<String>()
    func show() {
        guard let view = backend.thread(sent.threadId), let reply = view["messages"]?.array?.last else { return }
        let content = reply["content"]?.string ?? ""
        if kind == "agent" {
            if let run = reply["run"], let phase = run["phase"]?.string, phase != lastPhase {
                lastPhase = phase
                if !asJSON, RunRecord(json: run).phase.isUnfinished { print("[\(phase)] \(RunRecord(json: run).line())") }
            }
            let events = reply["events"]?.array ?? []
            while steps < events.count {
                let event = events[steps]; steps += 1
                let name = event["name"]?.string ?? "", output = (event["output"]?.string ?? "").replacingOccurrences(of: "\n", with: " ")
                switch event["type"]?.string {
                case "tool_use": if !asJSON { print("[\(name)] \(String(output.prefix(160)))") }
                case "tool_result": if !asJSON { print("  -> \(String(output.prefix(160)))") }
                default: break
                }
            }
        } else if !asJSON, content.hasPrefix(printed), content.count > printed.count {
            print(String(content.dropFirst(printed.count)), terminator: "")
            printed = content
        }
        fflush(stdout)
    }
    while backend.isBusy {
        if let approval = (try? await backend.status())?.job?.approval, !answered.contains(approval.id) {
            answered.insert(approval.id)
            if !asJSON { print("[approval] \(approval.description): \(approval.command) -> \(approve == "once" ? "allowed once" : "denied")") }
            try? backend.approve(id: approval.id, digest: approval.digest, choice: approve)
        }
        show()
        try? await Task.sleep(nanoseconds: 80_000_000)
    }
    await backend.waitForIdle()
    show()
    let finalThread = backend.thread(sent.threadId)
    let reply = finalThread?["messages"]?.array?.last
    let state = reply?["state"]?.string ?? "error"
    let text = reply?["content"]?.string ?? ""
    let meter = reply?["meter"]
    if asJSON {
        var out: [String: JSONValue] = ["threadId": .string(sent.threadId), "state": .string(state), "reply": .string(text)]
        if let meter { out["meter"] = meter }
        if let run = reply?["run"] { out["run"] = run }
        if let error = reply?["error"]?.string { out["error"] = .string(error) }
        print(JSONValue.object(out).text(pretty: true))
    } else {
        if kind == "agent" { print(text) } else if !text.hasPrefix(printed) || printed.isEmpty { print(text) }
        print("\n")
        print("thread: \(sent.threadId)")
        if let meter {
            var parts: [String] = []
            if let read = meter["read"]?.int { parts.append("read \(read) tokens/s") }
            if let write = meter["write"]?.int { parts.append("write \(write) tokens/s") }
            if !parts.isEmpty { print("meter: " + parts.joined(separator: ", ")) }
        }
        print("state: \(state)")
        if let run = runFacts(reply?["run"]) { print("run: \(run)") }
        if let phase = reply?["run"]?["phase"]?.string, phase == "stopped" || phase == "failed" { print("to carry on from the saved state: black-team code \"Continue.\" --thread \(sent.threadId)") }
        if let usage = finalThread?["usage"] {
            print("usage: \(usage["prompt"]?.int ?? 0) tokens in, \(usage["completion"]?.int ?? 0) out" + ((usage["cached"]?.int ?? 0) > 0 ? ", \(usage["cached"]!.int!) cached" : ""))
        }
        if finalThread?["privacy"]?.string == "cloud" { print("privacy: leaves \(Place.this), sent to \(finalThread?["provider"]?.string ?? "a cloud service")") }
        if let error = reply?["error"]?.string { FileHandle.standardError.write(Data(("error: " + error + "\n").utf8)) }
    }
    return state == "done" ? 0 : 1
}

// MARK: Room

@MainActor func roomProject(_ backend: Backend, _ given: String) -> String {
    let all = backend.projectList()
    if let hit = all.first(where: { $0.id == given }) ?? all.first(where: { $0.name.lowercased() == given.lowercased() }) { return hit.id }
    let prefixed = all.filter { $0.id.hasPrefix(given.lowercased()) && given.count >= 4 }
    if prefixed.count == 1 { return prefixed[0].id }
    fail("No project \"\(given)\". Projects: \(all.map(\.name).joined(separator: ", "))")
}

@MainActor func roomTask(_ state: RoomState, _ given: String) -> RoomTask {
    if let n = Int(given), n >= 1, n <= state.tasks.count { return state.tasks[n - 1] }
    let hits = state.tasks.filter { $0.id == given || (given.count >= 4 && $0.id.hasPrefix(given.lowercased())) }
    if hits.count == 1 { return hits[0] }
    fail("No task \"\(given)\" (use its number from `room show`, or its id).")
}

@MainActor func roomMember(_ state: RoomState, _ given: String) -> RoomMemberView {
    let hits = state.members.filter { $0.id == given || $0.name.lowercased() == given.lowercased() || (given.count >= 4 && $0.id.hasPrefix(given.lowercased())) }
    if hits.count == 1 { return hits[0] }
    fail("No member \"\(given)\"" + (hits.count > 1 ? " (more than one matches)." : "."))
}

@MainActor func printRoom(_ state: RoomState) {
    if asJSON { printJSON(state); return }
    print("Room for \(state.projectName)" + (state.cloudAllowed ? "" : " (local only)"))
    print("Members:")
    for m in state.members {
        let who = m.agent ?? m.modelKey.map { "model \($0)" } ?? ""
        print("  \(m.name)" + (m.role.isEmpty ? "" : " [\(m.role)]") + " - \(m.kind)" + (m.kind == "cloud" ? " (\(m.provider))" : "") + ", \(who)"
              + (m.usable ? "" : " - cannot be used now: \(m.reason)") + "  id \(m.id)")
    }
    print("Tasks:")
    for (n, t) in state.tasks.enumerated() {
        let owner = state.members.first { $0.id == t.assignee }?.name ?? "unassigned"
        print("  \(n + 1). [\(t.status.rawValue)] \(t.title) - \(owner)" + (t.changed.map { $0 > 0 ? ", \($0) file change(s)" : "" } ?? "") + "  id \(t.id)")
        if t.status == .review, !t.result.isEmpty { print("     result: \(String(t.result.prefix(300)).replacingOccurrences(of: "\n", with: " "))") }
        if t.status == .todo, !t.note.isEmpty { print("     \(t.failed ? "last run failed" : "sent back"): \(t.note)") }
    }
    if !state.notes.isEmpty {
        print("Log:")
        for n in state.notes.prefix(10) { print("  \(n.at)  \(n.text)") }
    }
}

@MainActor func printTeamEntry(_ entry: TeamLogEntry) {
    let who = entry.memberName.isEmpty ? "" : " \(entry.memberName)"
    let text = String(entry.text.replacingOccurrences(of: "\n", with: " ").prefix(400))
    print("[\(entry.kind)]\(who): \(text)")
    fflush(stdout)
}

/// The ledger of a driven run: the plain sentence, then each member's tokens and time ("not measured" where none were reported).
func grouped(_ n: Int) -> String { let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","; f.locale = Locale(identifier: "en_US"); return f.string(from: NSNumber(value: n)) ?? "\(n)" }

func ledgerText(_ ledger: RunLedger) -> String {
    var rows = [ledger.summary]
    for line in ledger.lines {
        let tokens = line.measured ? "\(grouped(line.prompt ?? 0)) read, \(grouped(line.completion ?? 0)) written" : "not measured"
        rows.append("  \(line.name) (\(line.paid ? "paid" : "local")): \(tokens), \(line.seconds) s, \(line.runs) run\(line.runs == 1 ? "" : "s")")
    }
    return rows.joined(separator: "\n")
}

/// `room roster list | add | remove | use | save`: Black Team agents made once and added to any project's room.
@MainActor func runRoomRoster(_ backend: Backend) -> Int32 {
    let action = arguments.isEmpty ? "list" : arguments.removeFirst()
    func printRoster(_ list: [RosterEntryView]) {
        if asJSON { printJSON(list); return }
        if list.isEmpty { print("The roster is empty. Add one: room roster add --name N (--model <key> | --agent claude|codex)"); return }
        for (i, item) in list.enumerated() {
            let e = item.entry
            print("\(i + 1). \(e.name)" + (e.role.isEmpty ? "" : " [\(e.role)]") + " - " + (item.kind == "cloud" ? "paid (\(item.provider))" : "local")
                  + (e.agent != nil ? ", \(e.agent!) \(e.permission ?? "edit")" : ", \(e.work ?? "code") work") + (item.usable ? "" : " - cannot be used: \(item.reason)"))
        }
    }
    func pick(_ list: [RosterEntryView], _ given: String) -> RosterEntryView {
        let hits = list.enumerated().filter { "\($0.offset + 1)" == given || $0.element.entry.id == given || $0.element.entry.name.lowercased() == given.lowercased() }
        if hits.count == 1 { return hits[0].element }
        fail("No saved agent \"\(given)\"" + (hits.count > 1 ? " (more than one matches)." : "."))
    }
    do {
        switch action {
        case "list": printRoster(backend.roster())
        case "add":
            let name = option("--name"), role = option("--role") ?? "", model = option("--model"), agent = option("--agent")
            let work = option("--work"), permission = option("--permission")
            guard let name else { fail("--name is required.", code: 2) }
            var engine: String?
            if let agent {
                guard let service = AgentService.allCases.first(where: { $0.program == agent }) else { fail("--agent takes claude or codex.", code: 2) }
                engine = service.engine
            }
            printRoster(try backend.rosterCreate(name: name, role: role, modelKey: model, agent: engine, permission: permission, work: work))
        case "remove":
            guard arguments.count == 1 else { fail("room roster remove takes a number or name.\n\n\(usage)", code: 2) }
            printRoster(try backend.rosterRemove(id: pick(backend.roster(), arguments[0]).entry.id))
        case "use":
            guard arguments.count == 2 else { fail("room roster use takes a project and a saved agent.\n\n\(usage)", code: 2) }
            let id = roomProject(backend, arguments[0])
            printRoom(try backend.roomAddFromRoster(projectId: id, rosterId: pick(backend.roster(), arguments[1]).entry.id))
        case "save":
            guard arguments.count == 2 else { fail("room roster save takes a project and a member.\n\n\(usage)", code: 2) }
            let id = roomProject(backend, arguments[0])
            printRoster(try backend.roomSaveToRoster(projectId: id, memberId: roomMember(try backend.room(projectId: id), arguments[1]).id))
        default: fail("room roster takes list, add, remove, use or save.\n\n\(usage)", code: 2)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data((describe(error) + "\n").utf8))
        return 1
    }
}

@MainActor func runRoomTeam(_ backend: Backend) async -> Int32 {
    func projectArg() -> String {
        guard !arguments.isEmpty else { fail("Name the project.\n\n\(usage)", code: 2) }
        return roomProject(backend, arguments.removeFirst())
    }
    do {
        if arguments.first == "stop" {
            arguments.removeFirst()
            let id = projectArg()
            let before = try backend.room(projectId: id).team
            let after = try backend.roomTeamStop(projectId: id).team
            if asJSON { printJSON(after) }
            else { print(before.map { $0.phase.finished ? "No team run is going." : "Stopping the team run." } ?? "No team run is going.") }
            return 0
        }
        let lead = option("--lead"), reviewer = option("--reviewer")
        let confirmed = arguments.contains("--yes")
        arguments.removeAll { $0 == "--yes" }
        let pipeline = arguments.contains("--pipeline")
        arguments.removeAll { $0 == "--pipeline" }
        let id = projectArg()
        guard arguments.count == 1 else { fail("room team takes a project and a goal in quotes.\n\n\(usage)", code: 2) }
        let current = try backend.room(projectId: id)
        // A paid lead drives (hands work to the other members while it works) unless --pipeline asks for plan, work, review, report.
        let leadId = lead.map { roomMember(current, $0).id }
        let driven = !pipeline && backend.roomCanDrive(projectId: id, leadId: leadId)
        let preview = try backend.roomTeamPreview(projectId: id, goal: arguments[0], leadId: leadId,
                                                  reviewerId: reviewer.map { roomMember(current, $0).id }, driven: driven)
        if asJSON { printJSON(preview) } else {
            print(preview.agreement + "\n")
            for m in preview.members {
                print("  \(m.name)" + (m.role.isEmpty ? "" : " [\(m.role)]") + " - \(m.kind)" + (m.kind == "cloud" ? " (\(m.provider))" : "")
                      + (m.lead ? " - lead" : "") + (m.reviewer ? " - reviewer" : "") + (m.usable ? "" : " - cannot be used: \(m.reason)"))
            }
        }
        guard confirmed else {
            if !asJSON { print("\nNothing was started. Add --yes to run the team.") }
            return 0
        }
        _ = try backend.roomTeamRun(projectId: id, goal: preview.goal, leadId: preview.leadId, reviewerId: preview.reviewerId, digest: preview.digest,
                                    from: .mac, driven: driven)
        var seen: TeamLogEntry?
        var printed = 0
        while true {
            let team = try backend.room(projectId: id).team
            if let team {
                // New entries are the ones after the last one printed (the log keeps only its newest 200).
                var start = 0
                if let seen, let at = team.log.lastIndex(of: seen) { start = at + 1 } else if seen != nil { start = team.log.count }
                if !asJSON { for entry in team.log[start...] { printTeamEntry(entry); printed += 1 } }
                seen = team.log.last ?? seen
                if team.phase.finished { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await backend.roomTeamSettle()
        guard let final = try backend.room(projectId: id).team else { return 1 }
        if asJSON { printJSON(final) } else {
            if !final.report.isEmpty { print("\nReport:\n\(final.report)") }
            if let ledger = final.ledger { print("\n" + ledgerText(ledger)) }
            print("\nTeam run \(final.phase.rawValue)" + (final.message.isEmpty ? "" : ": \(final.message)") + " (\(final.runs) member runs).")
        }
        return final.phase == .done ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data((describe(error) + "\n").utf8))
        return 1
    }
}

@MainActor func runRoom(_ backend: Backend) async -> Int32 {
    let action = arguments.isEmpty ? "" : arguments.removeFirst()
    func projectArg() -> String {
        guard !arguments.isEmpty else { fail("Name the project.\n\n\(usage)", code: 2) }
        return roomProject(backend, arguments.removeFirst())
    }
    do {
        switch action {
        case "show":
            let id = projectArg()
            printRoom(try backend.room(projectId: id))
        case "member":
            guard arguments.first == "add" else { fail("room member takes add.\n\n\(usage)", code: 2) }
            arguments.removeFirst()
            let name = option("--name"), role = option("--role") ?? "", model = option("--model"), agent = option("--agent")
            let work = option("--work"), permission = option("--permission")
            let id = projectArg()
            guard let name else { fail("--name is required.", code: 2) }
            var engine: String?
            if let agent {
                guard let service = AgentService.allCases.first(where: { $0.program == agent }) else { fail("--agent takes claude or codex.", code: 2) }
                engine = service.engine
            }
            printRoom(try backend.roomAddMember(projectId: id, name: name, role: role, modelKey: model, agent: engine, permission: permission, work: work))
        case "task":
            guard arguments.first == "add" else { fail("room task takes add.\n\n\(usage)", code: 2) }
            arguments.removeFirst()
            let detail = option("--detail") ?? "", to = option("--to")
            let id = projectArg()
            guard let title = arguments.first, arguments.count == 1 else { fail("Give one title in quotes.\n\n\(usage)", code: 2) }
            let current = try backend.room(projectId: id)
            printRoom(try backend.roomAddTask(projectId: id, title: title, detail: detail, assignee: to.map { roomMember(current, $0).id }))
        case "start":
            let id = projectArg()
            guard arguments.count == 1 else { fail("room start takes a project and a task.\n\n\(usage)", code: 2) }
            let task = roomTask(try backend.room(projectId: id), arguments[0])
            let started = try await backend.roomStart(projectId: id, taskId: task.id)
            let threadId = started.tasks.first { $0.id == task.id }?.threadId
            var printed = "", steps = 0
            while backend.isBusy {
                if let threadId, let reply = backend.thread(threadId)?["messages"]?.array?.last, !asJSON {
                    let events = reply["events"]?.array ?? []
                    while steps < events.count {
                        let event = events[steps]; steps += 1
                        if event["type"]?.string == "tool_use" { print("[\(event["name"]?.string ?? "")] \(String((event["output"]?.string ?? "").replacingOccurrences(of: "\n", with: " ").prefix(160)))") }
                    }
                    let content = reply["content"]?.string ?? ""
                    if content.hasPrefix(printed), content.count > printed.count { print(String(content.dropFirst(printed.count)), terminator: ""); printed = content }
                    fflush(stdout)
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await backend.waitForIdle()
            await backend.roomSettle()
            let final = try backend.room(projectId: id)
            if !asJSON { print("\n") }
            printRoom(final)
            return final.tasks.first { $0.id == task.id }?.status == .review ? 0 : 1
        case "accept":
            let id = projectArg()
            guard arguments.count == 1 else { fail("room accept takes a project and a task.\n\n\(usage)", code: 2) }
            let task = roomTask(try backend.room(projectId: id), arguments[0])
            printRoom(try backend.roomAccept(projectId: id, taskId: task.id))
        case "sendback":
            let note = option("--note")
            let id = projectArg()
            guard arguments.count == 1, let note else { fail("room sendback takes a project, a task and --note.\n\n\(usage)", code: 2) }
            let task = roomTask(try backend.room(projectId: id), arguments[0])
            printRoom(try backend.roomSendBack(projectId: id, taskId: task.id, note: note))
        case "handoff":
            let to = option("--to"), title = option("--title"), detail = option("--detail")
            let includeResult = !arguments.contains("--no-result"), confirmed = arguments.contains("--yes")
            arguments.removeAll { $0 == "--no-result" || $0 == "--yes" }
            let id = projectArg()
            guard arguments.count == 1, let to else { fail("room handoff takes a project, a task and --to.\n\n\(usage)", code: 2) }
            let current = try backend.room(projectId: id)
            let task = roomTask(current, arguments[0]), receiver = roomMember(current, to)
            let preview = try backend.roomHandOffPreview(projectId: id, taskId: task.id, to: receiver.id, title: title, detail: detail, includeResult: includeResult)
            if asJSON { printJSON(preview) } else {
                print("This is exactly what \(preview.receiverName) would be given:\n")
                print(preview.text)
                print("\n" + (preview.leavesThisMac ? "This leaves \(Place.this): it goes to \(preview.provider)." : "This stays on \(Place.this)."))
            }
            guard confirmed else {
                if !asJSON { print("Nothing was sent. Add --yes to create the task.") }
                return 0
            }
            let after = try backend.roomHandOff(projectId: id, taskId: task.id, to: receiver.id, title: preview.title, detail: preview.detail,
                                                includeResult: includeResult, digest: preview.digest)
            if !asJSON { print("Created a task for \(preview.receiverName). Start it with: room start \(id) \(after.tasks.count)") }
        case "team":
            return await runRoomTeam(backend)
        case "roster":
            return runRoomRoster(backend)
        default:
            fail("room takes show, member add, task add, start, accept, sendback, handoff, team or roster.\n\n\(usage)", code: 2)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data((describe(error) + "\n").utf8))
        return 1
    }
}

// MARK: Commands

@MainActor func run(_ backend: Backend) async -> Int32 {
    guard !arguments.isEmpty else { fail(usage, code: 2) }
    let command = arguments.removeFirst()
    do {
        switch command {
        case "status":
            let status = try await backend.status()
            if asJSON { printJSON(status); return 0 }
            print("version: \(status.version)")
            print("setup complete: \(status.setupComplete ? "yes" : "no")")
            print("model: \(status.config.model.name) (\(status.config.model.source))")
            if status.cloud.selected { print("privacy: cloud model; conversations with it leave \(Place.this) for \(status.cloud.provider)") }
            print("runtime: \(status.runtime.state)\(status.runtime.error.map { " - \($0)" } ?? "")")
            print("saved models: \(status.models.count)")
            print("downloaded llama.cpp: \(status.downloadedRuntime.map { $0.tag + " at " + $0.executable } ?? "none")")
            print("memory: \(status.hardware.memory.total / 1_048_576) MB total, \(status.hardware.memory.free / 1_048_576) MB free")
            print("conversations: \(status.threads.count)")
            for warning in status.hardware.warnings { print("warning: \(warning)") }
            return 0

        case "starter":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            if action == "list" {
                let catalogue = backend.starterModels()
                if asJSON { printJSON(catalogue); return 0 }
                for entry in catalogue.models {
                    let marks = [entry.installed ? "installed" : nil, entry.recommended ? "recommended" : nil, entry.fits ? nil : "may not fit"].compactMap { $0 }
                    print("\(entry.id)\t\(entry.model.name)\t\(gigabytes(entry.model.bytes))\(marks.isEmpty ? "" : "\t" + marks.joined(separator: ", "))")
                }
                print("runtime: \(catalogue.runtime.map { $0.tag + " installed" } ?? "not installed (starter install downloads it)")")
                return 0
            }
            if action == "install" {
                guard !arguments.isEmpty else { fail("Name a starter model: black-team starter list", code: 2) }
                let id = arguments.removeFirst()
                let last = ProgressMemory()
                let result = try await backend.setUpStarter(modelID: id) { progress in
                    if asJSON { return }
                    if let line = last.line(progress) { print(line); fflush(stdout) }
                }
                if asJSON { printJSON(result) } else {
                    print("Set up \(result.modelName) with llama.cpp \(result.runtimeTag).")
                    if let warning = result.warning { print("warning: \(warning)") }
                }
                return 0
            }
            fail(usage, code: 2)

        case "setup":
            // One approval for every agent on this computer. Nothing is installed, downloaded or connected without a yes (or --yes).
            let approveAll = arguments.contains("--yes")
            arguments.removeAll { $0 == "--yes" }
            if !arguments.isEmpty { fail(usage, code: 2) }
            #if os(Linux)
            backend.integrations.hermesSupported = true   // the command line sets Hermes up on Linux as the window does
            #endif
            let plan = backend.setupPlan()
            if asJSON && !approveAll { printJSON(plan); return 0 }
            if !asJSON {
                print("Set up your agents")
                for step in plan.steps where step.kind != "note" {
                    let mark = step.state == .done ? "[done]" : step.state == .willDo ? "[will do]" : "[needs something]"
                    print("  \(mark) \(step.title): \(step.detail)")
                    for change in step.changes where step.state == .willDo { print("             - \(change)") }
                    if let needs = step.needs, step.state == .needsSomething { print("             \(needs)") }
                }
                for step in plan.steps where step.kind == "note" {
                    print("  \(step.title) (Black Team does not install these; the command is shown for you to run):")
                    for hint in step.commands { print("    \(hint.name): \(hint.command)") }
                }
            }
            let waiting = plan.pending
            if waiting.isEmpty { if !asJSON { print("Nothing to set up.") } else { printJSON(plan) }; return 0 }
            var approved = approveAll
            if !approveAll {
                if isatty(0) == 0 { print("Run `black-team setup --yes` to approve all of the steps marked [will do]."); return 1 }
                print("Approve these \(waiting.count) step\(waiting.count == 1 ? "" : "s")? [y/N] ", terminator: "")
                fflush(stdout)
                approved = ["y", "yes"].contains((readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased())
            }
            if !approved { try? backend.dismissSetupOffer(); print("Not now. Nothing was changed."); return 0 }
            let last = ProgressMemory()
            let results = try await backend.applySetup(approved: waiting.map(\.id)) { event in
                if asJSON { return }
                if let line = last.line(SetupProgress(stage: event.stage, fraction: event.fraction, bytesPerSecond: event.bytesPerSecond)), event.status == "running" { print(line); fflush(stdout) }
            }
            if asJSON { printJSON(results) } else {
                for result in results { print("\(result.status == "done" ? "done" : result.status): \(waiting.first { $0.id == result.id }?.title ?? result.id) - \(result.message)") }
            }
            return results.contains { $0.status == "failed" } ? 1 : 0

        case "recommend":
            let recommendations = backend.modelRecommendations()
            if asJSON { printJSON(recommendations); return 0 }
            print("This \(Place.kind): \(recommendations.summary)")
            if let note = recommendations.note { print("note: \(note)") }
            func line(_ entry: ModelAssessment) -> String {
                let picks = entry.picks.map { ["best": "BEST FOR THIS COMPUTER", "code": "best for Code (tools)", "fastest": "fastest"][$0] ?? $0 }
                let fit = entry.fit == .comfortable ? "fits well" : entry.fit == .tight ? "tight" : "too big"
                return "\(entry.id)\t\(entry.model.name)\t\(gigabytes(entry.model.bytes))\t\(fit)\t\(entry.speed.text)\t\(entry.goodFor.joined(separator: ", "))"
                    + (picks.isEmpty ? "" : "\t<- " + picks.joined(separator: ", ")) + (entry.installed ? "\tinstalled" : "")
            }
            for entry in recommendations.models { print(line(entry)); print("\t\(entry.reason)") }
            print("Download one with: black-team download <id>")
            return 0

        case "search":
            guard !arguments.isEmpty else { fail("Search for what? black-team search <words>, or black-team search <owner/repo> to list a repository's files.", code: 2) }
            let query = arguments.joined(separator: " "); arguments.removeAll()
            if HuggingFaceHub.isValidRepo(query) {
                let repo = try await backend.hubRepo(query)
                if asJSON { printJSON(repo); return 0 }
                print("\(repo.repo): \(repo.license) licence, made by \(query.split(separator: "/")[0]) (a third party), \(repo.page)")
                if let problem = repo.problem { print(problem) }
                for entry in repo.files {
                    let fit = entry.fit == .comfortable ? "fits well" : entry.fit == .tight ? "tight" : "too big"
                    print("\(entry.suggested ? "*" : " ") \(entry.file.path)\t\(entry.file.quant)\t\(gigabytes(entry.file.bytes))\t\(entry.unavailable ?? fit)")
                }
                if let vision = repo.visionFile { print("  vision file: \(vision.name) (\(gigabytes(vision.bytes))): add --with-vision when downloading") }
                if let draft = repo.draftFile { print("  speed-up file: \(draft.name) (\(gigabytes(draft.bytes))): add --with-draft when downloading") }
                print("* is the one suggested for this \(Place.kind). Download with: black-team download \(repo.repo) <file>")
                return 0
            }
            let results = try await backend.searchModels(query)
            if asJSON { printJSON(results); return 0 }
            if results.isEmpty { print("No GGUF models found for \"\(query)\".") }
            for item in results { print("\(item.repo)\t\(item.downloads) downloads\t\(item.likes) likes\(item.gated ? "\tneeds you to accept terms on huggingface.co" : "")") }
            return 0

        case "download":
            let withVision = arguments.contains("--with-vision"), withDraft = arguments.contains("--with-draft"), makeCurrent = arguments.contains("--use")
            let noOptimize = arguments.contains("--no-optimize")
            arguments.removeAll { ["--with-vision", "--with-draft", "--use", "--no-optimize"].contains($0) }
            guard !arguments.isEmpty else { fail("Name a model: black-team recommend, or black-team download <owner/repo> <file>.", code: 2) }
            let first = arguments.removeFirst()
            let choice: ModelChoice
            if HuggingFaceHub.isValidRepo(first) {
                guard !arguments.isEmpty else { fail("Name the file: black-team search \(first)", code: 2) }
                choice = .hub(repo: first, path: arguments.removeFirst(), vision: withVision, draft: withDraft)
            } else { choice = .catalogue(id: first, vision: withVision, draft: withDraft) }
            let last = ProgressMemory()
            let result = try await backend.getModel(choice, makeCurrent: makeCurrent) { progress in
                if asJSON { return }
                if let line = last.line(progress) { print(line); fflush(stdout) }
            }
            // A model that has just arrived is measured on this computer, so it starts with the settings that are fastest here.
            var optimized: String?
            if !noOptimize, case .started = await backend.optimizeAfterAdding(modelKey: result.key) {
                if !asJSON { print("Optimizing for this \(Place.kind) (about 3 minutes; the model starts a few times)\u{2026}"); fflush(stdout) }
                await backend.waitForOptimize()
                let status = backend.optimizeStatus()
                optimized = status["summary"]?.string ?? status["error"]?.string
            }
            if asJSON { printJSON(result); return 0 }
            print(result.message)
            if let optimized { print("Optimized: \(optimized)") }
            print("\(result.modelName): a model by someone else from Hugging Face (\(result.repo)), \(result.license) licence.")
            if let warning = result.warning { print("warning: \(warning)") }
            return 0

        case "runtime":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            if action == "status" {
                let installed = backend.downloadedRuntime()
                if asJSON { printJSON(installed); return 0 }
                if let installed { print("llama.cpp \(installed.tag) at \(installed.executable)\n\(installed.versionOutput ?? "")") } else { print("No llama.cpp runtime is installed.") }
                return 0
            }
            if action == "install" {
                let last = ProgressMemory()
                let installed = try await backend.installRuntime { progress in
                    if asJSON { return }
                    if let line = last.line(progress) { print(line); fflush(stdout) }
                }
                if asJSON { printJSON(installed) } else { print("Installed llama.cpp \(installed.tag) at \(installed.executable)\n\(installed.versionOutput ?? "")") }
                return 0
            }
            fail(usage, code: 2)

        case "find":
            let found = await backend.findMyModels()
            if asJSON { printJSON(found); return 0 }
            for item in found.servers { print("server\t\(item.key)\t\(item.server.name)\t\(item.server.endpoint)\(item.saved ? "\tsaved" : "")") }
            for item in found.files { print("file\t\(item.key)\t\(item.file.name)\t\(item.file.file)\t\(gigabytes(Int64(item.file.bytes)))\(item.saved ? "\tsaved" : "")") }
            if found.servers.isEmpty && found.files.isEmpty { print("No model servers or model files found.") }
            for name in found.added { print("added\t\(name)") }
            print("runtime: \(found.runtime.isEmpty ? "none" : found.runtime)")
            return 0

        case "models":
            let config = try backend.configStore.read()
            let list = backend.savedModels.list(active: config.model)
            if asJSON { printJSON(list); return 0 }
            if list.isEmpty { print("No saved models.") }
            for item in list { print("\(item.active ? "*" : " ") \(item.key)\t\(item.name)\t\(item.source)\t\(item.context) tokens\(item.isCloud ? "\tcloud: \(item.provider)" : "")") }
            return 0

        case "use":
            guard !arguments.isEmpty else { fail("Name a model key: black-team models", code: 2) }
            let result = try await backend.switchTo(key: arguments.removeFirst())
            if asJSON { printJSON(["switched": JSONValue.bool(result.switched), "name": JSONValue.string(result.name)]) } else { print("Now using \(result.name).") }
            return 0

        case "optimize":
            // The model named (its key, or the start of its name), or the one in use. The model is stopped while it is measured.
            let config = try backend.configStore.read()
            let list = backend.savedModels.list(active: config.model)
            let wanted = arguments.isEmpty ? "" : arguments.removeFirst()
            guard let target = wanted.isEmpty ? list.first(where: { $0.active }) : (list.first { $0.key == wanted } ?? list.first { $0.name.lowercased().hasPrefix(wanted.lowercased()) }) else {
                fail(wanted.isEmpty ? "No model is in use. Name one: black-team models" : "No saved model matches \(wanted). See: black-team models", code: 2)
            }
            let started = try await backend.optimize(key: target.key)
            guard started == .started else {
                if asJSON { printJSON(["result": JSONValue.string(started.text)]) } else { print("Not started (\(started.text)). A response or another setup action is running.") }
                return 1
            }
            if !asJSON { print("Optimizing \(target.name) for \(Place.this). This takes up to about 3 minutes and the model restarts a few times. Press Ctrl-C to stop.") }
            var shown = 0
            while true {
                let status = backend.optimizeStatus()
                let lines = status["log"]?.array?.compactMap { $0.string } ?? []
                if !asJSON { for line in lines.dropFirst(min(shown, lines.count)) { print(line); fflush(stdout) } }
                shown = lines.count
                if status["running"]?.bool != true { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await backend.waitForOptimize()
            let final = backend.optimizeStatus()
            if asJSON { printJSON(final); return final["error"]?.string?.isEmpty == false ? 1 : 0 }
            if let error = final["error"]?.string, !error.isEmpty { FileHandle.standardError.write(Data((error + "\n").utf8)); return 1 }
            if final["stopped"]?.bool == true { print("Stopped. The model is as it was."); return 130 }
            print("Optimized for \(Place.this): \(final["summary"]?.string ?? "")")
            return 0

        case "cloud":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            if arguments.contains("--key") { fail("A key is never taken from the command line. Put it in an environment variable and pass --key-env NAME.", code: 2) }
            func key(_ name: String?) -> String? {
                guard let name else { return nil }
                guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { fail("The environment variable \(name) is empty or not set.", code: 2) }
                return value
            }
            if action == "add" {
                guard let url = option("--url"), let keyName = option("--key-env"), let id = option("--model") else {
                    fail("cloud add needs --url, --key-env and --model.\n\n\(usage)", code: 2)
                }
                let name = option("--name") ?? id
                let context = Int(option("--context") ?? "") ?? 128_000
                let form: JSONValue = ["model": ["source": "cloud", "endpoint": .string(url), "id": .string(id), "apiKey": .string(key(keyName) ?? ""), "name": .string(name),
                                                 "context": .number(Double(context))]]
                _ = try await backend.saveSetup(form)
                let status = try await backend.status()
                if asJSON { printJSON(status.cloud) } else { print("Saved cloud model \(name) at \(status.cloud.provider). It is now the model in use. Conversations with it leave \(Place.this).") }
                return 0
            }
            if action == "models" {
                let url = option("--url"), keyName = option("--key-env")
                let found: DiscoveredCloud
                if let url { found = try await backend.discoverCloud(endpoint: url, apiKey: key(keyName) ?? "") }
                else { found = try await backend.discoverCloud(endpoint: try backend.configStore.read().model.endpoint) }
                if asJSON { printJSON(found.models.map { ["id": JSONValue.string($0.id)] }); return 0 }
                for item in found.models { print(item.id + (item.context.map { "\t\($0) tokens" } ?? "")) }
                return 0
            }
            fail(usage, code: 2)

        case "vision":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            if action == "status" {
                let status = try backend.visionStatus()
                if asJSON { printJSON(status); return 0 }
                print("can read images: \(status.canSee ? "yes" : "no")")
                print(status.summary)
                if status.needsFile { print("run: black-team vision install") }
                return 0
            }
            if action == "install" {
                let last = ProgressMemory()
                let result = try await backend.installVision { progress in
                    if asJSON { return }
                    if let line = last.line(progress) { print(line); fflush(stdout) }
                }
                if asJSON { printJSON(result) } else { print("Vision file set: \(result.file)\(result.restarted ? " (model restarted)" : "")") }
                return 0
            }
            fail(usage, code: 2)

        case "chat", "code":
            var imagePaths: [String] = []
            while let path = option("--image") { imagePaths.append(path) }
            if command == "code", !imagePaths.isEmpty { fail(ImageRules.codeRefusal) }
            var uploads: [ImageUpload] = []
            for path in imagePaths {
                do { uploads.append(try ImagePreparer.prepare(url: URL(fileURLWithPath: path))) } catch { fail("\((path as NSString).lastPathComponent): \(describe(error))") }
            }
            let thread = option("--thread"), mode = option("--mode") ?? "balanced"
            let workspace = command == "code" ? option("--workspace") : nil
            // `code --continue --thread <id>` carries on a task that stopped or was cut off, from its saved state.
            let carryOn = command == "code" && arguments.contains("--continue")
            arguments.removeAll { $0 == "--continue" }
            if carryOn { guard thread != nil, arguments.isEmpty else { fail("--continue takes --thread <id> and no message.", code: 2) }; arguments = ["Continue."] }
            let approve = option("--approve") ?? "deny"
            let allowCloud = arguments.contains("--allow-cloud"), stopOther = arguments.contains("--stop-other")
            arguments.removeAll { $0 == "--allow-cloud" || $0 == "--stop-other" }
            guard ["once", "deny"].contains(approve) else { fail("--approve takes once or deny.", code: 2) }
            guard let message = arguments.first, arguments.count == 1 else { fail("Give one message in quotes.\n\n\(usage)", code: 2) }
            return await runTurn(backend, message: message, kind: command == "chat" ? "chat" : "agent", mode: mode, thread: thread, workspace: workspace, approve: approve, images: uploads, allowCloud: allowCloud, stopOther: stopOther)

        case "agent":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            if action == "rollback" {
                guard arguments.count == 2 else { fail("agent rollback needs a thread id and a run id.\n\n\(usage)", code: 2) }
                do {
                    let restored = try backend.rollBack(threadId: arguments[0], runId: arguments[1])
                    if asJSON { print(JSONValue.object(["restored": .array(restored.restored.map { .string($0) }), "removed": .array(restored.removed.map { .string($0) })]).text(pretty: true)) }
                    else {
                        print("restored \(restored.restored.count) file(s)\(restored.restored.isEmpty ? "" : ": " + restored.restored.joined(separator: ", "))")
                        print("removed \(restored.removed.count) file(s)\(restored.removed.isEmpty ? "" : ": " + restored.removed.joined(separator: ", "))")
                    }
                    return 0
                } catch { fail(describe(error)) }
            }
            if action == "signin" {
                guard arguments.count == 1, let service = AgentService.allCases.first(where: { $0.program == arguments[0] }) else {
                    fail("agent signin takes claude or codex.\n\n\(usage)", code: 2)
                }
                do { try await backend.openAgentSignIn(service: service) } catch { fail(describe(error)) }
                print("Opened \(service.displayName) sign-in in Terminal. Finish it there, then send your message again.")
                return 0
            }
            guard let service = AgentService.allCases.first(where: { $0.program == action }) else {
                fail("agent takes claude or codex, then the task in quotes, signin, or rollback.\n\n\(usage)", code: 2)
            }
            let thread = option("--thread")
            let rawWorkspace = option("--workspace")
            // A folder given on the command line is made absolute, so the saved folder still means the same thing later.
            let workspace = rawWorkspace.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let allowCloud = arguments.contains("--allow-cloud")
            arguments.removeAll { $0 == "--allow-cloud" }
            let rawPermission = option("--permission")
            let permission = rawPermission.flatMap { AgentPermission(rawValue: $0) }
            if rawPermission != nil, permission == nil { fail("--permission takes ask, edit or auto.", code: 2) }
            let approve = option("--approve") ?? "deny"
            guard ["once", "deny"].contains(approve) else { fail("--approve takes once or deny.", code: 2) }
            guard let message = arguments.first, arguments.count == 1 else { fail("Give one task in quotes.\n\n\(usage)", code: 2) }
            return await runAgentTask(backend, service: service, message: message, thread: thread, workspace: workspace, allowCloud: allowCloud,
                                      permission: permission, approve: approve)

        case "room":
            return await runRoom(backend)

        case "skills":
            let action = arguments.isEmpty ? "list" : arguments.removeFirst()
            let skills = backend.skills
            let workspace = option("--workspace").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            switch action {
            case "list":
                let found = skills.list(workspace: workspace)
                if asJSON { printJSON(backend.skillsView(workspace: workspace)); return 0 }
                if found.isEmpty { print("No skills saved yet. Code saves one when it has a routine that worked and you approve it.") }
                for skill in found { print("\(skill.name)\t\(skill.source)\t\(skill.enabled ? "on" : "off")\t\(skill.description)") }
                if !found.isEmpty { print("\(found.count) skills in \(skills.folder)") }
            case "show":
                guard arguments.count == 1 else { fail("Give the skill's name: black-team skills show <name>", code: 2) }
                let text = try skills.text(arguments[0], workspace: workspace)
                if asJSON { printJSON(["name": arguments[0], "text": text]) } else { print(text) }
            case "remove":
                guard arguments.count == 1 else { fail("Give the skill's name: black-team skills remove <name>", code: 2) }
                try skills.remove(arguments[0])
                print("Removed \(arguments[0]). It was moved to \(skills.folder)/.trash.")
            default: fail(usage, code: 2)
            }
            return 0

        case "memory":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            switch action {
            case "core":
                let core = backend.memory.core()
                if asJSON { printJSON(["core": core]) } else { print(core.isEmpty ? "Core memory is empty." : core) }
            case "list":
                let overview = try backend.memoryOverview()
                if asJSON { printJSON(overview); return 0 }
                for note in overview.notes { print("\(note.id)\t\(note.size) chars") }
                print("\(overview.keeper.usage.notes) notes, \(overview.keeper.usage.percent)% of the memory limit")
            case "search":
                guard !arguments.isEmpty else { fail("Give a search: black-team memory search <query>", code: 2) }
                let hits = try await backend.memorySearch(arguments.joined(separator: " "))
                if asJSON { printJSON(hits); return 0 }
                if hits.isEmpty { print("No matches.") }
                for hit in hits { print("\(hit.id):\(hit.line)\t\(hit.text)") }
            default: fail(usage, code: 2)
            }
            return 0

        case "phone":
            let action = arguments.isEmpty ? "" : arguments.removeFirst()
            switch action {
            case "status":
                let detected = await backend.phoneDetect()
                let state = try await backend.phoneState(fresh: true)
                if asJSON { printJSON(state); return 0 }
                print("tailscale: \(detected.installed ? (detected.online ? "online as \(detected.owner) at \(detected.hostname)" : "installed, not signed in") : "not installed")")
                print("phone access: \(state.enabled ? "on" : "off")")
                print("route: \(state.routeReady ? "Black Team's private route is in place" : "not in place")")
                print("local server: \(state.serverRunning ? "listening on 127.0.0.1:\(Phone.localPort)" : "not running in this process (black-team serve, or the app, runs it)")")
                if state.enabled { print("address: \(state.url)") }
                if !state.routeReady, let problem = state.problem { print("problem: \(problem)") }
            case "enable":
                let state = try await backend.phoneEnable()
                if asJSON { printJSON(state); return 0 }
                print("Phone access is on. Route: \(state.url) (tailnet only).")
                print("Run `black-team serve` to answer phones, and `black-team phone link` for the pairing link.")
            case "disable":
                let result = try await backend.phoneDisable()
                if asJSON { printJSON(result); return 0 }
                print("Phone access is off.")
                if let warning = result.warning { print("warning: \(warning)") }
            case "link":
                // From a separate process the serving one is not asked: the route and the key decide.
                let link = try await backend.phonePairingLink(requireServer: false)
                if asJSON { printJSON(["link": link]) } else { print(link) }
            case "reset":
                try backend.phoneResetPairing()
                print("Phone pairing reset. Every paired phone is unpaired; scan a new link to pair again.")
            default: fail(usage, code: 2)
            }
            return 0

        case "hermes":
            return try await runHermesCommand(backend)

        case "serve":
            try await backend.startPhoneAccess()
            let state = try await backend.phoneState(fresh: true)
            print("Black Team is running. Phone access: \(state.enabled ? (state.serverRunning ? "listening on 127.0.0.1:\(Phone.localPort)" : "not started") : "off"). Press Ctrl-C to stop.")
            fflush(stdout)
            while true { try await Task.sleep(nanoseconds: 2_000_000_000); await backend.syncPhoneAccess() }

        case "help", "--help", "-h":
            print(usage)
            return 0

        default:
            fail("Unknown command: \(command)\n\n\(usage)", code: 2)
        }
    } catch {
        // Returned, not exited, so the model is shut down first.
        FileHandle.standardError.write(Data((describe(error) + "\n").utf8))
        return 1
    }
}

/// Prints a progress line when the stage changes or the download has moved on by a percent.
final class ProgressMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "", percent = -1
    func line(_ progress: SetupProgress) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = progress.fraction.map { Int($0 * 100) } ?? -1
        if progress.stage == stage && now == percent { return nil }
        stage = progress.stage; percent = now
        var text = progress.stage
        if now >= 0 { text += ": \(now)%" }
        if progress.bytesPerSecond > 0 { text += " at \(rate(progress.bytesPerSecond))" }
        return text
    }
}
