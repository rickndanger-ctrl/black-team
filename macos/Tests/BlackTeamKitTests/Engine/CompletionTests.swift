import XCTest
@testable import BlackTeamKit

/// `Engine.complete`: the streamed call, its idle allowance and its timing capture.
final class CompletionTests: XCTestCase {
    func data(_ value: JSONValue) -> String { "data: \(value.text())" }

    func testWithoutServerTimingsTheClockGivesTheTwoSpeeds() async throws {
        let ticks = Counter()
        // Each call to now() moves the clock one second: sent at 0, first token at 1, finished at 2.
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: Double(ticks.next())) }
        let fetch: HTTPStreamFetch = { _ in
            (httpResponse(), lines([self.data(["choices": [["delta": ["content": "Hi"]]]]), self.data(["choices": [["delta": [:], "finish_reason": "stop"]], "usage": ["prompt_tokens": 600, "completion_tokens": 40]]), "data: [DONE]"]))
        }
        var seen = ""
        let box = Box()
        let result = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: ["model": "m"], idleMs: 60000, fetch: fetch, onText: { box.set($0) }, now: clock)
        seen = box.value
        XCTAssertEqual(seen, "Hi"); XCTAssertEqual(result.text, "Hi"); XCTAssertEqual(result.finish, "stop")
        XCTAssertEqual(result.usage, CompletionUsage(promptTokens: 600, completionTokens: 40))
        let timings = try XCTUnwrap(result.timings)
        XCTAssertEqual(timings.promptN, 600); XCTAssertEqual(timings.predictedN, 40)
        XCTAssertEqual(timings.promptPerSecond, 600 / 1.0, accuracy: 0.001)
        XCTAssertEqual(timings.predictedPerSecond, 40 / 1.0, accuracy: 0.001)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var stored = ""
        func set(_ text: String) { lock.lock(); stored = text; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testToolCallsAssembleFromPiecesAndTheCountOfIndexesIsKept() async throws {
        let fetch: HTTPStreamFetch = { _ in
            (httpResponse(), lines([
                self.data(["choices": [["delta": ["tool_calls": [["index": 1, "id": "b", "function": ["name": "list", "arguments": "{}"]]]]]]]),
                self.data(["choices": [["delta": ["tool_calls": [["index": 0, "id": "a", "function": ["name": "re", "arguments": "{\"pa"]]]]]]]),
                self.data(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["name": "ad", "arguments": "th\":\"x\"}"]]]]]]]),
                self.data(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            ]))
        }
        let result = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: fetch)
        XCTAssertEqual(result.calls, [ToolCallPart(id: "a", name: "read", arguments: "{\"path\":\"x\"}"), ToolCallPart(id: "b", name: "list", arguments: "{}")])
        XCTAssertNil(result.timings)
    }

    func testAnErrorStatusReportsTheServersWordsAndFlagsAFullWindow() async throws {
        let fetch: HTTPStreamFetch = { _ in (httpResponse(400), lines([self.data([:]).replacingOccurrences(of: "data: ", with: ""), ""])) }
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: fetch); XCTFail() } catch let error as ModelRequestError {
            XCTAssertEqual(error.message, "The model returned HTTP 400."); XCTAssertFalse(error.overflow); XCTAssertEqual(error.status, 400)
        }
        let full: HTTPStreamFetch = { _ in (httpResponse(400), lines([#"{"error":{"message":"the request exceeds the available context size"}}"#])) }
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: full); XCTFail() } catch let error as ModelRequestError {
            XCTAssertEqual(error.message, "The model returned HTTP 400. the request exceeds the available context size"); XCTAssertTrue(error.overflow)
        }
    }

    func testStreamErrorsEndOfStreamWithoutAFinishAndOversizedRepliesAreRefused() async throws {
        let failing: HTTPStreamFetch = { _ in (httpResponse(), lines([self.data(["error": ["message": "slot busy"]])])) }
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: failing); XCTFail() } catch { XCTAssertEqual((error as? BlackTeamError)?.message, "slot busy") }
        let unfinished: HTTPStreamFetch = { _ in (httpResponse(), lines([self.data(["choices": [["delta": ["content": "partial"]]]]), "data: [DONE]"])) }
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: unfinished); XCTFail() } catch {
            XCTAssertEqual((error as? BlackTeamError)?.message, "The model stream ended before it finished. Send a message to continue.")
        }
        let huge = String(repeating: "x", count: 300_000)
        let big: HTTPStreamFetch = { _ in (httpResponse(), lines([self.data(["choices": [["delta": ["content": .string(huge)]]]])])) }
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 60000, fetch: big); XCTFail() } catch {
            XCTAssertEqual((error as? BlackTeamError)?.message, "The reply reached the storage limit.")
        }
    }

    func testASilentModelIsStoppedAfterTheIdleAllowanceButAStopWins() async throws {
        let silent: HTTPStreamFetch = { _ in
            let stream = HTTPLines { continuation in continuation.onTermination = { _ in } }
            return (httpResponse(), stream)
        }
        let began = Date()
        do { _ = try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], idleMs: 300, fetch: silent); XCTFail() } catch {
            XCTAssertEqual((error as? BlackTeamError)?.message, "The model stopped sending data. What it wrote so far is saved.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let signal = CancelSignal()
        let task = Task { try await Engine.complete(endpoint: "http://127.0.0.1:1/v1", body: [:], signal: signal, idleMs: 60000, fetch: silent) }
        try await Task.sleep(nanoseconds: 100_000_000)
        signal.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
