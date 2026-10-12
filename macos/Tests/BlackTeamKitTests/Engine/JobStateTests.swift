import XCTest
@testable import BlackTeamKit

final class JobStateTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [JobSnapshot] = []
        func add(_ item: JobSnapshot) { lock.lock(); items.append(item); lock.unlock() }
        var all: [JobSnapshot] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testFieldsAreObservedAndSnapshotsAreConsistent() {
        let job = JobState(id: "j1", threadId: "t1", kind: "agent", progress: "Preparing local model\u{2026}")
        let log = Log()
        let stop = job.observe { log.add($0) }
        job.progress = "Thinking\u{2026}"
        job.context = ["method": "estimated-bytes"]
        job.meter = JobMeter(read: 40, write: 12, used: 5, budget: 100, window: 200, trims: 0)
        job.state = "done"
        stop()
        job.progress = "ignored by the stopped observer"
        XCTAssertEqual(log.all.map(\.progress).last, "Thinking\u{2026}")
        XCTAssertEqual(log.all.count, 4)
        let snapshot = job.snapshot
        XCTAssertEqual(snapshot.id, "j1"); XCTAssertEqual(snapshot.threadId, "t1"); XCTAssertEqual(snapshot.kind, "agent"); XCTAssertEqual(snapshot.state, "done")
        XCTAssertEqual(snapshot.context?["method"], "estimated-bytes")
        XCTAssertEqual(job.meter?.json, ["read": 40, "write": 12, "used": 5, "budget": 100, "window": 200, "trims": 0])
        XCTAssertEqual(JobMeter(write: 12).json, ["write": 12])
    }

    func testAnApprovalIsAnsweredOnlyByTheMatchingIdDigestAndChoice() throws {
        let job = JobState()
        XCTAssertThrowsError(try job.approve(id: "x", digest: "y", choice: "once"))
        nonisolated(unsafe) var answered: String?
        job.present(PendingApproval(id: "a", digest: "d", command: "rm x", description: "Run?", expires: 0)) { answer in
            guard answer.id == "a", answer.digest == "d", ["once", "deny"].contains(answer.choice) else { throw BlackTeamError("No matching active approval.") }
            answered = answer.choice
        }
        XCTAssertEqual(job.approval?.command, "rm x")
        XCTAssertThrowsError(try job.approve(id: "a", digest: "wrong", choice: "once"))
        try job.approve(id: "a", digest: "d", choice: "deny")
        XCTAssertEqual(answered, "deny")
        job.withdraw()
        XCTAssertNil(job.approval)
        XCTAssertThrowsError(try job.approve(id: "a", digest: "d", choice: "once"))
    }

    func testTheThreadRefReplacesOnlyTheLastMessage() {
        let thread = ThreadRef(["id": "t", "messages": [["role": "user", "content": "a"], ["role": "assistant", "content": ""]]])
        thread.setLast(["role": "assistant", "content": "done"])
        XCTAssertEqual(thread.value["messages"]?[0]?["content"], "a")
        XCTAssertEqual(thread.value["messages"]?[1]?["content"], "done")
        XCTAssertEqual(thread.value["id"], "t")
    }

    func testTextHelpersCountUTF16AndNeverSplitAPair() {
        XCTAssertEqual(EText.prefix("a\u{1F5A4}b", 2), "a")
        XCTAssertEqual(EText.prefix("a\u{1F5A4}b", 3), "a\u{1F5A4}")
        XCTAssertEqual(EText.length("\u{1F5A4}"), 2)
        XCTAssertEqual(EText.trim("\u{FEFF} \u{00A0}x y\n\u{2028}"), "x y")
        XCTAssertEqual(EText.round(2.5), 3); XCTAssertEqual(EText.round(2.4), 2)
        XCTAssertEqual(EText.grouped(8192), "8,192"); XCTAssertEqual(EText.grouped(999), "999"); XCTAssertEqual(EText.grouped(1234567), "1,234,567")
        XCTAssertEqual(EText.iso(Date(timeIntervalSince1970: 1.5)), "1970-01-01T00:00:01.500Z")
    }
}
