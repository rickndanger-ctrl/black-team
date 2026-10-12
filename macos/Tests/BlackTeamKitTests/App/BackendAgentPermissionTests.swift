import XCTest
@testable import BlackTeamKit

/// A collector the approval-answering task writes into.
final class AskSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AskSeenItem] = []
    func add(_ item: AskSeenItem) { lock.lock(); items.append(item); lock.unlock() }
    var all: [AskSeenItem] { lock.lock(); defer { lock.unlock() }; return items }
}
struct AskSeenItem: Equatable { var command: String; var description: String }
final class AskOpened: @unchecked Sendable {
    var calls: [(String, String)] = []
}

// The three permission levels, Ask's approval loop and signing in again, with a fake launcher: nothing real starts.
final class BackendAgentPermissionTests: XCTestCase {
    func make(_ fixture: BackendFixture, agents: FakeAgentLauncher, terminal: @escaping TerminalOpener = { _, _ in }) throws -> Backend {
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine, memory: nil,
            fetch: { _ in throw URLError(.cannotConnectToHost) }, stream: { _ in throw URLError(.cannotConnectToHost) },
            contextPlanner: nil, discover: { noTools }, terminal: terminal, home: fixture.files.dir + "/home",
            keeperInterval: 3600, agents: agents)
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        return backend
    }

    func openProject(_ backend: Backend) throws -> ProjectSummary {
        let project = try backend.createProject(name: "Agent Work")
        _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true)
        return project
    }

    /// Answers every approval card with `choice` until cancelled, noting what was asked.
    func answering(_ backend: Backend, _ choice: String, _ seen: AskSeen) -> Task<Void, Never> {
        Task {
            var done = Set<String>()
            while !Task.isCancelled {
                if let approval = (try? await backend.status())?.job?.approval, !done.contains(approval.id) {
                    done.insert(approval.id)
                    seen.add(AskSeenItem(command: approval.command, description: approval.description))
                    try? backend.approve(id: approval.id, digest: approval.digest, choice: choice)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    func run(_ backend: Backend, _ text: String, service: AgentService = .claudeCode, thread: String? = nil, project: String? = nil,
             permission: AgentPermission? = nil) async throws -> SubmitResult {
        let result = try backend.submitAgentTask(service: service, message: text, requestId: newID(), threadId: thread, project: project, permission: permission)
        await backend.waitForIdle()
        return result
    }

    func reply(_ backend: Backend, _ result: SubmitResult) throws -> JSONValue {
        try XCTUnwrap(backend.history.get(result.threadId)?["messages"]?.array?.last)
    }

    // MARK: recorded shapes

    func start(_ session: String = "sess-1") -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(session)"}"#
    }
    func denied(_ tool: String, _ input: String, id: String = "tu1") -> [String] {
        [#"{"type":"system","subtype":"permission_denied","tool_name":"\#(tool)","tool_use_id":"\#(id)","message":"\#(tool) needs approval. Ask the user."}"#,
         #"{"type":"result","subtype":"success","is_error":false,"result":"I need approval.","session_id":"sess-1","permission_denials":[{"tool_name":"\#(tool)","tool_use_id":"\#(id)","tool_input":\#(input)}]}"#]
    }
    var okRun: [String] { [start(), #"{"type":"result","subtype":"success","is_error":false,"result":"Done it.","session_id":"sess-1"}"#] }
    func bash(_ command: String) -> [String] {
        let escaped = command.replacingOccurrences(of: "\n", with: "\\n")
        return [start()] + denied("Bash", #"{"command":"\#(escaped)"}"#)
    }

    // MARK: Ask loop

    func testAllowingResumesWithExactlyThatRule() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [bash("touch asked.txt"), okRun]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
        let result = try await run(backend, "make a file", project: project.id, permission: .ask)
        XCTAssertEqual(agents.commands.count, 2)
        let first = agents.commands[0].arguments, second = agents.commands[1].arguments
        XCTAssertEqual(first[first.firstIndex(of: "--permission-mode")! + 1], "manual")
        XCTAssertFalse(first.contains("--allowedTools"))
        XCTAssertEqual(second[second.firstIndex(of: "--allowedTools")! + 1], "Bash(touch asked.txt)")
        XCTAssertEqual(second[second.firstIndex(of: "--allowedTools")! + 2], "--strict-mcp-config")
        XCTAssertEqual(second[1], "Approved: go ahead with what was just approved. Do not do anything else that needs approval without asking.")
        XCTAssertEqual(Array(second.suffix(2)), ["--resume", "sess-1"])
        XCTAssertEqual(seen.all, [AskSeenItem(command: "touch asked.txt", description: "Bash needs approval. Ask the user.")])
        let message = try reply(backend, result)
        XCTAssertEqual(message["state"], "done")
        XCTAssertFalse(message["content"]?.string?.contains("Not done") ?? true)
    }

    func testDenyingDoesNotResumeAndSaysWhatWasNotDone() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [bash("touch asked.txt"), okRun]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let seen = AskSeen(); let answerer = answering(backend, "deny", seen); defer { answerer.cancel() }
        let result = try await run(backend, "make a file", project: project.id, permission: .ask)
        XCTAssertEqual(agents.commands.count, 1)
        let message = try reply(backend, result)
        XCTAssertEqual(message["state"], "done")
        XCTAssertTrue(message["content"]?.string?.hasSuffix("Not done (not approved): touch asked.txt.") ?? false, message["content"]?.string ?? "")
    }

    func testEditsAreAskedAsEditOrCreateAndOutsideThePathIsRefusedWithoutAQuestion() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher()
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        // First learn the workspace the conversation runs in.
        agents.scripts = [okRun]
        _ = try await run(backend, "hello", project: project.id, permission: .ask)
        let workspace = try XCTUnwrap(agents.commands.first).workspace
        let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
        agents.scripts = [[start()] + denied("Write", #"{"file_path":"\#(workspace)/new.txt"}"#, id: "a")
                          .dropLast() + [#"{"type":"result","is_error":false,"result":"x","permission_denials":[{"tool_name":"Write","tool_use_id":"a","tool_input":{"file_path":"\#(workspace)/new.txt"}},{"tool_name":"Edit","tool_use_id":"b","tool_input":{"file_path":"/etc/hosts"}},{"tool_name":"Edit","tool_use_id":"c","tool_input":{"file_path":"\#(workspace)/../escape.txt"}}]}"#],
                         okRun]
        let before = agents.commands.count
        let result = try await run(backend, "go", thread: nil, project: project.id, permission: .ask)
        XCTAssertEqual(agents.commands.count - before, 2)
        XCTAssertEqual(seen.all.map(\.command), ["Create \(workspace)/new.txt"])
        let second = agents.commands.last!.arguments
        XCTAssertEqual(second[second.firstIndex(of: "--allowedTools")! + 1], "Write(\(workspace)/new.txt)")
        let text = try XCTUnwrap(reply(backend, result)["content"]?.string)
        XCTAssertTrue(text.contains("Not done (outside this conversation's folder): /etc/hosts; "), text)
        XCTAssertTrue(text.contains("escape.txt"), text)
    }

    func testACommandWithANewlineIsNeverAskedOrAllowed() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [bash("echo a\ntouch b"), okRun]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
        let result = try await run(backend, "go", project: project.id, permission: .ask)
        XCTAssertEqual(agents.commands.count, 1)
        XCTAssertTrue(seen.all.isEmpty)
        XCTAssertTrue(try XCTUnwrap(reply(backend, result)["content"]?.string).contains("Not done (cannot be allowed as one exact command)"))
    }

    func testAtMostFiveResumesPerMessage() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [bash("touch asked.txt")]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
        let result = try await run(backend, "go", project: project.id, permission: .ask)
        XCTAssertEqual(agents.commands.count, 6)
        XCTAssertEqual(seen.all.count, 5)
        XCTAssertTrue(try XCTUnwrap(reply(backend, result)["content"]?.string).hasSuffix("Not done (needs approval): touch asked.txt."))
    }

    func testAllowedRulesAreNotRememberedForTheNextMessage() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [bash("touch asked.txt"), okRun]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
        let first = try await run(backend, "go", project: project.id, permission: .ask)
        XCTAssertTrue(agents.commands[1].arguments.contains("--allowedTools"))
        _ = try await run(backend, "and now?", thread: first.threadId)
        let last = try XCTUnwrap(agents.commands.last).arguments
        XCTAssertFalse(last.contains("--allowedTools"))
        XCTAssertEqual(last[last.firstIndex(of: "--permission-mode")! + 1], "manual", "the level is the conversation's")
        XCTAssertEqual(backend.history.get(first.threadId)?["agentPermission"], "ask")
    }

    // MARK: Edit, Auto, Codex Ask

    func testEditAndAutoEndWithAPlainLineAndNeverAsk() async throws {
        for (level, hint) in [(AgentPermission.edit, "Switch this conversation to Ask or Auto to allow it."),
                              (.auto, "Switch this conversation to Ask to be asked first.")] {
            let fixture = try BackendFixture(self)
            let agents = FakeAgentLauncher(); agents.scripts = [bash("touch asked.txt")]
            let backend = try make(fixture, agents: agents)
            let project = try openProject(backend)
            let seen = AskSeen(); let answerer = answering(backend, "once", seen); defer { answerer.cancel() }
            let result = try await run(backend, "go", project: project.id, permission: level)
            XCTAssertEqual(agents.commands.count, 1)
            XCTAssertTrue(seen.all.isEmpty)
            XCTAssertTrue(try XCTUnwrap(reply(backend, result)["content"]?.string).hasSuffix("Not done (needs approval): touch asked.txt. \(hint)"))
            let args = agents.commands[0].arguments
            XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], level == .edit ? "acceptEdits" : "auto")
        }
    }

    func testNewConversationDefaultsToEditAndSavesTheLevel() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(); agents.scripts = [okRun]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let result = try await run(backend, "hi", project: project.id)
        XCTAssertNil(backend.history.get(result.threadId)?["agentPermission"])
        let args = agents.commands[0].arguments
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
    }

    func testCodexAskIsReadOnlyAndSaysSoOnlyWhenItCouldNotAct() async throws {
        let fixture = try BackendFixture(self)
        let change = [#"{"type":"thread.started","thread_id":"c1"}"#,
                      #"{"type":"item.completed","item":{"id":"i1","type":"file_change","status":"failed","changes":[{"path":"a.txt"}]}}"#,
                      #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"I could not write."}}"#,
                      #"{"type":"turn.completed"}"#]
        let agents = FakeAgentLauncher(); agents.scripts = [change, codexRecordedLines]
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let first = try await run(backend, "write a.txt", service: .codex, project: project.id, permission: .ask)
        let args = agents.commands[0].arguments
        XCTAssertEqual(args[args.firstIndex(of: "-s")! + 1], "read-only")
        XCTAssertTrue(try XCTUnwrap(reply(backend, first)["content"]?.string).hasSuffix(AgentAsk.codexReadOnlyLine))
        let second = try await run(backend, "just read", service: .codex, thread: first.threadId)
        XCTAssertFalse(try XCTUnwrap(reply(backend, second)["content"]?.string).contains("cannot ask for approval"))
        XCTAssertTrue(agents.commands[1].arguments.contains("sandbox_mode=\"read-only\""))
    }

    // MARK: signed out

    func testClaudeSignedOutEndsInErrorWithTheFlag() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher()
        agents.scripts = [[start(), #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#]]
        agents.exit = AgentExit(status: 1)
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let message = try reply(backend, try await run(backend, "hi", project: project.id))
        XCTAssertEqual(message["state"], "error")
        XCTAssertEqual(message["needsSignIn"], "claude-code")
        XCTAssertEqual(message["error"], "Claude Code is signed out. Sign in again, then send your message once more.")
    }

    func testCodexSignedOutFromItsErrorOrItsStandardError() async throws {
        for lines: [(AgentStream, String)] in [
            [(.stdout, #"{"type":"turn.failed","error":{"message":"Your access token could not be refreshed. Please log out and sign in again."}}"#)],
            [(.stderr, "ERROR: Not logged in. Run codex login.")]] {
            let fixture = try BackendFixture(self)
            let agents = FakeAgentLauncher(lines: lines, exit: AgentExit(status: 1))
            let backend = try make(fixture, agents: agents)
            let project = try openProject(backend)
            let message = try reply(backend, try await run(backend, "hi", service: .codex, project: project.id))
            XCTAssertEqual(message["state"], "error")
            XCTAssertEqual(message["needsSignIn"], "codex")
            XCTAssertEqual(message["error"], "Codex is signed out. Sign in again, then send your message once more.")
        }
    }

    func testOtherFailuresAreNotSignedOut() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher(lines: [(.stdout, #"{"type":"turn.failed","error":{"message":"Rate limit reached."}}"#)], exit: AgentExit(status: 1))
        let backend = try make(fixture, agents: agents)
        let project = try openProject(backend)
        let message = try reply(backend, try await run(backend, "hi", service: .codex, project: project.id))
        XCTAssertEqual(message["state"], "error")
        XCTAssertNil(message["needsSignIn"])
    }

    func testSignInCommandAndItsTerminalLaunch() async throws {
        let fixture = try BackendFixture(self)
        let agents = FakeAgentLauncher()
        let opened = AskOpened()
        let backend = try make(fixture, agents: agents) { app, script in opened.calls.append((app, script)) }
        let claude = backend.agentSignInCommand(service: .claudeCode)
        XCTAssertEqual(claude.executable, "/fake/bin/agent"); XCTAssertEqual(claude.arguments, ["auth", "login"])
        XCTAssertEqual(backend.agentSignInCommand(service: .codex).arguments, ["login"])
        try await backend.openAgentSignIn(service: .claudeCode)
        let call = try XCTUnwrap(opened.calls.first)
        XCTAssertEqual(call.0, "Terminal")
        let text = try String(contentsOfFile: call.1, encoding: .utf8)
        XCTAssertTrue(text.contains("exec '/fake/bin/agent' 'auth' 'login'"), text)
        XCTAssertFalse(text.contains("ANTHROPIC_API_KEY"))
    }
}
