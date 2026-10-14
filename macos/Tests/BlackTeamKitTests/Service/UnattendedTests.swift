import XCTest
@testable import BlackTeamKit

/// What a scheduled Code run may do without asking, at each of the three levels, and what happens to a question nobody answers.
final class UnattendedTests: XCTestCase {
    var scratch = ""

    override func setUpWithError() throws {
        let base = try XCTUnwrap(PathUtil.realpath(NSTemporaryDirectory()))
        scratch = base + "/bt-unattended-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

    final class Questions: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ApprovalRequest] = []
        var answer = "once"
        var list: [ApprovalRequest] { lock.lock(); defer { lock.unlock() }; return all }
        func add(_ request: ApprovalRequest) -> String { lock.lock(); all.append(request); let reply = answer; lock.unlock(); return reply }
    }

    func tools(_ level: UnattendedPermission?, _ questions: Questions) throws -> (Tools, String) {
        let dir = scratch + "/ws-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "keep\n".write(toFile: dir + "/a.txt", atomically: false, encoding: .utf8)
        let made = try Tools(workspace: dir, artifacts: scratch + "/art", undoDir: scratch + "/undo", home: scratch, ask: { questions.add($0) }, useRtk: false, unattended: level)
        return (made, dir)
    }

    func names(_ tools: Tools) -> [String] { tools.schemaList.compactMap { $0["function"]?["name"]?.string } }

    // MARK: Read only

    func testReadOnlyIsNotEvenOfferedTheToolsThatChangeThingsAndNeverAsks() async throws {
        let questions = Questions()
        let (tools, dir) = try tools(.readOnly, questions)
        XCTAssertEqual(names(tools), ["read", "search", "list", "todo"])
        for (name, args) in [("write", ["path": "b.txt", "content": "x"]), ("edit", ["path": "a.txt", "old": "keep", "new": "gone"]),
                             ("run", ["command": "touch c.txt"]), ("publish", ["path": "a.txt"])] as [(String, JSONValue)] {
            let result = await tools.call(name, args)
            XCTAssertTrue(result.error, name)
            XCTAssertTrue(result.output.contains("read-only"), "\(name): \(result.output)")
        }
        XCTAssertEqual(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/b.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/c.txt"))
        XCTAssertTrue(questions.list.isEmpty, "read-only never asks")
        // Reading and searching still work.
        let read = await tools.call("read", ["path": "a.txt"])
        XCTAssertFalse(read.error)
        XCTAssertTrue(read.output.contains("keep"))
        let todo = await tools.call("todo", ["items": [["text": "look", "done": true]]])
        XCTAssertFalse(todo.error)
    }

    // MARK: Ask

    func testAskWaitsForAYesBeforeEveryFileChangeAndEveryCommand() async throws {
        let questions = Questions()
        let (tools, dir) = try tools(.ask, questions)
        XCTAssertEqual(names(tools).count, 8)
        questions.answer = "deny"
        var result = await tools.call("write", ["path": "b.txt", "content": "x"])
        XCTAssertTrue(result.error)
        XCTAssertTrue(result.output.contains("declined"))
        result = await tools.call("edit", ["path": "a.txt", "old": "keep", "new": "gone"])
        XCTAssertTrue(result.output.contains("declined"))
        result = await tools.call("run", ["command": "echo hello"])
        XCTAssertTrue(result.output.contains("declined"))
        XCTAssertEqual(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/b.txt"))
        XCTAssertEqual(questions.list.map(\.command), ["write b.txt", "edit a.txt", "echo hello"])
        XCTAssertEqual(questions.list.first?.description, "Change this file in your project?")
        // A yes lets that one step through.
        questions.answer = "once"
        result = await tools.call("edit", ["path": "a.txt", "old": "keep", "new": "changed"])
        XCTAssertFalse(result.error, result.output)
        XCTAssertEqual(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8), "changed\n")
        result = await tools.call("run", ["command": "echo hello"])
        XCTAssertTrue(result.output.contains("hello"))
        XCTAssertEqual(questions.list.count, 5)
        // Reading never asks.
        let before = questions.list.count
        _ = await tools.call("read", ["path": "a.txt"]); _ = await tools.call("list", [:])
        XCTAssertEqual(questions.list.count, before)
    }

    // MARK: Allow in project

    func testAllowInProjectEditsFilesInTheProjectWithoutAskingButStillAsksForCommands() async throws {
        let questions = Questions()
        let (tools, dir) = try tools(.allowInProject, questions)
        questions.answer = "deny"
        var result = await tools.call("write", ["path": "b.txt", "content": "new"])
        XCTAssertFalse(result.error, result.output)
        result = await tools.call("edit", ["path": "a.txt", "old": "keep", "new": "changed"])
        XCTAssertFalse(result.error, result.output)
        XCTAssertEqual(try String(contentsOfFile: dir + "/b.txt", encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8), "changed\n")
        XCTAssertTrue(questions.list.isEmpty, "file edits inside the project did not ask")
        // Outside the project folder is still refused, asked or not.
        result = await tools.call("write", ["path": "../outside.txt", "content": "x"])
        XCTAssertTrue(result.output.contains("only inside the workspace"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/outside.txt"))
        // Any terminal command asks, even a harmless one; a no stops it.
        result = await tools.call("run", ["command": "touch c.txt"])
        XCTAssertTrue(result.output.contains("declined"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/c.txt"))
        XCTAssertEqual(questions.list.map(\.command), ["touch c.txt"])
    }

    func testTheUsualInteractiveRulesAreUnchangedWithoutALevel() async throws {
        let questions = Questions()
        let (tools, dir) = try tools(nil, questions)
        _ = await tools.call("write", ["path": "b.txt", "content": "x"])
        _ = await tools.call("run", ["command": "echo hi"])
        XCTAssertTrue(questions.list.isEmpty, "only risky commands ask for a person at the window")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/b.txt"))
        questions.answer = "deny"
        let risky = await tools.call("run", ["command": "rm -f a.txt"])
        XCTAssertTrue(risky.output.contains("declined"))
        XCTAssertEqual(questions.list.count, 1)
    }

    // MARK: The engine

    func session(_ level: UnattendedPermission, seconds: Int) throws -> (job: JobState, thread: ThreadRef, config: Config, dir: String) {
        let dir = scratch + "/run-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let thread: JSONValue = ["id": .string(UUID().uuidString.lowercased()), "kind": "agent", "messages": [
            ["id": .string(UUID().uuidString.lowercased()), "role": "user", "content": "Tidy up", "state": "done"],
            ["id": .string(UUID().uuidString.lowercased()), "role": "assistant", "content": "", "state": "writing"]]]
        let job = JobState()
        job.unattended = UnattendedPolicy(permission: level, approvalSeconds: seconds)
        return (job, ThreadRef(thread), Config(model: ModelConfig(source: "gguf", file: "/models/fixture.gguf", context: 65536), workspace: dir), dir)
    }

    func run(_ s: (job: JobState, thread: ThreadRef, config: Config, dir: String), _ fetch: @escaping HTTPStreamFetch) async throws {
        let engine = try Engine(stateDir: scratch + "/state", fetch: fetch, home: scratch, useRtk: false)
        try await engine.run(thread: s.thread, config: s.config, runtime: FixedHeadersRuntime(["Authorization": "Bearer engine-test-key"]),
                             endpoint: "http://127.0.0.1:5555/v1", job: s.job, signal: CancelSignal(), save: { _ in }, mode: "fast")
    }

    func testAReadOnlyRunIsOfferedOnlyTheReadingTools() async throws {
        let s = try session(.readOnly, seconds: 60), seen = Seen()
        try await run(s, fakeModel([Step(text: "Nothing to change.")], seen: seen))
        let offered = (seen[0]["tools"]?.array ?? []).compactMap { $0["function"]?["name"]?.string }
        XCTAssertFalse(offered.contains("write")); XCTAssertFalse(offered.contains("edit")); XCTAssertFalse(offered.contains("run"))
        XCTAssertTrue(offered.contains("read"))
    }

    func testAQuestionIsHeldForTheConfiguredTimeAndThenTheRunEndsNotApproved() async throws {
        let s = try session(.ask, seconds: 1)
        try "keep".write(toFile: s.dir + "/keep.txt", atomically: false, encoding: .utf8)
        let started = Date()
        do {
            try await run(s, fakeModel([Step(calls: [("run", ["command": "echo ran > ran.txt"])]), Step(text: "It must not get here.")]))
            XCTFail("the run should have ended")
        } catch {
            XCTAssertEqual((error as? BlackTeamError)?.message, Engine.notApprovedMessage)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9, "it waited for the question")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.dir + "/ran.txt"), "the command was not run")
        XCTAssertNil(s.job.approval, "the question is gone with the run")
    }

    func testTheQuestionIsPresentedWhileWaitingAndAnAnswerLetsTheRunGoOn() async throws {
        let s = try session(.ask, seconds: 3600)
        let task = Task { try await self.run(s, fakeModel([Step(calls: [("write", ["path": "made.txt", "content": "hello"])]), Step(text: "Written.")])) }
        for _ in 0..<400 where s.job.approval == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let ask = try XCTUnwrap(s.job.approval)
        XCTAssertEqual(ask.command, "write made.txt")
        XCTAssertEqual(ask.description, "Change this file in your project?")
        // The question runs out in an hour, not in five minutes.
        XCTAssertGreaterThan(Double(ask.expires) / 1000, Date().timeIntervalSince1970 + 3000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.dir + "/made.txt"))
        try s.job.approve(id: ask.id, digest: ask.digest, choice: "once")
        try await task.value
        XCTAssertEqual(try String(contentsOfFile: s.dir + "/made.txt", encoding: .utf8), "hello")
    }

    func testARunThatWaitedForAnAnswerStillFinishes() async throws {
        // The time check subtracts the waiting time (Engine.swift); a wait of a third of a second must not disturb anything.
        let s = try session(.ask, seconds: 3600)
        let task = Task { try await self.run(s, fakeModel([Step(calls: [("run", ["command": "echo hi"])]), Step(text: "Said hi.")])) }
        for _ in 0..<400 where s.job.approval == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let ask = try XCTUnwrap(s.job.approval)
        try await Task.sleep(nanoseconds: 300_000_000)
        try s.job.approve(id: ask.id, digest: ask.digest, choice: "deny")
        try await task.value
        XCTAssertEqual(s.thread.value["messages"]?.array?.last?["content"]?.string, "Said hi.")
    }

    func testAnInteractiveRunKeepsItsFiveMinuteQuestion() async throws {
        let job = JobState()
        XCTAssertNil(job.unattended)
        XCTAssertEqual(Engine.APPROVAL_SECONDS, 300)
    }
}
