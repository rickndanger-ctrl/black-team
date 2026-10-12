import XCTest
@testable import BlackTeamKit

// The parsers read the JSON lines the two tools print. The lines are recorded from real runs (see FakeAgentLauncher.swift).
final class AgentEventsTests: XCTestCase {
    func testClaudeCodeLinesGiveSessionTextToolStepsAndResult() {
        let events = claudeRecordedLines.flatMap { AgentEventParser.parse($0, service: .claudeCode) }.filter { $0 != .ignored }
        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(events[0], .session("8f1c2d3e-1111-4a5b-9c8d-000000000001"))
        guard case .toolUse(let id, let name, let input) = events[1] else { return XCTFail("tool use expected") }
        XCTAssertEqual(id, "toolu_01THcKM8aeiRgWikLKXUN6xC"); XCTAssertEqual(name, "Read"); XCTAssertTrue(input.contains("greet.py"))
        guard case .toolResult(let resultId, let output, let isError) = events[2] else { return XCTFail("tool result expected") }
        XCTAssertEqual(resultId, "toolu_01THcKM8aeiRgWikLKXUN6xC"); XCTAssertTrue(output.contains("nme")); XCTAssertFalse(isError)
        XCTAssertEqual(events[3].name, "Edit")
        XCTAssertEqual(events[5], .text(claudeReplyText))
        XCTAssertEqual(events[7], .finished(text: claudeReplyText, isError: false))
    }

    func testClaudeCodeToolResultTextBlocksAndErrors() {
        let blocks = #"{"type":"user","message":{"content":[{"tool_use_id":"t2","type":"tool_result","content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}],"is_error":true}]}}"#
        XCTAssertEqual(AgentEventParser.parse(blocks, service: .claudeCode), [.toolResult(id: "t2", output: "line one\nline two", isError: true)])
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login","session_id":"s"}"#
        XCTAssertEqual(AgentEventParser.parse(failed, service: .claudeCode), [.session("s"), .finished(text: "Not logged in · Please run /login", isError: true)])
    }

    func testCodexLinesGiveSessionTextAndTheEnd() {
        let events = codexRecordedLines.flatMap { AgentEventParser.parse($0, service: .codex) }.filter { $0 != .ignored }
        XCTAssertEqual(events[0], .session("019e0000-0000-7000-8000-000000000002"))
        XCTAssertEqual(events[1], .text("I\u{2019}ll inspect and edit `greet.py` without running commands, the script, or tests.\n"))
        XCTAssertEqual(events.last, .finished(text: "", isError: false))
    }

    func testCodexCommandStepsGiveToolSteps() {
        let events = codexCommandLines.flatMap { AgentEventParser.parse($0, service: .codex) }
        XCTAssertEqual(events[0], .toolUse(id: "item_3", name: "shell", input: "/bin/zsh -lc 'cat greet.py'"))
        guard case .toolResult(let id, let output, let isError) = events[1] else { return XCTFail("command result expected") }
        XCTAssertEqual(id, "item_3"); XCTAssertTrue(output.contains("nme")); XCTAssertFalse(isError)
    }

    func testCodexFailuresAreReported() {
        let failedCommand = #"{"type":"item.completed","item":{"id":"item_9","type":"command_execution","command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}"#
        XCTAssertEqual(AgentEventParser.parse(failedCommand, service: .codex), [.toolResult(id: "item_9", output: "", isError: true)])
        let turnFailed = #"{"type":"turn.failed","error":{"message":"You are not signed in. Run codex login."}}"#
        XCTAssertEqual(AgentEventParser.parse(turnFailed, service: .codex), [.failed("You are not signed in. Run codex login.")])
        // A reconnect warning is not the end of the run.
        XCTAssertEqual(AgentEventParser.parse(#"{"type":"error","message":"Reconnecting... 1/5"}"#, service: .codex), [.ignored])
    }

    func testUnknownAndBrokenLinesAreIgnoredAndNeverThrow() {
        let lines = ["", "   ", "not json", "[1,2]", #"{"type":"stream_event","event":{}}"#, #"{"type":"assistant"}"#, #"{"type":"item.started"}"#, "{\"type\":"]
        for service in AgentService.allCases {
            for line in lines {
                XCTAssertEqual(AgentEventParser.parse(line, service: service), [.ignored], "\(service) \(line)")
            }
        }
    }
}

extension AgentEvent {
    var name: String? {
        if case .toolUse(_, let name, _) = self { return name }
        return nil
    }
}
