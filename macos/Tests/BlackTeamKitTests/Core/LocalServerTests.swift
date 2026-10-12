import XCTest
@testable import BlackTeamKit

private final class Calls: @unchecked Sendable { var count = 0; var request: URLRequest? }

private func reply(_ status: Int, _ body: String, url: String = "http://127.0.0.1:1234/v1/models") -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

final class LocalServerTests: XCTestCase {
    func testEndpointsStayOnLoopback() async throws {
        XCTAssertEqual(try localEndpoint("http://localhost:11434/v1/"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(try localEndpoint("http://[::1]:1234/v1"), "http://[::1]:1234/v1")
        for url in ["https://example.com/v1", "http://192.168.1.2:1234/v1", "http://localhost.evil.test:1234/v1", "http://user:key@localhost:1234/v1",
                    "http://localhost:1234/v1?key=secret", "http://localhost:1234/v1#x", "file:///tmp/v1", "http://localhost/v1", "http://localhost:1234/v2"] {
            XCTAssertThrowsError(try localEndpoint(url), url)
        }
        XCTAssertThrowsError(try localEndpoint("not a url"))
    }

    func testDiscoveryAsksOnlyLoopbackAndNeverEchoesTheKey() async throws {
        let calls = Calls()
        do {
            _ = try await discoverModels(endpoint: "https://example.com/v1", fetch: { _ in calls.count += 1; return reply(200, "{}") })
            XCTFail("remote endpoint accepted")
        } catch {}
        XCTAssertEqual(calls.count, 0)
        let found = try await discoverModels(endpoint: "http://localhost:1234/v1", apiKey: "fixture-secret", fetch: { request in
            calls.request = request
            return reply(200, #"{"data":[{"id":"qwen"},{"id":"qwen"},{"id":3}]}"#)
        })
        XCTAssertEqual(calls.request?.url?.absoluteString, "http://127.0.0.1:1234/v1/models")
        XCTAssertEqual(calls.request?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(found.models, ["qwen"])
        XCTAssertFalse("\(found)".contains("fixture-secret"))
        for (status, body) in [(401, "{}"), (200, #"{"data":[]}"#), (200, #"{"unexpected":true}"#), (200, "nonsense"), (500, "{}")] {
            do {
                _ = try await discoverModels(endpoint: "http://localhost:1234/v1", fetch: { _ in reply(status, body) })
                XCTFail("accepted \(status) \(body)")
            } catch {}
        }
    }

    func testUnreachableServerAndKeyMessages() async {
        do {
            _ = try await discoverModels(endpoint: "http://localhost:1234/v1", fetch: { _ in throw URLError(.cannotConnectToHost) })
            XCTFail()
        } catch { XCTAssertTrue((error as! BlackTeamError).message.hasPrefix("Cannot reach the local model server")) }
        do {
            _ = try await discoverModels(endpoint: "http://localhost:1234/v1", fetch: { _ in reply(403, "") })
            XCTFail()
        } catch { XCTAssertEqual((error as! BlackTeamError).message, "The local server requires a valid API key.") }
        XCTAssertThrowsError(try serverHeaders("has space"))
        XCTAssertEqual(try serverHeaders(""), [:])
    }
}
