import XCTest
@testable import BlackTeamKit

final class ThinkingTests: XCTestCase {
    func testThinkingLevelFollowsTheMode() {
        let fast: [String: JSONValue] = ["reasoning_effort": "none", "chat_template_kwargs": ["enable_thinking": false, "preserve_thinking": true]]
        XCTAssertEqual(thinkingOptions("fast"), fast)
        let balanced: [String: JSONValue] = ["reasoning_effort": "medium", "thinking_budget_tokens": 512, "chat_template_kwargs": ["enable_thinking": true, "preserve_thinking": true]]
        XCTAssertEqual(thinkingOptions("balanced"), balanced)
        XCTAssertEqual(thinkingOptions("deep")["reasoning_effort"], "high")
        XCTAssertEqual(thinkingOptions("extended")["thinking_budget_tokens"], 2048)
        XCTAssertEqual(thinkingOptions("nonsense")["reasoning_effort"], "none", "an unknown mode thinks no more than fast")
        XCTAssertEqual(thinkingOptions(), balanced)
    }
}
