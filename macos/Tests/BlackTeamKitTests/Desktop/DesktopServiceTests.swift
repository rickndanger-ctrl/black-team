import XCTest
#if canImport(Glibc)
import Glibc
#endif
@testable import BlackTeamKit

// The Linux desktop service: the window's session over HTTP, the control channel, and the busy and validation rules of main.cjs.

/// A service on a free port with a throwaway web folder and the Node-written data folder.
final class ServiceRig {
    let fx: NodeFixture
    let backend: Backend
    let service: DesktopService
    let runtime = StubRuntime()
    let web: String
    var port: Int { service.port }

    init(_ test: XCTestCase, discover: @escaping @Sendable () -> DiscoveryResult = { noTools }) async throws {
        fx = try NodeFixture(test)
        web = fx.root + "/web"
        try FileManager.default.createDirectory(atPath: web, withIntermediateDirectories: true)
        try "<html>black team</html>".write(toFile: web + "/index.html", atomically: true, encoding: .utf8)
        // Nothing real is touched: no network (the model finder asks local ports), and "home" is the temporary folder.
        backend = try Backend(dataFolder: fx.data, version: "1.2.3", runtime: runtime, fetch: { _ in throw URLError(.cannotConnectToHost) },
                              discover: discover, home: fx.root, keeperInterval: 3600)
        service = try DesktopService(options: DesktopServiceOptions(web: web, version: "1.2.3", port: 0, dataFolder: fx.data, tailscale: { _, _, _ in throw PhoneCommandError(notFound: true) }), backend: backend)
        service.control = DesktopControl(backend, home: fx.root, environment: ["PATH": ""])
        let ready = try JSONValue.parse(try await service.start())
        XCTAssertEqual(ready["ready"]?.bool, true)
        XCTAssertEqual(ready["origin"]?.string, "http://127.0.0.1:\(service.port)")
        XCTAssertEqual(ready["dataFolder"]?.string, fx.data)
        XCTAssertEqual(ready["bootstrapURL"]?.string, service.session.bootstrapURL(port: service.port))
        test.addTeardownBlock { [service] in await service.shutdown() }
    }

    /// One HTTP exchange, the way the window (or anything else on this computer) would make it.
    func http(_ method: String, _ path: String, body: String = "", cookie: String? = nil, origin: String? = nil, host: String? = nil) -> (status: Int, headers: String, body: String) {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"]
        if let cookie { lines.append("Cookie: \(cookie)") }
        if let origin { lines.append("Origin: \(origin)") }
        if method == "POST" { lines += ["Content-Type: application/json", "Content-Length: \(body.utf8.count)"] }
        let reply = rawExchange(port: port, [Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)]).reply
        let parts = reply.components(separatedBy: "\r\n\r\n")
        let status = Int(reply.split(separator: " ", maxSplits: 2).dropFirst().first ?? "0") ?? 0
        return (status, parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    var session: String { "black_team_session=\(service.session.sessionKey)" }
    var origin: String { "http://127.0.0.1:\(port)" }

    func ask(_ action: String, _ data: String = "{}", id: Int = 1) async -> JSONValue {
        let reply = await service.respond(toLine: "{\"id\":\(id),\"action\":\"\(action)\",\"data\":\(data)}")
        return (try? JSONValue.parse(reply ?? "null")) ?? .null
    }

    func fails(_ action: String, _ data: String = "{}", with message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let reply = await ask(action, data)
        XCTAssertEqual(reply["ok"]?.bool, false, "\(action) \(data)", file: file, line: line)
        XCTAssertEqual(reply["error"]?.string, message, "\(action) \(data)", file: file, line: line)
    }
}

final class DesktopSessionTests: XCTestCase {
    func testTheWindowOpensBootstrapOnceAndKeepsACookie() async throws {
        let rig = try await ServiceRig(self)
        // Without the session the local address grants nothing.
        let stranger = rig.http("GET", "/")
        XCTAssertEqual(stranger.status, 401)
        XCTAssertTrue(stranger.body.contains("Open Black Team on this computer"))
        XCTAssertEqual(rig.http("GET", "/api/status").status, 401)
        XCTAssertEqual(rig.http("GET", "/bootstrap?key=wrong").status, 401)
        XCTAssertEqual(rig.http("GET", "/bootstrap").status, 401)
        XCTAssertEqual(rig.http("GET", "/", cookie: "black_team_session=wrong").status, 401)
        // The right key redirects home and sets the session cookie, with the flags lib/server.cjs gives it.
        let opened = rig.http("GET", "/bootstrap?key=\(rig.service.session.bootstrapKey)")
        XCTAssertEqual(opened.status, 303)
        XCTAssertTrue(opened.headers.contains("Location: /\r\n"))
        XCTAssertTrue(opened.headers.contains("Set-Cookie: black_team_session=\(rig.service.session.sessionKey); Path=/; HttpOnly; SameSite=Strict\r\n"))
        XCTAssertTrue(opened.headers.contains("Content-Security-Policy:"))
        // With it: the web app, and the desktop's status.
        let page = rig.http("GET", "/", cookie: rig.session)
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.body, "<html>black team</html>")
        let status = rig.http("GET", "/api/status", cookie: rig.session)
        XCTAssertEqual(status.status, 200)
        let json = try JSONValue.parse(status.body)
        XCTAssertEqual(json["access"]?.string, "desktop")
        XCTAssertEqual(json["config"]?["model"]?["id"]?.string, "ornith-1.5-ünï")
        XCTAssertEqual(json["threads"]?.array?.count, 3)
        // The same fields as the control channel's status.
        let control = await rig.ask("status")
        XCTAssertEqual(Set(control["result"]?.object?.keys.map { $0 } ?? []), Set(json.object?.keys.map { $0 } ?? []))
    }

    func testTheSameRulesAsTheNodeServer() async throws {
        let rig = try await ServiceRig(self)
        let remember = "{\"title\":\"Tea\",\"text\":\"green\"}"
        // A request from another address, a foreign origin, or without the origin on a POST is refused, even with the cookie.
        XCTAssertEqual(rig.http("GET", "/api/status", cookie: rig.session, host: "evil.test").status, 403)
        XCTAssertEqual(rig.http("GET", "/api/status", cookie: rig.session, host: "127.0.0.1:1").status, 403)
        XCTAssertEqual(rig.http("GET", "/api/status", cookie: rig.session, origin: "http://evil.test").status, 403)
        let noOrigin = rig.http("POST", "/api/memory/remember", body: remember, cookie: rig.session)
        XCTAssertEqual(noOrigin.status, 403)
        XCTAssertTrue(noOrigin.body.contains("A same-origin request is required."))
        let saved = rig.http("POST", "/api/memory/remember", body: remember, cookie: rig.session, origin: rig.origin)
        XCTAssertEqual(saved.status, 200, saved.body)
        XCTAssertEqual(try JSONValue.parse(saved.body)["id"]?.string, "Notes/Tea")
        // Routes the desktop shares with the phone.
        let thread = rig.http("GET", "/api/thread/\(rig.fx.id("chat"))", cookie: rig.session)
        XCTAssertEqual(thread.status, 200)
        XCTAssertEqual(try JSONValue.parse(thread.body)["messages"]?[1]?["content"]?.string, "Hi! ☕")
        XCTAssertEqual(rig.http("GET", "/api/request/\(rig.fx.text("requests", "chat"))", cookie: rig.session).status, 200)
        XCTAssertEqual(rig.http("GET", "/api/memory", cookie: rig.session).status, 200)
        let file = rig.http("GET", "/api/file/\(rig.fx.expected["artifact"]?.string ?? "")", cookie: rig.session)
        XCTAssertEqual(file.status, 200)
        XCTAssertEqual(file.body, "hello artifact")
        XCTAssertTrue(file.headers.contains("filename*=UTF-8''report%20%C3%BC.txt"))
        XCTAssertEqual(rig.http("GET", "/api/nothing", cookie: rig.session).status, 404)
        // A pairing request is for phones only.
        XCTAssertEqual(rig.http("POST", "/api/pair", body: "{}", cookie: rig.session, origin: rig.origin).status, 404)
        // Dictation: the desktop may ask; with no tool set up it is told so.
        let dictate = rig.http("POST", "/api/dictate", body: "{}", cookie: rig.session, origin: rig.origin)
        XCTAssertEqual(dictate.status, 404)
        XCTAssertTrue(dictate.body.contains("No system dictation tool is set up on this computer."))
        // Code needs no model server to be refused politely: a chat with setup incomplete is a 409 from the engine, not a crash.
        let chat = rig.http("POST", "/api/chat", body: "{\"message\":\"hi\",\"requestId\":\"nope\"}", cookie: rig.session, origin: rig.origin)
        XCTAssertEqual(chat.status, 400)
        XCTAssertTrue(chat.body.contains("A valid request ID is required."))
    }

    func testAPhoneCookieDoesNotOpenTheLocalAddress() async throws {
        let rig = try await ServiceRig(self)
        let phone = rig.fx.text("phone", "session")
        XCTAssertEqual(rig.http("GET", "/api/status", cookie: "black_team_phone=\(phone)").status, 401)
        // The phone's own address still needs the phone's checks: the computer name alone is not enough from this address.
        let remote = rig.http("GET", "/", host: "\(rig.fx.text("phone", "hostname")):8449")
        XCTAssertEqual(remote.status, 401)
    }

    func testShutdownStopsTheServerAndGivesTheLockBack() async throws {
        let rig = try await ServiceRig(self)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fx.data + "/engine.lock"))
        XCTAssertTrue(rawExchange(port: rig.port, [Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(rig.port)\r\n\r\n".utf8)]).connected)
        await rig.service.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.fx.data + "/engine.lock"))
        XCTAssertFalse(rawExchange(port: rig.port, [Data("GET / HTTP/1.1\r\n\r\n".utf8)]).connected)
        XCTAssertGreaterThan(rig.runtime.disposals, 0)
    }

    func testAPortInUseIsReportedInTheNodeAppsWords() async throws {
        let rig = try await ServiceRig(self)
        let fx2 = try NodeFixture(self)
        let second = try DesktopService(options: DesktopServiceOptions(web: rig.web, version: "1", port: rig.port, dataFolder: fx2.data),
                                        backend: try fx2.backend())
        do { _ = try await second.start(); XCTFail("started on a used port") }
        catch { XCTAssertEqual((error as? BlackTeamError)?.message, "Black Team\u{2019}s local port \(rig.port) is already in use. Close the other copy or free this port, then reopen Black Team.") }
        XCTAssertTrue(DesktopService.notReady(BlackTeamError("x")).contains("\"ready\":false"))
        await second.shutdown()
    }
}

final class DesktopControlTests: XCTestCase {
    func testLinesThatAreNotRequestsAreRefused() async throws {
        let rig = try await ServiceRig(self)
        for line in ["garbage", "[]", "{\"id\":1}", "{\"id\":1,\"action\":5}", "{\"id\":1,\"action\":\"status\",\"data\":[]}", "{\"id\":1,\"action\":\"status\",\"data\":null}", "{\"id\":1,\"action\":\"status\",\"data\":\"x\"}"] {
            let reply = try JSONValue.parse(await rig.service.respond(toLine: line) ?? "")
            XCTAssertEqual(reply["ok"]?.bool, false, line)
            XCTAssertEqual(reply["error"]?.string, "Invalid desktop request.", line)
        }
        let nobody = await rig.service.respond(toLine: "   ")
        XCTAssertNil(nobody)
        await rig.fails("shell-out", with: "Unsupported desktop action.")
        // `data` may be left out; the id is echoed as it came.
        let reply = try JSONValue.parse(await rig.service.respond(toLine: "{\"id\":\"abc\",\"action\":\"phone-command\"}") ?? "")
        XCTAssertEqual(reply["id"]?.string, "abc")
        XCTAssertEqual(reply["ok"]?.bool, true)
        XCTAssertEqual(reply["result"]?["command"]?.string, "tailscale serve --bg --https=8449 http://127.0.0.1:18199")
        // Every action of preload.cjs is known, and the ones for cloud models and subscription agents, which preload.cjs adds afterwards
        // (Desktop/DesktopCloud.swift answers them).
        let added = "cloud-discover cloud-save project-cloud agents-status agent-signin agent-update vision-install vision-cancel starter-list starter-install starter-cancel optimize-start optimize-cancel setup-plan setup-apply setup-dismiss setup-cancel models-recommend models-search models-repo model-get model-get-stop"
        let preload = "setup-help installed-discover hermes-inspect phone-setup phone-off integrations-save harness-connect harness-launch server-discover model-inspect status setup-save models-find models-add models-ignore model-switch model-forget runtime-start runtime-stop phone-save phone-detect phone-command phone-connect phone-disconnect open-data"
        XCTAssertEqual(DesktopControl.actions, Set((preload + " " + added).split(separator: " ").map(String.init)))
    }

    func testInputsAreCheckedAsMainCjsChecksThem() async throws {
        let rig = try await ServiceRig(self)
        await rig.fails("server-discover", "{\"endpoint\":\"http://127.0.0.1:1/v1\",\"extra\":1}", with: "Unsupported server discovery setting.")
        await rig.fails("server-discover", "{}", with: "Enter a local server URL such as http://127.0.0.1:11434/v1.")
        await rig.fails("server-discover", "{\"endpoint\":\"https://example.com/v1\"}", with: "Use a loopback HTTP address with a port and /v1 (localhost, 127.0.0.1, or [::1]).")
        await rig.fails("model-inspect", "{\"file\":\"/x.gguf\",\"more\":true}", with: "Unsupported setup setting.")
        await rig.fails("models-add", "{\"items\":[],\"x\":1}", with: "Unsupported setup setting.")
        await rig.fails("models-add", "{}", with: "Choose at least one model to add.")
        await rig.fails("models-ignore", "{}", with: "Choose a found model to pass over.")
        await rig.fails("model-switch", "{}", with: "Choose a model from your list.")
        await rig.fails("model-switch", "{\"key\":\"nope\"}", with: "That model is not in your list.")
        await rig.fails("model-forget", "{\"key\":5}", with: "Choose a model from your list.")
        await rig.fails("model-forget", "{\"key\":\"\(rig.fx.text("keys", "server"))\"}", with: "This model is in use. Switch to another model before removing it.")
        await rig.fails("setup-save", "{\"phone\":{}}", with: "Unsupported setup setting.")
        await rig.fails("setup-save", "{\"model\":{\"context\":3}}", with: "Context size must be a whole number from 512 to 131072.")
        await rig.fails("integrations-save", "{\"bogus\":1}", with: "Unsupported integration setting.")
        await rig.fails("integrations-save", "{\"engine\":\"x\"}", with: "Choose Black Team or Hermes for Code conversations.")
        await rig.fails("harness-launch", "{\"id\":\"missing\"}", with: "Configure this harness in Settings first.")
        await rig.fails("harness-connect", "{\"id\":\"claude\"}", with: "That app was not found on this computer.")
        await rig.fails("phone-save", "{}", with: "Choose whether to enable Companion.")
        await rig.fails("phone-save", "{\"enabled\":true,\"hostname\":\"\",\"owner\":\"\"}", with: "Detect this computer and its Tailscale owner first.")
        await rig.fails("phone-save", "{\"enabled\":false,\"hostname\":\"example.com\"}", with: "Use this computer\u{2019}s private Tailscale hostname.")
        await rig.fails("phone-connect", "{}", with: "Tailscale must be online with the saved computer and owner. Detect and save again.")
        await rig.fails("setup-help", "{\"topic\":\"evil\"}", with: "Unsupported setup help.")
        let help = await rig.ask("setup-help", "{\"topic\":\"ollama\"}")
        XCTAssertEqual(help["result"]?["url"]?.string, "https://ollama.com/download/linux")
        let folder = await rig.ask("open-data")
        XCTAssertEqual(folder["result"]?["path"]?.string, rig.fx.data)
        // A good change goes through and shows in the next status.
        let renamed = await rig.ask("setup-save", "{\"model\":{\"name\":\"Renamed\"}}")
        XCTAssertEqual(renamed["ok"]?.bool, true, "\(renamed)")
        XCTAssertEqual(renamed["result"]?["saved"]?.bool, true)
        let status = await rig.ask("status")
        XCTAssertEqual(status["result"]?["config"]?["model"]?["name"]?.string, "Renamed")
        let forgotten = await rig.ask("model-forget", "{\"key\":\"\(rig.fx.text("keys", "gguf"))\"}")
        XCTAssertEqual(forgotten["result"]?["removed"]?.bool, true)
        let ignored = await rig.ask("models-ignore", "{\"key\":\"0123456789abcdef\"}")
        XCTAssertEqual(ignored["result"]?["ignored"]?.bool, true)
        let stopped = await rig.ask("runtime-stop")
        XCTAssertEqual(stopped["result"]?["state"]?.string, "off")
    }

    func testOneSetupActionAtATime() async throws {
        let rig = try await ServiceRig(self)
        let gate = BackendGate()
        rig.runtime.stopAction = { await gate.wait() }
        let slow = Task { await rig.ask("runtime-stop", id: 1) }
        // Wait until the stop is under way.
        for _ in 0..<200 where rig.runtime.stops.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.runtime.stops.count, 1)
        await rig.fails("setup-save", "{\"model\":{\"name\":\"Late\"}}", with: "Another setup action is still running.")
        await rig.fails("integrations-save", "{\"dictation\":\"\"}", with: "Another setup action is still running.")
        await rig.fails("phone-off", with: "Another setup action is still running.")
        await rig.fails("phone-save", "{\"enabled\":false}", with: "Another setup action is still running.")
        // Reading is never held up.
        let status = await rig.ask("status")
        XCTAssertEqual(status["ok"]?.bool, true)
        await gate.open()
        let done = await slow.value
        XCTAssertEqual(done["ok"]?.bool, true)
        let later = await rig.ask("setup-save", "{\"model\":{\"name\":\"Later\"}}")
        XCTAssertEqual(later["ok"]?.bool, true)
    }

    func testHermesIsFoundAndItsSettingsKept() async throws {
        let home = NSTemporaryDirectory() + "bt-home-\(UUID().uuidString.lowercased())"
        let source = home + "/.hermes/hermes-agent"
        try FileManager.default.createDirectory(atPath: source + "/venv/bin", withIntermediateDirectories: true)
        for name in ["hermes_bootstrap.py", "cli.py"] { try "".write(toFile: source + "/" + name, atomically: true, encoding: .utf8) }
        try "#!/bin/sh\n".write(toFile: source + "/venv/bin/python", atomically: true, encoding: .utf8)
        chmod(source + "/venv/bin/python", 0o755)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        let found = discoverLinux(home: home, env: ["PATH": ""])
        XCTAssertEqual(found.hermes, [HermesInstall(source: source, python: source + "/venv/bin/python")])
        XCTAssertEqual(found.json["hermes"]?[0]?["python"]?.string, source + "/venv/bin/python")
        XCTAssertEqual(inspectHermes(source: source, python: "/bin/sh"), HermesInstall(source: source, python: "/bin/sh"))
        XCTAssertNil(inspectHermes(source: "relative"))
        XCTAssertNil(inspectHermes(source: home))
        // The settings the Node app saved are accepted, kept, and shown; changing something else does not lose them.
        let rig = try await ServiceRig(self)
        let settings = "{\"hermes\":{\"enabled\":true,\"python\":\"/bin/sh\",\"source\":\"\(source)\",\"browserExecutable\":\"\",\"desktopDriver\":\"\",\"coding\":true,\"browser\":true,\"desktop\":false},\"engine\":\"hermes\"}"
        let saved = await rig.ask("integrations-save", settings)
        XCTAssertEqual(saved["result"]?["saved"]?.bool, true, "\(saved)")
        let again = await rig.ask("integrations-save", "{\"dictation\":\"\"}")
        XCTAssertEqual(again["ok"]?.bool, true)
        let status = await rig.ask("status")
        XCTAssertEqual(status["result"]?["integrations"]?["hermes"]?["enabled"]?.bool, true)
        XCTAssertEqual(status["result"]?["integrations"]?["hermes"]?["browser"]?.bool, true)
        XCTAssertEqual(status["result"]?["integrations"]?["engine"]?.string, "hermes")
        let onDisk = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: rig.fx.data + "/integrations.json")))
        XCTAssertEqual(onDisk["hermes"]?["source"]?.string, source)
        // Wrong places are refused with the Node app's words.
        await rig.fails("integrations-save", "{\"hermes\":{\"enabled\":true,\"python\":\"/bin/sh\",\"source\":\"/tmp\",\"coding\":true,\"browser\":false,\"desktop\":false}}",
                        with: "Hermes was not found in this folder. Choose your installed Hermes Agent folder or use Find again.")
        let inspected = await rig.ask("hermes-inspect", "{\"source\":\"\(source)\"}")
        XCTAssertEqual(inspected["result"]?["source"]?.string, source)
        let none = await rig.ask("hermes-inspect", "{\"source\":\"/tmp\"}")
        XCTAssertEqual(none["ok"]?.bool, true)
        XCTAssertEqual(none["result"], JSONValue.null)
        // The Mac and the terminal program still refuse Hermes.
        let mac = try NodeFixture(self)
        let plain = try mac.backend()
        do { _ = try plain.integrations.save(try JSONValue.parse(settings)); XCTFail("Hermes enabled without the desktop service") }
        catch { XCTAssertEqual((error as? BlackTeamError)?.message, "Hermes is not available on macOS yet.") }
    }

    func testFoundModelsAndToolsHaveTheNodeShape() async throws {
        let rig = try await ServiceRig(self)
        let found = await rig.ask("models-find")
        XCTAssertEqual(found["ok"]?.bool, true)
        for key in ["servers", "files", "runtime", "looked"] { XCTAssertNotNil(found["result"]?[key], key) }
        let tools = await rig.ask("installed-discover")
        for key in ["hermes", "terminals", "apps", "presets", "runtime", "dictation", "graph"] { XCTAssertNotNil(tools["result"]?[key], key) }
        XCTAssertEqual(tools["result"]?["presets"]?.array?.map { $0["id"]?.string ?? "" }, ["claude", "codex", "pi", "opencode", "dsh", "aider"])
        let phone = await rig.ask("phone-detect")
        XCTAssertNotNil(phone["result"]?["installed"])
    }

    func testTheEnginesOwnMemoryFilesAreReadable() throws {
        let fx = try NodeFixture(self)
        let engine = try Engine(stateDir: fx.data, vault: try Memory(vault: fx.data + "/vault"), fetch: { _ in throw URLError(.cannotConnectToHost) }, graph: { "" })
        let memory = engine.loadMemory(fx.id("agent"), "server:ornith-1.5-ünï")
        XCTAssertEqual(memory.readSpeed, 41.5)
        XCTAssertEqual(memory.writeSpeed, 9.2)
        XCTAssertEqual(memory.log, ["read a.txt"])
        XCTAssertEqual(memory.core, "Prefers short answers.")
        // A conversation with no file yet starts from the model's measured speed.
        XCTAssertEqual(engine.loadMemory(fx.id("chat"), "server:ornith-1.5-ünï").readSpeed, 41.5)
    }
}
