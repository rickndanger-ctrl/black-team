import XCTest
@testable import BlackTeamKit

// The room: a task board per project, run through the real Backend with the fake runtime, network and agent launcher.
final class RoomTests: XCTestCase {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."
    let vaultNote = "the umbrella is kept in Vault-Secret-Beta"

    struct Rig {
        var fixture: BackendFixture
        var backend: Backend
        var agents: FakeAgentLauncher
        var project: ProjectSummary
        var localKey: String
        var pid: String { project.id }
    }

    /// A backend with a vault, a local model in use, a project (cloud allowed or not), and fakes for every outside thing.
    func rig(cloudAllowed: Bool = true, agents: FakeAgentLauncher = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) }),
             vault: Bool = true) async throws -> Rig {
        let fixture = try BackendFixture(self)
        if vault {
            let memory = try Memory(vault: fixture.stateDir + "/vault")
            try memory.write("Core", "# Core\n\n\(vaultCore)\n")
            try memory.remember("Umbrella", vaultNote)
            fixture.memory = memory
        }
        let host = self.host
        fixture.reply = { request in
            request.url?.host == host ? sse("data: {\"choices\":[{\"delta\":{\"content\":\"Cloud answer\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
                                      : sse(answerStream)
        }
        let requests = fixture.requests, planned = fixture.planned
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine, memory: fixture.memory,
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            stream: { request in requests.add(request); return try await fixture.reply(request) },
            contextPlanner: { messages, context, mode, _, _, _ in
                planned.add(messages: messages, mode: mode)
                return PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, _ in }, home: fixture.files.dir + "/home", keeperInterval: 3600, agents: agents)
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        let project = try backend.createProject(name: "Team Work")
        if cloudAllowed { _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true) }
        let key = try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key
        return Rig(fixture: fixture, backend: backend, agents: agents, project: project, localKey: key)
    }

    func addCloudModel(_ backend: Backend) async throws -> String {
        _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": .string("https://\(host)/v1"), "id": "big-model", "apiKey": .string(secret),
                                                   "name": "Cloud Big", "context": .number(100_000)]])
        return try XCTUnwrap(backend.savedModels.list().first { $0.isCloud }).key
    }

    @discardableResult
    func addTask(_ r: Rig, _ title: String = "Add tests", detail: String = "", to member: String?) throws -> RoomTask {
        let state = try r.backend.roomAddTask(projectId: r.pid, title: title, detail: detail, assignee: member)
        return state.tasks.last!
    }

    func member(_ r: Rig, _ name: String, model: String? = nil, agent: String? = nil, work: String? = nil, permission: String? = nil) throws -> RoomMemberView {
        try r.backend.roomAddMember(projectId: r.pid, name: name, role: "tester", modelKey: model, agent: agent, permission: permission, work: work).members.last!
    }

    func task(_ r: Rig, _ id: String) throws -> RoomTask { try XCTUnwrap(try r.backend.room(projectId: r.pid).tasks.first { $0.id == id }) }

    func start(_ r: Rig, _ id: String, from origin: SubmitOrigin = .mac) async throws {
        _ = try await r.backend.roomStart(projectId: r.pid, taskId: id, from: origin)
        await r.backend.waitForIdle()
        await r.backend.roomSettle()
    }

    func fail(_ body: () async throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected a refusal", file: file, line: line) }
        catch { XCTAssertTrue(messageOf(error).contains(text), "\(messageOf(error)) should contain \(text)", file: file, line: line) }
    }

    // MARK: Storage

    func testMemberAndTaskLimitsAndExactlyOneKind() async throws {
        let r = try await rig()
        let b = r.backend
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "", modelKey: r.localKey) }, contains: "name")
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "X", role: String(repeating: "r", count: 41), modelKey: r.localKey) }, contains: "40")
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "X") }, contains: "model or an agent")
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "X", modelKey: r.localKey, agent: "codex") }, contains: "model or an agent")
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "X", modelKey: "0000000000000000") }, contains: "not in your list")
        await fail({ _ = try b.roomAddMember(projectId: r.pid, name: "X", agent: "codex", permission: "root") }, contains: "Permission")
        let agent = try member(r, "Codex", agent: "codex")
        XCTAssertEqual(agent.permission, "edit"); XCTAssertEqual(agent.kind, "cloud"); XCTAssertEqual(agent.provider, "openai.com")
        let model = try member(r, "Ornith", model: r.localKey)
        XCTAssertEqual(model.work, "code"); XCTAssertEqual(model.kind, "local"); XCTAssertTrue(model.usable)
        for n in 0..<6 { _ = try member(r, "M\(n)", model: r.localKey) }
        await fail({ _ = try self.member(r, "Ninth", model: r.localKey) }, contains: "up to 8")

        await fail({ _ = try b.roomAddTask(projectId: r.pid, title: " ") }, contains: "title")
        await fail({ _ = try b.roomAddTask(projectId: r.pid, title: String(repeating: "t", count: 121)) }, contains: "120")
        await fail({ _ = try b.roomAddTask(projectId: r.pid, title: "ok", detail: String(repeating: "d", count: 4001)) }, contains: "4000")
        await fail({ _ = try b.roomAddTask(projectId: r.pid, title: "ok", assignee: newID()) }, contains: "not in this room")
        _ = try b.roomAddTask(projectId: r.pid, title: String(repeating: "t", count: 120), detail: String(repeating: "d", count: 4000))
        for n in 1..<200 { _ = try b.roomAddTask(projectId: r.pid, title: "Task \(n)") }
        await fail({ _ = try b.roomAddTask(projectId: r.pid, title: "one more") }, contains: "200")
        // The log keeps the newest 100.
        let state = try b.room(projectId: r.pid)
        XCTAssertEqual(state.notes.count, 8)
        XCTAssertEqual(state.tasks.count, 200)
    }

    func testFileIsPrivateAndADamagedOrOddFileIsAnEmptyOrCleanedRoom() async throws {
        let r = try await rig()
        _ = try member(r, "Ornith", model: r.localKey)
        let file = r.fixture.stateDir + "/rooms/" + r.pid + ".json"
        var info = stat(); XCTAssertEqual(stat(file, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(r.fixture.stateDir + "/rooms", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)

        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: file))
        var state = try r.backend.room(projectId: r.pid)
        XCTAssertTrue(state.members.isEmpty); XCTAssertTrue(state.tasks.isEmpty); XCTAssertTrue(state.notes.isEmpty)

        let good = newID(), both = newID(), t1 = newID()
        let json = """
        {"members":[{"id":"\(good)","name":"Ornith","role":"x","modelKey":"abc","work":"weird"},
                    {"id":"\(both)","name":"Both","modelKey":"abc","agent":"codex"},
                    {"id":"nope","name":"Bad id","agent":"codex"}],
         "tasks":[{"id":"\(t1)","title":"Fine","status":"doing","assignee":"\(both)","detail":"\(String(repeating: "d", count: 5000))"},
                  {"id":"\(newID())","title":"Wrong status","status":"flying"},
                  {"id":"\(newID())","title":"","status":"todo"}],
         "notes":[{"at":"x","text":"kept"},{"at":5}]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: file))
        state = try r.backend.room(projectId: r.pid)
        XCTAssertEqual(state.members.map(\.id), [good]); XCTAssertEqual(state.members[0].work, "code")
        XCTAssertEqual(state.tasks.count, 1); XCTAssertNil(state.tasks[0].assignee)
        XCTAssertEqual(state.tasks[0].detail.utf16.count, 4000)
        XCTAssertTrue(state.notes.map(\.text).contains("kept")); XCTAssertEqual(state.notes.count, 2)
        // The oddly-stored "doing" task has no job behind it, so it was settled as well.
        XCTAssertEqual(state.tasks[0].status, .todo)
        await fail({ _ = try r.backend.room(projectId: "not-a-project") }, contains: "Invalid project")
    }

    // MARK: Transitions

    func testTransitionsAndTheirRefusals() async throws {
        let r = try await rig()
        let b = r.backend
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let t = try addTask(r, "Draft", to: ornith.id)
        await fail({ _ = try b.roomAccept(projectId: r.pid, taskId: t.id) }, contains: "waiting for review")
        await fail({ _ = try b.roomSendBack(projectId: r.pid, taskId: t.id, note: "x") }, contains: "waiting for review")
        _ = try b.roomUpdateTask(projectId: r.pid, taskId: t.id, title: "Draft v2", detail: "more", assignee: .some(nil))
        XCTAssertNil(try task(r, t.id).assignee)
        await fail({ _ = try await b.roomStart(projectId: r.pid, taskId: t.id) }, contains: "Assign")
        _ = try b.roomUpdateTask(projectId: r.pid, taskId: t.id, assignee: ornith.id)
        try await start(r, t.id)
        var now = try task(r, t.id)
        XCTAssertEqual(now.status, .review)
        await fail({ _ = try b.roomUpdateTask(projectId: r.pid, taskId: t.id, title: "no") }, contains: "waiting to start")
        await fail({ _ = try await b.roomStart(projectId: r.pid, taskId: t.id) }, contains: "waiting to start")
        await fail({ _ = try b.roomSendBack(projectId: r.pid, taskId: t.id, note: " ") }, contains: "note")
        let thread = try XCTUnwrap(now.threadId)
        _ = try b.roomSendBack(projectId: r.pid, taskId: t.id, note: "Shorter please")
        now = try task(r, t.id)
        XCTAssertEqual(now.status, .todo); XCTAssertEqual(now.note, "Shorter please"); XCTAssertEqual(now.assignee, ornith.id); XCTAssertEqual(now.threadId, thread)
        // Starting again continues the same conversation, with the note.
        try await start(r, t.id)
        now = try task(r, t.id)
        XCTAssertEqual(now.status, .review); XCTAssertEqual(now.threadId, thread)
        let messages = try XCTUnwrap(b.history.get(thread)?["messages"]?.array)
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(messages[2]["content"]?.string?.contains("The lead sent this back: Shorter please") == true)
        _ = try b.roomAccept(projectId: r.pid, taskId: t.id)
        XCTAssertEqual(try task(r, t.id).status, .done)
        await fail({ _ = try b.roomAccept(projectId: r.pid, taskId: t.id) }, contains: "waiting for review")
        _ = try b.roomDeleteTask(projectId: r.pid, taskId: t.id)
        XCTAssertTrue(try b.room(projectId: r.pid).tasks.isEmpty)
        XCTAssertTrue(try b.room(projectId: r.pid).notes.first?.text.contains("accepted") == true)
    }

    // MARK: Starting

    func testLocalModelMemberSwitchesModelRunsAndLandsInReview() async throws {
        let r = try await rig()
        let cloudKey = try await addCloudModel(r.backend)
        XCTAssertEqual(try r.backend.configStore.read().model.source, "cloud")
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let t = try addTask(r, "Add tests", detail: "Cover the parser.", to: ornith.id)
        _ = cloudKey
        try await start(r, t.id)
        XCTAssertEqual(try r.backend.configStore.read().model.source, "gguf")
        let done = try task(r, t.id)
        XCTAssertEqual(done.status, .review)
        XCTAssertEqual(done.result, "Private \u{1F5A4} caf\u{00E9}")
        let thread = try XCTUnwrap(r.backend.history.get(try XCTUnwrap(done.threadId)))
        XCTAssertEqual(thread["project"], .string(r.pid)); XCTAssertEqual(thread["privacy"], "local")
        XCTAssertEqual(thread["messages"]?.array?.first?["content"], "Add tests\n\nCover the parser.")
        let log = try r.backend.room(projectId: r.pid).notes.map(\.text)
        XCTAssertTrue(log.first?.contains("Ornith finished \u{201C}Add tests\u{201D}") == true)
    }

    func testCodeWorkReportsFileChanges() async throws {
        let r = try await rig()
        r.fixture.engine.action = { ref, _ in
            ref.updateLast { $0["content"] = "Done editing."; $0["events"] = [["type": "tool_use", "name": "edit", "output": "{}"], ["type": "tool_use", "name": "read", "output": "{}"],
                                                                              ["type": "tool_use", "name": "write", "output": "{}"]] }
        }
        let ornith = try member(r, "Ornith", model: r.localKey)
        let t = try addTask(r, "Refactor", to: ornith.id)
        try await start(r, t.id)
        let done = try task(r, t.id)
        XCTAssertEqual(done.status, .review); XCTAssertEqual(done.changed, 2); XCTAssertEqual(done.result, "Done editing.")
        XCTAssertTrue(try r.backend.room(projectId: r.pid).notes.first?.text.hasSuffix("2 files changed") == true)
    }

    func testAgentMemberRunsWithItsPermission() async throws {
        let r = try await rig()
        let claude = try member(r, "Claude Code", agent: "claude-code", permission: "auto")
        XCTAssertTrue(claude.usable)
        let t = try addTask(r, "Fix greet.py", to: claude.id)
        try await start(r, t.id)
        let done = try task(r, t.id)
        XCTAssertEqual(done.status, .review); XCTAssertEqual(done.result, claudeReplyText)
        XCTAssertGreaterThan(done.changed ?? 0, 0)
        let thread = try XCTUnwrap(r.backend.history.get(try XCTUnwrap(done.threadId)))
        XCTAssertEqual(thread["engine"], "claude-code"); XCTAssertEqual(thread["agentPermission"], "auto"); XCTAssertEqual(thread["project"], .string(r.pid))
        XCTAssertEqual(r.agents.commands.count, 1)
    }

    func testFailedRunReturnsToTodoWithTheError() async throws {
        let r = try await rig()
        r.fixture.reply = { _ in throw URLError(.cannotConnectToHost) }
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let t = try addTask(r, "Doomed", to: ornith.id)
        try await start(r, t.id)
        let after = try task(r, t.id)
        XCTAssertEqual(after.status, .todo); XCTAssertTrue(after.failed); XCTAssertFalse(after.note.isEmpty)
        XCTAssertNotNil(after.threadId)
        XCTAssertTrue(try r.backend.room(projectId: r.pid).notes.first?.text.contains("did not finish") == true)
        // The error is not passed off as the lead's words when the task is started again.
        r.fixture.reply = { _ in sse(answerStream) }
        try await start(r, t.id)
        let thread = try XCTUnwrap(r.backend.history.get(try XCTUnwrap(try task(r, t.id).threadId)))
        XCTAssertFalse(thread.text().contains("The lead sent this back"))
        XCTAssertEqual(try task(r, t.id).status, .review)
    }

    func testStoppedAgentRunReturnsToTodo() async throws {
        let agents = FakeAgentLauncher(lines: [])
        agents.holdUntilStopped = true
        let r = try await rig(agents: agents)
        let claude = try member(r, "Claude Code", agent: "claude-code")
        let t = try addTask(r, "Long job", to: claude.id)
        _ = try await r.backend.roomStart(projectId: r.pid, taskId: t.id)
        XCTAssertEqual(try task(r, t.id).status, .doing)
        XCTAssertTrue(try r.backend.room(projectId: r.pid).busy)
        await fail({ _ = try r.backend.roomDeleteTask(projectId: r.pid, taskId: t.id) }, contains: "Stop the running task")
        await fail({ _ = try r.backend.roomRemoveMember(projectId: r.pid, memberId: claude.id) }, contains: "finish the task")
        // One job at a time.
        let other = try addTask(r, "Second", to: claude.id)
        await fail({ _ = try await r.backend.roomStart(projectId: r.pid, taskId: other.id) }, contains: "already running")
        XCTAssertEqual(try task(r, other.id).status, .todo)
        // The tool has really started before Stop is pressed.
        for _ in 0..<400 where r.agents.commands.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(r.agents.commands.count, 1)
        r.backend.cancel()
        await r.backend.waitForIdle(); await r.backend.roomSettle()
        let after = try task(r, t.id)
        XCTAssertEqual(after.status, .todo); XCTAssertTrue(after.failed); XCTAssertTrue(after.note.lowercased().contains("stopped"))
    }

    func testATaskLeftDoingIsSettledFromItsConversation() async throws {
        let r = try await rig()
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let finished = try addTask(r, "Finished while away", to: ornith.id)
        let cut = try addTask(r, "Cut off", to: ornith.id)
        let lost = try addTask(r, "No conversation", to: ornith.id)
        func thread(_ state: String, content: String) throws -> String {
            var t = r.backend.history.create("hi")
            t = t.setting("messages", .array([["id": "a", "role": "user", "content": "hi", "state": "done"],
                                              ["id": "b", "role": "assistant", "content": .string(content), "state": .string(state)]]))
            try r.backend.history.save(t)
            return t["id"]!.string!
        }
        var data = RoomStore.load(dataFolder: r.fixture.stateDir, projectId: r.pid)
        for (id, thread) in [(finished.id, try thread("done", content: "All done")), (cut.id, try thread("writing", content: "par")), (lost.id, "")] {
            let i = data.tasks.firstIndex { $0.id == id }!
            data.tasks[i].status = .doing; data.tasks[i].threadId = thread.isEmpty ? nil : thread
        }
        try RoomStore.save(data, dataFolder: r.fixture.stateDir, projectId: r.pid)
        // "Next launch": a new Backend over the same data folder reads the room.
        let state = try r.backend.room(projectId: r.pid)
        let byTitle = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Finished while away"]?.status, .review); XCTAssertEqual(byTitle["Finished while away"]?.result, "All done")
        XCTAssertEqual(byTitle["Cut off"]?.status, .todo); XCTAssertTrue(byTitle["Cut off"]?.failed == true)
        XCTAssertTrue(byTitle["Cut off"]?.note.contains("closed") == true)
        XCTAssertEqual(byTitle["No conversation"]?.status, .todo)
        // And it was saved, not only shown.
        XCTAssertEqual(RoomStore.load(dataFolder: r.fixture.stateDir, projectId: r.pid).tasks.filter { $0.status == .doing }.count, 0)
    }

    // MARK: The gate

    func testLocalOnlyProjectRefusesCloudMembersAndLeavesTheTaskTodo() async throws {
        let r = try await rig(cloudAllowed: false)
        let cloudKey = try await addCloudModel(r.backend)
        _ = try await r.backend.switchTo(key: r.localKey)
        let big = try member(r, "Cloud Big", model: cloudKey)
        let claude = try member(r, "Claude Code", agent: "claude-code")
        XCTAssertEqual(big.kind, "cloud"); XCTAssertFalse(big.usable); XCTAssertTrue(big.reason.contains("local only"))
        XCTAssertFalse(claude.usable); XCTAssertTrue(claude.reason.contains("local only"))
        for who in [big, claude] {
            let t = try addTask(r, "Try \(who.name)", to: who.id)
            await fail({ _ = try await r.backend.roomStart(projectId: r.pid, taskId: t.id) }, contains: "local only")
            XCTAssertEqual(try task(r, t.id).status, .todo)
            XCTAssertNil(try task(r, t.id).threadId)
        }
        XCTAssertEqual(try r.backend.configStore.read().model.source, "gguf")
        XCTAssertEqual(r.agents.commands.count, 0)
        XCTAssertEqual(r.fixture.requests.list.filter { $0.url?.host == host }.count, 0)
    }

    func testAPhoneCannotStartACloudTask() async throws {
        let r = try await rig()
        let cloudKey = try await addCloudModel(r.backend)
        _ = try await r.backend.switchTo(key: r.localKey)
        let big = try member(r, "Cloud Big", model: cloudKey)
        let claude = try member(r, "Claude Code", agent: "claude-code")
        for who in [big, claude] {
            let t = try addTask(r, "From phone \(who.name)", to: who.id)
            do { _ = try await r.backend.roomStart(projectId: r.pid, taskId: t.id, from: .phone); XCTFail("a phone started a cloud task") } catch {}
            XCTAssertEqual(try task(r, t.id).status, .todo)
        }
        XCTAssertEqual(r.agents.commands.count, 0)
        XCTAssertEqual(r.fixture.requests.list.filter { $0.url?.host == host }.count, 0)
        // The same task starts from the Mac.
        let t = try addTask(r, "From the Mac", to: claude.id)
        try await start(r, t.id)
        XCTAssertEqual(try task(r, t.id).status, .review)
    }

    func testMembersReportMissingModelAndMissingTool() async throws {
        let agents = FakeAgentLauncher(lines: []); agents.tool = nil
        let r = try await rig(agents: agents)
        let gone = try member(r, "Gone", model: r.localKey)
        try r.backend.savedModels.forget(r.localKey)
        let state = try r.backend.room(projectId: r.pid)
        XCTAssertFalse(state.members.first { $0.id == gone.id }!.usable)
        XCTAssertTrue(state.members.first { $0.id == gone.id }!.reason.contains("no longer in your list"))
        let codex = try member(r, "Codex", agent: "codex")
        XCTAssertFalse(codex.usable); XCTAssertTrue(codex.reason.contains("not installed"))
    }

    // MARK: Hand-off

    /// A finished task by a local member, ready to hand on.
    func finished(_ r: Rig, detail: String = "ORIGINAL-SECRET-DETAIL") async throws -> (RoomMemberView, RoomTask) {
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let t = try addTask(r, "Draft notes", detail: detail, to: ornith.id)
        try await start(r, t.id)
        XCTAssertEqual(try task(r, t.id).status, .review)
        return (ornith, try task(r, t.id))
    }

    func testHandOffPreviewDigestAndRefusals() async throws {
        let r = try await rig()
        let (_, source) = try await finished(r)
        let claude = try member(r, "Claude Code", agent: "claude-code")
        let b = r.backend
        let p = try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: claude.id, title: "Review it", detail: "Check tone")
        XCTAssertEqual(p.text, "Review it\n\nCheck tone\n\nResult from Ornith:\nPrivate \u{1F5A4} caf\u{00E9}")
        XCTAssertTrue(p.leavesThisMac); XCTAssertEqual(p.provider, "anthropic.com")
        XCTAssertEqual(p.digest, roomDigest(text: p.text, receiver: claude.id))
        // Any change to the text or the receiver changes the digest.
        let p2 = try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: claude.id, title: "Review it", detail: "Check tone!")
        XCTAssertNotEqual(p.digest, p2.digest)
        let other = try member(r, "Codex", agent: "codex")
        XCTAssertNotEqual(p.digest, try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: other.id, title: "Review it", detail: "Check tone").digest)
        // A mismatch is refused and nothing is created.
        let before = try b.room(projectId: r.pid).tasks.count
        await fail({ _ = try b.roomHandOff(projectId: r.pid, taskId: source.id, to: claude.id, title: "Review it", detail: "Check tone!!", digest: p.digest) }, contains: "changed")
        await fail({ _ = try b.roomHandOff(projectId: r.pid, taskId: source.id, to: claude.id, title: "Review it", detail: "Check tone", includeResult: false, digest: p.digest) }, contains: "changed")
        await fail({ _ = try b.roomHandOff(projectId: r.pid, taskId: source.id, to: other.id, title: "Review it", detail: "Check tone", digest: p.digest) }, contains: "changed")
        XCTAssertEqual(try b.room(projectId: r.pid).tasks.count, before)
        // The matching digest creates a todo task, assigned, linked to the source, with the previewed text as its message.
        let state = try b.roomHandOff(projectId: r.pid, taskId: source.id, to: claude.id, title: "Review it", detail: "Check tone", digest: p.digest)
        let made = try XCTUnwrap(state.tasks.last)
        XCTAssertEqual(made.status, .todo); XCTAssertEqual(made.assignee, claude.id); XCTAssertEqual(made.from, source.id); XCTAssertNil(made.threadId)
        XCTAssertEqual(roomMessage(title: made.title, detail: made.detail, inherited: made.inherited, sentBack: nil), p.text)
        XCTAssertTrue(state.notes.first?.text == "Handed to Claude Code by you")
        // Without the result, only the new title and detail are given.
        let bare = try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: claude.id, title: "Fresh", detail: "", includeResult: false)
        XCTAssertEqual(bare.text, "Fresh"); XCTAssertFalse(bare.text.contains("Result from"))
        let made2 = try XCTUnwrap(try b.roomHandOff(projectId: r.pid, taskId: source.id, to: claude.id, title: "Fresh", detail: "", includeResult: false, digest: bare.digest).tasks.last)
        XCTAssertEqual(made2.inherited, "")
        // A local receiver stays on this Mac; only a finished task can be handed on.
        let ornith = try XCTUnwrap(try b.room(projectId: r.pid).members.first { $0.name == "Ornith" })
        let local = try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: ornith.id)
        XCTAssertFalse(local.leavesThisMac); XCTAssertEqual(local.provider, "")
        await fail({ _ = try b.roomHandOffPreview(projectId: r.pid, taskId: made.id, to: ornith.id) }, contains: "finished")
    }

    func testACloudReceiverGetsOnlyThePreviewedText() async throws {
        let r = try await rig()
        let cloudKey = try await addCloudModel(r.backend)
        _ = try await r.backend.switchTo(key: r.localKey)
        let (_, source) = try await finished(r)
        let big = try member(r, "Cloud Big", model: cloudKey, work: "chat")
        let b = r.backend
        let preview = try b.roomHandOffPreview(projectId: r.pid, taskId: source.id, to: big.id, title: "Review the draft", detail: "Check tone")
        XCTAssertTrue(preview.leavesThisMac); XCTAssertEqual(preview.provider, host)
        let state = try b.roomHandOff(projectId: r.pid, taskId: source.id, to: big.id, title: preview.title, detail: preview.detail, digest: preview.digest)
        let handed = try XCTUnwrap(state.tasks.last)
        let before = r.fixture.requests.count
        try await start(r, handed.id)
        let done = try task(r, handed.id)
        XCTAssertEqual(done.status, .review); XCTAssertEqual(done.result, "Cloud answer")
        let sent = r.fixture.requests.list.suffix(from: before).filter { $0.url?.host == host }
        XCTAssertEqual(sent.count, 1)
        let body = try JSONValue.parse(try XCTUnwrap(sent.first?.httpBody))
        let messages = body["messages"]?.array ?? []
        // What the cloud model was sent as the user's words is exactly the previewed text, once.
        XCTAssertEqual(messages.filter { $0["role"]?.string == "user" }.compactMap { $0["content"]?.string }, [preview.text])
        let everything = body.text()
        for secret in ["ORIGINAL-SECRET-DETAIL", "Draft notes", vaultCore, vaultNote, "Vault-Secret-Alpha", "Vault-Secret-Beta"] {
            XCTAssertFalse(everything.contains(secret), "\(secret) reached the cloud request")
        }
        XCTAssertFalse(messages.contains { $0["role"]?.string == "assistant" })
        // A new conversation, not the local member's.
        XCTAssertNotEqual(done.threadId, source.threadId)
        let thread = try XCTUnwrap(b.history.get(try XCTUnwrap(done.threadId)))
        XCTAssertEqual(thread["messages"]?.array?.count, 2); XCTAssertEqual(thread["privacy"], "cloud")
        XCTAssertEqual(b.history.get(try XCTUnwrap(source.threadId))?["privacy"], "local")
    }

    func testACloudResultCanGoToALocalMemberThroughTheSameCall() async throws {
        let r = try await rig()
        let cloudKey = try await addCloudModel(r.backend)
        _ = try await r.backend.switchTo(key: r.localKey)
        let big = try member(r, "Cloud Big", model: cloudKey, work: "chat")
        let ornith = try member(r, "Ornith", model: r.localKey, work: "chat")
        let t = try addTask(r, "Plan", to: big.id)
        try await start(r, t.id)
        let preview = try r.backend.roomHandOffPreview(projectId: r.pid, taskId: t.id, to: ornith.id)
        XCTAssertFalse(preview.leavesThisMac)
        XCTAssertEqual(preview.text, "Plan\n\nResult from Cloud Big:\nCloud answer")
        let handed = try XCTUnwrap(try r.backend.roomHandOff(projectId: r.pid, taskId: t.id, to: ornith.id, title: preview.title, detail: preview.detail, digest: preview.digest).tasks.last)
        try await start(r, handed.id)
        let done = try task(r, handed.id)
        XCTAssertEqual(done.status, .review)
        XCTAssertEqual(r.backend.history.get(try XCTUnwrap(done.threadId))?["privacy"], "local")
    }
}
