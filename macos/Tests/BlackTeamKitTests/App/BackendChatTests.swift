import XCTest
@testable import BlackTeamKit

// Ports of the chat tests in tests/server.test.cjs, over the Backend instead of HTTP.
final class BackendChatTests: XCTestCase {
    func hashOf(_ parts: [JSONValue]) -> String {
        SHA256.hash(data: Data(JSONValue.array(parts).text().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testOneChatStreamsSplitUTF8DeduplicatesRetriesAndStaysDeduplicatedAfterRestart() async throws {
        let fixture = try BackendFixture(self)
        let gate = BackendGate()
        fixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        let backend = try fixture.make()
        let requestId = newID()
        let sent = try backend.submit(message: " A private question ", mode: "deep", requestId: requestId)
        XCTAssertEqual(sent.state, "running")
        XCTAssertEqual(try backend.submit(message: " A private question ", mode: "deep", requestId: requestId), sent)
        XCTAssertThrowsError(try backend.submit(message: "different", mode: "deep", requestId: requestId)) {
            XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("Request ID was already used for another message."))
        }
        XCTAssertThrowsError(try backend.submit(message: "A private question", mode: "deep", requestId: newID())) {
            assertMatch(messageOf($0), "already running")
        }
        await gate.open()
        await backend.waitForIdle()
        XCTAssertEqual(fixture.runtime.starts, 1)
        XCTAssertEqual(fixture.requests.count, 1)
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["content"]?.string, "Private \u{1F5A4} caf\u{00E9}")
        XCTAssertEqual(reply["state"]?.string, "done")
        XCTAssertEqual(fixture.planned.modes, ["deep"])
        XCTAssertEqual(fixture.planned.messages[0].last?["content"]?.string, "A private question")
        let request = fixture.requests.list[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-key")
        let body = fixture.requests.body(0)
        XCTAssertEqual(body["max_tokens"]?.int, 512)
        XCTAssertEqual(body["stream"]?.bool, true)
        // The thinking level travels with every request, as one consistent set of fields.
        let thinking = body["chat_template_kwargs"]?["enable_thinking"]?.bool
        XCTAssertNotNil(thinking)
        XCTAssertEqual(body["reasoning_effort"]?.string == "none", thinking == false)
        XCTAssertEqual(fixture.runtime.busy, [true, false])
        await backend.shutdown()
        let restarted = try fixture.make()
        XCTAssertEqual(try restarted.submit(message: " A private question ", mode: "deep", requestId: requestId).state, "done")
        XCTAssertEqual(fixture.runtime.starts, 1)
        XCTAssertFalse(restarted.isBusy)
    }

    func testStartupFailureIsSavedAndARetryIDNeverRestartsTheModel() async throws {
        let fixture = try BackendFixture(self)
        fixture.runtime.startAction = { throw BlackTeamError("Missing runtime library") }
        let backend = try fixture.make()
        let requestId = newID()
        let sent = try backend.submit(message: "hello", requestId: requestId)
        await backend.waitForIdle()
        XCTAssertEqual(fixture.runtime.starts, 1)
        XCTAssertEqual(fixture.requests.count, 0)
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        assertMatch(reply["error"]?.string ?? "", "Missing runtime")
        XCTAssertEqual(try backend.submit(message: "hello", requestId: requestId).state, "error")
        XCTAssertEqual(fixture.runtime.starts, 1)
        await backend.shutdown()
        XCTAssertEqual(try fixture.make().submit(message: "hello", requestId: requestId).state, "error")
        XCTAssertEqual(fixture.runtime.starts, 1)
    }

    func testCancelDuringStartupIsDurableSendsNoInferenceAndDoesNotRetryAfterRestart() async throws {
        let fixture = try BackendFixture(self)
        let gate = BackendGate()
        fixture.runtime.state = .starting
        fixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        let backend = try fixture.make()
        let requestId = newID()
        let sent = try backend.submit(message: "hello", requestId: requestId)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(backend.cancel().stopping)
        await gate.open()
        await backend.waitForIdle()
        XCTAssertEqual(fixture.requests.count, 0)
        XCTAssertEqual(fixture.planned.modes.count, 0)
        XCTAssertEqual(fixture.runtime.stops, [true])
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "interrupted")
        await backend.shutdown()
        XCTAssertEqual(try fixture.make().submit(message: "hello", requestId: requestId).state, "interrupted")
        XCTAssertEqual(fixture.runtime.starts, 1)
        XCTAssertFalse(backend.cancel().stopping)
    }

    func testInterruptedPersistedRequestIsRecoveredWithoutAutomaticModelStartup() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let requestId = newID(), message = "recover this conversation"
        var thread = backend.history.create(message)
        thread = thread.setting("messages", [
            ["id": .string(newID()), "role": "user", "content": .string(message), "state": "done"],
            ["id": .string(newID()), "role": "assistant", "content": "partial", "state": "writing"],
        ])
        backend.history.remember(&thread, ["id": .string(requestId), "state": "running", "hash": .string(hashOf([.null, .string(message), "balanced"]))])
        try backend.history.save(thread)
        await backend.shutdown()
        let restarted = try fixture.make()
        XCTAssertEqual(try restarted.submit(message: message, requestId: requestId).state, "interrupted")
        XCTAssertEqual(lastMessage(restarted, thread["id"]!.string!)["content"]?.string, "partial")
        XCTAssertEqual(fixture.runtime.starts, 0)
    }

    func testIncompleteInferenceIsPersistedAsAnErrorWithNoAutomaticRetry() async throws {
        let fixture = try BackendFixture(self)
        fixture.reply = { _ in sse("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n") }
        let backend = try fixture.make()
        let requestId = newID()
        let sent = try backend.submit(message: "hello", requestId: requestId)
        await backend.waitForIdle()
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        XCTAssertEqual(reply["content"]?.string, "partial")
        assertMatch(reply["error"]?.string ?? "", "before the response finished")
        XCTAssertEqual(try backend.submit(message: "hello", requestId: requestId).state, "error")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testEmptyVisibleAnswerIsAnErrorEvenWhenTheStreamEndsNormally() async throws {
        let fixture = try BackendFixture(self)
        fixture.reply = { _ in sse("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden thought\"}}]}\ndata: [DONE]\n") }
        let backend = try fixture.make()
        let sent = try backend.submit(message: "hello", requestId: newID())
        await backend.waitForIdle()
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        XCTAssertEqual(reply["content"]?.string, "")
        assertMatch(reply["error"]?.string ?? "", "no visible answer")
    }

    func testAFailedFirstPersistenceDoesNotMutateAnExistingConversationOrPoisonRetryIDs() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let first = try backend.submit(message: "first", requestId: newID())
        await backend.waitForIdle()
        let before = backend.history.get(first.threadId)
        let secondId = newID()
        let folder = backend.history.dir
        chmod(folder, 0o500)
        XCTAssertThrowsError(try backend.submit(message: "second", requestId: secondId, threadId: first.threadId))
        chmod(folder, 0o700)
        XCTAssertEqual(backend.history.get(first.threadId), before)
        XCTAssertNil(backend.history.request(secondId))
        XCTAssertFalse(backend.isBusy)
        XCTAssertEqual(fixture.runtime.starts, 1)
        try backend.submit(message: "second", requestId: secondId, threadId: first.threadId)
        await backend.waitForIdle()
        XCTAssertEqual(fixture.runtime.starts, 2)
    }

    func testAnOversizedSingleContentDeltaCannotCreateHistoryThatFailsToReopen() async throws {
        let fixture = try BackendFixture(self)
        let big = "data: " + JSONValue.object(["choices": [["delta": ["content": .string(String(repeating: "x", count: 300_000))]]]]).text() + "\ndata: [DONE]\n"
        fixture.reply = { _ in sse(big) }
        let backend = try fixture.make()
        let sent = try backend.submit(message: "hello", requestId: newID())
        await backend.waitForIdle()
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        XCTAssertLessThanOrEqual(reply["content"]?.string?.utf16.count ?? 0, 256 * 1024)
        assertMatch(reply["error"]?.string ?? "", "storage limit")
        await backend.shutdown()
        XCTAssertNoThrow(try fixture.make())
    }

    func testCompatibleServerChatUsesTheSelectedModelExplicitEstimatesAndNeverPublishesItsKey() async throws {
        let fixture = try BackendFixture(self, server: true)
        let backend = try fixture.make()
        let status = try await backend.status()
        XCTAssertTrue(status.setupComplete)
        XCTAssertTrue(status.serverKeyConfigured)
        let encoded = String(data: try JSONEncoder().encode(status), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("private-server-credential"))
        try backend.submit(message: "Hello", requestId: newID())
        await backend.waitForIdle()
        XCTAssertEqual(fixture.requests.body(0)["model"]?.string, "a-custom-model")
        XCTAssertEqual(fixture.planned.modes.count, 0)
        let thread = backend.history.get(backend.history.list()[0].id)!
        let reply = thread["messages"]!.array!.last!
        XCTAssertEqual(reply["context"]?["method"]?.string, "estimated-bytes")
        XCTAssertEqual(reply["state"]?.string, "done")
    }

    func testChatIsToldCoreOnceRecallsMatchingNotesReplaysEarlierTurnsUnchangedAndReportsMeasuredSpeed() async throws {
        let fixture = try BackendFixture(self)
        fixture.reply = { _ in sse(timedStream) }
        let backend = try fixture.make()
        try backend.memorySave("Core", content: "Prefers one-sentence answers.")
        XCTAssertEqual(try backend.memoryRemember(title: "Release process", text: "Deploy with make ship after the tests pass."), "Notes/Release process")
        let first = try backend.submit(message: "How do I deploy after the tests pass?", requestId: newID())
        await backend.waitForIdle()
        let sent = fixture.requests.body(0)["messages"]!.array!
        assertMatch(sent[0]["content"]!.string!, "What you know about the user:\nPrefers one-sentence answers\\.$")
        assertMatch(sent[1]["content"]!.string!, "^How do I deploy after the tests pass\\?\n\n\\[From your memory\\. Use it only if it is relevant\\.\\]\n- Release process: .*make ship")
        let thread = backend.history.get(first.threadId)!
        XCTAssertEqual(thread["messages"]![0]!["recalled"]?.array?.compactMap { $0["title"]?.string }, ["Release process"])
        let meter = thread["messages"]![1]!["meter"]!
        XCTAssertEqual(meter["read"]?.int, 49)
        XCTAssertEqual(meter["write"]?.int, 12)
        XCTAssertEqual(meter["used"]?.int, 30)
        XCTAssertEqual(meter["budget"]?.int, 3000)
        // An unrelated message is not padded with memory, and Core stays as it was when the conversation began.
        try backend.memorySave("Core", content: "Changed later.")
        try backend.submit(message: "Thanks!", requestId: newID(), threadId: first.threadId)
        await backend.waitForIdle()
        let again = fixture.requests.body(1)["messages"]!.array!
        XCTAssertEqual(Array(again.prefix(2)), Array(sent.prefix(2)))
        XCTAssertEqual(again.last?["content"]?.string, "Thanks!")
        XCTAssertEqual(backend.history.get(first.threadId)!["messages"]![2]!["recalled"], [])
    }

    func testTheStatusFiguresPublishedToTheInterfaceDoNotIncludeKeysAndShowTheSavedModel() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let status = try await backend.status()
        XCTAssertEqual(status.version, "0.1.0-test")
        XCTAssertEqual(status.runtime.name, "Fixture model")
        XCTAssertEqual(status.runtime.state, "off")
        XCTAssertNil(status.job)
        XCTAssertEqual(status.models.map(\.name), ["Fixture model"])
        XCTAssertTrue(status.memory)
        XCTAssertFalse(status.codeMap)
        XCTAssertGreaterThan(status.hardware.memory.total, 0)
        XCTAssertEqual(status.config.model.file, fixture.files.model)
    }

    func testTheInterfaceIsToldWhenAJobChanges() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let changes = backend.changes()
        let heard = expectation(description: "changed")
        heard.assertForOverFulfill = false
        let listener = Task { for await _ in changes { heard.fulfill() } }
        try backend.submit(message: "hello", requestId: newID())
        await fulfillment(of: [heard], timeout: 3)
        await backend.waitForIdle()
        listener.cancel()
    }

    func testApprovalsNeedAnActiveApprovalAndUndoWaitsForARunningTask() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.approve(id: "x", digest: "y", choice: "once")) { XCTAssertEqual(messageOf($0), "No active approval.") }
        let gate = BackendGate()
        fixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        try backend.submit(message: "hello", requestId: newID())
        XCTAssertThrowsError(try backend.undo(String(repeating: "a", count: 24))) {
            XCTAssertEqual(messageOf($0), "Wait for the running task to finish, or stop it, before undoing an edit.")
        }
        await gate.open()
        await backend.waitForIdle()
        XCTAssertEqual(try backend.undo(String(repeating: "a", count: 24)), UndoResult(path: "a.txt", removed: false))
    }

    func testValidationRefusesBadInputBeforeAnythingIsSaved() throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.submit(message: "  ", requestId: newID())) { assertMatch(messageOf($0), "up to 16,000") }
        XCTAssertThrowsError(try backend.submit(message: String(repeating: "x", count: 16001), requestId: newID()))
        XCTAssertThrowsError(try backend.submit(message: "hi", kind: "other", requestId: newID())) { XCTAssertEqual(messageOf($0), "Choose Chat or Agent work.") }
        XCTAssertThrowsError(try backend.submit(message: "hi", mode: "wild", requestId: newID())) { XCTAssertEqual(messageOf($0), "Choose a supported response length.") }
        XCTAssertThrowsError(try backend.submit(message: "hi", requestId: "nope")) { XCTAssertEqual(messageOf($0), "A valid request ID is required.") }
        XCTAssertThrowsError(try backend.submit(message: "hi", requestId: newID(), threadId: "bad")) { XCTAssertEqual(messageOf($0), "Invalid conversation ID.") }
        XCTAssertThrowsError(try backend.submit(message: "hi", requestId: newID(), threadId: newID())) { XCTAssertEqual(messageOf($0), "Conversation not found.") }
        XCTAssertThrowsError(try backend.submit(message: "hi", requestId: newID(), project: newID())) { assertMatch(messageOf($0), "no longer exists") }
        XCTAssertTrue(backend.threads().isEmpty)
    }

    func testSetupMustBeCompleteBeforeAMessageIsAccepted() throws {
        let fixture = try BackendFixture(self)
        try fixture.rewriteConfig { $0.model.file = ""; $0.model.runtime = "" }
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.submit(message: "hi", requestId: newID())) {
            XCTAssertEqual(messageOf($0), "Complete model setup in the desktop app first.")
        }
    }

    func testAnArtifactIsFoundOnlyWhenAConversationListsItAndItIsARegularFile() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let id = String(repeating: "ab", count: 16)
        var thread = backend.history.create("make a file")
        thread = thread.setting("messages", [
            ["id": .string(newID()), "role": "user", "content": "x", "state": "done"],
            ["id": .string(newID()), "role": "assistant", "content": "y", "state": "done", "artifacts": [["id": .string(id), "name": "report one.txt"]]],
        ])
        try backend.history.save(thread)
        XCTAssertThrowsError(try backend.artifactFile(id)) { XCTAssertEqual(messageOf($0), "File not found.") }
        try FileManager.default.createDirectory(atPath: backend.dataFolder + "/artifacts", withIntermediateDirectories: true)
        try "data".write(toFile: backend.dataFolder + "/artifacts/" + id, atomically: true, encoding: .utf8)
        let file = try backend.artifactFile(id)
        XCTAssertEqual(file.name, "report one.txt")
        XCTAssertEqual(file.size, 4)
        XCTAssertThrowsError(try backend.artifactFile("../etc"))
        XCTAssertThrowsError(try backend.artifactFile(String(repeating: "cd", count: 16)))
        try FileManager.default.removeItem(atPath: backend.dataFolder + "/artifacts/" + id)
        try FileManager.default.createSymbolicLink(atPath: backend.dataFolder + "/artifacts/" + id, withDestinationPath: fixture.files.model)
        XCTAssertThrowsError(try backend.artifactFile(id))
    }

    func testShutdownStopsTheJobAndTheRuntime() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        await backend.shutdown()
        XCTAssertEqual(fixture.runtime.disposals, 1)
        XCTAssertThrowsError(try backend.submit(message: "late", requestId: newID())) { XCTAssertEqual(messageOf($0), "Black Team is closing.") }
    }
}
