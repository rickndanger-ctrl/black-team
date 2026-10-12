import XCTest
@testable import BlackTeamKit

/// Starts a real llama-server on a real model, asks for five words, and stops it.
/// Runs only when BLACK_TEAM_LIVE_SERVER (the llama-server) and BLACK_TEAM_LIVE_MODEL (a .gguf) are set.
final class LiveServerTests: XCTestCase {
    func testStartsAskesAndStopsARealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["BLACK_TEAM_LIVE_SERVER"], let model = env["BLACK_TEAM_LIVE_MODEL"] else {
            throw XCTSkip("Set BLACK_TEAM_LIVE_SERVER and BLACK_TEAM_LIVE_MODEL to run the live check.")
        }
        let dir = makeTemporaryFolder(self)
        let store = try ConfigStore(stateDir: dir + "/state")
        try store.save(Config(model: ModelConfig(name: "Live", file: model, runtime: server, context: 2048, threads: 4), workspace: dir))
        let runtime = ModelRuntime(configStore: store, startupTimeoutMs: 180_000)
        addTeardownBlock { try? await runtime.dispose() }
        let endpoint = try await runtime.start()
        let pid = await runtime.modelPid()
        XCTAssertNotNil(pid)
        var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for (name, value) in try await runtime.requestHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"model":"black-team-local","max_tokens":24,"messages":[{"role":"user","content":"Reply with exactly five words."}]}"#.utf8)
        let (data, reply) = try await LocalHTTP.fetch(request)
        XCTAssertEqual(reply.statusCode, 200)
        let text = try JSONValue.parse(data)["choices"]?[0]?["message"]?["content"]?.string ?? ""
        print("LIVE REPLY: \(text)")
        XCTAssertFalse(text.isEmpty)
        try await runtime.stop()
        let status = await runtime.status()
        XCTAssertEqual(status.state, .off)
        if let pid { XCTAssertNotEqual(kill(Int32(pid), 0), 0, "the model process must be gone") }
    }
}
