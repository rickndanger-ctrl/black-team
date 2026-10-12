import XCTest
@testable import BlackTeamKit

final class AgentTurnTests: XCTestCase {
    func testStepsAreStoredInTheWorkLogShape() {
        let turn = AgentTurn(service: .claudeCode)
        for line in claudeRecordedLines { turn.ingest(.stdout, line) }
        let fields = turn.fields
        XCTAssertEqual(fields.content, claudeReplyText)
        XCTAssertEqual(fields.events.count, 4)
        XCTAssertEqual(fields.events[0]["type"]?.string, "tool_use")
        XCTAssertEqual(fields.events[0]["name"]?.string, "Read")
        XCTAssertTrue(fields.events[0]["output"]?.string?.contains("greet.py") ?? false)
        XCTAssertEqual(fields.events[1]["type"]?.string, "tool_result")
        XCTAssertEqual(fields.events[1]["name"]?.string, "Read")
        XCTAssertEqual(fields.events[1]["error"], .bool(false))
        XCTAssertEqual(fields.events[2]["name"]?.string, "Edit")
    }

    func testSessionIsReportedOnce() {
        let turn = AgentTurn(service: .codex)
        turn.ingest(.stdout, codexRecordedLines[0])
        XCTAssertEqual(turn.takeSessionChange(), "019e0000-0000-7000-8000-000000000002")
        XCTAssertNil(turn.takeSessionChange())
    }

    func testReplyIsKeptWithinTheChatLimit() {
        let turn = AgentTurn(service: .claudeCode)
        let long = String(repeating: "a", count: 150_000)
        for _ in 0..<3 {
            turn.ingest(.stdout, #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(long)"}]}}"#)
        }
        XCTAssertTrue(turn.overflowed)
        XCTAssertLessThanOrEqual(EText.length(turn.fields.content), AgentTools.replyLimit)
    }

    func testStandardErrorIsOnlyKeptAsATail() {
        let turn = AgentTurn(service: .claudeCode)
        turn.ingest(.stderr, "first problem")
        turn.ingest(.stderr, "last problem")
        turn.ingest(.stdout, "not json")
        XCTAssertEqual(turn.lastError, "last problem")
        XCTAssertEqual(turn.fields.content, "")
        XCTAssertNil(turn.failureMessage)
    }
}
