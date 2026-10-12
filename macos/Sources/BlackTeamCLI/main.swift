import Foundation
import BlackTeamKit

// black-team-cli: the whole app from a terminal (for SSH on a Mac with no one at the screen).
// It uses the app's data folder (BLACK_TEAM_DATA overrides). Plain text by default, --json for JSON;
// the exit status is non-zero on failure. Every command ends by shutting the model down.

let usage = """
Usage: black-team-cli [--json] <command>

  status                              set-up state, runtime, saved models, hardware
  starter list                        the starter models, what is installed, the recommendation
  starter install <id>                download the runtime and a starter model and set it up
  runtime status | install            the downloaded llama.cpp program; download it (no model)
  find                                look for running model servers and model files
  models                              the saved models
  use <key>                           make a saved model the one in use
  cloud add --url <https address> --key-env <NAME> --model <id> [--name <text>] [--context <tokens>]
                                      save a cloud model; the key is read from the environment variable NAME
  cloud models [--url <address> --key-env <NAME>]
                                      ask the service which models it offers (the saved cloud model's, by default)
  chat "<message>" [--image <path>]... [--thread <id>] [--mode fast|balanced|deep|extended] [--allow-cloud]
  vision status | install             can the model read images; download a starter model's vision file
  code "<message>" [--workspace <folder>] [--thread <id>] [--mode ...] [--approve once|deny] [--allow-cloud]
  agent claude|codex "<message>" [--workspace <folder>] [--thread <id>] [--allow-cloud] [--permission ask|edit|auto] [--approve once|deny]
                                      ask: asks before changes (Claude Code) or only reads (Codex); edit: edits files; auto: more on its own
  agent signin claude|codex           open the tool's sign-in in Terminal
                                      hand a task to your Claude Code or Codex subscription (it leaves this Mac)
  agent rollback <thread id> <run id> undo the files a task changed
  room show <project>                 the team's task board
  room member add <project> --name N --role R (--model <key> [--work chat|code] | --agent claude|codex [--permission ask|edit|auto])
  room task add <project> "<title>" [--detail D] [--to <member>]
  room start <project> <task>         run a task with its assignee and wait; <task> is its number or id
  room accept <project> <task> | room sendback <project> <task> --note N
  room handoff <project> <task> --to <member> [--title T] [--detail D] [--no-result] [--yes]
                                      shows exactly what the member would be given and whether it leaves this Mac; --yes sends it
  room team <project> "<goal>" [--lead <member>] [--reviewer <member>] [--yes]
                                      the whole team works on one goal, one member at a time; without --yes it shows what would be
                                      shared and stops; with it, it runs, prints each step as it happens, then the report
  room team stop <project>            stop a team run in progress
  memory core | list | search <query>
  phone status | enable | disable | link | reset
  serve [--web <folder>]              keep Black Team and phone access running until Ctrl-C
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func describe(_ error: Error) -> String { (error as? BlackTeamError)?.message ?? error.localizedDescription }

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
let asJSON = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

/// Removes `--name value` from the arguments and returns the value.
@MainActor func option(_ name: String) -> String? {
    guard let at = arguments.firstIndex(of: name) else { return nil }
    guard at + 1 < arguments.count else { fail("\(name) needs a value.\n\n\(usage)", code: 2) }
    let value = arguments[at + 1]
    arguments.removeSubrange(at...(at + 1))
    return value
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self))
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
func rate(_ bytesPerSecond: Double) -> String { String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }

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
        if rollbackReady { print("rollback: black-team-cli agent rollback \(sent.threadId) \(sent.id)") }
        if let note = reply?["rollbackNote"]?.string { print("rollback: \(note)") }
        print("privacy: leaves this Mac, sent to \(service.provider) under your \(service.displayName) subscription")
        if let error = reply?["error"]?.string { FileHandle.standardError.write(Data(("error: " + error + "\n").utf8)) }
        if reply?["needsSignIn"] != nil { print("sign in: black-team-cli agent signin \(service.program)") }
    }
    return state == "done" ? 0 : 1
}

/// Runs one Chat or Code turn and prints it. Returns the exit status.
/// `allowCloud` answers the one question the Backend asks before a private conversation goes to a cloud service.
@MainActor func runTurn(_ backend: Backend, message: String, kind: String, mode: String, thread: String?, workspace: String?, approve: String, images: [ImageUpload] = [],
                        allowCloud: Bool = false) async -> Int32 {
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
            text += "\nOn the command line: add --allow-cloud to send this conversation, omit --thread to start a new one, or run `black-team-cli use <key>` to select a local model."
        }
        fail(text)
    }
    var printed = ""
    var steps = 0
    var answered = Set<String>()
    func show() {
        guard let view = backend.thread(sent.threadId), let reply = view["messages"]?.array?.last else { return }
        let content = reply["content"]?.string ?? ""
        if kind == "agent" {
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
        if let usage = finalThread?["usage"] {
            print("usage: \(usage["prompt"]?.int ?? 0) tokens in, \(usage["completion"]?.int ?? 0) out" + ((usage["cached"]?.int ?? 0) > 0 ? ", \(usage["cached"]!.int!) cached" : ""))
        }
        if finalThread?["privacy"]?.string == "cloud" { print("privacy: leaves this Mac, sent to \(finalThread?["provider"]?.string ?? "a cloud service")") }
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
        let id = projectArg()
        guard arguments.count == 1 else { fail("room team takes a project and a goal in quotes.\n\n\(usage)", code: 2) }
        let current = try backend.room(projectId: id)
        let preview = try backend.roomTeamPreview(projectId: id, goal: arguments[0], leadId: lead.map { roomMember(current, $0).id },
                                                  reviewerId: reviewer.map { roomMember(current, $0).id })
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
        _ = try backend.roomTeamRun(projectId: id, goal: preview.goal, leadId: preview.leadId, reviewerId: preview.reviewerId, digest: preview.digest)
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
                print("\n" + (preview.leavesThisMac ? "This leaves this Mac: it goes to \(preview.provider)." : "This stays on this Mac."))
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
        default:
            fail("room takes show, member add, task add, start, accept, sendback, handoff or team.\n\n\(usage)", code: 2)
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
            if status.cloud.selected { print("privacy: cloud model; conversations with it leave this Mac for \(status.cloud.provider)") }
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
                guard !arguments.isEmpty else { fail("Name a starter model: black-team-cli starter list", code: 2) }
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
            guard !arguments.isEmpty else { fail("Name a model key: black-team-cli models", code: 2) }
            let result = try await backend.switchTo(key: arguments.removeFirst())
            if asJSON { printJSON(["switched": JSONValue.bool(result.switched), "name": JSONValue.string(result.name)]) } else { print("Now using \(result.name).") }
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
                if asJSON { printJSON(status.cloud) } else { print("Saved cloud model \(name) at \(status.cloud.provider). It is now the model in use. Conversations with it leave this Mac.") }
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
                if status.needsFile { print("run: black-team-cli vision install") }
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
            let approve = option("--approve") ?? "deny"
            let allowCloud = arguments.contains("--allow-cloud")
            arguments.removeAll { $0 == "--allow-cloud" }
            guard ["once", "deny"].contains(approve) else { fail("--approve takes once or deny.", code: 2) }
            guard let message = arguments.first, arguments.count == 1 else { fail("Give one message in quotes.\n\n\(usage)", code: 2) }
            return await runTurn(backend, message: message, kind: command == "chat" ? "chat" : "agent", mode: mode, thread: thread, workspace: workspace, approve: approve, images: uploads, allowCloud: allowCloud)

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
                guard !arguments.isEmpty else { fail("Give a search: black-team-cli memory search <query>", code: 2) }
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
                print("local server: \(state.serverRunning ? "listening on 127.0.0.1:\(Phone.localPort)" : "not running in this process (black-team-cli serve, or the app, runs it)")")
                if state.enabled { print("address: \(state.url)") }
                if !state.routeReady, let problem = state.problem { print("problem: \(problem)") }
            case "enable":
                let state = try await backend.phoneEnable()
                if asJSON { printJSON(state); return 0 }
                print("Phone access is on. Route: \(state.url) (tailnet only).")
                print("Run `black-team-cli serve` to answer phones, and `black-team-cli phone link` for the pairing link.")
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

// MARK: Main

// A stand-in for a cloud service, for testing the wire format without a real key. BLACK_TEAM_CLOUD_TEST_HOST=<host:port> lets
// THIS command-line tool accept `http://<host:port>/v1` as a cloud address, and only when the host is 127.0.0.1 or localhost.
// The check lives here, in the black-team-cli target: BlackTeamKit's default (`CloudRules.standard`) never reads the variable, and
// the Black Team app does not contain this file or the variable's name. Real https addresses are still checked as usual.
func cloudRulesForThisRun() -> CloudRules {
    guard let hostPort = ProcessInfo.processInfo.environment["BLACK_TEAM_CLOUD_TEST_HOST"], !hostPort.isEmpty else { return .standard }
    let pieces = hostPort.split(separator: ":").map(String.init)
    guard pieces.count == 2, ["127.0.0.1", "localhost"].contains(pieces[0]), let port = Int(pieces[1]), (1...65535).contains(port) else {
        fail("BLACK_TEAM_CLOUD_TEST_HOST must be 127.0.0.1:<port> or localhost:<port>.", code: 2)
    }
    FileHandle.standardError.write(Data("NOTE: BLACK_TEAM_CLOUD_TEST_HOST is set. http://\(hostPort)/v1 is accepted as a cloud address in this run. No real cloud service should be in use.\n".utf8))
    return CloudRules { value in
        if let real = try? cloudEndpoint(value) { return real }
        guard let parts = URLComponents(string: value), parts.scheme == "http", parts.host == pieces[0], parts.port == port, ["/v1", "/v1/"].contains(parts.path),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw BlackTeamError("In this test run a cloud address must be http://\(hostPort)/v1 or a real https address.")
        }
        return CloudEndpoint(base: "http://\(hostPort)/v1", host: hostPort)
    }
}

let backend: Backend
do { backend = try Backend(cloud: cloudRulesForThisRun()) } catch { fail(describe(error)) }

// Ctrl-C stops the job and shuts the model down cleanly instead of leaving llama-server running.
var interrupts: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        backend.cancel()
        backend.cancelSetUp()
        Task {
            await backend.shutdown()
            exit(130)
        }
    }
    source.resume()
    interrupts.append(source)
}

var phoneOptions = PhoneOptions()
if let web = option("--web") ?? ProcessInfo.processInfo.environment["BLACK_TEAM_WEB"] { phoneOptions.webRoot = web }
backend.configurePhone(phoneOptions)

let status = await run(backend)
await backend.shutdown()
exit(status)
