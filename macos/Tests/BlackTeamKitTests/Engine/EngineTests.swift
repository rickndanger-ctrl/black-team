import XCTest
@testable import BlackTeamKit

/// Ports of the engine-loop tests in tests/engine.test.cjs (the tool-only ones live in ToolsTests).
final class EngineTests: XCTestCase {
    var scratch = ""
    var stateDir: String { scratch + "/state" }

    override func setUpWithError() throws {
        let base = try XCTUnwrap(PathUtil.realpath(NSTemporaryDirectory()))
        scratch = base + "/bt-engine-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

    struct Session {
        var dir: String
        var id: String
        var thread: ThreadRef
        var config: Config
        var job = JobState()
        var stop = CancelSignal()
        var reply: JSONValue { thread.value["messages"]!.array!.last! }
        var events: [JSONValue] { reply["events"]?.array ?? [] }
    }

    func setup(_ message: String = "Do the task", context: Int = 65536) throws -> Session {
        let dir = scratch + "/ws-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let thread: JSONValue = ["id": .string(id), "kind": "agent", "messages": [
            ["id": .string(UUID().uuidString.lowercased()), "role": "user", "content": .string(message), "state": "done"],
            ["id": .string(UUID().uuidString.lowercased()), "role": "assistant", "content": "", "state": "writing"]]]
        let config = Config(model: ModelConfig(source: "gguf", file: "/models/fixture.gguf", context: context), workspace: dir)
        return Session(dir: dir, id: id, thread: ThreadRef(thread), config: config)
    }

    func engine(_ fetch: @escaping HTTPStreamFetch, vault: Memory? = nil) throws -> Engine {
        try Engine(stateDir: stateDir, vault: vault, fetch: fetch, home: scratch, useRtk: false)
    }

    /// One Code turn, as the server runs it.
    func run(_ s: Session, _ fetch: @escaping HTTPStreamFetch, vault: Memory? = nil, mode: String = "fast") async throws {
        let instance = try engine(fetch, vault: vault)
        try await instance.run(thread: s.thread, config: s.config, runtime: FixedHeadersRuntime(["Authorization": "Bearer engine-test-key"]),
                               endpoint: "http://127.0.0.1:5555/v1", job: s.job, signal: s.stop, save: { _ in }, mode: mode)
    }

    func saved(_ id: String) throws -> JSONValue {
        try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: "\(stateDir)/engine/\(id).json")))
    }
    func put(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: false, encoding: .utf8) }
    func get(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    func pause(_ milliseconds: UInt64 = 5) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }

    func testLoopRunsToolsFeedsResultsBackAndFinishesWithTheModelText() async throws {
        let s = try setup(); let seen = Seen()
        try put(s.dir + "/a.txt", "one\ntwo\nthree\n")
        try await run(s, fakeModel([
            Step(text: "Looking.", calls: [("read", ["path": "a.txt", "start": 2, "lines": 1])], speed: 60),
            Step(calls: [("edit", ["path": "a.txt", "old": "two", "new": "TWO"]), ("todo", ["items": [["text": "edit a.txt", "done": true]]])]),
            Step(text: "Changed line 2."),
        ], seen: seen))
        XCTAssertEqual(s.reply["content"]?.string, "Changed line 2.")
        XCTAssertEqual(try get(s.dir + "/a.txt"), "one\nTWO\nthree\n")
        XCTAssertEqual(s.events.filter { $0["type"]?.string == "tool_use" }.compactMap { $0["name"]?.string }, ["read", "edit", "todo"])
        // The read result reached the model, numbered and limited to the line asked for.
        let second = try XCTUnwrap(seen[1]["messages"]?.array)
        assertMatch(second.last?["content"]?.string ?? "", #"^2\|two\n\(lines 2-2 of 3\. Next: start=3\.\)$"#)
        // History is only appended to between calls, so the server's prompt cache stays valid.
        let third = try XCTUnwrap(seen[2]["messages"]?.array)
        XCTAssertEqual(Array(third.prefix(second.count)), second)
        XCTAssertEqual(seen[0]["tools"]?.array?.count, 8)
        XCTAssertEqual(seen[0]["stream_options"]?["include_usage"], true)
        XCTAssertEqual(seen[0]["model"], "black-team-local")
        XCTAssertEqual(seen[0]["messages"]?[0]?["role"], "system")
        let kept = try saved(s.id)
        XCTAssertEqual(kept["todo"], [["text": "edit a.txt", "done": true]])
        XCTAssertTrue(kept["log"]?.array?.contains { $0.string?.hasPrefix("edit a.txt") == true } == true)
        // The measured speed is remembered for the model, so the next conversation starts calibrated.
        let profiles = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: stateDir + "/engine/models.json")))
        let readSpeed = try XCTUnwrap(kept["readSpeed"]?.double)
        XCTAssertEqual(profiles["gguf:fixture.gguf"]?["readSpeed"]?.double, (readSpeed * 10 + 0.5).rounded(.down) / 10)
        XCTAssertNotEqual(readSpeed, 40)
        let next = try setup(); try await run(next, fakeModel([Step(text: "Hello.")]))
        assertMatch(next.events[0]["output"]?.string ?? "", "reads about \(Int((readSpeed).rounded())) tokens/s")
    }

    func testAnApprovedCommandRunsOnceAndTheApprovalIsBoundToThatCommand() async throws {
        let s = try setup()
        let task = Task { try await self.run(s, fakeModel([Step(calls: [("run", ["command": "rm -f gone.txt && echo removed"])]), Step(text: "Removed.")])) }
        for _ in 0..<200 where s.job.approval == nil { await pause() }
        let approval = try XCTUnwrap(s.job.approval)
        XCTAssertEqual(approval.command, "rm -f gone.txt && echo removed")
        XCTAssertEqual(approval.digest.count, 64)
        XCTAssertThrowsError(try s.job.approve(ApprovalAnswer(id: "wrong", digest: approval.digest, choice: "once")))
        XCTAssertThrowsError(try s.job.approve(ApprovalAnswer(id: approval.id, digest: "wrong", choice: "once")))
        XCTAssertThrowsError(try s.job.approve(ApprovalAnswer(id: approval.id, digest: approval.digest, choice: "always")))
        XCTAssertNotNil(s.job.approval)
        try s.job.approve(ApprovalAnswer(id: approval.id, digest: approval.digest, choice: "once"))
        try await task.value
        XCTAssertNil(s.job.approval)
        let result = try XCTUnwrap(s.events.first { $0["type"]?.string == "tool_result" })
        assertMatch(result["output"]?.string ?? "", #"exit 0\nremoved"#)
        // With nothing waiting, an answer is refused.
        XCTAssertThrowsError(try s.job.approve(id: approval.id, digest: approval.digest, choice: "once"))
    }

    func testADeclinedCommandIsNotRunAndAStopDeniesAWaitingApproval() async throws {
        let s = try setup()
        try put(s.dir + "/keep.txt", "keep")
        let task = Task { try await self.run(s, fakeModel([Step(calls: [("run", ["command": "rm keep.txt"])]), Step(text: "Left it.")])) }
        for _ in 0..<200 where s.job.approval == nil { await pause() }
        let approval = try XCTUnwrap(s.job.approval)
        try s.job.approve(id: approval.id, digest: approval.digest, choice: "deny")
        try await task.value
        XCTAssertEqual(try get(s.dir + "/keep.txt"), "keep")
        let t = try setup()
        try put(t.dir + "/keep.txt", "keep")
        let waiting = Task { try await self.run(t, fakeModel([Step(calls: [("run", ["command": "rm keep.txt"])]), Step(text: "never")])) }
        for _ in 0..<200 where t.job.approval == nil { await pause() }
        XCTAssertNotNil(t.job.approval)
        t.stop.cancel()
        do { try await waiting.value; XCTFail("should have stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(t.job.approval)
        XCTAssertEqual(try get(t.dir + "/keep.txt"), "keep")
    }

    func testTrimmingKeepsTheRequestTodoAndWorkLogNeverSplitsAToolCallFromItsResult() {
        let big = String(repeating: "x", count: 14000)
        var memory = EngineMemory(messages: [["role": "user", "content": "Read all four parts and note each codeword."]],
                                  requests: ["Read all four parts and note each codeword."], log: ["read part1.txt 1-240 of 240", "run: echo A >> notes.txt \u{2192} exit 0"],
                                  todo: [TodoItem(text: "part 3", done: false)])
        for n in 1...4 {
            memory.messages.append(["role": "assistant", "content": .string("Reading part \(n)."),
                                    "tool_calls": [["id": .string("c\(n)"), "type": "function", "function": ["name": "read", "arguments": .string("{\"path\":\"part\(n).txt\"}")]]]])
            memory.messages.append(["role": "tool", "tool_call_id": .string("c\(n)"), "content": .string(big)])
        }
        let before = Engine.estimate(memory.messages)
        XCTAssertTrue(Engine.trim(&memory, 12000))
        XCTAssertLessThan(Engine.estimate(memory.messages), before / 2)
        let record = memory.messages[0], rest = Array(memory.messages.dropFirst())
        XCTAssertEqual(record["role"], "user")
        for expected in ["Read all four parts and note each codeword.", "[ ] part 3", "read part1.txt 1-240 of 240", "run: echo A >> notes.txt \u{2192} exit 0", "Reading part 3."] {
            XCTAssertTrue(record["content"]?.string?.contains(expected) == true, expected)
        }
        XCTAssertEqual(rest[0]["role"], "assistant"); XCTAssertEqual(rest[0]["tool_calls"]?[0]?["id"], "c4")
        XCTAssertEqual(rest[1]["tool_call_id"], "c4"); XCTAssertEqual(rest.count, 2)
        var small = EngineMemory(messages: [["role": "user", "content": "hi"]])
        XCTAssertFalse(Engine.trim(&small, 12000))
    }

    func testTrimmingKeepsTheLatestRequestWithTheRecordWhenTheKeptStepIsAUserMessage() {
        var memory = EngineMemory(messages: [["role": "user", "content": "first"], ["role": "assistant", "content": "ok"], ["role": "user", "content": .string(String(repeating: "q", count: 40000))]],
                                  requests: ["first", "second"])
        XCTAssertTrue(Engine.trim(&memory, 12000))
        XCTAssertEqual(memory.messages.count, 1)
        let content = memory.messages[0]["content"]?.string ?? ""
        XCTAssertTrue(content.contains("\n\n[Latest request]\nqqq"))
        XCTAssertTrue(content.contains("- first\n- second"))
        XCTAssertTrue(content.contains("(empty)"))
        XCTAssertEqual(memory.trims, 1)
    }

    func testTheRecordIsSizedToTheBudgetAndCountsUTF16() {
        var memory = EngineMemory(messages: [["role": "user", "content": "a"], ["role": "assistant", "content": .string("\u{1F5A4} " + String(repeating: "n", count: 500))], ["role": "user", "content": "b"]],
                                  requests: (1...12).map { "request \($0)" }, log: (1...40).map { "step \($0)" })
        XCTAssertTrue(Engine.trim(&memory, 100))
        let content = memory.messages[0]["content"]?.string ?? ""
        XCTAssertTrue(content.contains("- (4 earlier requests not listed)"))
        XCTAssertTrue(content.contains("(30 earlier steps not listed)\nstep 31"))
        XCTAssertTrue(content.contains("Your recent notes:\n- \u{1F5A4} nnn"))
        // Notes are cut at 400 UTF-16 units: the pair counts as two.
        XCTAssertTrue(content.contains(String(repeating: "n", count: 397) + "\n") || content.hasSuffix(String(repeating: "n", count: 397)))
    }

    func testEstimateCountsUTF16UnitsAndToolCalls() {
        XCTAssertEqual(Engine.estimate([]), 0)
        XCTAssertEqual(Engine.estimate([["role": "user", "content": "\u{1F5A4}"]]), 4) // ceil((12 + 2) / 3.5)
        let call: JSONValue = ["role": "assistant", "content": "", "tool_calls": [["id": "c", "type": "function", "function": ["name": "read", "arguments": "{}"]]]]
        let calls = call["tool_calls"]!.text().utf16.count
        XCTAssertEqual(Engine.estimate([call]), Int((Double(12 + calls) / 3.5).rounded(.up)))
    }

    func testBudgetsFollowTheMeasuredReadSpeedAndAFullWindowIsTrimmedAndRetried() async throws {
        XCTAssertEqual(Engine.budgets(30, 65536), Budgets(working: 21600, resultChars: 6300))
        XCTAssertEqual(Engine.budgets(2000, 131072), Budgets(working: 78643, resultChars: 48000))
        XCTAssertEqual(Engine.budgets(5, 65536).working, 12000)
        let s = try setup(); let seen = Seen()
        try put(s.dir + "/f.txt", String(repeating: "y", count: 9000))
        try await run(s, fakeModel([
            Step(calls: [("run", ["command": "cat f.txt"])]), Step(calls: [("run", ["command": "cat f.txt"])]),
            Step(status: 400, message: "request (70028 tokens) exceeds the available context size"),
            Step(text: "Recovered."),
        ], seen: seen))
        XCTAssertEqual(s.reply["content"], "Recovered.")
        XCTAssertTrue(s.events.contains { $0["type"] == "status" && ($0["output"]?.string ?? "").contains("window was full") })
        XCTAssertLessThan(seen[3]["messages"]!.array!.count, seen[2]["messages"]!.array!.count)
        assertMatch(seen[3]["messages"]![1]!["content"]!.string!, "Earlier steps were trimmed")
    }

    func testStopInterruptsTheTurnAndInvalidToolArgumentsAreReturnedToTheModel() async throws {
        let s = try setup(); let seen = Seen()
        try await run(s, fakeModel([Step(calls: [("read", "{not json")]), Step(text: "ok")], seen: seen))
        assertMatch(seen[1]["messages"]!.array!.last!["content"]!.string!, "not valid JSON")
        let t = try setup()
        let task = Task { try await self.run(t, fakeModel([Step(calls: [("run", ["command": "sleep 20"])]), Step(text: "never")])) }
        for _ in 0..<200 where t.events.isEmpty { await pause() }
        t.stop.cancel()
        let began = Date()
        do { try await task.value; XCTFail("should have stopped") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertNil(t.job.approval)
    }

    func testCancellingTheTaskStopsTheTurnToo() async throws {
        let t = try setup()
        let task = Task { try await self.run(t, fakeModel([Step(calls: [("run", ["command": "sleep 20"])]), Step(text: "never")])) }
        for _ in 0..<200 where t.events.isEmpty { await pause() }
        task.cancel()
        do { try await task.value; XCTFail("should have stopped") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testAStuckModelIsToldThenStoppedAndAnUnfinishedTurnNeverReadsAsDone() async throws {
        let s = try setup(); let seen = Seen()
        let again = Step(text: "Let me look.", calls: [("read", ["path": "/nowhere/part01.txt"])])
        try await run(s, fakeModel([again, again, again, again, again, Step(text: "never reached")], seen: seen))
        XCTAssertEqual(seen.count, 5)
        assertMatch(seen[1]["messages"]!.array!.last!["content"]!.string!, "relative to the workspace")
        assertMatch(seen[3]["messages"]!.array!.last!["content"]!.string!, "three times with the same result")
        assertMatch(s.reply["content"]!.string!, "^I stopped because I was repeating the same read call")
        XCTAssertEqual(s.reply["note"], "This turn stopped before the task was finished.")
        XCTAssertFalse(s.reply["content"]!.string!.contains("Let me look."))
    }

    func testTheEngineReportsALiveGaugeAndAttachesEachChangeToItsToolResult() async throws {
        let s = try setup()
        try put(s.dir + "/a.txt", "one\n")
        try await run(s, fakeModel([Step(calls: [("edit", ["path": "a.txt", "old": "one", "new": "two"])], prompt: 4000, speed: 80), Step(text: "Done.", prompt: 4100)]))
        let result = try XCTUnwrap(s.events.first { $0["type"] == "tool_result" })
        XCTAssertEqual(result["change"]?["path"], "a.txt")
        XCTAssertTrue(result["change"]?["diff"]?.string?.contains("-one\n+two") == true)
        let meter = try XCTUnwrap(s.reply["meter"])
        XCTAssertEqual(meter["used"], 4120); XCTAssertEqual(meter["window"], 65536); XCTAssertEqual(meter["write"], 12)
        XCTAssertGreaterThan(meter["read"]?.double ?? 0, 40); XCTAssertGreaterThanOrEqual(meter["budget"]?.double ?? 0, 12000)
        XCTAssertEqual(s.job.meter?.json, meter)
    }

    func testASmallContextWindowIsRefusedPlainly() async throws {
        let small = try setup("Do it", context: 4096)
        do { try await run(small, fakeModel([Step(text: "never")])); XCTFail("should have refused") } catch {
            assertMatch((error as? BlackTeamError)?.message ?? "", "at least 8,192 tokens")
        }
    }

    func testTheServerKeyNeverReachesSavedEvents() async throws {
        let s = try setup()
        try await run(s, fakeModel([Step(calls: [("run", ["command": "echo engine-test-key"])]), Step(text: "The key is engine-test-key.")]))
        XCTAssertFalse(s.thread.value.text().contains("engine-test-key"))
        assertMatch(s.reply["content"]?.string ?? "", #"\[redacted\]"#)
    }

    func testCodeRemembersAndRecallsThroughTheVaultIsToldCoreOnceAndJournalsEachTurn() async throws {
        let vault = try Memory(vault: scratch + "/vault")
        _ = try vault.write("Core", "Prefers small diffs.")
        let s = try setup("Note the deploy step"); let seen = Seen()
        try await run(s, fakeModel([
            Step(calls: [("remember", ["title": "Deploy", "text": "Run make ship.", "project": true])]),
            Step(calls: [("recall", ["query": "ship"])]), Step(text: "Saved."),
        ], seen: seen), vault: vault)
        XCTAssertEqual(seen[0]["tools"]?.array?.count, 10)
        assertMatch(seen[0]["messages"]![0]!["content"]!.string!, #"What you already know about the user:\nPrefers small diffs\."#)
        let folder = "Projects/" + (s.dir as NSString).lastPathComponent
        assertMatch(seen[1]["messages"]!.array!.last!["content"]!.string!, "Saved to memory as \\[\\[\(NSRegularExpression.escapedPattern(for: folder))/Deploy\\]\\]")
        assertMatch(seen[2]["messages"]!.array!.last!["content"]!.string!, #"Run make ship\."#)
        let journal = try vault.read("\(folder)/Journal").content
        assertMatch(journal, "Asked: Note the deploy step"); assertMatch(journal, "Result: Saved\\.")
        // Core is fixed for the conversation, so a later edit does not change the cached prompt.
        _ = try vault.write("Core", "Changed.")
        var messages = s.thread.value["messages"]!.array!
        messages.append(["id": .string(UUID().uuidString.lowercased()), "role": "user", "content": "again", "state": "done"])
        messages.append(messages[1])
        var object = s.thread.value.object!; object["messages"] = .array(messages); s.thread.value = .object(object)
        try await run(s, fakeModel([Step(text: "Ok.")], seen: seen), vault: vault)
        XCTAssertEqual(seen[3]["messages"]![0]!["content"], seen[0]["messages"]![0]!["content"])
    }

    func testTheSystemPromptIsTheLinuxAppsWordForWord() {
        let expected = "You are Black Team Code, a coding agent running on the user's own computer. Your workspace is /w.\n\nWork with the tools. Never state a result you have not seen in a tool result.\nGive file paths relative to the workspace, such as notes.txt or src/app.js.\nReading is slow on this machine: search before you read, and read only the lines you need.\nKeep your todo list current. As a task grows, older tool output is trimmed from your memory; your todo list and a log of what you did are what remain, and you can read any file again.\nAfter a change, run its check and read the result. When the task is done, reply with a short summary of what changed and what you verified."
        XCTAssertEqual(Engine.SYSTEM("/w"), expected)
        XCTAssertEqual(Engine.MIN_CONTEXT, 8192)
    }

    func testAStoredTodoListIsRestoredForTheNextTurnAndTheStepLimitStopsAnEndlessModel() async throws {
        let s = try setup()
        try await run(s, fakeModel([Step(calls: [("todo", ["items": [["text": "first", "done": false], ["text": "second", "done": true]]])]), Step(text: "ok")]))
        XCTAssertEqual(try saved(s.id)["todo"]?.array?.count, 2)
        // The next turn trims with the restored list in the record.
        var memory = EngineMemory(json: try saved(s.id), readSpeed: 40, writeSpeed: 12)
        memory.messages = [["role": "user", "content": "x"], ["role": "assistant", "content": "y"], ["role": "user", "content": .string(String(repeating: "z", count: 100))]]
        XCTAssertTrue(Engine.trim(&memory, 12000))
        XCTAssertTrue(memory.messages[0]["content"]!.string!.contains("[ ] first\n[x] second"))
    }
}
