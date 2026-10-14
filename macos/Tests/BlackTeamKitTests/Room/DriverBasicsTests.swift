import XCTest
@testable import BlackTeamKit

// The parts of a driven run that need no Backend: the MCP server, the ledger, the command lines, the gate and the roster.
final class DriverBasicsTests: XCTestCase {
    // MARK: MCP, spoken by a plain JSON-RPC client

    func server(_ calls: Seen? = nil) -> RoomMCPServer {
        RoomMCPServer { name, args in
            calls?.add(["name": .string(name), "arguments": args])
            return RoomToolReply(name == "team" ? "- Ornith: local" : "Result from Ornith", isError: false)
        }
    }

    /// The reply, or .null when the server sends none.
    func ask(_ s: RoomMCPServer, _ object: JSONValue) async throws -> JSONValue {
        guard let line = await s.handle(object.text()) else { return .null }
        return try JSONValue.parse(line)
    }

    func testHandshakeListAndCalls() async throws {
        let calls = Seen()
        let s = server(calls)
        let hello = try await (ask(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]))
        XCTAssertEqual(hello["id"], 1); XCTAssertEqual(hello["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertNotNil(hello["result"]?["capabilities"]?["tools"]); XCTAssertEqual(hello["result"]?["serverInfo"]?["name"], "black-team-room")
        let none = try await ask(s, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(none, .null, "a notification gets no answer")
        let pong = try await (ask(s, ["jsonrpc": "2.0", "id": "p", "method": "ping"]))
        XCTAssertEqual(pong["id"], "p"); XCTAssertNotNil(pong["result"])
        let list = try await (ask(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["team", "delegate"])
        XCTAssertEqual(tools[1]["inputSchema"]?["required"]?.array?.compactMap(\.string), ["member", "task"])
        XCTAssertNotNil(tools[1]["inputSchema"]?["properties"]?["may_change_files"])
        let team = try await (ask(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "team", "arguments": [:]]]))
        XCTAssertEqual(team["result"]?["content"]?[0]?["text"], "- Ornith: local"); XCTAssertEqual(team["result"]?["isError"], false)
        let delegate = try await (ask(s, ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                                   "params": ["name": "delegate", "arguments": ["member": "Ornith", "task": "x"]]]))
        XCTAssertEqual(delegate["result"]?["content"]?[0]?["type"], "text")
        XCTAssertEqual(calls[1]["arguments"]?["member"], "Ornith")
        // Mistakes are answered, not fatal.
        let unknown = try await (ask(s, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm", "arguments": [:]]]))
        XCTAssertEqual(unknown["result"]?["isError"], true)
        let method = try await (ask(s, ["jsonrpc": "2.0", "id": 6, "method": "nope"]))
        XCTAssertEqual(method["error"]?["code"], -32601)
        let garbage = await s.handle("{not json")
        XCTAssertEqual((try JSONValue.parse(try XCTUnwrap(garbage)))["error"]?["code"], -32700)
        XCTAssertEqual(calls.count, 2)
    }

    func testServesLinesFromAPipeAndSaysWhenTheRoomIsGone() async throws {
        let input = Pipe(), output = Pipe()
        let run = Task { await RoomMCPServer.runStdio(runFile: "/nonexistent/run.json", input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        for object: JSONValue in [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
                                  ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "team", "arguments": [:]]]] {
            input.fileHandleForWriting.write(Data((object.text() + "\n").utf8))
        }
        input.fileHandleForWriting.closeFile()
        await run.value
        output.fileHandleForWriting.closeFile()
        let rows = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        XCTAssertEqual(rows.count, 2)
        let call = try XCTUnwrap(rows.first { $0["id"] == 2 })
        XCTAssertEqual(call["result"]?["isError"], true)
        XCTAssertTrue(call["result"]?["content"]?[0]?["text"]?.string?.contains("no longer running") == true)
    }

    // MARK: Command lines

    func testClaudeGetsTheServerForOneLaunchOnly() {
        let plain = AgentTools.arguments(service: .claudeCode, task: "t", session: nil, workspace: "/w")
        XCTAssertEqual(plain.last, "{\"mcpServers\":{}}")
        XCTAssertFalse(plain.contains("--allowedTools"))
        let room = AgentTools.arguments(service: .claudeCode, task: "t", session: nil, workspace: "/w", permission: .ask, room: ("/bin/black-team", "/d/room-runs/a.json"))
        let config = try! JSONValue.parse(room[room.firstIndex(of: "--mcp-config")! + 1])
        XCTAssertEqual(config["mcpServers"]?["blackteam"]?["command"], "/bin/black-team")
        XCTAssertEqual(config["mcpServers"]?["blackteam"]?["args"]?.array?.compactMap(\.string), ["mcp-room", "--run", "/d/room-runs/a.json"])
        XCTAssertTrue(room.contains("--strict-mcp-config"))
        XCTAssertEqual(room[room.firstIndex(of: "--allowedTools")! + 1], "mcp__blackteam__team")
        XCTAssertEqual(room[room.firstIndex(of: "--allowedTools")! + 2], "mcp__blackteam__delegate")
        XCTAssertEqual(room[room.firstIndex(of: "--permission-mode")! + 1], "manual")
        XCTAssertFalse(room.joined().contains("secret"), "no secret is on the command line")
    }

    func testCodexGetsTheServerAsOverridesForOneLaunch() {
        let room = AgentTools.arguments(service: .codex, task: "do it", session: nil, workspace: "/w", room: ("/bin/black-team", "/d/a.json"))
        XCTAssertTrue(room.contains("mcp_servers.blackteam.command=\"/bin/black-team\""))
        XCTAssertTrue(room.contains("mcp_servers.blackteam.args=[\"mcp-room\",\"--run\",\"/d/a.json\"]"))
        XCTAssertTrue(room.contains("mcp_servers.blackteam.tool_timeout_sec=3600"))
        XCTAssertEqual(room.last, "do it")
        let resumed = AgentTools.arguments(service: .codex, task: "go on", session: "abc", workspace: "/w", room: ("/bin/black-team", "/d/a.json"))
        XCTAssertTrue(resumed.contains("mcp_servers.blackteam.command=\"/bin/black-team\"") && resumed.last == "go on")
        XCTAssertFalse(AgentTools.arguments(service: .codex, task: "x", session: nil, workspace: "/w").joined().contains("mcp_servers"))
    }

    // MARK: Ledger and usage

    func testLedgerArithmeticAndNotMeasured() {
        let ledger = RunLedger(lines: [
            LedgerLine(name: "Claude Code", role: "driver", paid: true, prompt: 8000, completion: 1800, seconds: 90, runs: 1),
            LedgerLine(name: "Ornith", role: "reader", paid: false, prompt: 40000, completion: 1200, seconds: 600, runs: 3),
            LedgerLine(name: "Nemo", role: "", paid: false, prompt: nil, completion: nil, seconds: 5, runs: 1),
        ])
        XCTAssertEqual(ledger.paidTokens, 9800); XCTAssertEqual(ledger.localTokens, 41200)
        XCTAssertEqual(ledger.notMeasured, ["Nemo"])
        XCTAssertTrue(ledger.summary.hasPrefix("Local agents did 41,200 tokens of work; paid agents used 9,800."))
        XCTAssertTrue(ledger.summary.contains("Not measured: Nemo"))
        let json = JSONValue.encoded(ledger)
        XCTAssertEqual(json["lines"]?[2]?["measured"], false); XCTAssertEqual(json["lines"]?[2]?["prompt"], .null)
        XCTAssertEqual(DriveStore.ledger(json)?.summary, ledger.summary, "what is saved reads back the same")
    }

    func testUsageIsReadFromTheToolsOwnFigures() {
        let claude = #"{"type":"result","subtype":"success","result":"x","usage":{"input_tokens":3,"cache_creation_input_tokens":7,"cache_read_input_tokens":90,"output_tokens":12}}"#
        XCTAssertEqual(AgentUsage.parse(claude, service: .claudeCode), CloudUsage(prompt: 100, completion: 12, cached: 90))
        let codex = #"{"type":"turn.completed","usage":{"input_tokens":95691,"cached_input_tokens":73088,"output_tokens":442}}"#
        XCTAssertEqual(AgentUsage.parse(codex, service: .codex), CloudUsage(prompt: 95691, completion: 442, cached: 73088))
        XCTAssertNil(AgentUsage.parse(#"{"type":"assistant"}"#, service: .claudeCode))
        XCTAssertNil(AgentUsage.parse("not json", service: .codex))
        let turn = AgentTurn(service: .codex)
        turn.ingest(.stdout, codex); turn.ingest(.stdout, codex)
        XCTAssertEqual(turn.usage?.completion, 884)
        XCTAssertNil(AgentTurn(service: .claudeCode).usage)
    }

    func testBriefIsShort() {
        let brief = RoomTools.brief(goal: "Fix it", driver: "Claude Code")
        XCTAssertLessThan(brief.utf16.count, 1400)
        XCTAssertTrue(brief.contains("cost nothing") && brief.contains("exact files") && brief.contains("Check each result") && brief.contains("Do not redo"))
        XCTAssertTrue(brief.hasSuffix("Fix it"))
    }

    // MARK: Gate

    func testGateRunsOneAtATimePrefersTheLoadedModelAndClosesOnStop() async {
        let gate = FairGate(last: "B")
        let order = Seen()
        let first = await gate.acquire("A"); XCTAssertTrue(first)
        // Each waiter joins the queue before the next is started: tasks started together may arrive in any order.
        var waiters: [Task<Bool, Never>] = []
        for (name, key) in [("A2", "A"), ("B1", "B"), ("A3", "A")] {
            waiters.append(Task { let ok = await gate.acquire(key); order.add(["n": .string(name), "ok": .bool(ok)]); if ok { gate.release(key) }; return ok })
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        gate.release("A")                                  // the first holder was model A, so A's waiters go first, in order
        for w in waiters { _ = await w.value }
        XCTAssertEqual(order.all.compactMap { $0["n"]?.string }, ["A2", "A3", "B1"])
        // Closing turns away anybody waiting.
        let closed = FairGate()
        let held = await closed.acquire("A"); XCTAssertTrue(held)
        let late = Task { await closed.acquire("A") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        closed.close()
        let admitted = await late.value
        XCTAssertFalse(admitted)
    }
}

// MARK: Roster

final class RosterTests: XCTestCase {
    let secret = "sk-roster-test-key-1234567890abcdef"

    func rig() async throws -> (BackendFixture, Backend, ProjectSummary, ProjectSummary, String, String) {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let a = try backend.createProject(name: "First"), b = try backend.createProject(name: "Second")
        let local = try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key
        _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": "https://api.cloud-test.com/v1", "id": "big", "apiKey": .string(secret), "name": "Cloud Big",
                                                    "context": .number(100_000)]])
        let cloud = try XCTUnwrap(backend.savedModels.list().first { $0.isCloud }).key
        return (fixture, backend, a, b, local, cloud)
    }

    func testCreateAddToAnyRoomSaveAMemberAndHoldNoSecrets() async throws {
        let (fixture, backend, a, b, local, cloud) = try await rig()
        XCTAssertEqual(backend.roster().count, 0)
        _ = try backend.rosterCreate(name: "Ornith", role: "reader", modelKey: local, work: "code")
        _ = try backend.rosterCreate(name: "Cloud Big", role: "lead", modelKey: cloud, work: "code")
        let list = try backend.rosterCreate(name: "Claude Code", agent: "claude-code", permission: "ask")
        XCTAssertEqual(list.map(\.entry.name), ["Ornith", "Cloud Big", "Claude Code"])
        XCTAssertEqual(list.map(\.kind), ["local", "cloud", "cloud"]); XCTAssertEqual(list[1].provider, "api.cloud-test.com")
        XCTAssertEqual(list[2].entry.permission, "ask")
        // One step adds it to a project; the room's member is its own copy.
        let one = try backend.roomAddFromRoster(projectId: a.id, rosterId: list[0].entry.id)
        _ = try backend.roomAddFromRoster(projectId: b.id, rosterId: list[0].entry.id)
        XCTAssertEqual(one.members.map(\.name), ["Ornith"]); XCTAssertEqual(one.members[0].role, "reader"); XCTAssertEqual(one.members[0].modelKey, local)
        XCTAssertNotEqual(one.members[0].id, list[0].entry.id)
        // A room member can be saved.
        let agent = try backend.roomAddMember(projectId: a.id, name: "Codex", agent: "codex", permission: "auto").members.last!
        let saved = try backend.roomSaveToRoster(projectId: a.id, memberId: agent.id)
        XCTAssertEqual(saved.last?.entry.agent, "codex"); XCTAssertEqual(saved.last?.entry.permission, "auto")
        // No secret anywhere in the roster file, which is private.
        let path = fixture.stateDir + "/roster.json"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains(secret) || text.contains("apiKey") || text.contains("sk-"))
        XCTAssertTrue(text.contains(cloud))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int), 0o600)
        // A model that left the list is shown as unusable, and removing works.
        _ = try await backend.switchTo(key: local)
        try await backend.forget(key: cloud)
        XCTAssertEqual(backend.roster().first { $0.entry.name == "Cloud Big" }?.usable, false)
        XCTAssertEqual(try backend.rosterRemove(id: list[1].entry.id).map(\.entry.name), ["Ornith", "Claude Code", "Codex"])
        // Mistakes are explained.
        do { _ = try backend.rosterCreate(name: "  "); XCTFail() } catch { XCTAssertTrue(messageOf(error).contains("name")) }
        do { _ = try backend.rosterCreate(name: "x", modelKey: local, agent: "codex"); XCTFail() } catch { XCTAssertTrue(messageOf(error).contains("not both")) }
        do { _ = try backend.rosterCreate(name: "x", modelKey: "nope"); XCTFail() } catch { XCTAssertTrue(messageOf(error).contains("not in your list")) }
        do { _ = try backend.roomAddFromRoster(projectId: a.id, rosterId: newID()); XCTFail() } catch { XCTAssertTrue(messageOf(error).contains("not in the roster")) }
        // A damaged file is an empty roster.
        try "{ broken".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(backend.roster().count, 0)
    }
}
