import XCTest
@testable import BlackTeamKit

/// Measuring a conversation that holds images: the text goes to the server's template and tokenizer, each image costs a fixed allowance.
final class ImageContextTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(route: String, body: JSONValue?)] = []
        func add(_ route: String, _ body: JSONValue?) { lock.lock(); list.append((route, body)); lock.unlock() }
        var all: [(route: String, body: JSONValue?)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// Every message is `textTokens` tokens; the context window is `window`.
    func fetch(_ calls: Calls, window: Int, textTokens: Int = 50) -> HTTPFetch {
        { request in
            let route = request.url!.path
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            calls.add(route, body)
            func reply(_ value: JSONValue) -> (Data, HTTPURLResponse) { (Data(value.text().utf8), httpResponse(200)) }
            switch route {
            case "/props": return reply(["default_generation_settings": ["n_ctx": .number(Double(window))]])
            case "/apply-template": return reply(["prompt": .string(body!["messages"]!.text())])
            case "/tokenize":
                let count = try JSONValue.parse(body!["content"]!.string!).array!.count * textTokens
                return reply(["tokens": .array(Array(repeating: 1, count: count))])
            default: throw URLError(.badURL)
            }
        }
    }

    let headers = ["Authorization": "Bearer k"]
    let endpoint = "http://127.0.0.1:45231/v1"
    let reference: JSONValue = [["id": "11111111-1111-1111-1111-111111111111", "name": "a.jpg", "bytes": 10, "width": 1, "height": 1]]

    func user(_ text: String, images: Bool = false) -> JSONValue {
        images ? ["role": "user", "content": .string(text), "images": reference] : ["role": "user", "content": .string(text)]
    }
    func assistant(_ text: String) -> JSONValue { ["role": "assistant", "content": .string(text)] }
    let system: JSONValue = ["role": "system", "content": "sys"]

    func testTheTemplateIsAskedWithTextOnlyAndEachImageAddsTheAllowance() async throws {
        let calls = Calls()
        let result = try await prepareContext(messages: [system, user("old", images: true), assistant("a"), user("new", images: true)], context: 32768, endpoint: endpoint,
                                              headers: headers, fetch: fetch(calls, window: 32768))
        for call in calls.all where call.route == "/apply-template" {
            XCTAssertTrue(call.body!["messages"]!.array!.allSatisfy { $0["images"] == nil })
        }
        XCTAssertEqual(result.report.measuredInputTokens, 4 * 50 + 2 * ImageCost.tokensPerImage)
        XCTAssertEqual(result.report.imageReserveTokens, 2 * ImageCost.tokensPerImage)
        XCTAssertEqual(result.report.json["imageReserveTokens"]?.int, 2 * ImageCost.tokensPerImage)
        // The messages handed back still carry their image references, for the request to fill in.
        XCTAssertEqual(result.messages.compactMap { $0["images"] }.count, 2)
    }

    func testAConversationWithoutImagesReportsNoReserve() async throws {
        let result = try await prepareContext(messages: [system, user("hi")], context: 4096, endpoint: endpoint, headers: headers, fetch: fetch(Calls(), window: 4096))
        XCTAssertNil(result.report.imageReserveTokens)
        XCTAssertNil(result.report.json["imageReserveTokens"])
    }

    func testTrimmingOlderTurnsTakesTheirImagesWithThemAndNeverLeavesOneAlone() async throws {
        // Room for the newest request with one image, not for the older turn that also has one.
        let window = 2560
        let calls = Calls()
        let result = try await prepareContext(messages: [system, user("old", images: true), assistant("a"), user("new", images: true)], context: window, mode: "fast",
                                              endpoint: endpoint, headers: headers, fetch: fetch(calls, window: window))
        XCTAssertEqual(result.report.omittedMessages, 2)
        XCTAssertEqual(result.messages.map { $0["role"]?.string }, ["system", "user"])
        XCTAssertEqual(result.messages.last?["content"]?.string, "new")
        XCTAssertEqual(result.messages.last?["images"]?.array?.count, 1)
        XCTAssertEqual(result.report.imageReserveTokens, ImageCost.tokensPerImage)
        XCTAssertEqual(result.report.decision, "select_recent")
        for message in result.messages where message["role"]?.string != "user" { XCTAssertNil(message["images"]) }
    }

    func testTheNewestRequestsImagesAreNeverTrimmedAway() async throws {
        let window = 1024
        do {
            _ = try await prepareContext(messages: [system, user("new", images: true)], context: window, mode: "fast", endpoint: endpoint, headers: headers, fetch: fetch(Calls(), window: window))
            XCTFail("an image that does not fit must be refused, not dropped")
        } catch { assertMatch(messageOf(error), "exceeding the") }
    }

    func testOtherServersAreEstimatedWithTheSameAllowance() throws {
        let plain = try prepareServerContext(messages: [system, user("hello")], context: 32768, endpoint: endpoint)
        let pictured = try prepareServerContext(messages: [system, user("hello", images: true)], context: 32768, endpoint: endpoint)
        XCTAssertEqual(pictured.report.measuredInputTokens - plain.report.measuredInputTokens, ImageCost.tokensPerImage)
        XCTAssertEqual(pictured.report.imageReserveTokens, ImageCost.tokensPerImage)
        let trimmed = try prepareServerContext(messages: [system, user("old", images: true), assistant("a"), user("new", images: true)], context: 2560, mode: "fast", endpoint: endpoint)
        XCTAssertEqual(trimmed.messages.map { $0["role"]?.string }, ["system", "user"])
        XCTAssertEqual(trimmed.messages.last?["images"]?.array?.count, 1)
    }

    func testChatStreamKeepsImagesWithTheirOwnMessageOnly() {
        let id1 = "11111111-1111-1111-1111-111111111111"
        let thread: JSONValue = ["messages": [
            ["id": "m1", "role": "user", "content": "first", "images": [["id": .string(id1), "name": "a.jpg", "bytes": 1, "width": 1, "height": 1]], "state": "done"],
            ["id": "m2", "role": "assistant", "content": "ok", "state": "done"],
            ["id": "m3", "role": "user", "content": "second", "state": "done"],
            ["id": "m4", "role": "assistant", "content": "", "state": "writing"],
        ]]
        let built = ChatStream.messagesFor(thread)
        XCTAssertEqual(built.map { $0["role"]?.string }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(built[1]["images"]?.array?.count, 1)
        XCTAssertNil(built[3]["images"])
        // A malformed reference (a path instead of an id) is dropped, not followed.
        let bad: JSONValue = ["messages": [["id": "m1", "role": "user", "content": "x", "images": [["id": "../../etc/passwd", "name": "a", "bytes": 1, "width": 1, "height": 1]], "state": "done"], ["id": "m2", "role": "assistant", "content": "", "state": "writing"]]]
        XCTAssertNil(ChatStream.messagesFor(bad).last?["images"])
    }
}
