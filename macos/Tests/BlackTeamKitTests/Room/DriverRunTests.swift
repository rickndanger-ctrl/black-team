import XCTest
@testable import BlackTeamKit

/// What the scripted model does next, from the request it was just sent.
enum Move {
    case say(String)
    case call(String, JSONValue)
}

/// Lets a test hold a scripted model until it says go.
final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    /// Waits until released; throws when the task is cancelled (a Stop).
    func wait() async throws {
        while !isOpen {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Counts requests that are being answered at once, and the most there ever were.
final class Overlap: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0, top = 0
    func enter() { lock.lock(); now += 1; top = max(top, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
    var most: Int { lock.lock(); defer { lock.unlock() }; return top }
}

/// Stands in for Claude Code as a DRIVER: when it "starts" with the room's MCP server on its command line, it calls the room's tools
/// through the real private channel (the same call `black-team mcp-room` makes), then prints its final answer.
final class DrivingLauncher: AgentLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentCommand] = []
    var drive: (@Sendable (_ call: @escaping @Sendable (String, JSONValue) async -> RoomToolReply, _ signal: CancelSignal) async -> String)?
    var usageLine: String?
    func executable(for service: AgentService) -> String? { "/fake/bin/claude" }
    var commands: [AgentCommand] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ command: AgentCommand, timeout: TimeInterval, signal: CancelSignal, onLine: @escaping @Sendable (AgentStream, String) -> Void) async -> AgentExit {
        lock.lock(); recorded.append(command); lock.unlock()
        var answer = "Plain answer."
        if let drive, let runFile = Self.runFile(command) {
            answer = await drive({ name, args in await RoomBridgeClient.call(runFile: runFile, tool: name, arguments: args) }, signal)
        }
        if signal.isCancelled { return AgentExit(status: nil, cancelled: true) }
        onLine(.stdout, JSONValue.object(["type": "system", "subtype": "init", "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"]).text())
        onLine(.stdout, JSONValue.object(["type": "assistant", "message": ["id": "m", "role": "assistant", "content": [["type": "text", "text": .string(answer)]]]]).text())
        var result: [String: JSONValue] = ["type": "result", "subtype": "success", "is_error": false, "result": .string(answer), "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"]
        if let usageLine, let usage = try? JSONValue.parse(usageLine) { result["usage"] = usage }
        onLine(.stdout, JSONValue.object(result).text())
        return AgentExit(status: 0)
    }

    /// The run file named in the `--mcp-config` of a driver's command line.
    static func runFile(_ command: AgentCommand) -> String? {
        guard let at = command.arguments.firstIndex(of: "--mcp-config"), at + 1 < command.arguments.count,
              let config = try? JSONValue.parse(command.arguments[at + 1]), let args = config["mcpServers"]?["blackteam"]?["args"]?.array,
              args.count == 3 else { return nil }
        return args[2].string
    }
}

// A driven run through the real Backend, the real Code engine with a scripted model server, and the room's usual fakes.
final class DriverRunTests: XCTestCase {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."

    struct Rig {
        var fixture: BackendFixture
        var backend: Backend
        var project: ProjectSummary
        var localKey: String
        var cloudKey: String
        var brain: Brain
        var seen: Seen
        var launcher: DrivingLauncher
        var pid: String { project.id }
    }

    /// What the scripted model says. `local` is a Code member on the local model; the cloud one is the driver (or another member).
    final class Brain: @unchecked Sendable {
        private let lock = NSLock()
        private var _decide: @Sendable (_ cloud: Bool, _ body: JSONValue) async throws -> Move = { _, _ in .say("Done.") }
        var decide: @Sendable (Bool, JSONValue) async throws -> Move {
            get { lock.lock(); defer { lock.unlock() }; return _decide }
            set { lock.lock(); _decide = newValue; lock.unlock() }
        }
    }

    func rig(cloudAllowed: Bool = true) async throws -> Rig {
        let fixture = try BackendFixture(self)
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        try vault.write("Core", "# Core\n\n\(vaultCore)\n")
        fixture.memory = vault
        let brain = Brain(), seen = Seen(), launcher = DrivingLauncher()
        let host = self.host
        fixture.reply = { _ in sse("data: [DONE]\n\n") }
        // Every request the Code engine makes goes through here: the driver's to the cloud host, a local member's to the local server.
        let script: HTTPStreamFetch = { request in
            let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
            seen.add(body.setting("cloud", .bool(request.url?.host == host)))
            let step = try await brain.decide(request.url?.host == host, body)
            let usage = request.url?.host == host ? #""usage":{"prompt_tokens":1000,"completion_tokens":100}"# : #""usage":{"prompt_tokens":500,"completion_tokens":50}"#
            switch step {
            case .say(let text):
                let chunk = JSONValue.object(["choices": [["delta": ["content": .string(text)]]]]).text()
                return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\(usage)}\n\ndata: [DONE]\n\n")
            case .call(let name, let args):
                let chunk = JSONValue.object(["choices": [["delta": ["tool_calls": [["index": 0, "id": .string("call-\(UUID().uuidString.prefix(6))"),
                                                                                    "function": ["name": .string(name), "arguments": .string(args.text())]]]]]]]).text()
                return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\(usage)}\n\ndata: [DONE]\n\n")
            }
        }
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, vault: vault, fetch: script, home: fixture.files.dir, useRtk: false)
        try fixture.rewriteConfig { $0.model.context = 65536 }
        let requests = fixture.requests
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.realEngine, memory: vault,
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            stream: { request in requests.add(request); return try await fixture.reply(request) },
            contextPlanner: { messages, context, mode, _, _, _ in
                PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, _ in }, home: fixture.files.dir + "/home", keeperInterval: 3600, agents: launcher)
        backend.bridgeProgramOverride = "/fake/bin/black-team"
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        let project = try backend.createProject(name: "Drive Work")
        if cloudAllowed { _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true) }
        let localKey = try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key
        _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": .string("https://\(host)/v1"), "id": "big-model", "apiKey": .string(secret),
                                                    "name": "Cloud Big", "context": .number(100_000)]])
        let cloudKey = try XCTUnwrap(backend.savedModels.list().first { $0.isCloud }).key
        _ = try await backend.switchTo(key: localKey)
        return Rig(fixture: fixture, backend: backend, project: project, localKey: localKey, cloudKey: cloudKey, brain: brain, seen: seen, launcher: launcher)
    }

    @discardableResult
    func add(_ r: Rig, _ name: String, role: String = "", model: String? = nil, agent: String? = nil, work: String = "code") throws -> RoomMemberView {
        try r.backend.roomAddMember(projectId: r.pid, name: name, role: role, modelKey: model, agent: agent, work: model == nil ? nil : work).members.last!
    }

    func fail(_ body: () async throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected a refusal", file: file, line: line) }
        catch { XCTAssertTrue(messageOf(error).contains(text), "\(messageOf(error)) should contain \(text)", file: file, line: line) }
    }

    func preview(_ r: Rig, goal: String = "Tidy the notes", lead: String? = nil) throws -> TeamPreview {
        try r.backend.roomTeamPreview(projectId: r.pid, goal: goal, leadId: lead, reviewerId: nil, driven: true)
    }

    /// Previews, starts and returns (before the end).
    func start(_ r: Rig, goal: String = "Tidy the notes", lead: String? = nil, from origin: SubmitOrigin = .mac) throws -> TeamRun {
        let p = try preview(r, goal: goal, lead: lead)
        return try r.backend.roomTeamRun(projectId: r.pid, goal: goal, leadId: lead, reviewerId: nil, digest: p.digest, from: origin, driven: true)
    }

    func finish(_ r: Rig) async throws -> TeamRun {
        await r.backend.roomTeamSettle()
        return try XCTUnwrap(try r.backend.room(projectId: r.pid).team)
    }

    func run(_ r: Rig, goal: String = "Tidy the notes", lead: String? = nil) async throws -> TeamRun {
        _ = try start(r, goal: goal, lead: lead)
        return try await finish(r)
    }

    func waitFor(_ what: String, timeout: Double = 15, _ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("timed out waiting for \(what)")
    }

    func toolNames(_ body: JSONValue) -> [String] { (body["tools"]?.array ?? []).compactMap { $0["function"]?["name"]?.string } }
    func lastToolResult(_ body: JSONValue) -> String? { (body["messages"]?.array ?? []).last { $0["role"]?.string == "tool" }?["content"]?.string }

    // MARK: A cloud model drives

    func testCloudModelDriverDelegatesToALocalMemberAndGetsTheResult() async throws {
        let r = try await rig()
        let driver = try add(r, "Cloud Big", role: "lead", model: r.cloudKey)
        let ornith = try add(r, "Ornith", role: "reader", model: r.localKey)
        let tally = Tally()
        r.brain.decide = { cloud, body in
            if cloud {
                switch tally.next() {
                case 1: return .call("team", [:])
                case 2: return .call("delegate", ["member": "Ornith", "task": "List the TODO comments in notes.txt", "files": ["notes.txt"]])
                default: return .say("All done: \(self.lastToolResult(body) ?? "?")")
                }
            }
            return .say("Found 3 TODO comments in notes.txt.")
        }
        let team = try await run(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.mode, "driven"); XCTAssertEqual(team.leadId, driver.id)
        // The driver's brief is the first message, with the goal, and is small.
        let first = r.seen[0]
        let brief = try XCTUnwrap(first["messages"]?.array?.first { $0["role"]?.string == "user" }?["content"]?.string)
        XCTAssertTrue(brief.contains("Tidy the notes") && brief.contains("cost nothing") && brief.contains("Check each result"))
        XCTAssertLessThan(brief.utf16.count, 1500)
        XCTAssertTrue(toolNames(first).contains("team") && toolNames(first).contains("delegate"))
        // `team` told the driver who is there; `delegate` brought back the member's result.
        let second = r.seen[1]
        let teamText = try XCTUnwrap(lastToolResult(second))
        XCTAssertTrue(teamText.contains("Ornith") && teamText.contains("runs on") && teamText.contains("code work") && teamText.contains("speed not measured yet"), teamText)
        XCTAssertTrue(teamText.contains("Delegations left in this run: 12"))
        XCTAssertFalse(teamText.contains("Cloud Big"), "the driver does not list itself")
        let third = r.seen.all.filter { $0["cloud"] == true }[2]
        XCTAssertTrue((lastToolResult(third) ?? "").contains("Result from Ornith (no files changed):\nFound 3 TODO comments in notes.txt."), lastToolResult(third) ?? "")
        // The member got a self-contained job in a NEW conversation, read-only, without memory, on the local model.
        let local = try XCTUnwrap(r.seen.all.first { $0["cloud"] == false })
        let ask = try XCTUnwrap(local["messages"]?.array?.last { $0["role"]?.string == "user" }?["content"]?.string)
        XCTAssertTrue(ask.contains("List the TODO comments in notes.txt") && ask.contains("- notes.txt") && ask.contains("read-only"))
        XCTAssertEqual(toolNames(local).sorted(), toolNames(local).filter { !["edit", "write", "run", "publish"].contains($0) }.sorted())
        XCTAssertFalse(toolNames(local).contains("edit") || toolNames(local).contains("run"), "a read-only job gets no tool that changes files")
        XCTAssertFalse(String(describing: local).contains("rare coins"), "the vault stays out of a run with a cloud member")
        // The board and the log show it like any task.
        let state = try r.backend.room(projectId: r.pid)
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.tasks[0].assignee, ornith.id); XCTAssertEqual(state.tasks[0].status, .done)
        XCTAssertEqual(state.tasks[0].result, "Found 3 TODO comments in notes.txt.")
        XCTAssertTrue(state.notes.contains { $0.text.contains("Ornith started") } && state.notes.contains { $0.text.contains("accepted") })
        XCTAssertEqual(r.backend.threads().count, 2, "the driver's conversation and the member's own")
        let memberThread = try XCTUnwrap(r.backend.history.get(try XCTUnwrap(state.tasks[0].threadId)))
        XCTAssertEqual(memberThread["noMemory"]?.bool, true); XCTAssertEqual(memberThread["readOnly"]?.bool, true)
        XCTAssertTrue(team.log.contains { $0.kind == "delegate" && $0.text.contains("gave Ornith") } && team.log.contains { $0.kind == "delegate" && $0.text.contains("Ornith finished") })
        let d = try XCTUnwrap(team.delegations?.first)
        XCTAssertEqual(d.status, .done); XCTAssertEqual(d.memberName, "Ornith"); XCTAssertFalse(d.write); XCTAssertFalse(d.paid)
        XCTAssertEqual(d.promptTokens, 500); XCTAssertEqual(d.completionTokens, 50)
        // The ledger: real numbers from the usage each side reported, grouped paid and local.
        let ledger = try XCTUnwrap(team.ledger)
        XCTAssertEqual(ledger.localTokens, 550); XCTAssertEqual(ledger.paidTokens, 3300)
        XCTAssertEqual(ledger.summary, "Local agents did 550 tokens of work; paid agents used 3,300.")
        XCTAssertEqual(ledger.lines.map(\.name), ["Cloud Big", "Ornith"]); XCTAssertEqual(ledger.lines.map(\.paid), [true, false])
        XCTAssertTrue(team.report.hasPrefix("All done: Result from Ornith") && team.report.hasSuffix(ledger.summary))
        XCTAssertEqual(team.runs, 1)
        XCTAssertFalse(r.backend.isBusy)
        // The run's files are gone and the selected model is what it was.
        XCTAssertEqual(keyOf(try r.backend.configStore.read().model), r.localKey)
        // The state round-trips through the room file.
        let again = try XCTUnwrap(try r.backend.room(projectId: r.pid).team)
        XCTAssertEqual(again.delegations, team.delegations); XCTAssertEqual(again.ledger, team.ledger)
    }

    func testDriverMayAskForChangesAndAChatMemberCannotBeToldToChangeFiles() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        try add(r, "Talker", model: r.localKey, work: "chat")
        let tally = Tally()
        let refusal = Seen()
        r.brain.decide = { cloud, body in
            guard cloud else { return .say("Edited it.") }
            switch tally.next() {
            case 1: return .call("delegate", ["member": "Talker", "task": "Fix notes.txt", "may_change_files": true])
            case 2: refusal.add(["text": .string(self.lastToolResult(body) ?? "")]); return .call("delegate", ["member": "Ornith", "task": "Fix notes.txt", "may_change_files": true])
            default: return .say("ok")
            }
        }
        let team = try await run(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertTrue(refusal[0]["text"]?.string?.contains("does chat work and cannot change files") == true)
        let local = try XCTUnwrap(r.seen.all.first { $0["cloud"] == false })
        XCTAssertTrue(toolNames(local).contains("edit") && toolNames(local).contains("write"))
        XCTAssertEqual(team.delegations?.count, 1); XCTAssertEqual(team.delegations?.first?.write, true)
    }

    func testUnknownMemberAndBadFilesAreExplainedToTheDriver() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        let tally = Tally()
        let said = Seen()
        r.brain.decide = { cloud, body in
            guard cloud else { return .say("never") }
            if tally.value > 0 { said.add(["text": .string(self.lastToolResult(body) ?? "")]) }
            switch tally.next() {
            case 1: return .call("delegate", ["member": "Nobody", "task": "x"])
            case 2: return .call("delegate", ["member": "Ornith", "task": "x", "files": ["../secret"]])
            case 3: return .call("delegate", ["member": "Ornith"])
            default: return .say("gave up")
            }
        }
        let team = try await run(r)
        XCTAssertEqual(team.phase, .done)
        XCTAssertTrue(said[0]["text"]?.string?.contains("No member called") == true)
        XCTAssertTrue(said[1]["text"]?.string?.contains("path inside the project folder") == true)
        XCTAssertTrue(said[2]["text"]?.string?.contains("needs a member and a task") == true)
        XCTAssertEqual(team.delegations?.count ?? 0, 0)
        XCTAssertEqual(try r.backend.room(projectId: r.pid).tasks.count, 0)
    }

    // MARK: Caps

    func testDelegationCapAndPaidTokenCap() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        r.backend.driveCapsOverride = DriveCaps(delegations: 1, minutes: 60, paidTokens: 1_000_000)
        let tally = Tally(), said = Seen()
        r.brain.decide = { cloud, body in
            guard cloud else { return .say("ok") }
            if tally.value > 0 { said.add(["text": .string(self.lastToolResult(body) ?? "")]) }
            switch tally.next() {
            case 1, 2: return .call("delegate", ["member": "Ornith", "task": .string("job \(tally.value)")])
            default: return .say("stopped delegating")
            }
        }
        let team = try await run(r)
        XCTAssertEqual(team.phase, .done)
        XCTAssertEqual(team.delegations?.count, 1)
        XCTAssertTrue(said[1]["text"]?.string?.contains("used its 1 delegations") == true, said[1]["text"]?.string ?? "")
        XCTAssertEqual(team.runs, 1, "a refused delegation is not a member run")

        // The paid-token cap: the driver's own usage (1,100 a request) passes it while it waits for a member.
        let q = try await rig()
        try add(q, "Cloud Big", model: q.cloudKey)
        try add(q, "Ornith", model: q.localKey)
        q.backend.driveCapsOverride = DriveCaps(delegations: 12, minutes: 60, paidTokens: 500)
        let hold = Hold(), cloudCalls = Tally()
        q.brain.decide = { cloud, _ in
            if cloud { return cloudCalls.next() == 1 ? .call("delegate", ["member": "Ornith", "task": "slow"]) : .say("late") }
            try await hold.wait()
            return .say("never")
        }
        let capped = try await run(q)
        XCTAssertEqual(capped.phase, .stopped)
        XCTAssertTrue(capped.message.contains("paid-token cap"), capped.message)
        XCTAssertEqual(capped.delegations?.count ?? 0, 0, "a delegation past the cap is refused before it is put on the board")
        XCTAssertFalse(q.backend.isBusy)
    }

    // MARK: Stop

    func testStopEndsTheDriverAndEverythingBeneathIt() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        let hold = Hold(), tally = Tally()
        r.brain.decide = { cloud, _ in
            if cloud { return tally.next() == 1 ? .call("delegate", ["member": "Ornith", "task": "a long job"]) : .say("never") }
            try await hold.wait()
            return .say("never")
        }
        _ = try start(r)
        try await waitFor("the delegation to run") { try r.backend.room(projectId: r.pid).team?.delegations?.first?.status == .running && r.backend.drivers.scope(try XCTUnwrap(r.backend.room(projectId: r.pid).team?.id))?.running.isEmpty == false }
        XCTAssertTrue(r.backend.isBusy)
        _ = try r.backend.roomTeamStop(projectId: r.pid)
        let team = try await finish(r)
        XCTAssertEqual(team.phase, .stopped); XCTAssertEqual(team.message, "Stopped by you.")
        XCTAssertEqual(team.delegations?.first?.status, .stopped)
        XCTAssertFalse(r.backend.isBusy)
        XCTAssertTrue(r.backend.drivers.child("x") == nil)
        let task = try XCTUnwrap(try r.backend.room(projectId: r.pid).tasks.first)
        XCTAssertNotEqual(task.status, .doing, "the member's task is settled, not left running")
        XCTAssertNotNil(team.ledger)
    }

    func testStoppingTheDriversOwnJobStopsTheMembersToo() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        let hold = Hold(), tally = Tally()
        r.brain.decide = { cloud, _ in
            if cloud { return tally.next() == 1 ? .call("delegate", ["member": "Ornith", "task": "a long job"]) : .say("never") }
            try await hold.wait()
            return .say("never")
        }
        _ = try start(r)
        try await waitFor("the delegation to run") { try r.backend.room(projectId: r.pid).team?.delegations?.first?.status == .running && r.backend.drivers.scope(try XCTUnwrap(r.backend.room(projectId: r.pid).team?.id))?.running.isEmpty == false }
        r.backend.cancel()
        let team = try await finish(r)
        XCTAssertTrue(team.phase == .stopped || team.phase == .failed, "\(team.phase)")
        XCTAssertFalse(r.backend.isBusy)
        XCTAssertEqual(team.delegations?.first?.status, .stopped)
    }

    // MARK: Subscription agent as the driver (the real private channel)

    func testAgentDriverUsesTheRoomsMCPServerAndQueuesLocalMembers() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", role: "lead", agent: "claude-code")
        try add(r, "Ornith", role: "reader", model: r.localKey)
        try add(r, "Nemo", role: "writer", model: r.localKey)
        let cloud = try add(r, "Cloud Big", role: "checker", model: r.cloudKey)
        let hold = Hold(), overlap = Overlap(), localCalls = Tally()
        r.brain.decide = { isCloud, _ in
            if isCloud { return .say("Cloud checked it.") }
            overlap.enter(); defer { overlap.leave() }
            if localCalls.next() == 1 { try await hold.wait() }
            return .say("Local did \(localCalls.value).")
        }
        let observed = Seen()
        r.launcher.usageLine = #"{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":300,"output_tokens":40}"#
        r.launcher.drive = { call, _ in
            // Two local jobs and one paid job at once, as an agent may call tools in parallel.
            async let a = call("delegate", ["member": "Ornith", "task": "Read all of notes.txt"])
            async let b = call("delegate", ["member": "Nemo", "task": "Summarise todo.md"])
            async let c = call("delegate", ["member": "Cloud Big", "task": "Check the summary"])
            // The paid member finishes while the first local job is held and the second is queued behind it.
            while true {
                let state = try? r.backend.room(projectId: r.pid).team?.delegations ?? []
                if let state, state.contains(where: { $0.memberName == "Cloud Big" && $0.status == .done }) {
                    observed.add(["statuses": .array(state.map { .string("\($0.memberName):\($0.status.rawValue)") })]); break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            hold.release()
            let results = await [a, b, c]
            return results.map(\.text).joined(separator: " | ")
        }
        let team = try await run(r, lead: claude.id)
        XCTAssertEqual(team.phase, .done, team.message)
        // The agent was launched with the room's server for this launch only, and with the two tools allowed by name.
        let args = try XCTUnwrap(r.launcher.commands.first).arguments
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let config = try JSONValue.parse(args[try XCTUnwrap(args.firstIndex(of: "--mcp-config")) + 1])
        XCTAssertEqual(config["mcpServers"]?["blackteam"]?["command"]?.string, "/fake/bin/black-team")
        XCTAssertEqual(config["mcpServers"]?["blackteam"]?["args"]?.array?.first?.string, "mcp-room")
        let allowed = Array(args[(try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1)...].prefix(2))
        XCTAssertEqual(allowed, ["mcp__blackteam__team", "mcp__blackteam__delegate"])
        XCTAssertEqual(r.launcher.commands[0].environment["MCP_TOOL_TIMEOUT"], "3600000")
        // A paid member ran while a local one was held; the second local member waited its turn; local runs never overlapped.
        let statuses = observed[0]["statuses"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(statuses.contains("Cloud Big:done") && statuses.filter { $0.hasSuffix(":running") }.count == 1 && statuses.filter { $0.hasSuffix(":queued") }.count == 1, "\(statuses)")
        XCTAssertEqual(overlap.most, 1)
        XCTAssertEqual(team.delegations?.count, 3); XCTAssertTrue(team.delegations?.allSatisfy { $0.status == .done } == true)
        XCTAssertTrue(team.report.contains("Local did 1.") && team.report.contains("Local did 2.") && team.report.contains("Cloud checked it."))
        // The agent's own usage is read from its result line: 10 + 20 + 300 read, 40 written.
        let ledger = try XCTUnwrap(team.ledger)
        let driverLine = try XCTUnwrap(ledger.lines.first { $0.name == "Claude Code" })
        XCTAssertEqual(driverLine.prompt, 330); XCTAssertEqual(driverLine.completion, 40); XCTAssertTrue(driverLine.paid)
        XCTAssertEqual(ledger.lines.first { $0.name == "Ornith" }?.completion, 50)
        XCTAssertEqual(ledger.lines.first { $0.name == "Cloud Big" }?.paid, true)
        XCTAssertEqual(ledger.localTokens, 1100); XCTAssertEqual(ledger.paidTokens, 370 + 1100)
        XCTAssertEqual(ledger.summary, "Local agents did 1,100 tokens of work; paid agents used 1,470.")
        // The channel is closed and its files are gone when the run ends.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: r.fixture.stateDir + "/room-runs")) ?? []
        XCTAssertEqual(leftovers, [])
        XCTAssertFalse(r.backend.isBusy)
        _ = cloud
    }

    func testAgentDriverWithoutUsageFiguresIsLedgeredAsNotMeasured() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", agent: "claude-code")
        try add(r, "Ornith", model: r.localKey)
        r.brain.decide = { _, _ in .say("fine") }
        r.launcher.drive = { call, _ in (await call("delegate", ["member": "Ornith", "task": "x"])).text }
        let team = try await run(r, lead: claude.id)
        let ledger = try XCTUnwrap(team.ledger)
        XCTAssertEqual(ledger.notMeasured, ["Claude Code"])
        XCTAssertNil(ledger.lines[0].prompt); XCTAssertFalse(ledger.lines[0].measured)
        XCTAssertEqual(ledger.paidTokens, 0)
        XCTAssertTrue(ledger.summary.contains("Not measured: Claude Code"))
    }

    func testTheChannelRefusesAWrongSecretAndAnEndedRun() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", agent: "claude-code")
        try add(r, "Ornith", model: r.localKey)
        let kept = Seen()
        r.launcher.drive = { call, _ in
            let runFile = DrivingLauncher.runFile(r.launcher.commands[0])!
            let data = try! Data(contentsOf: URL(fileURLWithPath: runFile))
            let file = try! JSONValue.parse(data)
            kept.add(file)
            // A made-up secret is turned away.
            let forged = runFile + ".forged"
            try! JSONValue.object(["socket": file["socket"]!, "secret": .string("0000")]).text().write(toFile: forged, atomically: true, encoding: .utf8)
            let denied = await RoomBridgeClient.call(runFile: forged, tool: "team", arguments: [:])
            XCTAssertTrue(denied.isError && denied.text == "Not allowed.", denied.text)
            let perms = (try? FileManager.default.attributesOfItem(atPath: runFile)[.posixPermissions] as? Int) ?? 0
            XCTAssertEqual(perms, 0o600)
            try? FileManager.default.removeItem(atPath: forged)
            return (await call("team", [:])).text
        }
        let team = try await run(r, lead: claude.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertTrue(team.report.contains("Ornith"))
        // After the run, the same run file finds nothing.
        let later = await RoomBridgeClient.call(runFile: DrivingLauncher.runFile(r.launcher.commands[0])!, tool: "team", arguments: [:])
        XCTAssertTrue(later.isError && later.text.contains("no longer running"))
    }

    // MARK: The agreement and the refusals

    func testDrivenAgreementNamesTheDestinationAndEveryRuleStillHolds() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", role: "lead", agent: "claude-code")
        try add(r, "Ornith", role: "reader", model: r.localKey)
        try add(r, "Cloud Big", role: "checker", model: r.cloudKey)
        let p = try preview(r)
        XCTAssertEqual(p.mode, "driven"); XCTAssertEqual(p.leadId, claude.id); XCTAssertNil(p.reviewerId)
        XCTAssertEqual(p.caps, DriveCaps.standard)
        XCTAssertTrue(p.leavesThisMac); XCTAssertFalse(p.memoryUsed)
        XCTAssertTrue(p.agreement.hasPrefix("Driven run. Claude Code is a paid member and drives"), p.agreement)
        XCTAssertTrue(p.agreement.contains("What Ornith reads, writes and answers for those pieces is sent back to Claude Code, so it goes to anthropic.com."), p.agreement)
        XCTAssertTrue(p.agreement.contains("Cloud Big is also paid") && p.agreement.contains(host) && p.agreement.contains("Your memory is not used in this run."))
        XCTAssertTrue(p.agreement.contains("up to 12 hand-offs, 60 minutes and 400,000 tokens"))
        // The pipeline preview of the same room is what it always was.
        let old = try r.backend.roomTeamPreview(projectId: r.pid, goal: "Tidy the notes")
        XCTAssertNil(old.mode); XCTAssertNil(old.caps)
        XCTAssertTrue(old.agreement.hasPrefix("This run shares your goal and each member's results"))
        XCTAssertNotEqual(old.digest, p.digest, "a digest of one mode does not start the other")
        // canDrive tells the screens who may lead a driven run.
        let views = try r.backend.room(projectId: r.pid).members
        XCTAssertEqual(views.map { $0.canDrive }, [true, false, true])
        XCTAssertTrue(r.backend.roomCanDrive(projectId: r.pid, leadId: claude.id))
        XCTAssertFalse(r.backend.roomCanDrive(projectId: r.pid, leadId: views[1].id))
    }

    func testRefusals() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", agent: "claude-code")
        let ornith = try add(r, "Ornith", model: r.localKey)
        let p = try preview(r)
        // A phone never starts a run with a paid member.
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Tidy the notes", leadId: nil, reviewerId: nil, digest: p.digest, from: .phone, driven: true) },
                   contains: "decision made at")
        // The digest must match the room and the mode.
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Another goal", leadId: nil, reviewerId: nil, digest: p.digest, from: .mac, driven: true) },
                   contains: "has changed since you reviewed")
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Tidy the notes", leadId: nil, reviewerId: nil, digest: p.digest, from: .mac, driven: false) },
                   contains: "has changed since you reviewed")
        // A local lead cannot drive; a lead alone has nobody to hand work to.
        await fail({ _ = try self.preview(r, lead: ornith.id) }, contains: "cannot drive a run")
        let alone = try await rig()
        try add(alone, "Claude Code", agent: "claude-code")
        await fail({ _ = try self.preview(alone) }, contains: "at least one other member")
        // A project that does not allow cloud models refuses a paid driver.
        let local = try await rig(cloudAllowed: false)
        try add(local, "Claude Code", agent: "claude-code")
        try add(local, "Ornith", model: local.localKey)
        let lp = try preview(local)
        await fail({ _ = try local.backend.roomTeamRun(projectId: local.pid, goal: "Tidy the notes", leadId: nil, reviewerId: nil, digest: lp.digest, from: .mac, driven: true) },
                   contains: "local only")
        XCTAssertFalse(r.backend.isBusy); XCTAssertEqual(r.launcher.commands.count, 0, "nothing was started")
        _ = claude
    }

    func testOnlyOneRunAtATimeStillHolds() async throws {
        let r = try await rig()
        try add(r, "Cloud Big", model: r.cloudKey)
        try add(r, "Ornith", model: r.localKey)
        let hold = Hold()
        r.brain.decide = { cloud, _ in if cloud { try await hold.wait() }; return .say("done") }
        _ = try start(r)
        try await waitFor("the driver to start") { r.backend.isBusy }
        await fail({ _ = try self.start(r) }, contains: "already going")
        await fail({ _ = try await r.backend.roomStart(projectId: r.pid, taskId: newID()) }, contains: "A response is already running")
        hold.release()
        let team = try await finish(r)
        XCTAssertEqual(team.phase, .done)
    }
}
