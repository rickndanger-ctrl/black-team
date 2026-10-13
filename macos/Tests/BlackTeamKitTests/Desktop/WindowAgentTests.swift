import XCTest
@testable import BlackTeamKit

// Subscription agents (Claude Code, Codex) through the desktop window's surface, with fake tools: nothing real starts.
final class WindowAgentTests: XCTestCase {
    func start(_ session: String = "sess-1") -> String { #"{"type":"system","subtype":"init","session_id":"\#(session)"}"# }
    var okRun: [String] { [start(), #"{"type":"result","subtype":"success","is_error":false,"result":"Done it.","session_id":"sess-1"}"#] }
    func bash(_ command: String) -> [String] {
        [start(), #"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"tu1","message":"Bash needs approval. Ask the user."}"#,
         #"{"type":"result","subtype":"success","is_error":false,"result":"I need approval.","session_id":"sess-1","permission_denials":[{"tool_name":"Bash","tool_use_id":"tu1","tool_input":{"command":"\#(command)"}}]}"#]
    }

    /// A tool that prints a version, so the version check has something to read. It is a two-line shell script, not Claude Code.
    func fakeTool(_ r: WindowRig, version: String) throws -> String {
        let path = r.fixture.files.dir + "/fake-claude"
        try "#!/bin/sh\necho \"\(version) (Claude Code)\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    // MARK: Which are installed, and the version check

    func testWhichAgentsAreInstalledAndTheVersionLine() async throws {
        let r = try await WindowRig(self)
        r.agents.tool = try fakeTool(r, version: "2.1.289")
        let found = try await r.result("agents-status")
        let claude = try XCTUnwrap(found["agents"]?[0]), codex = try XCTUnwrap(found["agents"]?[1])
        XCTAssertEqual(claude["engine"]?.string, "claude-code"); XCTAssertEqual(claude["name"]?.string, "Claude Code")
        XCTAssertEqual(claude["provider"]?.string, "anthropic.com"); XCTAssertEqual(claude["program"]?.string, "claude")
        XCTAssertEqual(claude["installed"]?.bool, true)
        XCTAssertEqual(claude["installedVersion"]?.string, "2.1.289"); XCTAssertEqual(claude["latestVersion"]?.string, "9.9.9")
        XCTAssertEqual(claude["updateAvailable"]?.bool, true)
        XCTAssertEqual(codex["engine"]?.string, "codex"); XCTAssertEqual(codex["provider"]?.string, "openai.com")
        // One tool, and without the registry question.
        let asked = r.discovery.count
        let one = try await r.result("agents-status", ["engine": "codex", "versions": false])
        XCTAssertEqual(one["agents"]?.array?.count, 1)
        XCTAssertNil(one["agents"]?[0]?["installedVersion"])
        XCTAssertEqual(r.discovery.count, asked)
        // A tool that is not installed.
        r.agents.tool = nil
        let none = try await r.result("agents-status")
        XCTAssertEqual(none["agents"]?.array?.map { $0["installed"]?.bool }, [false, false])
        let status = try await r.result("status")
        XCTAssertEqual(status["agents"]?.array?.map { $0["installed"]?.bool }, [false, false])
        await r.expectRefusal("agents-status", ["engine": "nope"], exact: "The agent is claude-code or codex.")
        await r.expectRefusal("agents-status", ["other": 1], exact: "Unsupported agent setting.")
    }

    // MARK: A conversation with an agent

    func testStartingAnAgentConversationWithALevelAndContinuingIt() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Agent Work", cloud: true)
        let check = await r.desktop("GET", "/api/privacy?agent=claude-code&project=\(project.id)")
        XCTAssertEqual(check["outcome"]?.string, "startsCloud")
        XCTAssertEqual(check["provider"]?.string, "anthropic.com"); XCTAssertEqual(check["modelName"]?.string, "Claude Code")
        XCTAssertEqual(check["willLeave"]?.array?.compactMap { $0.string }, ["your messages", "the files in this project folder that the agent chooses to read", "the output of commands it runs"])
        XCTAssertEqual(check["message"]?.string, "This conversation leaves \(Place.this). It is handed to Claude Code, which runs on anthropic.com under your subscription: your messages, "
            + "and the files in this project folder that the agent chooses to read, and the output of commands it runs. "
            + "Claude Code uses its own tools and its maker\u{2019}s service, and Black Team\u{2019}s memory is not used.")

        let sent = await r.chat("greet.py has a bug. Fix it.", ["agent": "claude-code", "project": .string(project.id), "permission": "auto"])
        XCTAssertEqual(sent.status, 202, sent.text)
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        let view = await r.desktop("GET", "/api/thread/\(threadId)")
        XCTAssertEqual(view["engine"]?.string, "claude-code"); XCTAssertEqual(view["kind"]?.string, "agent")
        XCTAssertEqual(view["privacy"]?.string, "cloud"); XCTAssertEqual(view["provider"]?.string, "anthropic.com")
        XCTAssertEqual(view["agentPermission"]?.string, "auto"); XCTAssertEqual(view["project"]?.string, project.id)
        let reply = try XCTUnwrap(view["messages"]?.array?.last)
        XCTAssertEqual(reply["state"]?.string, "done"); XCTAssertEqual(reply["content"]?.string, claudeReplyText)
        XCTAssertEqual(reply["rollback"]?.bool, true); XCTAssertNotNil(reply["run"]?.string)
        XCTAssertEqual(reply["events"]?.array?.count, 4)
        let args = try XCTUnwrap(r.agents.commands.first).arguments
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "auto")
        // The vault and the local conversation machinery were not involved; only the task text went to the tool.
        XCTAssertFalse(r.agents.commands.flatMap { $0.arguments }.joined().contains("Vault-Secret"))
        XCTAssertEqual(r.requests.count, 0, "no model server was asked")

        // A follow-up keeps the saved level; a new level applies from that message on.
        _ = await r.chat("and the docs?", ["agent": "claude-code", "threadId": .string(threadId)])
        XCTAssertEqual(r.agents.commands.count, 2)
        XCTAssertEqual(r.agents.commands[1].arguments[r.agents.commands[1].arguments.firstIndex(of: "--permission-mode")! + 1], "auto")
        _ = await r.chat("careful now", ["agent": "claude-code", "threadId": .string(threadId), "permission": "ask"])
        XCTAssertEqual(r.thread(threadId)["agentPermission"]?.string, "ask")
        // The words for wrong input.
        let bad = await r.chat("x", ["agent": "claude-code", "permission": "root"], wait: false)
        XCTAssertEqual(bad.status, 400); XCTAssertEqual(bad.error, "Permission is ask, edit or auto.")
        let notAgent = await r.chat("x", ["agent": "gemini"], wait: false)
        XCTAssertEqual(notAgent.status, 400); XCTAssertEqual(notAgent.error, "The agent is claude-code or codex.")
        let plain = await r.chat("x", ["permission": "ask"], wait: false)
        XCTAssertEqual(plain.status, 400); XCTAssertEqual(plain.error, "Permission applies to subscription agents only.")
        let pictures = await r.chat("x", ["agent": "codex", "images": ["abc"]], wait: false)
        XCTAssertEqual(pictures.status, 400); XCTAssertEqual(pictures.error, ImageRules.codeRefusal)
        // The plain Chat route refuses to carry an agent conversation on, in the Mac's words.
        let wrongRoute = await r.chat("x", ["threadId": .string(threadId)], wait: false)
        XCTAssertEqual(wrongRoute.status, 400); XCTAssertEqual(wrongRoute.error, "This conversation uses Claude Code. Continue it with Claude Code, or start a new conversation.")
        // A thread of the other agent is not continued with this one.
        let other = await r.chat("x", ["agent": "codex", "threadId": .string(threadId)], wait: false)
        XCTAssertEqual(other.error, "This conversation uses Claude Code. Continue it with Claude Code, or start a new conversation.")
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    func testAnAgentIsRefusedInALocalOnlyProjectAndNothingStarts() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Secrets")
        let check = await r.desktop("GET", "/api/privacy?agent=codex&project=\(project.id)")
        XCTAssertEqual(check["outcome"]?.string, "projectLocalOnly")
        XCTAssertEqual(check["message"]?.string, "The project Secrets is local only, so Codex (which runs on openai.com) is not used for conversations in it. "
            + "To change that, choose \u{201C}Allow cloud models\u{201D} in the project\u{2019}s menu.")
        let refused = await r.chat("hi", ["agent": "codex", "project": .string(project.id)], wait: false)
        XCTAssertEqual(refused.status, 400); XCTAssertEqual(refused.error, check["message"]?.string)
        XCTAssertEqual(r.agents.commands.count, 0)
        XCTAssertEqual(r.backend.threads().count, 0)
    }

    func testAnAgentConversationThatStayedOnThisComputerNeedsAConfirmationBeforeItIsSent() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Work", cloud: true)
        // A conversation with the agent's name on it that was kept private (the gate must not rely on how it came to be).
        var thread = r.backend.history.create("private notes")
        thread = thread.setting("kind", "agent").setting("engine", "claude-code").setting("privacy", "local").setting("project", .string(project.id))
        try r.backend.history.save(thread)
        let threadId = try XCTUnwrap(thread["id"]?.string)
        let check = await r.desktop("GET", "/api/privacy?agent=claude-code&threadId=\(threadId)")
        XCTAssertEqual(check["outcome"]?.string, "needsChoice")
        XCTAssertEqual(check["message"]?.string, "This conversation is private to \(Place.this), and Claude Code would send it to anthropic.com. "
            + "Nothing in a private conversation is sent off \(Place.this) without your say-so. Start a new conversation with Claude Code, or send this conversation to anthropic.com.")
        XCTAssertEqual(check["convertWarning"]?.string, "Send this conversation to anthropic.com? Everything in it so far will be sent to anthropic.com with your next message: all your messages and the replies, "
            + "and the file contents and command output the agent saw. The conversation stays marked as having left \(Place.this), even if you later continue it with a local model.")
        let refused = await r.chat("fix it", ["agent": "claude-code", "threadId": .string(threadId)], wait: false)
        XCTAssertEqual(refused.status, 400); XCTAssertEqual(refused.error, check["message"]?.string)
        XCTAssertEqual(r.agents.commands.count, 0)
        // The service named is the agent's own; the agent is read from the conversation, not the request.
        let wrong = await r.desktop("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": "openai.com"])
        XCTAssertEqual(wrong.error, "Confirm which service this conversation will be sent to (anthropic.com) before it is converted.")
        let converted = await r.desktop("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": "anthropic.com"])
        XCTAssertEqual(converted.status, 200, converted.text)
        XCTAssertEqual(converted["thread"]?["privacy"]?.string, "cloud")
        let sent = await r.chat("fix it", ["agent": "claude-code", "threadId": .string(threadId)])
        XCTAssertEqual(sent.status, 202, sent.text)
        XCTAssertEqual(r.agents.commands.count, 1)
    }

    // MARK: Rolling a task back

    func testRollingBackATask() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Agent Work", cloud: true)
        try "def greet(name):\n    return 'Hello ' + nme\n".write(toFile: project.workspace + "/greet.py", atomically: true, encoding: .utf8)
        r.agents.effect = { command in
            try? "fixed\n".write(toFile: command.workspace + "/greet.py", atomically: true, encoding: .utf8)
            try? "made by the agent\n".write(toFile: command.workspace + "/notes.md", atomically: true, encoding: .utf8)
        }
        let sent = await r.chat("Fix greet.py.", ["agent": "claude-code", "project": .string(project.id)])
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        let run = try XCTUnwrap(r.thread(threadId)["messages"]?.array?.last?["run"]?.string)
        // A phone cannot roll anything back.
        let phone = await r.phone("POST", "/api/agent/rollback", ["threadId": .string(threadId), "runId": .string(run)])
        XCTAssertEqual(phone.status, 403); XCTAssertEqual(phone.error, DesktopRefusal.desktopOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.workspace + "/notes.md"))
        let done = await r.desktop("POST", "/api/agent/rollback", ["threadId": .string(threadId), "runId": .string(run)])
        XCTAssertEqual(done.status, 200, done.text)
        XCTAssertEqual(done["restored"]?.array?.compactMap { $0.string }, ["greet.py"]); XCTAssertEqual(done["removed"]?.array?.compactMap { $0.string }, ["notes.md"])
        XCTAssertTrue(try String(contentsOfFile: project.workspace + "/greet.py", encoding: .utf8).contains("nme"))
        let view = await r.desktop("GET", "/api/thread/\(threadId)")
        XCTAssertEqual(view["messages"]?.array?.last?["rolledBack"]?.bool, true)
        let again = await r.desktop("POST", "/api/agent/rollback", ["threadId": .string(threadId), "runId": .string(run)])
        XCTAssertEqual(again.status, 400); XCTAssertEqual(again.error, "This task has already been rolled back.")
        let missing = await r.desktop("POST", "/api/agent/rollback", ["threadId": .string(threadId), "runId": "x"])
        XCTAssertEqual(missing.error, "Not found.")
    }

    // MARK: The Ask loop

    func askAndAnswer(_ r: WindowRig, choice: String, from phone: Bool) async throws -> WindowAnswer {
        let project = try await r.project("Ask \(choice)", cloud: true)
        let sent = await r.chat("make a file", ["agent": "claude-code", "project": .string(project.id), "permission": "ask"], wait: false)
        XCTAssertEqual(sent.status, 202, sent.text)
        // The window polls its status for the approval card.
        var approval: JSONValue = .null
        for _ in 0..<500 where approval == .null {
            approval = await r.desktop("GET", "/api/status")["job"]?["approval"] ?? .null
            if approval == .null { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(approval["command"]?.string, "touch asked.txt")
        XCTAssertEqual(approval["description"]?.string, "Bash needs approval. Ask the user.")
        let id = try XCTUnwrap(approval["id"]?.string), digest = try XCTUnwrap(approval["digest"]?.string)
        // A wrong digest answers nothing.
        let wrong = await r.http("POST", "/api/approval", ["id": .string(id), "digest": "00", "choice": "once"], phone: phone)
        XCTAssertEqual(wrong.status, 409); XCTAssertEqual(wrong.error, "No matching active approval.")
        let answer = await r.http("POST", "/api/approval", ["id": .string(id), "digest": .string(digest), "choice": .string(choice)], phone: phone)
        await r.backend.waitForIdle()
        return answer
    }

    func testTheAskLoopIsAnsweredThroughTheApprovalRoute() async throws {
        let r = try await WindowRig(self)
        r.agents.scripts = [bash("touch asked.txt"), okRun]
        let answer = try await askAndAnswer(r, choice: "once", from: false)
        XCTAssertEqual(answer.status, 200); XCTAssertEqual(answer["sent"]?.bool, true)
        XCTAssertEqual(r.agents.commands.count, 2)
        let second = r.agents.commands[1].arguments
        XCTAssertEqual(second[second.firstIndex(of: "--allowedTools")! + 1], "Bash(touch asked.txt)")
        XCTAssertNotEqual(r.agents.commands[0].arguments.firstIndex(of: "--allowedTools"), 0)
    }

    func testAskApprovalsAreTheSameForAPhoneAsTheMacAlwaysAllowedAndDenyingStopsTheResume() async throws {
        // On the Mac a paired phone may answer any approval card through the same route; the new surface keeps that and adds nothing.
        let r = try await WindowRig(self)
        r.agents.scripts = [bash("touch asked.txt"), okRun]
        let answer = try await askAndAnswer(r, choice: "deny", from: true)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(r.agents.commands.count, 1, "denied: the tool is not run again")
        let reply = try XCTUnwrap(r.backend.threads().first).id
        XCTAssertTrue(r.thread(reply)["messages"]?.array?.last?["content"]?.string?.hasSuffix("Not done (not approved): touch asked.txt.") ?? false)
    }

    // MARK: Sign-in and updates

    func testSigningInAndUpdatingOpenTheToolsOwnCommandsInATerminal() async throws {
        let r = try await WindowRig(self)
        r.agents.lines = [(.stderr, "OAuth session expired")]; r.agents.exit = AgentExit(status: 1)
        let project = try await r.project("Agent Work", cloud: true)
        let sent = await r.chat("hello", ["agent": "claude-code", "project": .string(project.id)])
        let reply = try XCTUnwrap(r.thread(try XCTUnwrap(sent["threadId"]?.string))["messages"]?.array?.last)
        XCTAssertEqual(reply["state"]?.string, "error"); XCTAssertEqual(reply["needsSignIn"]?.string, "claude-code")
        XCTAssertEqual(reply["error"]?.string, "Claude Code is signed out. Sign in again, then send your message once more.")
        // The sign-in is the tool's own, in the person's terminal; Black Team sees none of it.
        let opened = try await r.result("agent-signin", ["engine": "claude-code"])
        XCTAssertEqual(opened["opened"]?.bool, true); XCTAssertEqual(opened["name"]?.string, "Claude Code")
        XCTAssertTrue(r.opened.all.last?.contains("'auth' 'login'") ?? false, r.opened.all.last ?? "")
        _ = try await r.result("agent-signin", ["engine": "codex"])
        XCTAssertTrue(r.opened.all.last?.hasSuffix("exec '/fake/bin/agent' 'login'\n") ?? false, r.opened.all.last ?? "")
        _ = try await r.result("agent-update", ["engine": "claude-code"])
        XCTAssertTrue(r.opened.all.last?.hasSuffix("exec '/fake/bin/agent' 'update'\n") ?? false, r.opened.all.last ?? "")
        await r.expectRefusal("agent-signin", ["engine": "gemini"], exact: "The agent is claude-code or codex.")
        r.agents.tool = nil
        await r.expectRefusal("agent-signin", ["engine": "codex"], exact: "Codex is not installed on \(Place.this). Install it, then sign in with your subscription.")
        await r.expectRefusal("agent-update", ["engine": "codex"], exact: "Codex is not installed on \(Place.this). Install it, then sign in with your subscription.")
        // A tool that says it needs updating is reported as such.
        r.agents.tool = "/fake/bin/agent"
        r.agents.lines = [(.stderr, "This version requires a newer version of Claude Code. Please upgrade to the latest version.")]
        let again = await r.chat("hello again", ["agent": "claude-code", "threadId": .string(try XCTUnwrap(sent["threadId"]?.string))])
        let next = try XCTUnwrap(r.thread(try XCTUnwrap(again["threadId"]?.string))["messages"]?.array?.last)
        XCTAssertEqual(next["needsUpdate"]?.string, "claude-code")
        XCTAssertTrue(next["error"]?.string?.hasPrefix("Claude Code needs updating before it can run this. Update it, then send your message once more.\n") ?? false)
    }

    // MARK: A phone

    func testAPhoneCannotSignInChangeALevelOrStartAnAgent() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Agent Work", cloud: true)
        // Sign-in and update open a terminal on the computer: the desktop's alone.
        for action in ["agent-signin", "agent-update", "agents-status"] {
            do { _ = try await r.control.handle(action, ["engine": "claude-code"], access: .phone); XCTFail("\(action) must be refused for a phone") }
            catch { XCTAssertEqual(messageOf(error), DesktopRefusal.desktopOnly, action) }
        }
        XCTAssertEqual(r.opened.all.count, 0)
        for path in ["/api/agent-signin", "/api/agent/signin", "/api/agent-update", "/api/agents"] {
            let answer = await r.phone("POST", path, ["engine": "claude-code"])
            XCTAssertEqual(answer.status, 404, path)
        }
        // Starting a conversation with an agent is a decision made at the Mac, in the gate's words; choosing a level is the desktop's.
        let start = await r.chat("hello", ["agent": "claude-code", "project": .string(project.id)], phone: true, wait: false)
        XCTAssertEqual(start.status, 403)
        XCTAssertEqual(start.error, "Starting a conversation with Claude Code is a decision made at \(Place.the). Open Black Team on \(Place.your) to start one, or ask there.")
        let level = await r.chat("hello", ["permission": "auto"], phone: true, wait: false)
        XCTAssertEqual(level.status, 403); XCTAssertEqual(level.error, DesktopRefusal.agentPermission)
        let phoneCheck = await r.phone("GET", "/api/privacy?agent=claude-code&project=\(project.id)")
        XCTAssertEqual(phoneCheck["outcome"]?.string, "phoneNeedsMac")
        XCTAssertEqual(r.agents.commands.count, 0)
        XCTAssertEqual(r.backend.threads().count, 0)
        // The desktop, in the same state, is allowed to do all of it.
        let sent = await r.chat("hello", ["agent": "claude-code", "project": .string(project.id), "permission": "edit"])
        XCTAssertEqual(sent.status, 202, sent.text)
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        // A phone does not continue an agent conversation, or change its level, either.
        let carry = await r.chat("more", ["agent": "claude-code", "threadId": .string(threadId)], phone: true, wait: false)
        XCTAssertEqual(carry.status, 400); XCTAssertEqual(carry.error, "This conversation uses Claude Code. Continue it with Claude Code, or start a new conversation.")
        let plain = await r.chat("more", ["threadId": .string(threadId)], phone: true, wait: false)
        XCTAssertEqual(plain.status, 400)
        let change = await r.chat("more", ["agent": "claude-code", "threadId": .string(threadId), "permission": "auto"], phone: true, wait: false)
        XCTAssertEqual(change.status, 403)
        XCTAssertEqual(r.thread(threadId)["agentPermission"]?.string, "edit")
        XCTAssertEqual(r.agents.commands.count, 1)
        _ = try await r.result("agent-signin", ["engine": "claude-code"])
        XCTAssertEqual(r.opened.all.count, 1)
    }
}
