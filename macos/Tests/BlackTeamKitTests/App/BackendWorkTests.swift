import XCTest
@testable import BlackTeamKit

// Projects, memory, Code and the keeper (tests/server.test.cjs).
final class BackendWorkTests: XCTestCase {
    func testProjectsGetAFolderInTheWorkspaceAndNotesInMemoryAndMemoryStaysInsideTheVault() async throws {
        let fixture = try BackendFixture(self)
        let work = fixture.files.dir + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false)
        try fixture.rewriteConfig { $0.workspace = work }
        let backend = try fixture.make()
        let made = try backend.createProject(name: "Night Shift")
        let real = String(cString: realpath(work, nil)!)
        XCTAssertEqual(made.workspace, real + "/night-shift")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.workspace, isDirectory: &isDirectory) && isDirectory.boolValue)
        for name in ["night shift", "../x", "", ".hidden", String(repeating: "x", count: 61)] {
            XCTAssertThrowsError(try backend.createProject(name: name), name)
        }
        let status = try await backend.status()
        XCTAssertEqual(status.projects.map { [$0.name, String($0.exists), $0.notes] }, [["Night Shift", "true", "Projects/night-shift"]])
        let overview = try String(contentsOfFile: backend.dataFolder + "/vault/Projects/night-shift/Overview.md", encoding: .utf8)
        XCTAssertTrue(overview.hasPrefix("# Night Shift\n"))
        try backend.memorySave("Plan", content: "# Plan\n\nShip it. See [[Later]].")
        XCTAssertEqual(try backend.memoryNote("Plan").content, "# Plan\n\nShip it. See [[Later]].")
        XCTAssertThrowsError(try backend.memorySave("../escape", content: "x")) { assertMatch(messageOf($0), "valid note name") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backend.dataFolder + "/escape.md"))
        let hits = try await backend.memorySearch("ship")
        XCTAssertEqual(hits.first?.id, "Plan")
        let overviewData = try backend.memoryOverview()
        XCTAssertTrue(overviewData.graph.edges.contains { $0.from == "Plan" && $0.to == "?Later" })
        XCTAssertEqual(overviewData.keeper.limits.noteChars, 6000)
        XCTAssertEqual(overviewData.keeper.usage.notes, 2)
        XCTAssertEqual(try backend.memoryRemember(title: "House rule", text: "Small diffs.", project: made.id), "Projects/night-shift/House rule")
        XCTAssertThrowsError(try backend.memoryRemember(title: "Core", text: "x"))
        let tidied = await backend.memoryTidy()
        XCTAssertEqual(tidied, "Memory is within its limits.")
        try backend.memoryDelete("Plan")
        XCTAssertThrowsError(try backend.memoryNote("Plan"))
        XCTAssertThrowsError(try backend.submit(message: "In a project", requestId: newID(), project: newID())) { assertMatch(messageOf($0), "no longer exists") }
        // Projects survive a restart.
        await backend.shutdown()
        let restarted = try fixture.make()
        XCTAssertEqual(restarted.projectList().map(\.name), ["Night Shift"])
    }

    func testCodeRunsOnTheBuiltInEngineInTheProjectFolderKeepsItsEngineAndUndoWaitsForARunningTask() async throws {
        let fixture = try BackendFixture(self)
        let work = fixture.files.dir + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false)
        try fixture.rewriteConfig { $0.workspace = work }
        let gate = BackendGate()
        fixture.engine.action = { ref, _ in await gate.wait(); ref.updateLast { $0["content"] = "Edited." } }
        let backend = try fixture.make()
        let project = try backend.createProject(name: "Alpha")
        let result = try backend.submit(message: "Change a.txt", kind: "agent", mode: "deep", requestId: newID(), project: project.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.engine.runs.first?.workspace, project.workspace)
        XCTAssertEqual(fixture.engine.runs.first?.mode, "deep")
        XCTAssertEqual(fixture.requests.count, 0)
        XCTAssertEqual(backend.thread(result.threadId)?["kind"]?.string, "agent")
        XCTAssertThrowsError(try backend.undo(String(repeating: "a", count: 24))) { assertMatch(messageOf($0), "Wait for the running task") }
        await gate.open()
        await backend.waitForIdle()
        let thread = backend.history.get(result.threadId)!
        XCTAssertEqual(thread["engine"]?.string, "black-team")
        XCTAssertEqual(thread["project"]?.string, project.id)
        XCTAssertEqual(thread["messages"]!.array!.last!["state"]?.string, "done")
        XCTAssertEqual(thread["messages"]!.array!.last!["content"]?.string, "Edited.")
        XCTAssertEqual(backend.threads()[0], ThreadSummary(id: thread["id"]!.string!, title: "Change a.txt", updated: thread["updated"]!.string!, kind: "agent", project: project.id))
        XCTAssertEqual(try backend.undo(String(repeating: "a", count: 24)), UndoResult(path: "a.txt", removed: false))
        XCTAssertEqual(fixture.engine.undone, [String(repeating: "a", count: 24)])
        // A chat message cannot join a Code conversation, and a Hermes conversation is not moved to another engine.
        XCTAssertThrowsError(try backend.submit(message: "chat", kind: "chat", requestId: newID(), threadId: result.threadId)) { assertMatch(messageOf($0), "new conversation") }
        var old = backend.history.create("Old Hermes task")
        old = old.setting("kind", "agent").setting("hermesSession", "saved").setting("messages", [
            ["id": .string(newID()), "role": "user", "content": "x", "state": "done"],
            ["id": .string(newID()), "role": "assistant", "content": "y", "state": "done"],
        ])
        try backend.history.save(old)
        XCTAssertThrowsError(try backend.submit(message: "continue", kind: "agent", requestId: newID(), threadId: old["id"]!.string!)) { assertMatch(messageOf($0), "uses Hermes") }
    }

    func testACodeFailureIsSavedAndStopIsReportedAsInterrupted() async throws {
        let fixture = try BackendFixture(self)
        fixture.engine.action = { _, _ in throw BlackTeamError("Code needs a context window of at least 8,192 tokens.") }
        let backend = try fixture.make()
        let sent = try backend.submit(message: "go", kind: "agent", requestId: newID())
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "error")
        assertMatch(lastMessage(backend, sent.threadId)["error"]?.string ?? "", "at least 8,192")
        let status = try await backend.status()
        XCTAssertEqual(status.job?.state, "error")
        XCTAssertEqual(status.job?.kind, "agent")

        let gate = BackendGate()
        fixture.engine.action = { _, _ in await gate.wait(); throw CancellationError() }
        let again = try backend.submit(message: "go again", kind: "agent", requestId: newID(), threadId: sent.threadId)
        try await Task.sleep(nanoseconds: 50_000_000)
        backend.cancel()
        await gate.open()
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, again.threadId)["state"]?.string, "interrupted")
        XCTAssertEqual(lastMessage(backend, again.threadId)["error"]?.string, "Response stopped.")
    }

    func testTheKeeperCondensesAnOversizedNoteWithALoadedIdleModelAndNeverStartsOneItself() async throws {
        let fixture = try BackendFixture(self)
        let vault = fixture.files.dir + "/keeper-vault"
        let memory = try Memory(vault: vault, limits: MemoryLimits(noteChars: 300, journalEntries: 30, totalChars: 400_000))
        try memory.write("Notes/Long", "# Long\n\n" + String(repeating: "- a repeated fact about the build\n", count: 30))
        fixture.memory = memory
        let gate = BackendGate()
        let sent = ServerRequests()
        fixture.fetch = { request in
            sent.add(request)
            await gate.wait()
            let body = "{\"choices\":[{\"message\":{\"content\":\"# Long\\n\\n- The build fact, once.\"}}]}"
            return (Data(body.utf8), httpResponse())
        }
        let backend = try fixture.make()
        let first = await backend.memoryTidy()
        assertMatch(first, "^Start your model")
        XCTAssertEqual(fixture.runtime.starts, 0)
        XCTAssertEqual(sent.count, 0)
        fixture.runtime.state = .ready
        let second = await backend.memoryTidy()
        assertMatch(second, "^Condensing one note")
        let status = try await backend.status()
        XCTAssertEqual(status.job?.kind, "memory")
        XCTAssertThrowsError(try backend.submit(message: "Hello", requestId: newID())) { assertMatch(messageOf($0), "already running") }
        await gate.open()
        await backend.waitForIdle()
        XCTAssertEqual(sent.body(0)["stream"]?.bool, false)
        XCTAssertEqual(sent.list[0].value(forHTTPHeaderField: "Authorization"), "Bearer local-test-key")
        assertMatch(try memory.read("Notes/Long").content, "^# Long\n\n- The build fact, once\\.\n\n_Condensed by Black Team")
        let keeper = try backend.memoryOverview().keeper
        XCTAssertEqual(keeper.usage.oversized.count, 0)
        XCTAssertEqual(keeper.usage.archived, 1)
        assertMatch(keeper.actions[0].text, "^Condensed Long from")
        XCTAssertEqual(fixture.runtime.busy, [true, false])
        // The keeper's log survives a restart.
        await backend.shutdown()
        XCTAssertEqual(try fixture.make().memoryOverview().keeper.actions.first?.text, keeper.actions[0].text)
    }

    func testTheIdleKeeperSweepsOnlyAfterFifteenQuietMinutes() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        await backend.keeperTick()
        XCTAssertEqual(try backend.memoryOverview().keeper.actions.count, 0)
    }

    func testRenamingAConversationChangesOnlyItsTitle() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let sent = try backend.submit(message: "hello", requestId: newID())
        await backend.waitForIdle()
        try backend.renameThread(sent.threadId, title: "  A   better\ttitle ")
        XCTAssertEqual(backend.threads().first?.title, "A better title")
        XCTAssertThrowsError(try backend.renameThread(sent.threadId, title: " "))
        XCTAssertThrowsError(try backend.renameThread(newID(), title: "x"))
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "done")
    }
}
