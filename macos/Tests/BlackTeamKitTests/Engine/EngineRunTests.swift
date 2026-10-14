import XCTest
@testable import BlackTeamKit

/// The run state, pause and resume, ceilings, the review before finishing and the summary of trimmed steps.
/// A cloud model is a scripted stand-in (the same fake the other engine tests use) behind a cloud address rule that accepts it.
extension EngineTests {
    final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ phase: String) { lock.lock(); if !phase.isEmpty, seen.last != phase { seen.append(phase) }; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    var settings: CodeSettingsStore { CodeSettingsStore(dataFolder: stateDir) }

    /// A session whose model is a cloud service at a made-up host.
    func cloudSetup(_ message: String = "Do the task") throws -> Session {
        var s = try setup(message)
        s.config.model = ModelConfig(source: "cloud", endpoint: "https://cloud.test/v1", id: "model-x", apiKey: "cloud-test-key", name: "Cloud X", context: 65536)
        return s
    }

    func codeEngine(_ fetch: @escaping HTTPStreamFetch, skills: SkillStore? = nil) throws -> Engine {
        let rules = CloudRules { _ in CloudEndpoint(base: "http://127.0.0.1:5555/v1", host: "cloud.test") }
        return try Engine(stateDir: stateDir, vault: nil, fetch: fetch, home: scratch, useRtk: false, cloud: rules, skills: skills)
    }

    func go(_ s: Session, _ fetch: @escaping HTTPStreamFetch, skills: SkillStore? = nil, engine custom: Engine? = nil) async throws {
        let instance = try custom ?? codeEngine(fetch, skills: skills)
        try await instance.run(thread: s.thread, config: s.config, runtime: FixedHeadersRuntime(["Authorization": "Bearer engine-test-key"]),
                               endpoint: "http://127.0.0.1:5555/v1", job: s.job, signal: s.stop, save: { _ in }, mode: "fast")
    }

    func runRecord(_ s: Session) -> JSONValue { s.reply["run"] ?? .null }

    // MARK: Phases

    func testARunMovesThroughPlanningWorkingAndDoneAndSavesItsState() async throws {
        let s = try setup(); let phases = Phases()
        _ = s.job.observe { phases.add($0.phase) }
        try put(s.dir + "/a.txt", "one\n")
        try await go(s, fakeModel([
            Step(calls: [("todo", ["items": [["text": "read a.txt", "done": false]]])]),
            Step(calls: [("read", ["path": "a.txt"]), ("todo", ["items": [["text": "read a.txt", "done": true]]])]),
            Step(text: "Read it."),
        ]))
        XCTAssertEqual(phases.all, ["planning", "working", "done"])
        XCTAssertEqual(runRecord(s)["phase"], "done")
        XCTAssertEqual(runRecord(s)["steps"], 3)
        XCTAssertEqual(runRecord(s)["todo"], [["text": "read a.txt", "done": true]])
        XCTAssertEqual(runRecord(s)["toolStatus"], "done")
        XCTAssertEqual(runRecord(s)["tokens"], JSONValue.number(1560))
        // The same state is kept with the engine's own record of the conversation.
        let kept = try saved(s.id)
        XCTAssertEqual(kept["run"]?["phase"], "done")
        XCTAssertEqual(kept["run"]?["steps"], 3)
        XCTAssertTrue(kept["run"]?["recent"]?.array?.contains { $0.string?.hasPrefix("read a.txt") == true } == true)
    }

    func testAnApprovalShowsWaitingAndAStoppedRunSaysStopped() async throws {
        let s = try setup(); let phases = Phases()
        _ = s.job.observe { phases.add($0.phase) }
        try put(s.dir + "/keep.txt", "keep")
        let task = Task { try await self.go(s, fakeModel([Step(calls: [("run", ["command": "rm keep.txt"])]), Step(text: "never")])) }
        for _ in 0..<200 where s.job.approval == nil { await pause() }
        XCTAssertEqual(s.job.phase, "waiting")
        XCTAssertEqual(runRecord(s)["phase"], "waiting")
        s.stop.cancel()
        do { try await task.value; XCTFail("should have stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(phases.all.contains("waiting"))
        XCTAssertEqual(try saved(s.id)["run"]?["phase"], "stopped")
    }

    func testAFailedRunSaysFailed() async throws {
        let s = try setup()
        do { try await go(s, fakeModel([Step(status: 500, message: "model exploded")])); XCTFail("should have failed") } catch {}
        XCTAssertEqual(s.job.phase, "failed")
        XCTAssertEqual(try saved(s.id)["run"]?["phase"], "failed")
    }

    // MARK: Pause and resume

    func testPauseTakesEffectBetweenStepsNeverInsideAToolAndResumeGoesOn() async throws {
        let s = try setup(); let seen = Seen(); let phases = Phases()
        _ = s.job.observe { phases.add($0.phase) }
        let script: [Step] = [Step(calls: [("write", ["path": "made.txt", "content": "hello"])]), Step(text: "Made it.")]
        let model = fakeModel(script, seen: seen)
        // Pause is pressed while the first reply is being written; the write that reply asks for still happens.
        let pressing: HTTPStreamFetch = { request in
            let answer = try await model(request)
            if seen.count == 1 { s.job.requestPause() }
            return answer
        }
        let task = Task { try await self.go(s, pressing) }
        // The window learns of the pause a moment before the thread is saved.
        for _ in 0..<400 where s.job.phase != "paused" || (try? saved(s.id)["run"]?["phase"]) != "paused" { await pause() }
        XCTAssertEqual(s.job.phase, "paused")
        XCTAssertTrue(s.job.snapshot.pausing)
        XCTAssertEqual(try get(s.dir + "/made.txt"), "hello")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(try saved(s.id)["run"]?["phase"], "paused")
        await pause(150)
        XCTAssertEqual(seen.count, 1, "nothing is asked of the model while paused")
        s.job.resume()
        try await task.value
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(s.reply["content"], "Made it.")
        XCTAssertEqual(phases.all, ["planning", "working", "paused", "working", "done"])
        XCTAssertFalse(s.job.snapshot.pausing)
    }

    func testStopWorksWhilePaused() async throws {
        let s = try setup()
        s.job.requestPause()
        let task = Task { try await self.go(s, fakeModel([Step(text: "never")])) }
        // The window learns of the pause a moment before the thread is saved.
        for _ in 0..<400 where s.job.phase != "paused" || (try? saved(s.id)["run"]?["phase"]) != "paused" { await pause() }
        XCTAssertEqual(s.job.phase, "paused")
        s.stop.cancel()
        do { try await task.value; XCTFail("should have stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(s.job.phase, "stopped")
    }

    // MARK: Resume after a restart

    func testAnInterruptedRunContinuesFromItsSavedStateAfterARestart() async throws {
        let s = try setup("Make a.txt")
        // What a run cut off by a crash leaves behind: a tool call with no result, a todo list, and a phase that never finished.
        let cut: JSONValue = [
            "messages": [["role": "user", "content": "Make a.txt"],
                         ["role": "assistant", "content": "On it.", "tool_calls": [["id": "c1", "type": "function", "function": ["name": "run", "arguments": "{\"command\":\"sleep 60\"}"]]]]],
            "requests": ["Make a.txt"], "log": ["read b.txt 1-3 of 3"], "todo": [["text": "make a.txt", "done": false], ["text": "read b.txt", "done": true]],
            "readSpeed": 40, "writeSpeed": 12, "promptTokens": 0, "trims": 0,
            "run": ["phase": "working", "steps": 4, "tool": "run", "toolStatus": "running", "promptTokens": 2000, "completionTokens": 80, "tokens": 2080, "recent": ["read b.txt 1-3 of 3"]],
        ]
        try FileManager.default.createDirectory(atPath: stateDir + "/engine", withIntermediateDirectories: true)
        try writeJSON("\(stateDir)/engine/\(s.id).json", cut)
        let seen = Seen()
        // A fresh engine, as after Black Team was closed and opened again.
        try await go(s, fakeModel([Step(text: "Carried on.")], seen: seen))
        let sent = try XCTUnwrap(seen[0]["messages"]?.array)
        XCTAssertEqual(sent.count, 5, "system, the earlier request, the call, its filled-in result, and the new message")
        XCTAssertEqual(sent[1]["content"], "Make a.txt")
        XCTAssertEqual(sent[3]["role"], "tool")
        assertMatch(sent[3]["content"]?.string ?? "", "interrupted before the tool finished")
        assertMatch(sent[4]["content"]?.string ?? "", "cut off at step 4 while using run")
        XCTAssertTrue(s.events.contains { $0["name"] == "Continuing" })
        // The counters carried on from the saved state, and the todo list came back.
        XCTAssertEqual(runRecord(s)["steps"], 5)
        XCTAssertEqual(runRecord(s)["tokens"], JSONValue.number(2600))
        XCTAssertEqual(runRecord(s)["phase"], "done")
        XCTAssertEqual(try saved(s.id)["todo"], [["text": "make a.txt", "done": false], ["text": "read b.txt", "done": true]])
    }

    func testAFinishedRunIsNotTreatedAsInterrupted() async throws {
        let s = try setup("First")
        try await go(s, fakeModel([Step(text: "One.")]))
        XCTAssertEqual(s.reply["content"], "One.")
        let seen = Seen()
        let t = Session(dir: s.dir, id: s.id, thread: ThreadRef(["id": .string(s.id), "kind": "agent", "messages": [["role": "user", "content": "More"], ["role": "assistant", "content": "", "state": "writing"]]]), config: s.config)
        try await go(t, fakeModel([Step(text: "Two.")], seen: seen))
        XCTAssertFalse((seen[0]["messages"]?.array?.last?["content"]?.string ?? "").contains("cut off"))
        XCTAssertFalse(t.events.contains { $0["name"] == "Continuing" })
    }

    // MARK: Ceilings

    func testTheTokenCeilingStopsTheRunWithAPlainMessageAndKeepsStopping() async throws {
        let s = try setup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.tokenCeiling = 1000 }
        // 520 tokens per request: the ceiling is reached after the second.
        let calls = [Step(calls: [("list", [:])]), Step(calls: [("list", ["path": "."])]), Step(calls: [("search", ["pattern": "x"])]), Step(text: "never")]
        try await go(s, fakeModel(calls, seen: seen))
        XCTAssertEqual(seen.count, 2)
        assertMatch(s.reply["content"]?.string ?? "", "^I stopped because this conversation reached its limit of 1,000 tokens \\(it has used 1,040\\)")
        XCTAssertEqual(s.reply["note"], "This turn stopped before the task was finished.")
        XCTAssertEqual(runRecord(s)["phase"], "stopped")
        // Asking again changes nothing until the limit is raised; no request is made.
        let more = Session(dir: s.dir, id: s.id, thread: ThreadRef(["id": .string(s.id), "kind": "agent", "messages": [["role": "user", "content": "continue"], ["role": "assistant", "content": "", "state": "writing"]]]), config: s.config)
        try await go(more, fakeModel([Step(text: "never")], seen: seen))
        XCTAssertEqual(seen.count, 2)
        try settings.updateThread(s.id) { $0.tokenCeiling = 0 }
        try await go(more, fakeModel([Step(text: "Finished now.")], seen: seen))
        XCTAssertEqual(more.reply["content"], "Finished now.")
    }

    func testTheMoneyCeilingStopsACloudRunAtThePricesThePersonSet() async throws {
        let s = try cloudSetup(); let seen = Seen()
        try settings.updateGlobal { $0.prices["cloud.test/model-x"] = ModelPrice(input: 10, output: 30); $0.check = false }
        try settings.updateThread(s.id) { $0.moneyCeiling = 0.01 }
        // 500 read and 20 written per request: $0.0056 each.
        try await go(s, fakeModel([Step(calls: [("list", [:])]), Step(calls: [("list", ["path": "."])]), Step(calls: [("search", ["pattern": "x"])]), Step(text: "never")], seen: seen))
        XCTAssertEqual(seen.count, 2)
        assertMatch(s.reply["content"]?.string ?? "", "^I stopped because this conversation reached its spending limit of \\$0\\.010 \\(it has spent \\$0\\.011 at the prices you set\\)")
        XCTAssertEqual(runRecord(s)["cost"]?.double ?? 0, 0.0112, accuracy: 0.00001)
        XCTAssertEqual(s.thread.value["usage"]?["prompt"], 1000)
    }

    func testAMoneyCeilingWithoutAPriceStopsBeforeAnythingIsSent() async throws {
        let s = try cloudSetup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.moneyCeiling = 1 }
        try await go(s, fakeModel([Step(text: "never")], seen: seen))
        XCTAssertEqual(seen.count, 0)
        assertMatch(s.reply["content"]?.string ?? "", "no price is set for Cloud X")
    }

    func testAMoneyCeilingMeansNothingForAModelOnThisComputer() async throws {
        let s = try setup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.moneyCeiling = 0.0001 }
        try await go(s, fakeModel([Step(text: "Fine.")], seen: seen))
        XCTAssertEqual(s.reply["content"], "Fine.")
        XCTAssertNil(runRecord(s)["cost"])
    }

    func testCostIsShownFromTheReportedUsageOnlyForACloudModelWithAPrice() async throws {
        let s = try cloudSetup()
        try settings.updateGlobal { $0.prices["cloud.test/model-x"] = ModelPrice(input: 2, output: 8); $0.check = false }
        try await go(s, fakeModel([Step(text: "Hi.")]))
        XCTAssertEqual(runRecord(s)["cost"]?.double ?? 0, 500.0 / 1e6 * 2 + 20.0 / 1e6 * 8, accuracy: 1e-9)
        let line = RunRecord(json: runRecord(s)).line(price: ModelPrice(input: 2, output: 8))
        assertMatch(line, "^Done\\. 520 tokens, \\$0\\.0012 spent$")
    }

    // MARK: Checking before finishing

    func testTheReviewIsOffForAModelOnThisComputerUnlessSwitchedOn() async throws {
        let s = try setup(); let seen = Seen()
        try await go(s, fakeModel([Step(calls: [("write", ["path": "a.txt", "content": "x"])]), Step(text: "Done.")], seen: seen))
        XCTAssertEqual(seen.count, 2)
    }

    func testTheReviewIsCappedAtTwoRoundsAndSendsTheModelBackToWork() async throws {
        let s = try setup(); let seen = Seen(); let phases = Phases()
        _ = s.job.observe { phases.add($0.phase) }
        try settings.updateThread(s.id) { $0.check = true }
        try await go(s, fakeModel([
            Step(calls: [("write", ["path": "a.txt", "content": "x"])]),
            Step(text: "Done."),                                              // asked to check (1 of 2)
            Step(calls: [("edit", ["path": "a.txt", "old": "x", "new": "y"])]), // found something missing
            Step(text: "Done again."),                                        // asked to check (2 of 2)
            Step(calls: [("list", [:])]),
            Step(text: "Finished."),                                          // no third review
            Step(text: "never"),
        ], seen: seen))
        XCTAssertEqual(seen.count, 6)
        assertMatch(seen[2]["messages"]!.array!.last!["content"]!.string!, "check 1 of 2")
        assertMatch(seen[4]["messages"]!.array!.last!["content"]!.string!, "check 2 of 2")
        XCTAssertEqual(s.reply["content"], "Finished.")
        XCTAssertEqual(try get(s.dir + "/a.txt"), "y")
        XCTAssertEqual(phases.all, ["planning", "working", "checking", "working", "checking", "working", "done"])
        XCTAssertEqual(s.events.filter { $0["name"] == "Check" }.count, 2)
    }

    func testAReviewThatFindsNothingMissingFinishesAtOnce() async throws {
        let s = try setup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.check = true }
        try await go(s, fakeModel([Step(calls: [("write", ["path": "a.txt", "content": "x"])]), Step(text: "Done."), Step(text: "Checked: a.txt exists."), Step(text: "never")], seen: seen))
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(s.reply["content"], "Checked: a.txt exists.")
    }

    func testAnAnswerWithNoWorkAndNoOpenTodoIsNotReviewed() async throws {
        let s = try setup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.check = true }
        try await go(s, fakeModel([Step(text: "Four.")], seen: seen))
        XCTAssertEqual(seen.count, 1)
    }

    func testTheReviewIsOnByDefaultForACloudModel() async throws {
        let s = try cloudSetup(); let seen = Seen()
        try await go(s, fakeModel([Step(calls: [("write", ["path": "a.txt", "content": "x"])]), Step(text: "Done."), Step(text: "All good."), Step(text: "never")], seen: seen))
        XCTAssertEqual(seen.count, 3)
        try settings.updateThread(s.id) { $0.check = false }
        let off = try cloudSetup(); let seenOff = Seen()
        try settings.updateThread(off.id) { $0.check = false }
        try await go(off, fakeModel([Step(calls: [("write", ["path": "a.txt", "content": "x"])]), Step(text: "Done.")], seen: seenOff))
        XCTAssertEqual(seenOff.count, 2)
    }

    // MARK: Working memory

    /// A run whose first reply reports a prompt too big for the working budget, so the next step trims.
    func trimmingScript(summaryText: String? = nil) -> [Step] {
        var script = [Step(calls: [("list", [:])], prompt: 40000)]
        if let summaryText { script.append(Step(text: summaryText)) }
        return script + [Step(text: "Done.")]
    }

    func testTrimmingNeedsNoModelCallOnAModelOnThisComputer() async throws {
        let s = try setup(); let seen = Seen()
        try await go(s, fakeModel(trimmingScript(), seen: seen))
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(s.events.contains { ($0["output"]?.string ?? "").contains("No model call needed") })
        XCTAssertNil(try saved(s.id)["summary"])
    }

    func testASummaryOfTrimmedStepsIsWrittenOnlyWhenThePersonAsksAndKeptAsANote() async throws {
        let s = try setup(); let seen = Seen()
        try settings.updateThread(s.id) { $0.summarize = true }
        try await go(s, fakeModel(trimmingScript(summaryText: "Listed the folder; nothing open."), seen: seen))
        XCTAssertEqual(seen.count, 3)
        assertMatch(seen[1]["messages"]![0]!["content"]!.string!, "short, exact summaries")
        XCTAssertEqual(try saved(s.id)["summary"], "Listed the folder; nothing open.")
        let note = try XCTUnwrap(s.events.first { $0["name"] == "Summary of trimmed steps" })
        XCTAssertEqual(note["output"], "Listed the folder; nothing open.")
        assertMatch(seen[2]["messages"]![1]!["content"]!.string!, "A summary of the trimmed steps:\\nListed the folder; nothing open\\.")
        XCTAssertEqual(runRecord(s)["tokens"], JSONValue.number(41060), "the summary request is counted too")
    }

    func testASummaryIsWrittenByDefaultForACloudModel() async throws {
        let s = try cloudSetup(); let seen = Seen()
        try settings.updateGlobal { $0.check = false }
        try await go(s, fakeModel(trimmingScript(summaryText: "Cloud summary."), seen: seen))
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(try saved(s.id)["summary"], "Cloud summary.")
    }
}
