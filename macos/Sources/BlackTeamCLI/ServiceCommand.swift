import Foundation
import BlackTeamKit
import BlackTeamTerminal
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// black-team service run | install | uninstall | start | stop | restart | status | logs | set
// black-team schedule list | add | remove | pause | resume | run
// black-team inbox [approve <id> | deny <id>]
//
// `service run` is the long-running process: the engine and loopback server with no window, plus the scheduler. The unit that `service install`
// writes starts it at login. The other commands talk to it when it is running (the same address and secret the window uses, found in
// <data>/service.json) and read or edit the same files when it is not. None of them starts a second engine beside a running service.

// MARK: service

/// Where this program's web files and scripts are: beside the program in an installed app (bin/black-team, dist, scripts).
private func appFolder() -> String {
    let program = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    return program.deletingLastPathComponent().deletingLastPathComponent().path
}

private func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

@MainActor func runServiceCommand(_ given: [String]) async -> Int32 {
    var rest = given
    guard let sub = rest.first else { say(commandHelp["service"] ?? usage); return 2 }
    rest.removeFirst()
    asJSON = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let data = AppPaths.dataFolder()
    let manager = ServiceManager(dataFolder: data)
    do {
        switch sub {
        case "run":
            return await runBackgroundService(rest)
        case "install":
            let path = try await manager.install()
            print(asJSONText(["installed": true, "unit": .string(path)]) ?? "The background service is on. It starts when you log in.")
            if !asJSON { print("Unit: \(path)\nStart it now with: black-team service start") }
            return 0
        case "uninstall":
            let removed = try await manager.uninstall()
            print(asJSONText(["removed": .bool(removed)]) ?? (removed ? "The background service is off and its unit is removed." : "The background service was not turned on."))
            return 0
        case "start":
            try await manager.start()
            print(asJSONText(["started": true]) ?? "Started.")
            return 0
        case "stop":
            try await manager.stop()
            print(asJSONText(["stopped": true]) ?? "Stopped.")
            return 0
        case "restart":
            try await manager.restart()
            print(asJSONText(["restarted": true]) ?? "Restarted.")
            return 0
        case "logs":
            var lines = 100
            if let at = rest.firstIndex(of: "-n"), at + 1 < rest.count, let count = Int(rest[at + 1]) { lines = count }
            print(await manager.logs(lines: lines))
            return 0
        case "status":
            return await printServiceStatus(manager, data)
        case "set":
            guard rest.count == 2, let value = Int(rest[1]) else { say("Usage: black-team service set idle-minutes|approval-hours|runs-per-day <number>"); return 2 }
            let store = ServiceSettingsStore(dataFolder: data)
            var settings = store.read()
            switch rest[0] {
            case "idle-minutes": settings.idleMinutes = value
            case "approval-hours": settings.approvalHours = value
            case "runs-per-day": settings.maxRunsPerDay = value
            default: say("Unknown setting: \(rest[0])"); return 2
            }
            try store.save(settings)
            print("Saved. A running background service uses it from the next check.")
            return 0
        default:
            say("Unknown service command: \(sub)\n\n\(commandHelp["service"] ?? usage)")
            return 2
        }
    } catch {
        say(describe(error))
        return 1
    }
}

private func asJSONText(_ value: JSONValue) -> String? { asJSON ? value.text(pretty: true) : nil }

/// Exit status 0 when the service is running, 3 when it is not (like `systemctl is-active`).
@MainActor private func printServiceStatus(_ manager: ServiceManager, _ data: String) async -> Int32 {
    let unit = await manager.state()
    let finding = await ServiceClient.find(dataFolder: data, version: nil)
    var out: [String: JSONValue] = ["unit": unit.json]
    var lines: [String] = []
    lines.append("starts at login: " + (!unit.supported ? "not available on this computer" : unit.installed ? "yes" + (unit.enabled ? "" : " (the unit is written but not enabled)") : "no"))
    var code: Int32 = 3
    switch finding {
    case .running(let connection), .mismatch(let connection, _):
        code = 0
        out["running"] = true; out["pid"] = .number(Double(connection.pid)); out["port"] = .number(Double(connection.port)); out["version"] = .string(connection.version)
        lines.append("running: yes (process \(connection.pid), version \(connection.version), port \(connection.port))")
        if case .mismatch(_, let message) = finding { lines.append(message) }
        if let state = try? await ServiceClient(connection).get("/api/service") {
            out["service"] = state
            if state["unloaded"]?.bool == true { lines.append("model: unloaded to free memory (it starts again when needed)") }
            lines.append("waiting for you: \(state["inbox"]?.int ?? 0)")
            if let next = state["nextRun"]?.double { lines.append("next scheduled run: " + clockText(next)) }
            for helper in state["helpers"]?.array ?? [] { lines.append("helper \(helper["name"]?.string ?? ""): \(helper["state"]?.string ?? "")") }
        }
    case .refused(let why):
        out["running"] = true; out["refused"] = .string(why)
        lines.append("running: yes, but " + why)
        code = 0
    case .none, .stale:
        out["running"] = false
        lines.append("running: no")
        if unit.installed { lines.append("Start it with: black-team service start") }
        else { lines.append("Turn it on with: black-team service install  (or in Settings, App & data)") }
        let waiting = InboxStore(dataFolder: data).waiting().count
        if waiting > 0 { lines.append("waiting for you: \(waiting)  (black-team inbox)") }
    }
    if asJSON { print(JSONValue.object(out).text(pretty: true)) } else { print(lines.joined(separator: "\n")) }
    return code
}

private func clockText(_ seconds: Double) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium; formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
}

/// `black-team service run`: stays in the foreground until it is told to stop.
@MainActor private func runBackgroundService(_ given: [String]) async -> Int32 {
    var web: String?, version: String?, port = Phone.localPort, data = AppPaths.dataFolder(), scripts: String?
    var rest = given[...]
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { say("\(flag) needs a value."); return 2 }
        switch flag {
        case "--web": web = value
        case "--version": version = value
        case "--port": guard let number = Int(value), (0...65535).contains(number) else { say("--port needs a number from 0 to 65535."); return 2 }; port = number
        case "--data": guard value.hasPrefix("/") else { say("--data needs an absolute folder."); return 2 }; data = value
        case "--scripts": scripts = value
        default: say("Unknown option: \(flag)"); return 2
        }
    }
    let app = appFolder()
    let webFolder = web ?? ProcessInfo.processInfo.environment["BLACK_TEAM_WEB"] ?? app + "/dist"
    let scriptsFolder = scripts ?? (FileManager.default.fileExists(atPath: app + "/scripts/agent-runner.py") ? app + "/scripts" : nil)
    guard webFolder.hasPrefix("/") else { say("The web folder must be an absolute path."); return 2 }
    signal(SIGPIPE, SIG_IGN)
    let service: BackgroundService
    do {
        service = try BackgroundService(options: DesktopServiceOptions(web: webFolder, version: version ?? programVersion, port: port, dataFolder: data, scripts: scriptsFolder))
        let connection = try await service.start()
        say("Black Team background service ready on \(connection.origin) (version \(connection.version), data \(data)).")
    } catch {
        say(describe(error))
        return 1
    }
    let ending = BackgroundStop()
    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { ending.run(service) }
        source.resume()
        sources.append(source)
    }
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000); _ = sources.count }
}

/// Ends the service once, from whichever signal comes first.
final class BackgroundStop: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func run(_ service: BackgroundService) {
        lock.lock(); let first = !started; started = true; lock.unlock()
        guard first else { return }
        Task {
            await service.shutdown()
            exit(0)
        }
    }
}

// MARK: schedule and inbox

/// The service when it is running (the same commands work from another terminal), or the files in the data folder when it is not.
enum ServiceTransport {
    case remote(ServiceClient)
    case local(ServiceHooks)

    func schedules() async throws -> JSONValue {
        switch self {
        case .remote(let client): return try await client.get("/api/schedules")
        case .local(let hooks): return hooks.schedulesJSON()
        }
    }
    func save(_ input: [String: JSONValue]) async throws -> JSONValue {
        switch self {
        case .remote(let client): return try await client.post("/api/schedules/save", .object(input))
        case .local(let hooks): return try hooks.saveSchedule(input)
        }
    }
    func remove(_ id: String) async throws {
        switch self {
        case .remote(let client): _ = try await client.post("/api/schedules/remove", ["id": .string(id)])
        case .local(let hooks): try hooks.schedules.remove(id)
        }
    }
    func pause(_ id: String, _ paused: Bool) async throws {
        switch self {
        case .remote(let client): _ = try await client.post("/api/schedules/pause", ["id": .string(id), "paused": .bool(paused)])
        case .local(let hooks): _ = try hooks.schedules.setEnabled(id, !paused)
        }
    }
    func run(_ id: String) async throws {
        switch self {
        case .remote(let client): _ = try await client.post("/api/schedules/run", ["id": .string(id)])
        case .local(let hooks): try hooks.runSchedule(id)
        }
    }
    func inbox() async throws -> JSONValue {
        switch self {
        case .remote(let client): return try await client.get("/api/inbox")
        case .local(let hooks): return hooks.inboxJSON()
        }
    }
    func answer(_ id: String, approve: Bool) async throws {
        switch self {
        case .remote(let client): _ = try await client.post("/api/inbox/answer", ["id": .string(id), "choice": .string(approve ? "approve" : "deny")])
        case .local(let hooks): try hooks.answer(id, approve: approve)
        }
    }
    var isRemote: Bool { if case .remote = self { return true }; return false }
}

/// `schedule` and `inbox` reach the running service first, before any engine of their own is opened.
@MainActor func attachedTransport() async -> ServiceTransport? {
    guard case .running(let connection) = await ServiceClient.find(dataFolder: AppPaths.dataFolder(), version: nil) else { return nil }
    return .remote(ServiceClient(connection))
}

@MainActor func runScheduleCommand(_ transport: ServiceTransport) async -> Int32 {
    guard !arguments.isEmpty else { say(commandHelp["schedule"] ?? usage); return 2 }
    let sub = arguments.removeFirst()
    do {
        let all = try await transport.schedules()
        let list = all["schedules"]?.array ?? []
        func find(_ word: String?) throws -> JSONValue {
            guard let word, !word.isEmpty else { throw BlackTeamError("Name the schedule (its name or the start of its id).") }
            let matches = list.filter { $0["id"]?.string?.hasPrefix(word) == true || ($0["name"]?.string ?? "").lowercased() == word.lowercased() }
            if matches.count > 1 { throw BlackTeamError("More than one schedule matches \"\(word)\". Use more of its id.") }
            guard let found = matches.first else { throw BlackTeamError("There is no schedule called \"\(word)\".") }
            return found
        }
        switch sub {
        case "list":
            if asJSON { print(all.text(pretty: true)); return 0 }
            if list.isEmpty { print("No schedules. Add one with: black-team schedule add --name <name> --message <text> --when \"daily at 9:30\"") }
            for item in list {
                let last = item["lastRun"]
                let next = item["nextRun"]?.double.map { clockText($0) } ?? "-"
                print("\((item["id"]?.string ?? "").prefix(8))  \(item["name"]?.string ?? "")  [\(item["kind"]?.string == "chat" ? "Chat" : "Code")]  \(item["whenDescription"]?.string ?? "")  \(item["state"]?.string ?? "")  next: \(next)  last: \(last?["state"]?.string ?? "-")")
            }
            if !transport.isRemote && !list.isEmpty { print("Schedules run only while the background service is on: black-team service status") }
            return 0
        case "add":
            var input: [String: JSONValue] = [:]
            if let value = option("--name") { input["name"] = .string(value) }
            if let value = option("--message") { input["message"] = .string(value) }
            if let value = option("--when") { input["whenText"] = .string(value) }
            if let value = option("--kind") { input["kind"] = .string(value == "code" ? "agent" : value) }
            if let value = option("--permission") { input["permission"] = .string(value) }
            if let value = option("--model") { input["model"] = .string(value) }
            if let value = option("--project") {
                let projects = all["projects"]?.array ?? []
                guard let project = projects.first(where: { $0["id"]?.string == value || ($0["name"]?.string ?? "").lowercased() == value.lowercased() }) else {
                    throw BlackTeamError("There is no project called \"\(value)\".")
                }
                input["project"] = project["id"]
            }
            if input["kind"] == nil { input["kind"] = "agent" }
            let saved = try await transport.save(input)
            if asJSON { print(saved.text(pretty: true)) }
            else { print("Added \(saved["name"]?.string ?? "") (\(saved["whenDescription"]?.string ?? "")). Next run: " + (saved["nextRun"]?.double.map { clockText($0) } ?? "-")) }
            return 0
        case "remove":
            let item = try find(arguments.first)
            try await transport.remove(item["id"]?.string ?? "")
            print("Removed \(item["name"]?.string ?? "").")
            return 0
        case "pause", "resume":
            let item = try find(arguments.first)
            try await transport.pause(item["id"]?.string ?? "", sub == "pause")
            print((sub == "pause" ? "Paused " : "Resumed ") + (item["name"]?.string ?? "") + ".")
            return 0
        case "run":
            let item = try find(arguments.first)
            try await transport.run(item["id"]?.string ?? "")
            print("Queued \(item["name"]?.string ?? ""). It starts as soon as the model is free.")
            return 0
        default:
            say("Unknown schedule command: \(sub)\n\n\(commandHelp["schedule"] ?? usage)")
            return 2
        }
    } catch {
        say(describe(error))
        return 1
    }
}

@MainActor func runInboxCommand(_ transport: ServiceTransport) async -> Int32 {
    do {
        let inbox = try await transport.inbox()
        let items = inbox["items"]?.array ?? []
        if let sub = arguments.first, sub == "approve" || sub == "deny" {
            guard arguments.count > 1 else { say("Usage: black-team inbox approve|deny <id>"); return 2 }
            let word = arguments[1]
            let matches = items.filter { $0["state"]?.string == "waiting" && $0["id"]?.string?.hasPrefix(word) == true }
            guard matches.count == 1, let id = matches[0]["id"]?.string else {
                say(matches.isEmpty ? "Nothing waiting matches \"\(word)\"." : "More than one question matches \"\(word)\". Use more of its id.")
                return 1
            }
            try await transport.answer(id, approve: sub == "approve")
            print(sub == "approve" ? "Approved." : "Denied.")
            return 0
        }
        if !arguments.isEmpty { say("Usage: black-team inbox [approve|deny <id>]"); return 2 }
        if asJSON { print(inbox.text(pretty: true)); return 0 }
        let waiting = items.filter { $0["state"]?.string == "waiting" }
        if waiting.isEmpty { print("Nothing is waiting for you.") }
        for item in waiting {
            print("\((item["id"]?.string ?? "").prefix(8))  \(item["scheduleName"]?.string ?? "")  \(item["question"]?.string ?? "")")
            print("    \(item["command"]?.string ?? "")")
            print("    runs out: " + clockText(item["expires"]?.double ?? 0) + "   black-team inbox approve|deny \((item["id"]?.string ?? "").prefix(8))")
        }
        return 0
    } catch {
        say(describe(error))
        return 1
    }
}

// MARK: attaching the other commands

/// `black-team -p "<message>"` for Chat, through the running background service instead of a second engine that could not start the model.
/// Code (it works in the current folder) and pictures need an engine of their own, so they return nil and go the usual way.
@MainActor func runOneShotViaService(_ transport: ServiceTransport, _ options: OneShotOptions) async -> Int32? {
    guard case .remote(let client) = transport, !options.code, options.images.isEmpty, options.workspace == nil else { return nil }
    var message = options.message ?? ""
    if message.isEmpty, !isTerminal(0) {
        message = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !message.isEmpty else { return nil }
    var body: [String: JSONValue] = ["message": .string(message), "kind": "chat", "mode": .string(options.pace), "requestId": .string(UUID().uuidString.lowercased())]
    if let thread = options.thread { body["threadId"] = .string(thread) }
    do {
        let sent = try await client.post("/api/chat", .object(body))
        guard let threadId = sent["threadId"]?.string else { throw BlackTeamError("The background service did not start the reply.") }
        var printed = ""
        var last: JSONValue = .null
        while true {
            let thread = try await client.get("/api/thread/\(threadId)")
            last = thread["messages"]?.array?.last ?? .null
            let content = last["content"]?.string ?? ""
            if !options.json, content.hasPrefix(printed), content.count > printed.count { emit(String(content.dropFirst(printed.count))); printed = content }
            if let state = last["state"]?.string, state != "writing" { break }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        let state = last["state"]?.string ?? "error"
        if options.json {
            var out: [String: JSONValue] = ["threadId": .string(threadId), "state": .string(state), "reply": .string(last["content"]?.string ?? "")]
            if let error = last["error"]?.string { out["error"] = .string(error) }
            print(JSONValue.object(out).text(pretty: true))
        } else if !printed.isEmpty { emit("\n") }
        if state != "done", let error = last["error"]?.string { emitError(error + "\n") }
        return state == "done" ? 0 : 1
    } catch {
        emitError(describe(error) + "\n")
        return 1
    }
}

/// `black-team status` from the running service: the same lines, read from the service\u{2019}s own status.
@MainActor func runStatusViaService(_ transport: ServiceTransport) async -> Int32? {
    guard case .remote(let client) = transport, let status = try? await client.get("/api/status") else { return nil }
    if asJSON { print(status.text(pretty: true)); return 0 }
    let model = status["config"]?["model"]
    print("version: \(status["version"]?.string ?? "")")
    print("setup complete: \(status["setupComplete"]?.bool == true ? "yes" : "no")")
    print("model: \(model?["name"]?.string ?? "") (\(model?["source"]?.string ?? ""))")
    print("runtime: \(status["runtime"]?["state"]?.string ?? "")" + (status["service"]?["unloaded"]?.bool == true ? " (unloaded to free memory; it starts again when needed)" : ""))
    print("saved models: \(status["models"]?.array?.count ?? 0)")
    print("conversations: \(status["threads"]?.array?.count ?? 0)")
    print("served by: the background service (black-team service status)")
    return 0
}
