import XCTest
@testable import BlackTeamKit

/// Ports of tests/context.test.cjs.
final class ContextTests: XCTestCase {
    let system: JSONValue = ["role": "system", "content": "Private instructions \u{1F5A4}"]
    let latest: JSONValue = ["role": "user", "content": "Latest request with exact whitespace.  \n"]

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(route: String, body: JSONValue?, request: URLRequest)] = []
        func add(_ route: String, _ body: JSONValue?, _ request: URLRequest) { lock.lock(); list.append((route, body, request)); lock.unlock() }
        var all: [(route: String, body: JSONValue?, request: URLRequest)] { lock.lock(); defer { lock.unlock() }; return list }
        var routes: [String] { all.map(\.route) }
    }

    struct Options {
        var actualContext = 4096
        var count: (([JSONValue]) -> Int)?
        var respond: (@Sendable (String) -> (Int, JSONValue)?)?
    }

    func harness(_ options: Options = Options()) -> (calls: Calls, fetch: HTTPFetch) {
        let calls = Calls()
        let fetch: HTTPFetch = { request in
            let route = request.url!.path
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            calls.add(route, body, request)
            func reply(_ status: Int, _ value: JSONValue) -> (Data, HTTPURLResponse) { (Data(value.text().utf8), httpResponse(status)) }
            if let custom = options.respond?(route) { return reply(custom.0, custom.1) }
            switch route {
            case "/props": return reply(200, ["default_generation_settings": ["n_ctx": .number(Double(options.actualContext))]])
            case "/apply-template": return reply(200, ["prompt": .string(body!["messages"]!.text())])
            case "/tokenize":
                let messages = try JSONValue.parse(body!["content"]!.string!).array!
                let count = options.count?(messages) ?? (100 + messages.count * 100)
                return reply(200, ["tokens": .array(Array(repeating: 10, count: count))])
            default: throw URLError(.badURL)
            }
        }
        return (calls, fetch)
    }

    let headers = ["Authorization": "Bearer private-test-key"]
    let endpoint = "http://127.0.0.1:45231/v1"

    func testMeasuresTheRealChatTemplateLocallyAndPreservesExactRequestAndSystemContent() async throws {
        let (calls, fetch) = harness()
        let original = [system, latest]
        let result = try await prepareContext(messages: original, context: 4096, mode: "balanced", endpoint: endpoint, headers: headers, fetch: fetch)
        XCTAssertEqual(result.messages, original)
        XCTAssertEqual(result.report, ContextReport(measuredInputTokens: 300, context: 4096, maxTokens: 1024, omittedMessages: 0, method: "local-tokenizer", inputBudget: 2944, safetyMargin: 128, decision: "keep"))
        XCTAssertEqual(result.maxTokens, 1024)
        XCTAssertEqual(calls.routes, ["/props", "/apply-template", "/tokenize"])
        XCTAssertEqual(calls.all[2].body?["add_special"], true)
        XCTAssertEqual(calls.all[2].body?["parse_special"], true)
        for call in calls.all {
            XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer private-test-key")
            XCTAssertEqual(call.request.url?.host, "127.0.0.1")
        }
        XCTAssertFalse(result.report.json.text().contains("private-test-key"))
    }

    func testModeBudgetsAndRuntimeContextClampReserveSpaceForGeneration() async throws {
        for (mode, expected) in ["fast": 512, "balanced": 1024, "deep": 2048, "extended": 4096] {
            let (_, fetch) = harness(Options(actualContext: 32768))
            let result = try await prepareContext(messages: [system, latest], context: 32768, mode: mode, endpoint: endpoint, headers: headers, fetch: fetch)
            XCTAssertEqual(result.maxTokens, expected)
        }
        var (_, fetch) = harness(Options(actualContext: 2048))
        var result = try await prepareContext(messages: [system, latest], context: 4096, mode: "extended", endpoint: endpoint, headers: headers, fetch: fetch)
        XCTAssertEqual(result.report.context, 2048)
        XCTAssertEqual(result.maxTokens, 512)
        (_, fetch) = harness(Options(actualContext: 32768))
        result = try await prepareContext(messages: [system, latest], context: 1024, endpoint: endpoint, headers: headers, fetch: fetch)
        XCTAssertEqual(result.report.context, 1024)
    }

    func testDropsOldestCompleteTurnsWhileRetainingRecentContextAndStoredHistory() async throws {
        let (_, fetch) = harness(Options(actualContext: 1024, count: { $0.reduce(0) { $0 + ($1["role"] == "system" ? 20 : 150) } }))
        var messages = [system]
        for i in 0..<6 { messages += [["role": "user", "content": .string("Question \(i)")], ["role": "assistant", "content": .string("Answer \(i)")]] }
        messages.append(latest)
        let snapshot = messages
        let result = try await prepareContext(messages: messages, context: 4096, endpoint: endpoint, headers: headers, fetch: fetch)
        XCTAssertEqual(result.messages, [system, ["role": "user", "content": "Question 5"], ["role": "assistant", "content": "Answer 5"], latest])
        XCTAssertEqual(result.report.measuredInputTokens, 470)
        XCTAssertEqual(result.report.omittedMessages, 10)
        XCTAssertEqual(result.report.decision, "select_recent")
        XCTAssertEqual(messages, snapshot)
    }

    func testTheNewestRequestIsNeverSilentlyShortenedWhenItAloneExceedsTheBudget() async throws {
        let (_, fetch) = harness(Options(actualContext: 512, count: { _ in 600 }))
        do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: endpoint, headers: headers, fetch: fetch); XCTFail("should throw") } catch {
            assertMatch((error as? BlackTeamError)?.message ?? "", "latest request.*600 tokens.*256-token input budget")
        }
    }

    func testLongSavedHistoryUsesAtMostEightTemplateTokenizerChecksAndOmitsCompleteTurns() async throws {
        let (calls, fetch) = harness(Options(actualContext: 4096))
        var messages = [system]
        for i in 0..<1000 { messages += [["role": "user", "content": .string("Q\(i)")], ["role": "assistant", "content": .string("A\(i)")]] }
        messages.append(latest)
        let result = try await prepareContext(messages: messages, context: 4096, endpoint: endpoint, headers: headers, fetch: fetch)
        XCTAssertLessThanOrEqual(calls.routes.filter { $0 == "/apply-template" }.count, 8)
        XCTAssertGreaterThan(result.report.omittedMessages, 1800)
        XCTAssertEqual(result.report.omittedMessages % 2, 0)
        XCTAssertEqual(result.messages.last, latest)
        XCTAssertLessThanOrEqual(result.report.measuredInputTokens + result.maxTokens + 128, result.report.context)
        XCTAssertEqual(messages.count, 2002)
    }

    func testUnsupportedLocalEndpointsFailVisiblyWithoutSubstitutingCharacterEstimates() async throws {
        for route in ["/props", "/apply-template", "/tokenize"] {
            let (_, fetch) = harness(Options(respond: { $0 == route ? (404, [:]) : nil }))
            do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: endpoint, headers: headers, fetch: fetch); XCTFail("should throw") } catch {
                assertMatch((error as? BlackTeamError)?.message ?? "", "requires working llama.cpp.*HTTP 404")
            }
        }
    }

    func testMalformedContextTemplateAndTokenResponsesAreRejected() async throws {
        let cases: [(String, JSONValue, String)] = [
            ("/props", [:], "did not report a usable context"),
            ("/apply-template", [:], "did not return a chat template"),
            ("/tokenize", ["tokens": ["fake"]], "did not return valid token IDs"),
            ("/tokenize", [:], "did not return valid token IDs"),
        ]
        for (route, body, expected) in cases {
            let (_, fetch) = harness(Options(respond: { $0 == route ? (200, body) : nil }))
            do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: endpoint, headers: headers, fetch: fetch); XCTFail("should throw") } catch {
                assertMatch((error as? BlackTeamError)?.message ?? "\(error)", expected)
            }
        }
    }

    func testExternalURLsAndIncompleteConversationsAreNotAccepted() async throws {
        let (calls, fetch) = harness()
        for bad in ["https://example.com/v1", "http://localhost:1234/v1", "http://127.0.0.1:1234/v1?remote=true", "http://user:password@127.0.0.1:1234/v1"] {
            do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: bad, headers: headers, fetch: fetch); XCTFail("should throw \(bad)") } catch {
                assertMatch((error as? BlackTeamError)?.message ?? "", "only connects to the owned model")
            }
        }
        let cases: [[JSONValue]] = [
            [["role": "assistant", "content": "orphan"], latest],
            [latest, ["role": "assistant", "content": "completed"]],
            [latest, system],
            [["role": "user", "content": "unfinished"], latest],
            [["role": "user", "content": [["text": "unsupported"]]]],
        ]
        for messages in cases {
            do { _ = try await prepareContext(messages: messages, context: 4096, endpoint: endpoint, headers: headers, fetch: fetch); XCTFail("should throw") } catch {}
        }
        XCTAssertEqual(calls.all.count, 0)
    }

    func testAbortedContextReviewPerformsNoFurtherRequests() async throws {
        let (calls, fetch) = harness()
        let signal = CancelSignal(); signal.cancel()
        do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: endpoint, headers: headers, fetch: fetch, signal: signal); XCTFail("should throw") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls.all.count, 0)
    }

    func testRejectsBadContextModeAndMissingAuthentication() async throws {
        let (_, fetch) = harness()
        do { _ = try await prepareContext(messages: [system, latest], context: 100, endpoint: endpoint, headers: headers, fetch: fetch); XCTFail() } catch { assertMatch((error as? BlackTeamError)?.message ?? "", "at least 256 tokens") }
        do { _ = try await prepareContext(messages: [system, latest], context: 4096, mode: "turbo", endpoint: endpoint, headers: headers, fetch: fetch); XCTFail() } catch { assertMatch((error as? BlackTeamError)?.message ?? "", "Choose fast, balanced, deep, or extended") }
        do { _ = try await prepareContext(messages: [system, latest], context: 4096, endpoint: endpoint, headers: [:], fetch: fetch); XCTFail() } catch { assertMatch((error as? BlackTeamError)?.message ?? "", "private local model authentication") }
    }

    func testServerContextEstimatesBytesAndDropsOldTurnsFirst() throws {
        let plain = try prepareServerContext(messages: [system, latest], context: 4096, endpoint: endpoint)
        XCTAssertEqual(plain.report.method, "estimated-bytes")
        XCTAssertEqual(plain.report.measuredInputTokens, 128 + ("Private instructions \u{1F5A4}".utf8.count + 32) + ("Latest request with exact whitespace.  \n".utf8.count + 32))
        XCTAssertEqual(plain.report.decision, "keep")
        XCTAssertEqual(plain.maxTokens, 1024)
        var messages = [system]
        for i in 0..<30 { messages += [["role": "user", "content": .string(String(repeating: "q", count: 200) + "\(i)")], ["role": "assistant", "content": .string(String(repeating: "a", count: 200))]] }
        messages.append(latest)
        let cut = try prepareServerContext(messages: messages, context: 2048, mode: "fast", endpoint: endpoint)
        XCTAssertEqual(cut.report.decision, "select_recent")
        XCTAssertEqual(cut.report.omittedMessages, messages.count - cut.messages.count)
        XCTAssertEqual(cut.messages.last, latest)
        XCTAssertLessThanOrEqual(cut.report.measuredInputTokens, cut.report.inputBudget)
        XCTAssertThrowsError(try prepareServerContext(messages: [system, latest], context: 100, endpoint: endpoint))
        XCTAssertThrowsError(try prepareServerContext(messages: [system, latest], context: 200000, endpoint: endpoint))
        XCTAssertThrowsError(try prepareServerContext(messages: [system, latest], context: 4096, mode: "x", endpoint: endpoint))
        XCTAssertThrowsError(try prepareServerContext(messages: [system, latest], context: 4096, endpoint: "https://example.com/v1"))
        XCTAssertThrowsError(try prepareServerContext(messages: [system, ["role": "user", "content": .string(String(repeating: "x", count: 9000))]], context: 1024, endpoint: endpoint))
    }
}
