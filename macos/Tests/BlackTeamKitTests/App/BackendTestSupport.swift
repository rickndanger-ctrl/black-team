import XCTest
@testable import BlackTeamKit

/// Opens once; everything waiting on it continues.
actor BackendGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// A model runtime that records what the backend asks of it.
final class StubRuntime: BackendRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _busy: [Bool] = [], _stops: [Bool] = [], _disposals = 0
    private var _state = RuntimeState.off
    private var _busyFlag = false
    var startAction: (@Sendable () async throws -> String)?
    var stopAction: (@Sendable () async throws -> Void)?
    var headers = ["Authorization": "Bearer local-test-key"]

    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var starts: Int { sync { _starts } }
    var busy: [Bool] { sync { _busy } }
    var stops: [Bool] { sync { _stops } }
    var disposals: Int { sync { _disposals } }
    var state: RuntimeState { get { sync { _state } } set { sync { _state = newValue } } }

    func status() async -> RuntimeStatus {
        sync { RuntimeStatus(state: _state, ready: _state == .ready, busy: _busyFlag, error: nil, name: "Fixture model", port: nil, features: []) }
    }
    func modelPid() async -> Int? { nil }
    func requestHeaders() async throws -> [String: String] { headers }
    func setBusy(_ value: Bool) async throws { sync { _busy.append(value); _busyFlag = value } }
    func start() async throws -> String {
        sync { _starts += 1 }
        if let startAction { return try await startAction() }
        return "http://127.0.0.1:5555/v1"
    }
    func stop(force: Bool) async throws {
        sync { _stops.append(force) }
        try await stopAction?()
    }
    func dispose() async throws { sync { _disposals += 1 } }
}

/// A Code engine that does what the test says.
final class StubEngine: CodeEngine, @unchecked Sendable {
    struct Run: @unchecked Sendable { var workspace: String?; var mode: String; var config: Config }
    private let lock = NSLock()
    private var _runs: [Run] = [], _undone: [String?] = []
    var action: (@Sendable (ThreadRef, JobState) async throws -> Void)?
    var runs: [Run] { lock.lock(); defer { lock.unlock() }; return _runs }
    var undone: [String?] { lock.lock(); defer { lock.unlock() }; return _undone }
    private func record(_ run: Run) { lock.lock(); _runs.append(run); lock.unlock() }
    private func recordUndo(_ id: String?) { lock.lock(); _undone.append(id); lock.unlock() }

    func run(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, signal: CancelSignal?,
             save: @escaping @Sendable (JSONValue) throws -> Void, mode: String, workspace: String?) async throws {
        record(Run(workspace: workspace, mode: mode, config: config))
        XCTAssertEqual(runtime.requestHeaders()["Authorization"], "Bearer local-test-key")
        try await action?(thread, job)
    }
    func undo(_ id: String?) throws -> UndoResult { recordUndo(id); return UndoResult(path: "a.txt", removed: false) }
}

/// Every request the fake model server saw.
final class ServerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URLRequest] = []
    func add(_ request: URLRequest) { lock.lock(); all.append(request); lock.unlock() }
    var list: [URLRequest] { lock.lock(); defer { lock.unlock() }; return all }
    var count: Int { list.count }
    func body(_ index: Int) -> JSONValue { (try? JSONValue.parse(list[index].httpBody ?? Data())) ?? .null }
}

/// A chat reply as the server would stream it: `text` split into lines.
func sse(_ text: String, status: Int = 200) -> (HTTPURLResponse, HTTPLines) {
    var rows = text.components(separatedBy: "\n")
    if rows.last == "" { rows.removeLast() }
    return (httpResponse(status), lines(rows))
}

let answerStream = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n"
    + "data: {\"choices\":[{\"delta\":{\"content\":\"Private \u{1F5A4} caf\u{00E9}\"}}]}\r\n\r\n"
    + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

let timedStream = "data: {\"choices\":[{\"delta\":{\"content\":\"Use make ship.\"}}]}\n\n"
    + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":900,\"completion_tokens\":40},\"timings\":{\"prompt_n\":900,\"prompt_per_second\":48.6,\"predicted_n\":40,\"predicted_per_second\":11.7}}\n\ndata: [DONE]\n\n"

let noTools = DiscoveryResult(terminals: [], apps: [], presets: [], runtime: "", dictation: "", graph: "")

/// What a test of the backend needs: files that pass the model checks, a fake runtime, fake network.
final class BackendFixture {
    let test: XCTestCase
    var files: RuntimeFixture
    let runtime = StubRuntime()
    let engine = StubEngine()
    let requests = ServerRequests()
    let planned = PlannerRequests()
    var reply: @Sendable (URLRequest) async throws -> (HTTPURLResponse, HTTPLines) = { _ in sse(answerStream) }
    var memory: Memory?
    var installer: RuntimeProviding?
    var downloader: FileDownloading?
    var fetch: HTTPFetch = { _ in throw URLError(.cannotConnectToHost) }
    var backends: [Backend] = []

    init(_ test: XCTestCase, server: Bool = false) throws {
        self.test = test
        files = try RuntimeFixture(test)
        if server {
            files.config.model = ModelConfig(source: "server", endpoint: "http://127.0.0.1:5555/v1", id: "a-custom-model", apiKey: "private-server-credential", name: "Fixture model")
        } else {
            files.config.model.name = "Fixture model"
        }
        try files.store.save(files.config)
    }

    var stateDir: String { files.stateDir }

    func make(keeperInterval: TimeInterval = 3600) throws -> Backend {
        let requests = self.requests, reply = self.reply, planned = self.planned
        let backend = try Backend(
            dataFolder: stateDir, version: "0.1.0-test", runtime: runtime, engine: engine, memory: memory,
            fetch: fetch,
            stream: { request in requests.add(request); return try await reply(request) },
            contextPlanner: { messages, context, mode, endpoint, headers, _ in
                planned.add(messages: messages, mode: mode)
                return PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, runtimeInstaller: installer, downloader: { [downloader] in downloader ?? Downloader() },
            terminal: { _, _ in }, home: files.dir + "/home", keeperInterval: keeperInterval)
        backends.append(backend)
        test.addTeardownBlock { await backend.shutdown() }
        return backend
    }

    func rewriteConfig(_ change: (inout Config) -> Void) throws {
        var config = try files.store.read()
        change(&config)
        try files.store.save(config)
    }
}

/// What the context planner was asked.
final class PlannerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [[JSONValue]] = [], _modes: [String] = []
    func add(messages: [JSONValue], mode: String) { lock.lock(); _messages.append(messages); _modes.append(mode); lock.unlock() }
    var messages: [[JSONValue]] { lock.lock(); defer { lock.unlock() }; return _messages }
    var modes: [String] { lock.lock(); defer { lock.unlock() }; return _modes }
}

func newID() -> String { UUID().uuidString.lowercased() }

/// The last message of a conversation.
func lastMessage(_ backend: Backend, _ threadId: String) -> JSONValue {
    backend.history.get(threadId)?["messages"]?.array?.last ?? .null
}
