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
  find                                look for running model servers and model files
  models                              the saved models
  use <key>                           make a saved model the one in use
  chat "<message>" [--thread <id>] [--mode fast|balanced|deep|extended]
  code "<message>" [--workspace <folder>] [--thread <id>] [--mode ...] [--approve once|deny]
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

/// Runs one Chat or Code turn and prints it. Returns the exit status.
@MainActor func runTurn(_ backend: Backend, message: String, kind: String, mode: String, thread: String?, workspace: String?, approve: String) async -> Int32 {
    let sent: SubmitResult
    do { sent = try backend.submit(message: message, kind: kind, mode: mode, requestId: UUID().uuidString.lowercased(), threadId: thread, workspace: workspace) }
    catch { fail(describe(error)) }
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
        if let error = reply?["error"]?.string { FileHandle.standardError.write(Data(("error: " + error + "\n").utf8)) }
    }
    return state == "done" ? 0 : 1
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
            for item in list { print("\(item.active ? "*" : " ") \(item.key)\t\(item.name)\t\(item.source)\t\(item.context) tokens") }
            return 0

        case "use":
            guard !arguments.isEmpty else { fail("Name a model key: black-team-cli models", code: 2) }
            let result = try await backend.switchTo(key: arguments.removeFirst())
            if asJSON { printJSON(["switched": JSONValue.bool(result.switched), "name": JSONValue.string(result.name)]) } else { print("Now using \(result.name).") }
            return 0

        case "chat", "code":
            let thread = option("--thread"), mode = option("--mode") ?? "balanced"
            let workspace = command == "code" ? option("--workspace") : nil
            let approve = option("--approve") ?? "deny"
            guard ["once", "deny"].contains(approve) else { fail("--approve takes once or deny.", code: 2) }
            guard let message = arguments.first, arguments.count == 1 else { fail("Give one message in quotes.\n\n\(usage)", code: 2) }
            return await runTurn(backend, message: message, kind: command == "chat" ? "chat" : "agent", mode: mode, thread: thread, workspace: workspace, approve: approve)

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

let backend: Backend
do { backend = try Backend() } catch { fail(describe(error)) }

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
