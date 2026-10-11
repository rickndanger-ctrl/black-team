import XCTest
@testable import BlackTeamKit

/// Ports of the `readStream` and `messagesFor` tests in tests/server.test.cjs.
final class ChatStreamTests: XCTestCase {
    func testStreamParserRejectsMalformedProviderErrorOversizedAndUnfinishedFrames() async throws {
        for text in ["data: {bad json}", #"data: {"error":{"message":"provider private details"}}"#, "data: " + String(repeating: "x", count: 1024 * 1024 + 1), #"data: {"choices":[]}"#] {
            do { _ = try await ChatStream.readStream(lines([text]), onDelta: { _ in }); XCTFail("should throw") } catch {
                XCTAssertFalse(((error as? BlackTeamError)?.message ?? "").contains("private details"))
            }
        }
        var deltas: [JSONValue] = []
        let result = try await ChatStream.readStream(lines([#"data: {"choices":[{"delta":{"content":"\#u{1F5A4}"}}]}"#, "data: [DONE]"]), onDelta: { deltas.append($0) })
        XCTAssertEqual(deltas[0]["content"], "\u{1F5A4}")
        XCTAssertNil(result.finishReason)
    }

    func testReadsFinishReasonUsageAndTimings() async throws {
        let rows = [#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#, "", #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2},"timings":{"predicted_per_second":12.5}}"#, "data: [DONE]"]
        var content = ""
        let result = try await ChatStream.readStream(lines(rows), onDelta: { content += $0["content"]?.string ?? "" })
        XCTAssertEqual(content, "Hi")
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.usage?["completion_tokens"], 2)
        XCTAssertEqual(result.timings?["predicted_per_second"]?.double, 12.5)
        // A reply that only says [DONE] has finished too, with no reason.
        let bare = try await ChatStream.readStream(lines(["data: [DONE]"]), onDelta: { _ in })
        XCTAssertNil(bare.finishReason)
        // A stop signal ends the read.
        let signal = CancelSignal(); signal.cancel()
        do { _ = try await ChatStream.readStream(lines(rows), onDelta: { _ in }, signal: signal); XCTFail("should stop") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testContextOnlyIncludesCompletedHistoricalPairsAndTheLatestRequest() {
        let thread: JSONValue = ["messages": [
            ["role": "user", "content": "old"], ["role": "assistant", "content": "complete", "state": "done"],
            ["role": "user", "content": "failed"], ["role": "assistant", "content": "partial", "state": "error"],
            ["role": "user", "content": "new"], ["role": "assistant", "content": "", "state": "writing"]]]
        XCTAssertEqual(Array(ChatStream.messagesFor(thread).dropFirst()), [["role": "user", "content": "old"], ["role": "assistant", "content": "complete"], ["role": "user", "content": "new"]])
        let plain: JSONValue = ["messages": [["role": "user", "content": "plain"], ["role": "assistant", "content": "", "state": "writing"]]]
        XCTAssertEqual(ChatStream.messagesFor(plain).compactMap { $0["role"]?.string }, ["system", "user"])
    }

    func testCoreAndRecalledMemoryAreAttachedTheSameWayEveryTime() {
        let thread: JSONValue = ["core": "Prefers one-sentence answers.", "messages": [
            ["role": "user", "content": "How do I deploy?", "recalled": [["title": "Release process", "text": "make ship"]]],
            ["role": "assistant", "content": "Run it.", "state": "done"],
            ["role": "user", "content": "Thanks!", "recalled": []], ["role": "assistant", "content": "", "state": "writing"]]]
        let sent = ChatStream.messagesFor(thread)
        XCTAssertEqual(sent[0]["content"]?.string, ChatStream.SYSTEM + "\n\nWhat you know about the user:\nPrefers one-sentence answers.")
        XCTAssertEqual(sent[1]["content"], "How do I deploy?\n\n[From your memory. Use it only if it is relevant.]\n- Release process: make ship")
        XCTAssertEqual(sent[3]["content"], "Thanks!")
        XCTAssertTrue(ChatStream.SYSTEM.contains("running on the user\u{2019}s computer"))
    }
}
