import XCTest
@testable import BlackTeamKit

// The authorization and routes of lib/server.cjs for phones (tests/server.test.cjs, phone parts), plus the
// refusals the Mac port adds (no desktop session).

final class FakePhoneBackend: PhoneBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var busy = false
    var submitError: BlackTeamError?
    private(set) var submitted: [(message: String, kind: String, mode: String, requestId: String, threadId: String?, project: String?)] = []
    func note(_ text: String) { lock.withLock { _calls.append(text) } }

    func phoneStatus() async throws -> JSONValue { note("status"); return ["access": "phone", "config": ["model": ["name": "Fixture model"]], "phone": ["enabled": true]] }
    var isBusy: Bool { busy }
    func submit(message: String, kind: String, mode: String, requestId: String, threadId: String?, project: String?) throws -> SubmitResult {
        note("submit")
        lock.withLock { submitted.append((message, kind, mode, requestId, threadId, project)) }
        if let submitError { throw submitError }
        return SubmitResult(id: requestId, threadId: "t", state: "running")
    }
    func thread(_ id: String) -> JSONValue? { note("thread"); return id == "known" ? ["id": "known", "messages": []] : nil }
    func request(_ id: String) -> SubmitResult? { note("request"); return nil }
    func cancel() -> CancelResult { note("cancel"); return CancelResult(stopping: false) }
    func approve(id: String, digest: String, choice: String) throws { note("approve"); throw BlackTeamError("No active approval.") }
    func undo(_ id: String?) throws -> UndoResult { note("undo"); return UndoResult(path: "a.txt", removed: false) }
    func artifactFile(_ id: String) throws -> ArtifactFile { note("file"); throw BlackTeamError("File not found.") }
    func createProject(name: String) throws -> ProjectSummary { note("project"); return ProjectSummary(id: "p", name: name, workspace: "/w/p", exists: true, notes: "Projects/p") }
    func memoryOverview() throws -> MemoryOverview { note("memory"); throw BlackTeamError("nope") }
    func memoryNote(_ id: String) throws -> NoteContent { note("note"); return NoteContent(id: id, title: "t", content: "c", updated: 1) }
    func memorySearch(_ query: String) async throws -> [SearchHit] { note("search"); return [] }
    func memorySave(_ id: String, content: String) throws -> NoteContent { note("save"); return NoteContent(id: id, title: "t", content: content, updated: 1) }
    func memoryDelete(_ id: String) throws { note("delete") }
    func memoryRemember(title: String, text: String, project: String?) throws -> String { note("remember"); return "Notes/x" }
    func memoryTidy() async -> String { note("tidy"); return "ok" }
}

/// A router, a fake backend, a data folder with a key, and a small built web app with a file outside it.
final class PhoneRig {
    let folder: String
    let web: String
    let outside: String
    let store = FakePhoneStore(PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner))
    let backend = FakePhoneBackend()
    let keys: PhoneKeys
    let connected = PhoneBox(true)
    let router: PhoneRouter
    let origin = "https://\(phoneHost):\(Phone.phonePort)"

    init(_ test: XCTestCase) throws {
        folder = NSTemporaryDirectory() + "bt-phone-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        web = folder + "/dist"
        outside = folder + "/secret.txt"
        try FileManager.default.createDirectory(atPath: web + "/assets", withIntermediateDirectories: true)
        try Data("<html>shell</html>".utf8).write(to: URL(fileURLWithPath: web + "/index.html"))
        try Data("console.log(1)".utf8).write(to: URL(fileURLWithPath: web + "/assets/app.js"))
        try Data("self".utf8).write(to: URL(fileURLWithPath: web + "/sw.js"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: web + "/manifest.webmanifest"))
        try Data("TOP SECRET".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: web + "/leak.txt", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: web + "/leakdir", withDestinationPath: folder)
        keys = try PhoneKeys(folder: folder)
        let connected = self.connected
        router = PhoneRouter(backend: backend, config: store, keys: keys, webRoot: web, localPort: 18199, isConnected: { connected.value })
        let folder = self.folder
        test.addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
    }

    var pairSecret: String { keys.secret("pair", hostname: phoneHost, owner: phoneOwner) }
    var sessionSecret: String { keys.secret("session", hostname: phoneHost, owner: phoneOwner) }

    func head(_ method: String = "GET", _ path: String = "/", headers: [String: String] = [:], length: Int = 0, remove: [String] = []) -> HTTPHead {
        var all = ["host": "\(phoneHost):\(Phone.phonePort)", "tailscale-user-login": phoneOwner]
        if method == "POST" { all["origin"] = origin; all["content-type"] = "application/json" }
        for (key, value) in headers { all[key] = value }
        for key in remove { all[key] = nil }
        let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return HTTPHead(method: method, target: path, path: String(split[0]), query: split.count > 1 ? HTTPParser.parseQuery(String(split[1])) : [], headers: all, contentLength: length)
    }

    func send(_ method: String = "GET", _ path: String = "/", json: JSONValue? = nil, raw: Data? = nil, headers: [String: String] = [:], remove: [String] = [],
              peer: String? = "127.0.0.1", paired: Bool = false) async -> HTTPResponse {
        let body = raw ?? json.map { Data($0.text().utf8) } ?? Data()
        var all = headers
        if paired { all["cookie"] = "\(PhoneRouter.cookieName)=\(sessionSecret)" }
        return await router.respond(head(method, path, headers: all, length: body.count, remove: remove), body: body, peer: peer)
    }

    func text(_ response: HTTPResponse) -> String { String(decoding: response.body, as: UTF8.self) }
    func header(_ response: HTTPResponse, _ name: String) -> String? { response.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }
}

final class PhoneRouterTests: XCTestCase {
    func testUnpairedPhoneGetsTheShellAndNothingElse() async throws {
        let r = try PhoneRig(self)
        let shell = await r.send("GET", "/")
        XCTAssertEqual(shell.status, 200)
        XCTAssertEqual(r.text(shell), "<html>shell</html>")
        for path in ["/api/status", "/api/thread/known", "/api/memory", "/api/file/" + String(repeating: "a", count: 32)] {
            let answer = await r.send("GET", path)
            XCTAssertEqual(answer.status, 401, path)
        }
        let head = await r.send("HEAD", "/")
        XCTAssertEqual(head.status, 401, "HEAD is only for paired phones, as in server.cjs")
        let chat = await r.send("POST", "/api/chat", json: ["message": "x", "requestId": "y"])
        XCTAssertEqual(chat.status, 401)
        XCTAssertEqual(r.backend.calls, [])
    }

    func testPairingSetsTheCookieOnlyForTheRightSecret() async throws {
        let r = try PhoneRig(self)
        for key: JSONValue in [.string("wrong"), .string(""), .null, .number(1), .string(String(r.pairSecret.dropLast()))] {
            let refused = await r.send("POST", "/api/pair", json: ["key": key])
            XCTAssertEqual(refused.status, 401)
            XCTAssertNil(r.header(refused, "set-cookie"))
        }
        let missing = await r.send("POST", "/api/pair", json: [:])
        XCTAssertEqual(missing.status, 401)
        let ok = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)])
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(r.text(ok), "{\"paired\":true}")
        let cookie = try XCTUnwrap(r.header(ok, "set-cookie"))
        XCTAssertEqual(cookie, "black_team_phone=\(r.sessionSecret); Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000")
        XCTAssertNotEqual(r.pairSecret, r.sessionSecret)
        // The session cookie is not a pairing key.
        let swapped = await r.send("POST", "/api/pair", json: ["key": .string(r.sessionSecret)])
        XCTAssertEqual(swapped.status, 401)
    }

    func testPairedPhoneReadsTheReducedStatus() async throws {
        let r = try PhoneRig(self)
        let status = await r.send("GET", "/api/status", paired: true)
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(r.text(status), "{\"access\":\"phone\",\"config\":{\"model\":{\"name\":\"Fixture model\"}},\"phone\":{\"enabled\":true}}")
        let again = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)], paired: true)
        XCTAssertEqual(again.status, 200, "a paired phone can pair again")
    }

    func testSecurityHeadersAreOnEveryResponse() async throws {
        let r = try PhoneRig(self)
        for response in [await r.send("GET", "/"), await r.send("GET", "/api/status"), await r.send("GET", "/", headers: ["host": "evil.test"]), await r.send("GET", "/nope", paired: true)] {
            XCTAssertEqual(r.header(response, "cache-control"), "no-store")
            XCTAssertEqual(r.header(response, "x-content-type-options"), "nosniff")
            XCTAssertEqual(r.header(response, "x-frame-options"), "DENY")
            XCTAssertEqual(r.header(response, "referrer-policy"), "no-referrer")
            XCTAssertEqual(r.header(response, "permissions-policy"), "camera=(), microphone=(), geolocation=()")
            XCTAssertTrue(r.header(response, "content-security-policy")?.contains("frame-ancestors 'none'") ?? false)
            XCTAssertTrue(r.header(response, "content-security-policy")?.contains("default-src 'self'") ?? false)
        }
    }

    // MARK: Negative cases

    func testWrongHostIsRefused() async throws {
        let r = try PhoneRig(self)
        for host in ["attacker.test:8449", "attacker.test", "\(phoneHost):8450", phoneHost, "127.0.0.1:18199x", "", "other.testnet.ts.net:8449"] {
            let answer = await r.send("GET", "/", headers: ["host": host], paired: true)
            XCTAssertEqual(answer.status, 403, "host \(host)")
        }
        let missing = await r.send("GET", "/", remove: ["host"], paired: true)
        XCTAssertEqual(missing.status, 403)
        // Case does not matter, as in server.cjs.
        let upper = await r.send("GET", "/", headers: ["host": phoneHost.uppercased() + ":8449"], paired: true)
        XCTAssertEqual(upper.status, 200)
    }

    func testWrongOrMissingOriginIsRefused() async throws {
        let r = try PhoneRig(self)
        for origin in ["https://attacker.test", "http://127.0.0.1:18199", "https://\(phoneHost)", "http://\(phoneHost):8449", "null"] {
            let read = await r.send("GET", "/api/status", headers: ["origin": origin], paired: true)
            XCTAssertEqual(read.status, 403, origin)
            let pair = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)], headers: ["origin": origin])
            XCTAssertEqual(pair.status, 403, origin)
            let chat = await r.send("POST", "/api/chat", json: ["message": "x", "requestId": "y"], headers: ["origin": origin], paired: true)
            XCTAssertEqual(chat.status, 403, origin)
        }
        let noOrigin = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)], remove: ["origin"])
        XCTAssertEqual(noOrigin.status, 403)
        let emptyOrigin = await r.send("POST", "/api/chat", json: ["message": "x", "requestId": "y"], headers: ["origin": ""], paired: true)
        XCTAssertEqual(emptyOrigin.status, 403)
        // A same-origin GET with an Origin header is fine; a GET without one is too.
        let sameOrigin = await r.send("GET", "/api/status", headers: ["origin": r.origin], paired: true)
        XCTAssertEqual(sameOrigin.status, 200)
        XCTAssertEqual(r.backend.calls, ["status"])
    }

    func testOnlyLoopbackPeersAreServed() async throws {
        let r = try PhoneRig(self)
        for peer in ["100.100.100.100", "192.168.1.4", "::2", "0.0.0.0", "", "127.0.0.2", nil] {
            let answer = await r.send("GET", "/api/status", peer: peer, paired: true)
            XCTAssertEqual(answer.status, 403, peer ?? "nil")
        }
        for peer in ["127.0.0.1", "::1", "::ffff:127.0.0.1"] {
            let answer = await r.send("GET", "/api/status", peer: peer, paired: true)
            XCTAssertEqual(answer.status, 200, peer)
        }
    }

    func testTheTailscaleAccountMustBeTheSavedOwner() async throws {
        let r = try PhoneRig(self)
        for login in ["other@example.test", "", "OWNER@example.test", phoneOwner + " ", phoneOwner + "x"] {
            let answer = await r.send("GET", "/api/status", headers: ["tailscale-user-login": login], paired: true)
            XCTAssertEqual(answer.status, 401, "login '\(login)'")
            let shell = await r.send("GET", "/", headers: ["tailscale-user-login": login])
            XCTAssertEqual(shell.status, 401, "login '\(login)'")
        }
        let missing = await r.send("GET", "/api/status", remove: ["tailscale-user-login"], paired: true)
        XCTAssertEqual(missing.status, 401)
        let missingPair = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)], remove: ["tailscale-user-login"])
        XCTAssertEqual(missingPair.status, 401)
        // A saved setup with no owner never matches, not even an empty login.
        r.store.value = PhoneConfig(enabled: true, hostname: phoneHost, owner: "")
        let empty = await r.send("GET", "/", headers: ["tailscale-user-login": ""])
        XCTAssertEqual(empty.status, 403)
        XCTAssertEqual(r.backend.calls, [])
    }

    func testAWrongOrForeignCookieIsNotPaired() async throws {
        let r = try PhoneRig(self)
        for cookie in ["", "black_team_phone=", "black_team_phone=wrong", "black_team_session=\(r.sessionSecret)", "other=\(r.sessionSecret)", "black_team_phone=\(r.pairSecret)",
                       "black_team_phone=\(r.sessionSecret)0", "black_team_phone=\(String(r.sessionSecret.dropLast()))"] {
            let answer = await r.send("GET", "/api/status", headers: ["cookie": cookie])
            XCTAssertEqual(answer.status, 401, cookie)
        }
        // Several cookies: the right one is found among them.
        let several = await r.send("GET", "/api/status", headers: ["cookie": "a=b; black_team_phone=\(r.sessionSecret); c=d"])
        XCTAssertEqual(several.status, 200)
        // A cookie made for another owner or computer does not work.
        let foreign = r.keys.secret("session", hostname: phoneHost, owner: "someone@example.test")
        let other = await r.send("GET", "/api/status", headers: ["cookie": "black_team_phone=\(foreign)"])
        XCTAssertEqual(other.status, 401)
    }

    func testARouteThatIsNotConnectedRefusesEverything() async throws {
        let r = try PhoneRig(self)
        r.connected.value = false
        for (method, path) in [("GET", "/"), ("GET", "/api/status"), ("POST", "/api/pair"), ("GET", "/assets/app.js")] {
            let answer = await r.send(method, path, json: method == "POST" ? ["key": .string(r.pairSecret)] : nil, paired: true)
            XCTAssertEqual(answer.status, 401, path)
        }
        XCTAssertEqual(r.backend.calls, [])
        r.connected.value = true
        let back = await r.send("GET", "/api/status", paired: true)
        XCTAssertEqual(back.status, 200)
    }

    func testPhoneAccessThatIsOffRefusesEverything() async throws {
        let r = try PhoneRig(self)
        r.store.value = PhoneConfig(enabled: false, hostname: phoneHost, owner: phoneOwner)
        let answer = await r.send("GET", "/api/status", paired: true)
        XCTAssertEqual(answer.status, 403)
        let shell = await r.send("GET", "/")
        XCTAssertEqual(shell.status, 403)
        XCTAssertEqual(r.backend.calls, [])
    }

    func testAChangedOwnerOrComputerOrKeyUnpairsEveryPhone() async throws {
        let r = try PhoneRig(self)
        let cookie = r.sessionSecret
        let before = await r.send("GET", "/api/status", headers: ["cookie": "black_team_phone=\(cookie)"])
        XCTAssertEqual(before.status, 200)
        // Reset: the key file is replaced, and the running router notices at once.
        try PhoneKeys.reset(folder: r.folder)
        let after = await r.send("GET", "/api/status", headers: ["cookie": "black_team_phone=\(cookie)"])
        XCTAssertEqual(after.status, 401)
        let oldLink = await r.send("POST", "/api/pair", json: ["key": .string(cookie)])
        XCTAssertEqual(oldLink.status, 401)
        // The new pairing secret works and the new cookie then works.
        let paired = await r.send("POST", "/api/pair", json: ["key": .string(r.pairSecret)])
        XCTAssertEqual(paired.status, 200)
        let fresh = await r.send("GET", "/api/status", paired: true)
        XCTAssertEqual(fresh.status, 200)
        // A removed key refuses everything until it is restored.
        try FileManager.default.removeItem(atPath: r.folder + "/phone.key")
        let removed = await r.send("GET", "/api/status", paired: true)
        XCTAssertEqual(removed.status, 401)
        // A new owner makes every old cookie useless.
        try PhoneKeys.reset(folder: r.folder)
        let kept = r.sessionSecret
        r.store.value = PhoneConfig(enabled: true, hostname: phoneHost, owner: "new-owner@example.test")
        let moved = await r.send("GET", "/api/status", headers: ["tailscale-user-login": "new-owner@example.test", "cookie": "black_team_phone=\(kept)"])
        XCTAssertEqual(moved.status, 401)
    }

    func testTheLocalAddressGrantsNothingBecauseTheMacHasNoDesktopSession() async throws {
        let r = try PhoneRig(self)
        let local = ["host": "127.0.0.1:18199"]
        for (method, path) in [("GET", "/api/status"), ("GET", "/"), ("GET", "/bootstrap?key=abc"), ("POST", "/api/chat"), ("GET", "/api/memory")] {
            let origin = method == "POST" ? ["origin": "http://127.0.0.1:18199"] : [:]
            let answer = await r.send(method, path, json: method == "POST" ? ["message": "x", "requestId": "y"] : nil,
                                      headers: local.merging(origin) { $1 }.merging(["cookie": "black_team_session=anything; black_team_phone=\(r.sessionSecret)"]) { $1 }, paired: true)
            XCTAssertEqual(answer.status, 401, path)
        }
        // Not even with the phone's login header and a valid cookie.
        let spoofed = await r.send("GET", "/api/status", headers: local, paired: true)
        XCTAssertEqual(spoofed.status, 401)
        let badOrigin = await r.send("GET", "/api/status", headers: local.merging(["origin": "https://attacker.test"]) { $1 })
        XCTAssertEqual(badOrigin.status, 403)
        XCTAssertEqual(r.backend.calls, [])
    }

    // MARK: Bodies and limits

    func testOversizedBodiesAreRefusedBeforeTheyAreRead() async throws {
        let r = try PhoneRig(self)
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        var big = r.head("POST", "/api/chat", headers: ["cookie": "black_team_phone=\(r.sessionSecret)"], length: 65537)
        var answer = await r.router.respond(big, peer: "127.0.0.1", readBody: { reads.count += 1; return Data() })
        XCTAssertEqual(answer.status, 413)
        XCTAssertEqual(reads.count, 0, "an oversized body is never read")
        big = r.head("POST", "/api/memory/save", headers: ["cookie": "black_team_phone=\(r.sessionSecret)"], length: 900 * 1024 + 1)
        answer = await r.router.respond(big, peer: "127.0.0.1", readBody: { reads.count += 1; return Data() })
        XCTAssertEqual(answer.status, 413)
        // An unauthorised request's body is never read either.
        let stranger = r.head("POST", "/api/chat", headers: ["tailscale-user-login": "nobody"], length: 10)
        answer = await r.router.respond(stranger, peer: "127.0.0.1", readBody: { reads.count += 1; return Data() })
        XCTAssertEqual(answer.status, 401)
        XCTAssertEqual(reads.count, 0)
        // 64 KiB is fine for chat; a note may be bigger.
        let body = Data(JSONValue.object(["message": .string(String(repeating: "a", count: 60000)), "requestId": "id"]).text().utf8)
        let allowed = await r.send("POST", "/api/chat", raw: body, paired: true)
        XCTAssertEqual(allowed.status, 202)
        let note = Data(JSONValue.object(["id": "Notes/A", "content": .string(String(repeating: "n", count: 200_000))]).text().utf8)
        let saved = await r.send("POST", "/api/memory/save", raw: note, paired: true)
        XCTAssertEqual(saved.status, 200)
    }

    func testBodiesMustBeJSONObjects() async throws {
        let r = try PhoneRig(self)
        let wrongType = await r.send("POST", "/api/chat", raw: Data("hello".utf8), headers: ["content-type": "text/plain"], paired: true)
        XCTAssertEqual(wrongType.status, 415)
        let none = await r.send("POST", "/api/chat", raw: Data("{}".utf8), remove: ["content-type"], paired: true)
        XCTAssertEqual(none.status, 415)
        for raw in ["{", "[]", "null", "\"x\"", "{} x", ""] {
            let answer = await r.send("POST", "/api/chat", raw: Data(raw.utf8), paired: true)
            XCTAssertEqual(answer.status, 400, raw)
        }
        let upper = await r.send("POST", "/api/cancel", json: [:], headers: ["content-type": "Application/JSON; charset=utf-8"], paired: true)
        XCTAssertEqual(upper.status, 200)
    }

    // MARK: What a phone may and may not call

    func testAPhoneCannotCallDesktopOnlyOrUnknownRoutes() async throws {
        let r = try PhoneRig(self)
        for (method, path) in [("POST", "/api/config"), ("GET", "/api/config"), ("POST", "/api/setup"), ("GET", "/bootstrap"), ("POST", "/api/models"), ("POST", "/api/integrations"),
                               ("GET", "/api/hardware"), ("POST", "/api/phone"), ("POST", "/api/launch"), ("GET", "/api"), ("GET", "/api/"), ("POST", "/api/status"),
                               ("GET", "/api/chat"), ("GET", "/api/pair"), ("POST", "/api/thread/known"), ("GET", "/api/cancel")] {
            let answer = await r.send(method, path, json: method == "POST" ? [:] : nil, paired: true)
            XCTAssertEqual(answer.status, 404, "\(method) \(path)")
        }
        let dictate = await r.send("POST", "/api/dictate", json: [:], paired: true)
        XCTAssertEqual(dictate.status, 403)
        XCTAssertEqual(r.backend.calls, [])
    }

    func testTheAllowedRoutesReachTheBackend() async throws {
        let r = try PhoneRig(self)
        let known = await r.send("GET", "/api/thread/known", paired: true)
        XCTAssertEqual(known.status, 200)
        let unknown = await r.send("GET", "/api/thread/other", paired: true)
        XCTAssertEqual(unknown.status, 404)
        let request = await r.send("GET", "/api/request/x", paired: true)
        XCTAssertEqual(request.status, 404)
        let cancel = await r.send("POST", "/api/cancel", json: [:], paired: true)
        XCTAssertEqual(r.text(cancel), "{\"stopping\":false}")
        let approval = await r.send("POST", "/api/approval", json: ["id": "a", "digest": "b", "choice": "once"], paired: true)
        XCTAssertEqual(approval.status, 409)
        let bad = await r.send("POST", "/api/approval", json: ["id": 1], paired: true)
        XCTAssertEqual(bad.status, 409)
        let file = await r.send("GET", "/api/file/abc", paired: true)
        XCTAssertEqual(file.status, 404)
        let project = await r.send("POST", "/api/project-create", json: ["name": "Demo"], paired: true)
        XCTAssertEqual(project.status, 200)
        let undo = await r.send("POST", "/api/undo", json: ["id": "u"], paired: true)
        XCTAssertEqual(r.text(undo), "{\"path\":\"a.txt\",\"removed\":false}")
        r.backend.busy = true
        let busyUndo = await r.send("POST", "/api/undo", json: ["id": "u"], paired: true)
        XCTAssertEqual(busyUndo.status, 409)
        let tidy = await r.send("POST", "/api/memory/tidy", json: [:], paired: true)
        XCTAssertEqual(r.text(tidy), "{\"message\":\"A task is running. Tidy memory when it finishes.\"}")
        r.backend.busy = false
        let search = await r.send("GET", "/api/memory/search?q=a+b", paired: true)
        XCTAssertEqual(r.text(search), "{\"hits\":[]}")
        let remember = await r.send("POST", "/api/memory/remember", json: ["title": "T", "text": "X"], paired: true)
        XCTAssertEqual(remember.status, 200)
        let overview = await r.send("GET", "/api/memory", paired: true)
        XCTAssertEqual(overview.status, 400, "a plain error is a message for the person")
        XCTAssertEqual(r.text(overview), "{\"error\":\"nope\"}")
        let unknownMemory = await r.send("POST", "/api/memory/nothing", json: [:], paired: true)
        XCTAssertEqual(unknownMemory.status, 404)
    }

    func testChatReadsOnlyWhatServerCjsReads() async throws {
        let r = try PhoneRig(self)
        let id = UUID().uuidString.lowercased()
        // A phone cannot name a folder to work in.
        let sent = await r.send("POST", "/api/chat", json: ["message": "hi", "requestId": .string(id), "workspace": "/etc", "kind": "agent", "mode": "deep",
                                                           "threadId": "abc", "project": "p1", "model": "evil", "images": ["x"]], paired: true)
        XCTAssertEqual(sent.status, 202)
        XCTAssertEqual(r.text(sent), "{\"id\":\"\(id)\",\"state\":\"running\",\"threadId\":\"t\"}")
        let call = try XCTUnwrap(r.backend.submitted.first)
        XCTAssertEqual([call.message, call.kind, call.mode, call.requestId, call.threadId ?? "-", call.project ?? "-"], ["hi", "agent", "deep", id, "abc", "p1"])
        _ = await r.send("POST", "/api/chat", json: ["message": "hi", "requestId": .string(id)], paired: true)
        let defaults = r.backend.submitted[1]
        XCTAssertEqual([defaults.kind, defaults.mode], ["chat", "balanced"])
        XCTAssertNil(defaults.threadId)
        XCTAssertNil(defaults.project)
        // Wrong types are refused by the backend's own validation, never coerced.
        _ = await r.send("POST", "/api/chat", json: ["message": 5, "requestId": 7, "kind": 3, "mode": ["x"], "threadId": 4, "project": 9], paired: true)
        let wrong = r.backend.submitted[2]
        XCTAssertEqual(wrong.message, "")
        XCTAssertEqual(wrong.requestId, "")
        XCTAssertEqual(wrong.kind, "\u{0}")
        XCTAssertEqual(wrong.mode, "\u{0}")
        XCTAssertEqual(wrong.threadId, "\u{0}")
        XCTAssertEqual(wrong.project, "\u{0}")
        r.backend.submitError = BlackTeamError("A response is already running. Wait or stop it before sending another.")
        let busy = await r.send("POST", "/api/chat", json: ["message": "hi", "requestId": .string(id)], paired: true)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(PhoneRouter.submitStatus("Conversation not found."), 404)
        XCTAssertEqual(PhoneRouter.submitStatus("Black Team is closing."), 503)
        XCTAssertEqual(PhoneRouter.submitStatus("Enter a message of up to 16,000 characters."), 400)
    }

    // MARK: Static files

    func testStaticFilesAreServedWithTheirTypes() async throws {
        let r = try PhoneRig(self)
        let js = await r.send("GET", "/assets/app.js", paired: true)
        XCTAssertEqual(r.header(js, "content-type"), "text/javascript; charset=utf-8")
        let manifest = await r.send("GET", "/manifest.webmanifest", paired: true)
        XCTAssertEqual(r.header(manifest, "content-type"), "application/manifest+json")
        let worker = await r.send("GET", "/sw.js", paired: true)
        XCTAssertEqual(r.header(worker, "service-worker-allowed"), "/")
        XCTAssertNil(r.header(js, "service-worker-allowed"))
        let index = await r.send("GET", "/index.html", paired: true)
        XCTAssertEqual(index.status, 200)
        let head = await r.send("HEAD", "/", paired: true)
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.serialized(head: true).count, head.serialized(head: false).count - head.body.count)
        XCTAssertTrue(String(decoding: head.serialized(head: true), as: UTF8.self).contains("Content-Length: 18\r\n"))
    }

    func testPathTraversalAndSymbolicLinksAreRefused() async throws {
        let r = try PhoneRig(self)
        let attempts = ["/../secret.txt", "/assets/../../secret.txt", "/%2e%2e/secret.txt", "/%2E%2E/secret.txt", "/assets/..%2f..%2fsecret.txt", "/assets/%2e%2e/%2e%2e/secret.txt",
                        "/..%5csecret.txt", "/assets\\..\\..\\secret.txt", "/index.html%00.png", "/%00", "/assets/..", "/%zz", "/leak.txt", "/leakdir/secret.txt",
                        "//etc/passwd", "/etc/passwd", "/assets/", "/assets", "/nothing.js"]
        for path in attempts {
            let answer = await r.send("GET", path, paired: true)
            XCTAssertTrue([400, 404].contains(answer.status), "\(path) -> \(answer.status)")
            XCTAssertFalse(r.text(answer).contains("TOP SECRET"), path)
        }
        // The same for an unpaired phone, which may read the shell only.
        for path in ["/../secret.txt", "/leak.txt"] {
            let answer = await r.send("GET", path)
            XCTAssertNotEqual(answer.status, 200)
            XCTAssertFalse(r.text(answer).contains("TOP SECRET"))
        }
        // POST to a file path is not a file read.
        let post = await r.send("POST", "/index.html", json: [:], paired: true)
        XCTAssertEqual(post.status, 404)
    }

    func testAMissingWebFolderIsNotFoundNotACrash() async throws {
        let r = try PhoneRig(self)
        let router = PhoneRouter(backend: r.backend, config: r.store, keys: r.keys, webRoot: r.folder + "/nowhere", isConnected: { true })
        let answer = await router.respond(r.head("GET", "/"), peer: "127.0.0.1", readBody: { Data() })
        XCTAssertEqual(answer.status, 404)
    }
}
