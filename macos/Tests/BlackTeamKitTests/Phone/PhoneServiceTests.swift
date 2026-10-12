import XCTest
@testable import BlackTeamKit

// Backend.phoneEnable / phoneDisable / link / reset, with a fake Tailscale and a real server on a free port.

final class PhoneServiceTests: XCTestCase {
    private struct Setup { var fixture: BackendFixture; var backend: Backend; var tailscale: PhoneFixture; var rig: PhoneRig }

    private func setup(route: JSONValue = [:], tailscale failure: PhoneCommandError? = nil, port: Int = 0) throws -> Setup {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let tailscale = PhoneFixture(route: route, phone: PhoneConfig(), failure: failure)
        let rig = try PhoneRig(self)
        var options = PhoneOptions()
        options.runner = tailscale.run
        options.webRoot = rig.web
        options.port = port
        backend.configurePhone(options)
        return Setup(fixture: fixture, backend: backend, tailscale: tailscale, rig: rig)
    }

    private func needsPhoneServer() throws {}

    private func raw(_ setup: Setup, port: Int, _ path: String, headers: [String: String] = [:]) -> String {
        var lines = ["GET \(path) HTTP/1.1", "Host: \(phoneHost):\(Phone.phonePort)", "Tailscale-User-Login: \(phoneOwner)"]
        for (name, value) in headers { lines.append("\(name): \(value)") }
        return rawExchange(port: port, [Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)]).reply
    }

    func testEnableStartsTheServerThenTheRouteAndGivesTheLink() async throws {
        try needsPhoneServer()
        let s = try setup()
        let state = try await s.backend.phoneEnable()
        XCTAssertTrue(state.enabled)
        XCTAssertTrue(state.connected)
        XCTAssertTrue(state.serverRunning)
        XCTAssertEqual(state.hostname, phoneHost)
        XCTAssertEqual(state.owner, phoneOwner)
        XCTAssertEqual(state.url, "https://\(phoneHost):8449/")
        XCTAssertNil(state.problem)
        XCTAssertEqual(s.tailscale.mutations, [["serve", "--bg", "--https=8449", "--yes", Phone.target]])
        XCTAssertEqual(try s.fixture.files.store.read().phone, PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner))
        let link = try await s.backend.phonePairingLink()
        let key = try PhoneKeys(folder: s.fixture.stateDir)
        XCTAssertEqual(link, "https://\(phoneHost):8449/#pair=" + key.secret("pair", hostname: phoneHost, owner: phoneOwner))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("#pair"))
        // The key file is private.
        var info = CStat()
        XCTAssertEqual(stat(s.fixture.stateDir + "/phone.key", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        // The server answers a phone through the (fake) route: the shell for an unpaired phone, nothing else.
        let port = try XCTUnwrap(s.backend.phone().server?.port)
        XCTAssertTrue(raw(s, port: port, "/").hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(raw(s, port: port, "/api/status").hasPrefix("HTTP/1.1 401"))
        // The real web app's own folder is not required for the API: pair, then read the status.
        let secret = key.secret("pair", hostname: phoneHost, owner: phoneOwner)
        let body = "{\"key\":\"\(secret)\"}"
        let pair = "POST /api/pair HTTP/1.1\r\nHost: \(phoneHost):8449\r\nTailscale-User-Login: \(phoneOwner)\r\nOrigin: https://\(phoneHost):8449\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let paired = rawExchange(port: port, [Data(pair.utf8)]).reply
        XCTAssertTrue(paired.hasPrefix("HTTP/1.1 200 OK"), paired)
        let cookie = try XCTUnwrap(paired.components(separatedBy: "\r\n").first { $0.hasPrefix("Set-Cookie: ") }).dropFirst(12).components(separatedBy: ";")[0]
        let status = raw(s, port: port, "/api/status", headers: ["Cookie": cookie])
        XCTAssertTrue(status.contains("\"access\":\"phone\""), status)
        XCTAssertFalse(status.contains(s.fixture.stateDir))
        // Reset: the same cookie and the old link stop working at once, in the running server.
        try s.backend.phoneResetPairing()
        XCTAssertTrue(raw(s, port: port, "/api/status", headers: ["Cookie": cookie]).hasPrefix("HTTP/1.1 401"))
        XCTAssertEqual(stat(s.fixture.stateDir + "/phone.key", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let newLink = try await s.backend.phonePairingLink()
        XCTAssertNotEqual(newLink, link)
        // Turning it off stops the server and removes only the owned route.
        let off = try await s.backend.phoneDisable()
        XCTAssertTrue(off.disabled)
        XCTAssertNil(off.warning)
        XCTAssertFalse(try s.fixture.files.store.read().phone.enabled)
        XCTAssertEqual(s.tailscale.calls.map(\.args).filter { $0.contains("off") }, [["serve", "--https=8449", "off"]])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rawExchange(port: port, [Data("GET / HTTP/1.1\r\n\r\n".utf8)]).connected)
        let afterOff = try await s.backend.phoneState()
        XCTAssertFalse(afterOff.enabled)
        XCTAssertFalse(afterOff.serverRunning)
        do { _ = try await s.backend.phonePairingLink(); XCTFail("link while off") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("off") ?? false) }
    }

    func testEnableWithoutTailscaleChangesNothingAndLeavesNoServer() async throws {
        try needsPhoneServer()
        let s = try setup(tailscale: PhoneCommandError(notFound: true))
        do { _ = try await s.backend.phoneEnable(); XCTFail("should fail") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("Install Tailscale") ?? false) }
        XCTAssertEqual(try s.fixture.files.store.read().phone, PhoneConfig())
        XCTAssertNil(s.backend.phone().server?.isRunning == true ? true : nil)
        let detected = await s.backend.phoneDetect()
        XCTAssertFalse(detected.installed)
    }

    func testAPortInUseStopsEnableBeforeAnyRouteIsMade() async throws {
        try needsPhoneServer()
        let rig = try PhoneRig(self)
        let squatter = PhoneServer(router: rig.router, port: 0)
        try await squatter.start()
        addTeardownBlock { squatter.stop() }
        let s = try setup(port: squatter.port)
        do { _ = try await s.backend.phoneEnable(); XCTFail("should fail") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("in use") ?? false) }
        XCTAssertEqual(s.tailscale.calls.count, 0, "no Tailscale command ran")
        XCTAssertEqual(try s.fixture.files.store.read().phone, PhoneConfig())
    }

    func testAPublicOrForeignRouteIsRefusedAndExplained() async throws {
        try needsPhoneServer()
        let funnel = privateRoute().setting("AllowFunnel", ["\(phoneHost):8449": true])
        let s = try setup(route: funnel)
        do { _ = try await s.backend.phoneEnable(); XCTFail("should fail") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("will not overwrite") ?? false) }
        XCTAssertTrue(s.tailscale.mutations.isEmpty)
        // Enabled (setup saved it) but not connected, with the reason and no link.
        let state = try await s.backend.phoneState(fresh: true)
        XCTAssertTrue(state.enabled)
        XCTAssertFalse(state.connected)
        XCTAssertEqual(state.problem, "Port 8449 is used by another or public route. Black Team will not overwrite it.")
        do { _ = try await s.backend.phonePairingLink(); XCTFail("link on a public route") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("not connected") ?? false) }
    }

    func testSyncFollowsTheSavedSettingChangedByAnotherProcess() async throws {
        try needsPhoneServer()
        let s = try setup()
        _ = try await s.backend.phoneEnable()
        XCTAssertTrue(s.backend.phone().serverRunning)
        // Another process turns it off: only the saved setting changes here.
        try s.fixture.files.store.savePhone(PhoneConfig(enabled: false, hostname: phoneHost, owner: phoneOwner))
        await s.backend.syncPhoneAccess()
        XCTAssertFalse(s.backend.phone().serverRunning)
        try s.fixture.files.store.savePhone(PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner))
        await s.backend.syncPhoneAccess()
        XCTAssertTrue(s.backend.phone().serverRunning)
    }

    func testStartAtLaunchOnlyWhenEnabledAndShutdownStopsTheServer() async throws {
        try needsPhoneServer()
        let s = try setup()
        try await s.backend.startPhoneAccess()
        XCTAssertNil(s.backend.phone().server, "off: no socket")
        _ = try await s.backend.phoneEnable()
        s.backend.stopPhoneAccess()
        let stopped = try await s.backend.phoneState()
        XCTAssertFalse(stopped.serverRunning)
        XCTAssertFalse(stopped.connected, "a route with no server behind it is not connected")
        try await s.backend.startPhoneAccess()
        let running = try await s.backend.phoneState()
        XCTAssertTrue(running.connected)
        let port = try XCTUnwrap(s.backend.phone().server?.port)
        await s.backend.shutdown()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rawExchange(port: port, [Data("GET / HTTP/1.1\r\n\r\n".utf8)]).connected)
    }
}

final class PhoneKeyTests: XCTestCase {
    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "bt-key-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testTheKeyIsCreatedPrivateAndSecretsDependOnKindComputerAndOwner() throws {
        let dir = try folder()
        let keys = try PhoneKeys(folder: dir)
        var info = CStat()
        XCTAssertEqual(stat(dir + "/phone.key", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let text = try String(contentsOfFile: dir + "/phone.key", encoding: .utf8)
        XCTAssertEqual(text.count, 64)
        let a = keys.secret("pair", hostname: "h", owner: "o")
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, try PhoneKeys(folder: dir).secret("pair", hostname: "h", owner: "o"), "stable across restarts")
        XCTAssertNotEqual(a, keys.secret("session", hostname: "h", owner: "o"))
        XCTAssertNotEqual(a, keys.secret("pair", hostname: "h2", owner: "o"))
        XCTAssertNotEqual(a, keys.secret("pair", hostname: "h", owner: "o2"))
        XCTAssertTrue(phoneEqual(a, a))
        XCTAssertFalse(phoneEqual(a, String(a.dropLast())))
        XCTAssertFalse(phoneEqual(a, nil))
        XCTAssertFalse(phoneEqual(nil, nil))
    }

    func testTheSecretMatchesTheJavaScriptDerivation() throws {
        // HMAC-SHA256 with the key text as the key and JSON.stringify(["pair","h.t.ts.net","o@x"]) as the message,
        // computed with Node: createHmac('sha256', 'ab'.repeat(32)).update('["pair","h.t.ts.net","o@x"]').digest('hex').
        let dir = try folder()
        try Data(String(repeating: "ab", count: 32).utf8).write(to: URL(fileURLWithPath: dir + "/phone.key"))
        XCTAssertEqual(try PhoneKeys(folder: dir).secret("pair", hostname: "h.t.ts.net", owner: "o@x"), "b63b0c6230953c4519a30a687f29ce75e43bd5aeb7176d001856481d05f7efae")
    }

    func testASymbolicLinkOrADamagedKeyIsRefused() throws {
        let dir = try folder()
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/elsewhere"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/phone.key", withDestinationPath: dir + "/elsewhere")
        XCTAssertThrowsError(try PhoneKeys(folder: dir)) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "Phone pairing key must not be a symbolic link.") }
        // Reset replaces the link with a real private file and leaves the target alone.
        try PhoneKeys.reset(folder: dir)
        XCTAssertFalse(CoreFS.isSymlink(dir + "/phone.key"))
        XCTAssertEqual(try String(contentsOfFile: dir + "/elsewhere", encoding: .utf8), "x")
        XCTAssertNoThrow(try PhoneKeys(folder: dir))
        for damaged in ["", "short", String(repeating: "g", count: 64), String(repeating: "A", count: 64), String(repeating: "a", count: 64) + "\n"] {
            try Data(damaged.utf8).write(to: URL(fileURLWithPath: dir + "/phone.key"))
            XCTAssertThrowsError(try PhoneKeys(folder: dir), damaged) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "The phone pairing key is damaged. Restore it from your backup.") }
        }
    }
}
