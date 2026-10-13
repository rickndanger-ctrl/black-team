import XCTest
@testable import BlackTeamKit

// A desktop service without a socket: a real Backend (fake model runtime, fake Claude Code and Codex, a stubbed network and terminal),
// the control channel, and the phone router with the desktop's session, so the same request can be made as the window and as a paired
// phone. Nothing real starts and nothing leaves the test process.

/// Everything the window or a phone was told, kept to prove a key never shows up in it. When WINDOW_API_EXAMPLES names a file, the first
/// request and answer of each kind is written there (the examples in the window API document come from these tests).
final class WindowWire: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var seen = Set<String>()
    var all: String { lock.withLock { texts.joined(separator: "\n") } }

    func note(label: String, request: JSONValue?, response: String, status: String) {
        lock.withLock {
            texts.append(response)
            guard let path = ProcessInfo.processInfo.environment["WINDOW_API_EXAMPLES"], seen.insert(label + " " + status).inserted else { return }
            // Tests run one after another in one process; each new kind of exchange is appended to what the file holds.
            var current = FileManager.default.contents(atPath: path).flatMap { try? JSONValue.parse($0) }?.array ?? []
            current.append(["label": .string(label), "status": .string(status), "request": request ?? .null, "response": (try? JSONValue.parse(response)) ?? .string(response)])
            try? Data(JSONValue.array(current).text(pretty: true).utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

final class TerminalScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    func add(_ text: String) { lock.withLock { scripts.append(text) } }
    var all: [String] { lock.withLock { scripts } }
}

struct WindowAnswer {
    var status: Int
    var text: String
    var json: JSONValue { (try? JSONValue.parse(text)) ?? .null }
    var error: String { json["error"]?.string ?? "" }
    subscript(key: String) -> JSONValue? { json[key] }
}

final class WindowRig {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."
    let vaultNote = "the umbrella is kept in Vault-Secret-Beta"
    let fixture: BackendFixture
    let backend: Backend
    let agents: FakeAgentLauncher
    let responder = Responder()
    let wire = WindowWire()
    let opened = TerminalScripts()
    let requests = ServerRequests()        // every model request: local and cloud
    let discovery = ServerRequests()       // every "list models" request
    let service: DesktopService
    let router: PhoneRouter
    let session = DesktopSession()
    let routes: DesktopRoutes
    let phoneSession: String
    let web: String
    let port = 18199
    let origin = "http://127.0.0.1:18199"
    var control: DesktopControl { service.control }
    /// What the fake service lists for `GET /models` (OpenRouter-shaped: prices, supported parameters).
    nonisolated(unsafe) static var modelList: JSONValue = [
        "data": [
            ["id": "vendor/paid-model", "context_length": 200000, "pricing": ["prompt": "0.000003", "completion": "0.000015"], "supported_parameters": ["tools", "temperature"]],
            ["id": "vendor/free-agent:free", "context_length": 131072, "pricing": ["prompt": "0", "completion": "0"], "supported_parameters": ["tools"]],
            ["id": "vendor/free-chat:free", "context_length": 32768, "pricing": ["prompt": "0", "completion": "0"], "supported_parameters": ["temperature"]],
        ],
    ]

    init(_ test: XCTestCase, seedVault: Bool = true, agents given: FakeAgentLauncher? = nil, images: Bool = false) async throws {
        fixture = try BackendFixture(test, server: images)
        let agents = given ?? FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
        self.agents = agents
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        if seedVault {
            try vault.write("Core", "# Core\n\n\(vaultCore)\n")
            try vault.remember("Umbrella", vaultNote)
        }
        let requests = self.requests, discovery = self.discovery, responder = self.responder, opened = self.opened
        let host = self.host, secret = self.secret
        responder.respond = { cloud, _ in cloud ? "Cloud answer" : "Local answer" }
        let planned = fixture.planned
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine, memory: vault,
            fetch: { request in
                // The model list of a cloud service, and the version registry. A wrong key is refused the way a service does.
                discovery.add(request)
                if request.url?.host == host {
                    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                    let status = auth == "Bearer \(secret)" ? 200 : 401
                    return (Data(WindowRig.modelList.text().utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
                }
                if request.url?.host == "registry.npmjs.org" {
                    return (Data(#"{"version":"9.9.9"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
                }
                throw URLError(.cannotConnectToHost)
            },
            stream: { request in
                requests.add(request)
                let cloud = request.url?.host == host
                let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
                let prompt = body["messages"]?.array?.last?["content"]?.string ?? ""
                let text = try await responder.respond(cloud, prompt)
                var stream = "data: " + JSONValue.object(["choices": [["delta": ["content": .string(text)]]]]).text() + "\n\n"
                stream += "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                if cloud { stream += "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12480,\"completion_tokens\":1930,\"prompt_tokens_details\":{\"cached_tokens\":2000}}}\n\n" }
                return sse(stream + "data: [DONE]\n\n")
            },
            contextPlanner: { messages, context, mode, _, _, _ in
                planned.add(messages: messages, mode: mode)
                return PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, script in opened.add((try? String(contentsOfFile: script, encoding: .utf8)) ?? script) },
            home: fixture.files.dir + "/home", keeperInterval: 3600, agents: agents)
        fixture.backends.append(backend)
        self.backend = backend
        test.addTeardownBlock { await backend.shutdown() }

        web = fixture.files.dir + "/web"
        try FileManager.default.createDirectory(atPath: web, withIntermediateDirectories: true)
        try "<html>black team</html>".write(toFile: web + "/index.html", atomically: true, encoding: .utf8)
        var phoneOptions = PhoneOptions()
        phoneOptions.webRoot = web; phoneOptions.port = port; phoneOptions.desktop = session
        phoneOptions.runner = { _, _, _ in throw PhoneCommandError(notFound: true) }
        backend.configurePhone(phoneOptions)
        backend.configureDesktop()
        service = try DesktopService(options: DesktopServiceOptions(web: web, version: "1.2.3", port: 0, dataFolder: fixture.stateDir,
                                                                    tailscale: { _, _, _ in throw PhoneCommandError(notFound: true) }), backend: backend)
        service.control = DesktopControl(backend, home: fixture.files.dir, environment: ["PATH": ""])
        let keysFolder = fixture.files.dir + "/phone-keys"
        try FileManager.default.createDirectory(atPath: keysFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys = try PhoneKeys(folder: keysFolder)
        phoneSession = keys.secret("session", hostname: phoneHost, owner: phoneOwner)
        routes = DesktopRoutes(backend)
        router = PhoneRouter(backend: BackendPhone(backend), config: FakePhoneStore(PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner)), keys: keys,
                             webRoot: web, localPort: port, desktop: session, desktopRoutes: routes, isConnected: { true })
    }

    // MARK: Control channel

    /// One line of the control channel, as the window's main process sends it.
    @discardableResult
    func ask(_ action: String, _ data: JSONValue = [:]) async -> JSONValue {
        let line = JSONValue.object(["id": 1, "action": .string(action), "data": data]).text()
        let reply = await service.respond(toLine: line) ?? "null"
        let json = (try? JSONValue.parse(reply)) ?? .null
        wire.note(label: action, request: data, response: json["ok"]?.bool == true ? (json["result"] ?? .null).text() : reply, status: json["ok"]?.bool == true ? "ok" : "error")
        return json
    }

    func result(_ action: String, _ data: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let reply = await ask(action, data)
        XCTAssertEqual(reply["ok"]?.bool, true, "\(action): \(reply["error"]?.string ?? "")", file: file, line: line)
        return reply["result"] ?? .null
    }

    func refused(_ action: String, _ data: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) async -> String {
        let reply = await ask(action, data)
        XCTAssertEqual(reply["ok"]?.bool, false, "\(action) should be refused", file: file, line: line)
        return reply["error"]?.string ?? ""
    }

    func expectRefusal(_ action: String, _ data: JSONValue = [:], exact: String? = nil, prefix: String? = nil, contains: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let message = await refused(action, data, file: file, line: line)
        if let exact { XCTAssertEqual(message, exact, action, file: file, line: line) }
        if let prefix { XCTAssertTrue(message.hasPrefix(prefix), "\(message) should start with \(prefix)", file: file, line: line) }
        if let contains { XCTAssertTrue(message.contains(contains), "\(message) should contain \(contains)", file: file, line: line) }
    }

    var address: JSONValue { .string("https://\(host)/v1") }

    // MARK: HTTP, as the window and as a phone

    func head(_ method: String, _ path: String, phone: Bool, length: Int, contentType: String?) -> HTTPHead {
        var headers: [String: String]
        if phone {
            headers = ["host": "\(phoneHost):\(Phone.phonePort)", "tailscale-user-login": phoneOwner, "cookie": "\(PhoneRouter.cookieName)=\(phoneSession)"]
            if method == "POST" { headers["origin"] = "https://\(phoneHost):\(Phone.phonePort)" }
        } else {
            headers = ["host": "127.0.0.1:\(port)", "cookie": "\(DesktopSession.cookieName)=\(session.sessionKey)"]
            if method == "POST" { headers["origin"] = origin }
        }
        if method == "POST" { headers["content-type"] = contentType ?? "application/json" }
        let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return HTTPHead(method: method, target: path, path: String(split[0]), query: split.count > 1 ? HTTPParser.parseQuery(String(split[1])) : [], headers: headers, contentLength: length)
    }

    @discardableResult
    func http(_ method: String, _ path: String, _ json: JSONValue? = nil, raw: Data? = nil, contentType: String? = nil, phone: Bool = false) async -> WindowAnswer {
        let body = raw ?? json.map { Data($0.text().utf8) } ?? Data()
        let response = await router.respond(head(method, path, phone: phone, length: body.count, contentType: contentType), body: body, peer: "127.0.0.1")
        let text = String(decoding: response.body, as: UTF8.self)
        let isImage = response.headers.contains { $0.0.lowercased() == "content-type" && $0.1.hasPrefix("image/") }
        wire.note(label: (phone ? "phone " : "") + method + " " + path.split(separator: "?").first.map(String.init)!, request: json, response: isImage ? "(image bytes)" : text, status: String(response.status))
        return WindowAnswer(status: response.status, text: text)
    }

    func desktop(_ method: String, _ path: String, _ json: JSONValue? = nil) async -> WindowAnswer { await http(method, path, json) }
    func phone(_ method: String, _ path: String, _ json: JSONValue? = nil) async -> WindowAnswer { await http(method, path, json, phone: true) }

    func bytes(_ path: String, phone: Bool = false) async -> (status: Int, data: Data, type: String) {
        let response = await router.respond(head("GET", path, phone: phone, length: 0, contentType: nil), body: Data(), peer: "127.0.0.1")
        return (response.status, response.body, response.headers.first { $0.0.lowercased() == "content-type" }?.1 ?? "")
    }

    // MARK: Helpers

    func chat(_ message: String = "where is my umbrella", _ more: [String: JSONValue] = [:], phone: Bool = false, wait: Bool = true) async -> WindowAnswer {
        var body: [String: JSONValue] = ["message": .string(message), "requestId": .string(newID())]
        for (key, value) in more { body[key] = value }
        let answer = await http("POST", "/api/chat", .object(body), phone: phone)
        if wait, answer.status == 202 { await backend.waitForIdle() }
        return answer
    }

    func addCloud(name: String = "Cloud Big", id: String = "big-model", endpoint: String? = nil, key: String? = nil) async throws {
        _ = try await result("cloud-save", ["endpoint": .string(endpoint ?? "https://\(host)/v1"), "id": .string(id), "apiKey": .string(key ?? secret), "name": .string(name), "context": 100_000])
    }

    var localKey: String { backend.savedModels.list().first { !$0.isCloud }!.key }
    var cloudKey: String { backend.savedModels.list().first { $0.isCloud }!.key }

    func useLocal() async throws { _ = try await result("model-switch", ["key": .string(localKey)]) }

    func project(_ name: String = "Work", cloud: Bool = false) async throws -> ProjectSummary {
        let made = try backend.createProject(name: name)
        if cloud { _ = try await result("project-cloud", ["id": .string(made.id), "allowed": true, "confirmed": true]) }
        return made
    }

    func thread(_ id: String) -> JSONValue { backend.history.get(id) ?? .null }

    /// Which files under the data folder contain `text`.
    func filesHolding(_ text: String) -> [String] {
        var holders: [String] = []
        for name in (FileManager.default.subpaths(atPath: fixture.stateDir) ?? []) {
            var isDirectory: ObjCBool = false
            let path = fixture.stateDir + "/" + name
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, let data = FileManager.default.contents(atPath: path) else { continue }
            if data.range(of: Data(text.utf8)) != nil { holders.append(name) }
        }
        return holders.sorted()
    }

    var requestText: String { requests.list.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined(separator: "\n") }
}

/// A 1x1 PNG.
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
