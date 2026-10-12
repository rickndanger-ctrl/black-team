import XCTest
@testable import BlackTeamKit

final class ResponseActivityTests: XCTestCase {
    private let thread = ActivityThread(id: "current", messages: [ActivityMessage(id: "reply", role: "assistant", state: "writing")])
    private let job = ActivityJob(threadId: "current", state: "running", kind: "chat", progress: "Thinking…")

    private func status(thread: ActivityThread?? = nil, threadId: String?? = nil, job: ActivityJob?? = nil, connection: String = "online") -> ResponseActivity? {
        ResponseActivity.current(thread: thread ?? self.thread, threadId: threadId ?? "current", job: job ?? self.job, connection: connection)
    }

    func testLiveThinkingAndStreamedRepliesAnimateTheirAssistantMessage() {
        XCTAssertEqual(status(), ResponseActivity(phase: .thinking, label: "Thinking", glowing: true, messageId: "reply"))
        var writing = job; writing.progress = "Writing a reply…"
        XCTAssertEqual(status(job: .some(writing))?.phase, .responding)
    }

    func testSavedWritingStateDoesNotAnimateWithoutALiveJob() {
        XCTAssertNil(status(job: .some(nil)))
        for state in ["done", "error", "interrupted"] {
            var j = job; j.state = state
            XCTAssertNil(status(job: .some(j)))
        }
    }

    func testADifferentConversationOrAModelServerOperationCannotLightTheRing() {
        XCTAssertNil(status(threadId: .some("other")))
        var start = job; start.kind = "start"
        XCTAssertNil(status(job: .some(start)))
        XCTAssertNil(status(threadId: .some(nil)))
    }

    func testDisconnectedApprovalAndStoppingStatesDoNotImplyActiveInference() {
        XCTAssertEqual(status(connection: "offline")?.glowing, false)
        var agent = job; agent.kind = "agent"; agent.hasApproval = true
        XCTAssertEqual(status(job: .some(agent))?.phase, .approval)
        var approval = job; approval.hasApproval = true
        XCTAssertEqual(status(job: .some(approval))?.glowing, false)
        var stopping = job; stopping.progress = "Stopping agent…"
        XCTAssertEqual(status(job: .some(stopping))?.glowing, false)
    }

    func testPreparationBeforeTheAssistantExistsGetsATemporaryIndicator() {
        let activity = status(thread: .some(ActivityThread(id: "current", messages: [ActivityMessage(role: "user")])))
        XCTAssertNil(activity?.messageId)
        XCTAssertEqual(activity?.glowing, true)
        var preparing = job; preparing.progress = "Preparing…"
        XCTAssertEqual(status(thread: .some(nil), job: .some(preparing))?.phase, .preparing)
    }

    func testThreadFetchLagNeverAssociatesTheCurrentJobWithTheOldConversation() {
        XCTAssertNil(status(thread: .some(ActivityThread(id: "old", messages: thread.messages)))?.messageId)
    }

    func testCompletedAssistantDoesNotGlowWhileTheFinalJobUpdateCatchesUp() {
        let completed = ActivityThread(id: "current", messages: [ActivityMessage(id: "reply", role: "assistant", state: "done")])
        XCTAssertNil(status(thread: .some(completed)))
    }

    func testAgentToolWorkHasAnHonestWorkingLabel() {
        var tool = job; tool.kind = "agent"; tool.progress = "Using read_file…"
        XCTAssertEqual(status(job: .some(tool))?.phase, .working)
    }
}
