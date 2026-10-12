import Foundation
import BlackTeamKit
import BlackTeamTerminal

// black-team: one terminal program for Mac and Linux. With no arguments it starts a session; `-p` sends one message;
// the subcommands (status, chat, code, agent, room, ...) drive the same engine one step at a time.
// The data folder is the app's own (BLACK_TEAM_DATA overrides). Every run ends by shutting the model down.

let programVersion = "0.1.0-alpha.1"
let rawArguments = Array(CommandLine.arguments.dropFirst())

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
