import XCTest
#if canImport(Glibc)
import Glibc
#endif
@testable import BlackTeamKit

/// How the window and the command find and use a running background service: the connection file, its checks, and the routes behind the
/// same session checks as every other route.
final class ServiceAttachTests: XCTestCase {
    // MARK: A service on a free port with a scratch data folder

    final class Rig {
        let fx: NodeFixture
        let backend: Backend
        let service: BackgroundService
        let connection: ServiceConnection
        var port: Int { connection.port }

        init(_ test: XCTestCase, version: String = "9.9.9") async throws {
            fx = try NodeFixture(test)
            let web = fx.root + "/web"
            try FileManager.default.createDirectory(atPath: web, withIntermediateDirectories: true)
            try "<html>black team</html>".write(toFile: web + "/index.html", atomically: true, encoding: .utf8)
            backend = try Backend(dataFolder: fx.data, version: version, runtime: StubRuntime(), fetch: { _ in throw URLError(.cannotConnectToHost) },
                                  discover: { noTools }, home: fx.root, keeperInterval: 3600)
            service = try BackgroundService(options: DesktopServiceOptions(web: web, version: version, port: 0, dataFolder: fx.data,
                                                                           tailscale: { _, _, _ in throw PhoneCommandError(notFound: true) }), backend: backend)
            service.desktop.control = DesktopControl(backend, home: fx.root, environment: ["PATH": ""])
            connection = try await service.start(startLoops: false)
            test.addTeardownBlock { [service] in await service.shutdown() }
        }

        func http(_ method: String, _ path: String, body: String = "", cookie: String? = nil, origin: String? = nil, host: String? = nil, extra: [String] = []) -> (status: Int, body: String) {
            var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"] + extra
            if let cookie { lines.append("Cookie: \(cookie)") }
            if let origin { lines.append("Origin: \(origin)") }
            if method == "POST" { lines += ["Content-Type: application/json", "Content-Length: \(body.utf8.count)"] }
            let reply = rawExchange(port: port, [Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)]).reply
            let parts = reply.components(separatedBy: "\r\n\r\n")
            let status = Int(reply.split(separator: " ", maxSplits: 2).dropFirst().first ?? "0") ?? 0
            return (status, parts.dropFirst().joined(separator: "\r\n\r\n"))
        }

        var cookie: String { "black_team_session=\(connection.secret)" }
        var origin: String { connection.origin }
        func get(_ path: String, extra: [String] = []) -> (status: Int, body: String) { http("GET", path, cookie: cookie, extra: extra) }
        func post(_ path: String, _ body: String) -> (status: Int, body: String) { http("POST", path, body: body, cookie: cookie, origin: origin) }
        /// The window\u{2019}s main process: the cookie, and the control key from the private file.
        func control(_ body: String) -> (status: Int, body: String) { http("POST", "/api/service/control", body: body, cookie: cookie, origin: origin, extra: ["X-Black-Team-Control: \(connection.control)"]) }
        func json(_ reply: (status: Int, body: String)) throws -> JSONValue { try JSONValue.parse(reply.body) }
    }

    // MARK: The connection file

    func testTheServiceWritesAPrivateConnectionFileOnlyOnceItListensAndRemovesItWhenItStops() async throws {
        let rig = try await Rig(self)
        let file = rig.fx.data + "/service.json"
        var info = stat()
        XCTAssertEqual(stat(file, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let saved = try JSONDecoder().decode(ServiceConnection.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertEqual(saved, rig.connection)
        XCTAssertEqual(saved.pid, getpid())
        XCTAssertEqual(saved.version, "9.9.9")
        XCTAssertEqual(saved.protocol, ServiceConnection.currentProtocol)
        XCTAssertEqual(saved.dataFolder, rig.fx.data)
        XCTAssertEqual(saved.secret, rig.service.desktop.session.sessionKey)
        XCTAssertEqual(saved.bootstrap, rig.service.desktop.session.bootstrapKey)
        XCTAssertEqual(saved.control, rig.service.desktop.session.controlKey)
        XCTAssertEqual(Set([saved.secret, saved.bootstrap, saved.control]).count, 3, "three different keys")
        XCTAssertEqual(saved.bootstrapURL, rig.service.desktop.session.bootstrapURL(port: rig.port))
        let text = try String(contentsOfFile: file, encoding: .utf8)
        for key in ["\"protocol\"", "\"version\"", "\"pid\"", "\"port\"", "\"secret\"", "\"bootstrap\"", "\"control\"", "\"started\"", "\"dataFolder\""] { XCTAssertTrue(text.contains(key), key) }
        await rig.service.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testAnotherProcessesConnectionFileIsNotRemovedByThisOne() async throws {
        let rig = try await Rig(self)
        var other = rig.connection
        other.pid = 1
        try other.write()
        ServiceConnection.remove(in: rig.fx.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.fx.data + "/service.json"))
        try rig.connection.write()
    }

    // MARK: Attach or spawn

    func testAWindowFindsTheRunningServiceAndTheCommandUsesItsSecret() async throws {
        let rig = try await Rig(self)
        let found = await ServiceClient.find(dataFolder: rig.fx.data, version: "9.9.9")
        XCTAssertEqual(found, .running(rig.connection))
        // The command talks to it the way the window does.
        let client = ServiceClient(rig.connection)
        let state = try await client.get("/api/service")
        XCTAssertEqual(state["mode"]?.string, "background")
        XCTAssertEqual(state["running"]?.bool, true)
        XCTAssertEqual(state["version"]?.string, "9.9.9")
        XCTAssertEqual(state["settings"]?["idleMinutes"]?.int, 10)
        XCTAssertEqual(state["settings"]?["approvalHours"]?.int, 24)
    }

    func testNoFileMeansSpawnAndALeftoverFileFromAGoneProcessIsIgnored() async throws {
        let fx = try NodeFixture(self)
        let none = await ServiceClient.find(dataFolder: fx.data, version: "1")
        XCTAssertEqual(none, .none)
        // A crashed service left its file behind: its process is gone.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", "exit 0"]
        try child.run(); child.waitUntilExit()
        let ghost = ServiceConnection(version: "1", pid: child.processIdentifier, port: 1, secret: "s", bootstrap: "b", started: 0, dataFolder: fx.data)
        try ghost.write()
        let stale = await ServiceClient.find(dataFolder: fx.data, version: "1")
        guard case .stale = stale else { return XCTFail("\(stale)") }
        // The file is damaged, or for another folder: also stale.
        try "{not json".write(toFile: fx.data + "/service.json", atomically: true, encoding: .utf8)
        chmod(fx.data + "/service.json", 0o600)
        let damaged = await ServiceClient.find(dataFolder: fx.data, version: "1")
        guard case .stale = damaged else { return XCTFail("\(damaged)") }
        var elsewhere = ghost
        elsewhere.pid = getpid(); elsewhere.dataFolder = "/somewhere/else"
        try writeJSON(fx.data + "/service.json", elsewhere)
        let wrongFolder = await ServiceLocator.find(dataFolder: fx.data, ping: { _ in .answered(pid: getpid(), version: "1", protocolVersion: 1) })
        guard case .stale = wrongFolder else { return XCTFail("\(wrongFolder)") }
    }

    func testAProcessThatIsAliveButNotTheServiceIsNotTrusted() async throws {
        let fx = try NodeFixture(self)
        // The file names a live process (this one), but nothing answers on the port, or something else does.
        try ServiceConnection(version: "1", pid: getpid(), port: 1, secret: "s", bootstrap: "b", started: 0, dataFolder: fx.data).write()
        let silent = await ServiceClient.find(dataFolder: fx.data, version: "1")
        guard case .stale = silent else { return XCTFail("\(silent)") }
        let stranger = await ServiceLocator.find(dataFolder: fx.data, ping: { _ in .answered(pid: getpid() + 1, version: "1", protocolVersion: 1) })
        guard case .stale = stranger else { return XCTFail("\(stranger)") }
    }

    func testAWrongSecretIsRefusedAndNeverReachesAnything() async throws {
        let rig = try await Rig(self)
        var wrong = rig.connection
        wrong.secret = "not-the-secret"
        let found = await ServiceClient.find(dataFolder: rig.fx.data, version: "9.9.9", fetch: LocalHTTP.fetch)
        XCTAssertEqual(found, .running(rig.connection))
        // The same lookup with another secret in the file.
        try wrong.write()
        let refused = await ServiceClient.find(dataFolder: rig.fx.data, version: "9.9.9")
        guard case .refused = refused else { return XCTFail("\(refused)") }
        try rig.connection.write()
        // And over the wire: no cookie, a wrong one, and the bootstrap key used as a session are all turned away.
        for cookie in [nil, "black_team_session=wrong", "black_team_session=\(rig.connection.bootstrap)"] {
            XCTAssertEqual(rig.http("GET", "/api/service/ping", cookie: cookie).status, 401, cookie ?? "no cookie")
            XCTAssertEqual(rig.http("POST", "/api/service/control", body: "{\"action\":\"status\"}", cookie: cookie, origin: rig.origin).status, 401, cookie ?? "no cookie")
        }
        XCTAssertEqual(rig.get("/api/service/ping").status, 200)
    }

    func testAServiceOfAnotherVersionOrProtocolSaysToRestartIt() async throws {
        let rig = try await Rig(self, version: "1.0.0")
        let newer = await ServiceClient.find(dataFolder: rig.fx.data, version: "1.1.0")
        guard case .mismatch(let connection, let message) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(connection, rig.connection)
        XCTAssertEqual(message, "Black Team\u{2019}s background service is version 1.0.0, but this is version 1.1.0. Restart the background service (black-team service restart), then try again.")
        let sameVersion = await ServiceClient.find(dataFolder: rig.fx.data, version: "1.0.0")
        XCTAssertEqual(sameVersion, .running(rig.connection))
        // An old service that speaks another protocol, whatever its version says.
        let oldProtocol = await ServiceLocator.find(dataFolder: rig.fx.data, version: "1.0.0", ping: { _ in .answered(pid: getpid(), version: "1.0.0", protocolVersion: 0) })
        guard case .mismatch = oldProtocol else { return XCTFail("\(oldProtocol)") }
    }

    func testAConnectionFileOpenToOtherUsersIsNotTrusted() async throws {
        let rig = try await Rig(self)
        chmod(rig.fx.data + "/service.json", 0o644)
        let found = await ServiceClient.find(dataFolder: rig.fx.data, version: "9.9.9")
        guard case .refused(let why) = found else { return XCTFail("\(found)") }
        XCTAssertTrue(why.contains("open to other users"))
        chmod(rig.fx.data + "/service.json", 0o600)
        // A link is not followed.
        try FileManager.default.moveItem(atPath: rig.fx.data + "/service.json", toPath: rig.fx.data + "/real.json")
        try FileManager.default.createSymbolicLink(atPath: rig.fx.data + "/service.json", withDestinationPath: rig.fx.data + "/real.json")
        let linked = await ServiceClient.find(dataFolder: rig.fx.data, version: "9.9.9")
        guard case .stale = linked else { return XCTFail("\(linked)") }
    }

    func testOnlyOneEngineOwnsADataFolderSoAServiceNextToAnotherCopyRefusesToStart() async throws {
        let fx = try NodeFixture(self)
        // Another Black Team (process 1 stands in for a live one) holds the folder's engine lock.
        let holder = EngineLock.Holder(pid: 1, program: "the Black Team app", started: 0)
        try writeJSON(fx.data + "/engine.lock", holder)
        let backend = try Backend(dataFolder: fx.data, version: "9.9.9", runtime: StubRuntime(), fetch: { _ in throw URLError(.cannotConnectToHost) },
                                  discover: { noTools }, home: fx.root, keeperInterval: 3600)
        let service = try BackgroundService(options: DesktopServiceOptions(web: fx.root + "/web", version: "9.9.9", port: 0, dataFolder: fx.data), backend: backend)
        do { _ = try await service.start(startLoops: false); XCTFail("should have refused") }
        catch { XCTAssertEqual((error as? BlackTeamError)?.message, "Black Team is already open in the Black Team app, and only one can run your model. Close it; the background service will start after that.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.data + "/service.json"), "nothing was announced")
        await backend.shutdown()
    }

    // MARK: What the window gets when it is attached

    func testTheControlRouteGivesTheWindowEverythingTheControlChannelGives() async throws {
        let rig = try await Rig(self)
        let status = try rig.json(rig.control("{\"action\":\"status\",\"data\":{}}"))
        XCTAssertEqual(status["ok"]?.bool, true)
        XCTAssertEqual(status["result"]?["access"]?.string, "desktop")
        XCTAssertEqual(status["result"]?["config"]?["model"]?["id"]?.string, "ornith-1.5-ünï")
        XCTAssertEqual(status["result"]?["service"]?["mode"]?.string, "background")
        XCTAssertEqual(status["result"]?["service"]?["inbox"]?.int, 0)
        // The same answer the control channel itself gives.
        let channel = await rig.service.desktop.respond(toLine: "{\"id\":1,\"action\":\"status\",\"data\":{}}")
        let viaChannel = try JSONValue.parse(channel ?? "null")
        XCTAssertEqual(status["result"]?["config"], viaChannel["result"]?["config"])
        // An action the window may not ask for, and a bad shape, are refused with the usual words.
        let unknown = rig.control("{\"action\":\"format-disk\"}")
        XCTAssertEqual(unknown.status, 400)
        XCTAssertEqual(try rig.json(unknown)["error"]?.string, "Unsupported desktop action.")
        XCTAssertEqual(rig.control("{\"action\":\"status\",\"data\":[1]}").status, 400)
        // The page has the session cookie but not the control key, so it cannot reach these actions that are the main process\u{2019}s alone.
        for extra in [[], ["X-Black-Team-Control: wrong"], ["X-Black-Team-Control: \(rig.connection.secret)"], ["X-Black-Team-Control: \(rig.connection.bootstrap)"]] {
            let page = rig.http("POST", "/api/service/control", body: "{\"action\":\"status\"}", cookie: rig.cookie, origin: rig.origin, extra: extra)
            XCTAssertEqual(page.status, 403, "\(extra)")
            XCTAssertEqual(try rig.json(page)["error"]?.string, "Desktop action is unavailable.")
        }
        // The web app is served to the window from the same address, with the same cookie.
        XCTAssertEqual(rig.get("/").body, "<html>black team</html>")
        let bootstrap = rig.http("GET", "/bootstrap?key=\(rig.connection.bootstrap)")
        XCTAssertEqual(bootstrap.status, 303)
    }

    func testTheHostAndOriginChecksApplyToTheNewRoutes() async throws {
        let rig = try await Rig(self)
        // A change needs the same origin; a page on another origin, or none, is refused.
        XCTAssertEqual(rig.http("POST", "/api/service/control", body: "{\"action\":\"status\"}", cookie: rig.cookie, extra: ["X-Black-Team-Control: \(rig.connection.control)"]).status, 403)
        XCTAssertEqual(rig.http("POST", "/api/service/control", body: "{\"action\":\"status\"}", cookie: rig.cookie, origin: "http://evil.example", extra: ["X-Black-Team-Control: \(rig.connection.control)"]).status, 403)
        XCTAssertEqual(rig.http("POST", "/api/schedules/save", body: "{}", cookie: rig.cookie, origin: "http://127.0.0.1:1").status, 403)
        // A wrong Host (a rebinding page) is refused whatever the cookie.
        XCTAssertEqual(rig.http("GET", "/api/schedules", cookie: rig.cookie, host: "evil.example").status, 403)
        XCTAssertEqual(rig.http("GET", "/api/inbox", cookie: rig.cookie, host: "127.0.0.1:1").status, 403)
        XCTAssertEqual(rig.http("GET", "/api/service/ping", cookie: rig.cookie, host: "localhost:\(rig.port)").status, 403)
    }

    // MARK: Schedules and the inbox over HTTP, as the window and the command use them

    func testSchedulesCanBeAddedListedPausedRunAndRemovedThroughTheService() async throws {
        let rig = try await Rig(self)
        let project = try rig.backend.createProject(name: "Allotment")
        let saved = try rig.json(rig.post("/api/schedules/save", "{\"name\":\"Morning\",\"message\":\"Say hello\",\"kind\":\"chat\",\"whenText\":\"weekdays at 9:30\",\"project\":\"\(project.id)\",\"permission\":\"read-only\"}"))
        let id = try XCTUnwrap(saved["id"]?.string)
        XCTAssertEqual(saved["whenDescription"]?.string, "Weekdays at 9:30 am")
        XCTAssertEqual(saved["permission"]?.string, "read-only")
        XCTAssertEqual(saved["projectName"]?.string, "Allotment")
        XCTAssertEqual(saved["state"]?.string, "scheduled")
        XCTAssertNotNil(saved["nextRun"]?.double)
        let list = try rig.json(rig.get("/api/schedules"))
        XCTAssertEqual(list["schedules"]?.array?.count, 1)
        XCTAssertEqual(list["running"]?.bool, true)
        XCTAssertEqual(list["limits"]?["schedules"]?.int, 20)
        XCTAssertTrue(list["projects"]?.array?.contains { $0["name"]?.string == "Allotment" } == true)
        // Bad input is answered in plain words.
        let bad = rig.post("/api/schedules/save", "{\"name\":\"x\",\"message\":\"y\",\"whenText\":\"*/5 * * * *\"}")
        XCTAssertEqual(bad.status, 400)
        XCTAssertTrue(try rig.json(bad)["error"]?.string?.contains("Say when like this") == true)
        XCTAssertEqual(rig.post("/api/schedules/save", "{\"name\":\"x\",\"message\":\"y\",\"whenText\":\"daily at 9\",\"permission\":\"root\"}").status, 400)
        XCTAssertEqual(rig.post("/api/schedules/save", "{\"name\":\"x\",\"message\":\"y\",\"whenText\":\"daily at 9\",\"project\":\"\(newID())\"}").status, 400)
        // The preview used while typing.
        let preview = try rig.json(rig.post("/api/schedules/parse", "{\"text\":\"every 2 hours\"}"))
        XCTAssertEqual(preview["description"]?.string, "Every 2 hours")
        // Pause, resume, run now, remove.
        let paused = try rig.json(rig.post("/api/schedules/pause", "{\"id\":\"\(id)\",\"paused\":true}"))
        XCTAssertEqual(paused["schedules"]?[0]?["enabled"]?.bool, false)
        XCTAssertEqual(paused["schedules"]?[0]?["state"]?.string, "paused")
        _ = try rig.json(rig.post("/api/schedules/pause", "{\"id\":\"\(id)\",\"paused\":false}"))
        XCTAssertEqual(rig.post("/api/schedules/run", "{\"id\":\"\(id)\"}").status, 200)
        XCTAssertEqual(rig.post("/api/schedules/run", "{\"id\":\"\(id)\"}").status, 400, "already waiting for its turn")
        _ = try rig.json(rig.post("/api/schedules/remove", "{\"id\":\"\(id)\"}"))
        XCTAssertEqual(try rig.json(rig.get("/api/schedules"))["schedules"]?.array?.count, 0)
        // And the same file is what the command reads without the service.
        XCTAssertEqual(ScheduleStore(dataFolder: rig.fx.data).list().count, 0)
    }

    func testTheInboxIsReadAndAnsweredThroughTheService() async throws {
        let rig = try await Rig(self)
        try rig.service.hooks.inbox.add(InboxItem(id: "ask-9", scheduleId: "s", scheduleName: "Nightly", threadId: nil, project: nil, command: "git push",
                                                  question: "Run this command on your computer?", digest: "d", created: 1, expires: 2, state: "waiting", answered: nil))
        let inbox = try rig.json(rig.get("/api/inbox"))
        XCTAssertEqual(inbox["waiting"]?.int, 1)
        XCTAssertEqual(inbox["items"]?[0]?["command"]?.string, "git push")
        XCTAssertEqual(rig.post("/api/inbox/answer", "{\"id\":\"ask-9\",\"choice\":\"maybe\"}").status, 400)
        // The run it belonged to is gone: the answer says so and the question is closed.
        let late = rig.post("/api/inbox/answer", "{\"id\":\"ask-9\",\"choice\":\"approve\"}")
        XCTAssertEqual(late.status, 400)
        XCTAssertEqual(try rig.json(late)["error"]?.string, "That question is not waiting any more.")
        XCTAssertEqual(rig.service.hooks.inbox.get("ask-9")?.state, "ended")
        // The command's client reads it too.
        let viaClient = try await ServiceClient(rig.connection).get("/api/inbox")
        XCTAssertEqual(viaClient["waiting"]?.int, 0)
    }

    func testAPhoneMayReadSchedulesAndTheInboxButNothingElseOfTheService() async throws {
        let rig = try await Rig(self)
        // A paired phone is a different kind of access; only its own routes are open. Here: the desktop cookie is not a phone's, and a
        // request without any session reaches none of them.
        for path in ["/api/schedules", "/api/inbox", "/api/service", "/api/service/ping"] { XCTAssertEqual(rig.http("GET", path).status, 401, path) }
        // The routes' own rule: a phone is refused the desktop-only ones with the usual words.
        let routes = ServiceRoutes(rig.service.hooks, rig.backend)
        let head = HTTPHead(method: "POST", target: "/api/service/install", path: "/api/service/install", query: [], headers: ["content-type": "application/json"], contentLength: 2)
        do { _ = try await routes.handle(head, body: Data("{}".utf8), who: .phone); XCTFail("a phone must not install the service") }
        catch let failure as HTTPFailure { XCTAssertEqual(failure.status, 403); XCTAssertEqual(failure.message, DesktopRefusal.desktopOnly) }
        let schedulesHead = HTTPHead(method: "GET", target: "/api/schedules", path: "/api/schedules", query: [], headers: [:], contentLength: 0)
        let allowed = try await routes.handle(schedulesHead, body: Data(), who: .phone)
        XCTAssertEqual(allowed.status, 200)
        let saveHead = HTTPHead(method: "POST", target: "/api/schedules/save", path: "/api/schedules/save", query: [], headers: ["content-type": "application/json"], contentLength: 2)
        do { _ = try await routes.handle(saveHead, body: Data("{}".utf8), who: .phone); XCTFail("a phone must not edit schedules") }
        catch let failure as HTTPFailure { XCTAssertEqual(failure.status, 403) }
    }

    func testTheSettingsCanBeChangedAndAreChecked() async throws {
        let rig = try await Rig(self)
        let changed = try rig.json(rig.post("/api/service/settings", "{\"idleMinutes\":30,\"approvalHours\":48,\"maxRunsPerDay\":10}"))
        XCTAssertEqual(changed["settings"], ["idleMinutes": 30, "approvalHours": 48, "maxRunsPerDay": 10])
        XCTAssertEqual(rig.post("/api/service/settings", "{\"idleMinutes\":-5}").status, 400)
        XCTAssertEqual(ServiceSettingsStore(dataFolder: rig.fx.data).read().approvalHours, 48)
        var info = stat()
        XCTAssertEqual(stat(rig.fx.data + "/service-settings.json", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testAnOpenWindowCountsButTheCommandDoesNot() async throws {
        let rig = try await Rig(self)
        let idle = try XCTUnwrap(rig.service.hooks.idle)
        XCTAssertNil(idle.windowSeenAt)
        XCTAssertEqual(rig.get("/api/service", extra: ["X-Black-Team-Client: cli"]).status, 200)
        _ = try await ServiceClient(rig.connection).get("/api/service")
        XCTAssertNil(idle.windowSeenAt, "the command is not a window")
        XCTAssertEqual(rig.get("/api/service").status, 200)
        XCTAssertNotNil(idle.windowSeenAt, "a request from the window counts")
    }
}
