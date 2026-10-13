import XCTest
@testable import BlackTeamKit

// Subscription agents (Claude Code, Codex) through the Backend, with a fake launcher: nothing real starts.
final class BackendAgentRunTests: XCTestCase {
    /// A backend whose agent launcher is `agents`. The fixture's model, runtime and network are the usual fakes.
    func make(_ fixture: BackendFixture, agents: FakeAgentLauncher) throws -> Backend {
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine, memory: nil,
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            stream: { _ in throw URLError(.cannotConnectToHost) },
            contextPlanner: nil, discover: { noTools }, terminal: { _, _ in }, home: fixture.files.dir + "/home",
            keeperInterval: 3600, agents: agents)
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        return backend
    }

    /// A project whose folder may use cloud models, so a subscription agent may run in it.
    func openProject(_ backend: Backend, name: String = "Agent Work") throws -> ProjectSummary {
        let project = try backend.createProject(name: name)
        _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true)
        return project
    }

    func agentRun(_ backend: Backend, service: AgentService, _ text: String, thread: String? = nil, project: String? = nil,
                  from origin: SubmitOrigin = .mac) async throws -> SubmitResult {
        let result = try backend.submitAgentTask(service: service, message: text, requestId: newID(), threadId: thread, project: project, from: origin)
        await backend.waitForIdle()
        return result
    }

    func testNewConversationSavesEngineProviderSessionAndTheWorkLog() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let result = try await agentRun(backend, service: .claudeCode, "greet.py has a bug. Fix it.", project: project.id)
        let thread = try XCTUnwrap(backend.history.get(result.threadId))
        XCTAssertEqual(thread["kind"], "agent"); XCTAssertEqual(thread["engine"], "claude-code")
        XCTAssertEqual(thread["privacy"], "cloud"); XCTAssertEqual(thread["provider"], .string("anthropic.com"))
        XCTAssertEqual(thread["agentSession"], .string("8f1c2d3e-1111-4a5b-9c8d-000000000001"))
        let reply = try XCTUnwrap(thread["messages"]?.array?.last)
        XCTAssertEqual(reply["state"], "done")
        XCTAssertEqual(reply["content"], .string(claudeReplyText))
        XCTAssertEqual(reply["run"], .string(result.id))
        XCTAssertEqual(reply["events"]?.array?.count, 4)
        XCTAssertEqual(reply["rollback"], .bool(true))
        XCTAssertEqual(thread["privacy"], "cloud")
        let args = try XCTUnwrap(agents.commands.first).arguments
        XCTAssertEqual(args[0], "-p")
        XCTAssertEqual(args[1], "User:\ngreet.py has a bug. Fix it.")
        XCTAssertEqual(thread["messages"]?.array?.count, 2)
    }

    func testAContinuedTaskResumesWithOnlyTheNewMessage() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let first = try await agentRun(backend, service: .claudeCode, "Fix greet.py.", project: project.id)
        _ = try await agentRun(backend, service: .claudeCode, "Add a comment.", thread: first.threadId)
        let args = try XCTUnwrap(agents.commands.last).arguments
        XCTAssertEqual(Array(args.suffix(2)), ["--resume", "8f1c2d3e-1111-4a5b-9c8d-000000000001"])
        XCTAssertEqual(args[1], "Add a comment.")
        XCTAssertFalse(args.contains { $0.contains("User:") })
    }

    func testOnlyTheAgentTaskTextReachesTheTool() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        // A conversation that carries memory: the core, and notes recalled for an earlier message, plus pictures.
        let vault = BackendCloudTests.helper()
        var thread = backend.history.create("hello")
        thread = thread.setting("kind", .string("agent")).setting("engine", .string("claude-code")).setting("privacy", .string("cloud"))
            .setting("provider", .string("anthropic.com")).setting("project", .string(project.id)).setting("core", .string(vault.vaultCore))
        thread = thread.setting("messages", .array([
            ["id": "m1", "role": "user", "content": "earlier question", "recalled": .string(vault.vaultNote),
             "images": ["data:image/png;base64,AAAA"]],
            ["id": "m2", "role": "assistant", "content": "earlier answer", "recalled": .string(vault.vaultNote)],
        ]))
        try backend.history.save(thread)
        let id = try XCTUnwrap(thread["id"]?.string)
        _ = try await agentRun(backend, service: .claudeCode, "next question", thread: id)
        let task = try XCTUnwrap(agents.commands.first?.arguments[1])
        XCTAssertEqual(task, "User:\nearlier question\n\nAssistant:\nearlier answer\n\nUser:\nnext question")
        for command in agents.commands {
            let everything = command.arguments.joined(separator: "\n") + "\n" + command.environment.values.joined(separator: "\n")
            XCTAssertFalse(everything.contains("Vault-Secret"))
            XCTAssertFalse(everything.contains("base64"))
        }
    }

    func testAPrivateConversationIsRefusedBeforeAnyProcessStarts() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        var thread = backend.history.create("private")
        thread = thread.setting("kind", .string("agent")).setting("engine", .string("claude-code")).setting("privacy", .string("local"))
        try backend.history.save(thread)
        let id = try XCTUnwrap(thread["id"]?.string)
        XCTAssertThrowsError(try backend.submitAgentTask(service: .claudeCode, message: "hello", requestId: newID(), threadId: id)) {
            assertMatch(messageOf($0), "private to \(Place.this)")
        }
        XCTAssertTrue(agents.commands.isEmpty)
        XCTAssertEqual(backend.history.get(id)?["messages"]?.array?.count, 0)
    }

    func testALocalOnlyProjectIsRefusedBeforeAnyProcessStarts() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try backend.createProject(name: "Secret Work")
        XCTAssertThrowsError(try backend.submitAgentTask(service: .codex, message: "hello", requestId: newID(), project: project.id)) {
            assertMatch(messageOf($0), "Codex"); assertMatch(messageOf($0), "local only")
        }
        XCTAssertTrue(agents.commands.isEmpty)
        XCTAssertTrue(backend.threads().isEmpty)
    }

    func testAPhoneDoesNotStartANewAgentConversation() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        XCTAssertThrowsError(try backend.submitAgentTask(service: .claudeCode, message: "hello", requestId: newID(), project: project.id, from: .phone)) {
            assertMatch(messageOf($0), "made at \(Place.the)")
        }
        XCTAssertTrue(agents.commands.isEmpty)
    }

    func testAConversationContinuesOnlyWithItsOwnService() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: codexRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let first = try await agentRun(backend, service: .codex, "Fix greet.py.", project: project.id)
        XCTAssertEqual(backend.history.get(first.threadId)?["engine"], "codex")
        XCTAssertThrowsError(try backend.submitAgentTask(service: .claudeCode, message: "again", requestId: newID(), threadId: first.threadId)) {
            assertMatch(messageOf($0), "uses Codex")
        }
        XCTAssertThrowsError(try backend.submit(message: "again", kind: "agent", requestId: newID(), threadId: first.threadId)) {
            assertMatch(messageOf($0), "uses Codex")
        }
        XCTAssertThrowsError(try backend.submit(message: "again", requestId: newID(), threadId: first.threadId))
        XCTAssertEqual(agents.commands.count, 1)
    }

    func testCodexRunsWithItsOwnArguments() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: codexRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let result = try await agentRun(backend, service: .codex, "Fix greet.py.", project: project.id)
        let thread = try XCTUnwrap(backend.history.get(result.threadId))
        XCTAssertEqual(thread["provider"], .string("openai.com"))
        XCTAssertEqual(thread["agentSession"], .string("019e0000-0000-7000-8000-000000000002"))
        XCTAssertEqual(thread["messages"]?.array?.last?["content"], .string(codexReplyText))
        XCTAssertEqual(agents.commands.first?.arguments.last, "User:\nFix greet.py.")
    }

    func testAMissingToolIsSaidPlainlyAndNothingIsSaved() throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher()
        agents.tool = nil
        let backend = try make(fixture, agents: agents)
        XCTAssertThrowsError(try backend.submitAgentTask(service: .codex, message: "hello", requestId: newID())) {
            assertMatch(messageOf($0), "Codex is not installed")
        }
        XCTAssertTrue(backend.threads().isEmpty)
    }

    func testStopEndsTheRunAsInterrupted() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher()
        agents.holdUntilStopped = true
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let result = try backend.submitAgentTask(service: .claudeCode, message: "long task", requestId: newID(), project: project.id)
        try await waitForAgentCondition { !agents.commands.isEmpty }
        backend.cancel()
        await backend.waitForIdle()
        let thread = try XCTUnwrap(backend.history.get(result.threadId))
        XCTAssertEqual(thread["messages"]?.array?.last?["state"], "interrupted")
        XCTAssertEqual(agents.commands.count, 1)
    }

    func testAReplyOverTheLimitStopsTheToolAndSaysSo() async throws {
        let fixture = try BackendFixture(self)
        let text = String(repeating: "b", count: 150_000)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
        let agents = FakeAgentLauncher(lines: [(.stdout, line), (.stdout, line), (.stdout, line), (.stdout, claudeRecordedLines.last!)])
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let result = try await agentRun(backend, service: .claudeCode, "write a lot", project: project.id)
        let reply = try XCTUnwrap(backend.history.get(result.threadId)?["messages"]?.array?.last)
        XCTAssertEqual(reply["state"], "error")
        XCTAssertEqual(reply["error"], .string("Response reached the storage limit. Ask for a shorter answer."))
        XCTAssertLessThanOrEqual(EText.length(reply["content"]?.string ?? ""), 256 * 1024)
    }

    func testTheSameRequestIsNotRunTwice() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let id = newID()
        let first = try backend.submitAgentTask(service: .claudeCode, message: "once", requestId: id, project: project.id)
        await backend.waitForIdle()
        let again = try backend.submitAgentTask(service: .claudeCode, message: "once", requestId: id, project: project.id)
        XCTAssertEqual(again.threadId, first.threadId)
        XCTAssertEqual(agents.commands.count, 1)
        XCTAssertThrowsError(try backend.submitAgentTask(service: .claudeCode, message: "different", requestId: id, project: project.id))
    }

    func testRollBackUndoesATaskAndIsRefusedWhileOneRuns() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let folder = project.workspace
        try "def greet(name):\n    return 'Hello ' + nme\n".write(toFile: folder + "/greet.py", atomically: true, encoding: .utf8)
        agents.effect = { command in
            try? "def greet(name):\n    return 'Hello ' + name\n".write(toFile: command.workspace + "/greet.py", atomically: true, encoding: .utf8)
            try? "made by the agent\n".write(toFile: command.workspace + "/notes.md", atomically: true, encoding: .utf8)
        }
        let result = try await agentRun(backend, service: .claudeCode, "Fix greet.py.", project: project.id)
        XCTAssertTrue(try String(contentsOfFile: folder + "/greet.py", encoding: .utf8).contains("+ name"))
        let runId = try XCTUnwrap(backend.history.get(result.threadId)?["messages"]?.array?.last?["run"]?.string)

        // Refused while a task runs.
        agents.holdUntilStopped = true
        _ = try backend.submitAgentTask(service: .claudeCode, message: "another", requestId: newID(), threadId: result.threadId)
        try await waitForAgentCondition { agents.commands.count == 2 }
        XCTAssertThrowsError(try backend.rollBack(threadId: result.threadId, runId: runId)) { assertMatch(messageOf($0), "running") }
        backend.cancel()
        await backend.waitForIdle()

        agents.holdUntilStopped = false
        let restored = try backend.rollBack(threadId: result.threadId, runId: runId)
        XCTAssertTrue(restored.restored.contains("greet.py"))
        XCTAssertEqual(restored.removed, ["notes.md"])
        XCTAssertTrue(try String(contentsOfFile: folder + "/greet.py", encoding: .utf8).contains("nme"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/notes.md"))
        let message = try XCTUnwrap(backend.history.get(result.threadId)?["messages"]?.array?.first { $0["run"]?.string == runId })
        XCTAssertEqual(message["rolledBack"], .bool(true))
        XCTAssertThrowsError(try backend.rollBack(threadId: result.threadId, runId: runId)) { assertMatch(messageOf($0), "already been rolled back") }
    }

    func testAFolderTooLargeToSnapshotStillRunsAndSaysSo() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        for index in 0..<(AgentSnapshots.maxFiles + 1) {
            FileManager.default.createFile(atPath: project.workspace + "/f\(index)", contents: nil)
        }
        let result = try await agentRun(backend, service: .claudeCode, "fix", project: project.id)
        let reply = try XCTUnwrap(backend.history.get(result.threadId)?["messages"]?.array?.last)
        XCTAssertEqual(reply["state"], "done")
        XCTAssertNil(reply["rollback"])
        assertMatch(reply["rollbackNote"]?.string ?? "", "20,000")
        XCTAssertEqual(agents.commands.count, 1)
    }

    func testTheNormalSubmitStillRefusesAgentConversations() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let first = try await agentRun(backend, service: .claudeCode, "Fix greet.py.", project: project.id)
        XCTAssertThrowsError(try backend.submit(message: "more", kind: "agent", requestId: newID(), threadId: first.threadId)) {
            assertMatch(messageOf($0), "uses Claude Code")
        }
    }
}

/// Waits (up to 5 seconds) for a condition that the test's background work makes true.
func waitForAgentCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), "condition never became true")
}
