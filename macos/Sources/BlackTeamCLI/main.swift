import Foundation
import BlackTeamKit
import BlackTeamTerminal

// black-team: one terminal program for Mac and Linux. With no arguments it starts a session; `-p` sends one message;
// the subcommands (status, chat, code, agent, room, ...) drive the same engine one step at a time.
// The data folder is the app's own (BLACK_TEAM_DATA overrides). Every run ends by shutting the model down.

/// The version of the app this program sits inside (the Mac app's Info.plist, the Linux package's package.json), so the two never
/// disagree; a bare build says "dev".
let programVersion: String = {
    let program = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let plist = program.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    if let data = try? Data(contentsOf: plist),
       let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let version = info["BlackTeamVersion"] as? String, !version.isEmpty { return version }
    // The Linux package: the program is in the app's bin folder, beside the app's package.json.
    let package = program.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
    if let data = try? Data(contentsOf: package), let value = try? JSONValue.parse(data),
       value["name"]?.string?.hasPrefix("black-team") == true, let version = value["version"]?.string, !version.isEmpty { return version }
    return ProcessInfo.processInfo.environment["BLACK_TEAM_VERSION"] ?? "0.1.0-dev"
}()
let rawArguments = Array(CommandLine.arguments.dropFirst())

// The Linux desktop app's engine. Handled first: its --version names the app, it is not a request for ours.
if rawArguments.first == "desktop-service" { exit(await runDesktopService(Array(rawArguments.dropFirst()))) }

// The room's tools for Claude Code and Codex, started by them for one driven run: `black-team mcp-room --run <file>`. It opens no data
// folder and no model; it relays each tool call to the running Black Team over the run's private channel (Room/RoomBridge.swift).
if rawArguments.first == "mcp-room" {
    guard rawArguments.count == 3, rawArguments[1] == "--run" else { fail("Usage: black-team mcp-room --run <file>", code: 2) }
    await RoomMCPServer.runStdio(runFile: rawArguments[2])
    exit(0)
}

if rawArguments.contains("--version") || rawArguments.first == "version" {
    print("black-team \(programVersion)")
    exit(0)
}
if rawArguments.contains("--help") || rawArguments.contains("-h") || rawArguments.first == "help" {
    let topic = rawArguments.first { !$0.hasPrefix("-") && $0 != "help" }
    if OneShotOptions.isOneShot(rawArguments) { print(helpTopicText) }
    else if let topic, let text = commandHelp[topic] { print(text) }
    else if let topic, topic != "help" { fail("There is no command \"\(topic)\".\n\n\(usage)", code: 2) }
    else { print(usage + "\n\n" + helpTopicText) }
    exit(0)
}
if rawArguments.first == "install-command" { exit(runInstallCommand(Array(rawArguments.dropFirst()))) }
_ = blackTeamProgramMarker

let oneShot: OneShotOptions?
if OneShotOptions.isOneShot(rawArguments) {
    do { oneShot = try OneShotOptions.parse(rawArguments) } catch let OneShotOptions.ParseError.message(text) { fail(text, code: 2) }
} else { oneShot = nil }
asJSON = oneShot == nil && arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
if oneShot == nil, let first = arguments.first, !first.hasPrefix("-"), !OneShotOptions.commandNames.contains(first) {
    fail("Unknown command: \(first)\n\n\(usage)", code: 2)
}

let backend: Backend
do { backend = try Backend(version: programVersion, cloud: cloudRulesForThisRun()) } catch { fail(describe(error)) }

Terminal.installSafetyNet()
Interrupts.install(backend)

var phoneOptions = PhoneOptions()
if let web = option("--web") ?? ProcessInfo.processInfo.environment["BLACK_TEAM_WEB"] { phoneOptions.webRoot = web }
backend.configurePhone(phoneOptions)

let status: Int32
if let oneShot {
    status = await runOneShot(backend, oneShot)
} else if arguments.isEmpty {
    status = await Session(backend: backend, interactive: isTerminal(0) && isTerminal(1)).run()
} else {
    status = await run(backend)
}
Terminal.leaveRaw()
await backend.shutdown()
exit(status)
