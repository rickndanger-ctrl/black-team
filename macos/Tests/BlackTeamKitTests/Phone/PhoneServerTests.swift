import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Network)
import Network
#endif
@testable import BlackTeamKit

// The strict HTTP reader, the loopback-only server, and a phone driving a real Backend through both.

final class PhoneHTTPParserTests: XCTestCase {
    private func parse(_ text: String) throws -> HTTPHead { try HTTPParser.parseHead(Data(text.utf8)) }
    private func refused(_ text: String, _ status: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(text); XCTFail("accepted: \(text.debugDescription)", file: file, line: line) }
        catch let failure as HTTPFailure { if let status { XCTAssertEqual(failure.status, status, text.debugDescription, file: file, line: line) } }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testAValidRequestIsParsed() throws {
        let head = try parse("POST /api/chat?a=b%20c&d=e+f&g HTTP/1.1\r\nHost: x.ts.net:8449\r\nContent-Length: 12\r\nContent-Type: application/json\r\nX-Many: 1\r\nx-many: 2")
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/api/chat")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertEqual(head.headers["host"], "x.ts.net:8449")
        XCTAssertEqual(head.headers["x-many"], "1, 2")
        XCTAssertEqual(head.queryValue("a"), "b c")
        XCTAssertEqual(head.queryValue("d"), "e f")
        XCTAssertEqual(head.queryValue("g"), "")
        XCTAssertNil(head.queryValue("z"))
        XCTAssertEqual(try parse("GET / HTTP/1.0\r\nHost: a").method, "GET")
        XCTAssertEqual(try parse("HEAD /x HTTP/1.1\r\nHost: a").method, "HEAD")
        // Percent-escapes and dot segments are left alone for the router.
        XCTAssertEqual(try parse("GET /a/%2e%2e/b HTTP/1.1\r\nHost: a").path, "/a/%2e%2e/b")
    }

    func testMalformedRequestsAreRefused() {
        refused("GET / HTTP/1.1\r\nHost: a\r\nHost: b", 400)
        refused("GET / HTTP/1.1\r\nCookie: a\r\nCookie: b", 400)
        refused("GET / HTTP/1.1\r\nOrigin: a\r\nOrigin: b", 400)
        refused("GET / HTTP/1.1\r\nTailscale-User-Login: a\r\ntailscale-user-login: b", 400)
        refused("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1", 400)
        refused("POST / HTTP/1.1\r\nTransfer-Encoding: chunked", 501)
        refused("POST / HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked", 501)
        refused("POST / HTTP/1.1\r\nHost: a", 411)
        refused("GET / HTTP/1.1\r\nContent-Length: 5", 400)
        for length in ["abc", "-1", "+5", "1e3", "", "99999999999", "0x10", " "] { refused("POST / HTTP/1.1\r\nContent-Length: \(length)", 400) }
        refused("PUT / HTTP/1.1\r\nHost: a", 405)
        refused("DELETE / HTTP/1.1", 405)
        refused("CONNECT a:443 HTTP/1.1", 405)
        refused("get / HTTP/1.1", 400)
        refused("GET / HTTP/2.0", 505)
        refused("GET / HTTP/0.9", 505)
        refused("GET / ")
        refused("GET  / HTTP/1.1", 400)
        refused("GET / HTTP/1.1 extra", 400)
        refused("GET http://evil.test/ HTTP/1.1", 400)
        refused("GET * HTTP/1.1", 400)
        refused("GET /a b HTTP/1.1", 400)
        refused("GET /#frag HTTP/1.1", 400)
        refused("GET /caf\u{e9} HTTP/1.1", 400)
        refused("GET /" + String(repeating: "a", count: 9000) + " HTTP/1.1", 400)
        refused("GET / HTTP/1.1\r\n folded: x", 400)
        refused("GET / HTTP/1.1\r\n\tfolded: x", 400)
        refused("GET / HTTP/1.1\r\nNoColon", 400)
        refused("GET / HTTP/1.1\r\n: empty", 400)
        refused("GET / HTTP/1.1\r\nBad Name: x", 400)
        refused("GET / HTTP/1.1\r\nHost: a\nX: y", 400)
        refused("GET / HTTP/1.1\r\nHost: a\rX: y", 400)
        refused("GET / HTTP/1.1\r\nHost: a\u{0}b", 400)
        refused("GET / HTTP/1.1\r\nHost: a\u{7f}", 400)
        refused("", 400)
        refused("GET / HTTP/1.1\r\n" + (0...100).map { "h\($0): v" }.joined(separator: "\r\n"), 431)
    }

    func testHeadEndFindsTheBlankLineAndBoundsTheHeader() throws {
        XCTAssertNil(try HTTPParser.headEnd(in: Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)))
        XCTAssertEqual(try HTTPParser.headEnd(in: Data("GET / HTTP/1.1\r\n\r\nbody".utf8)), 18)
        XCTAssertThrowsError(try HTTPParser.headEnd(in: Data(repeating: 97, count: HTTPLimits.headBytes + 1)))
        var big = Data("GET / HTTP/1.1\r\nX: ".utf8)
        big.append(Data(repeating: 97, count: HTTPLimits.headBytes))
        big.append(Data("\r\n\r\n".utf8))
        XCTAssertThrowsError(try HTTPParser.headEnd(in: big))
    }

    func testAResponseHasACorrectLengthAndNeverACarriageReturnInAHeader() {
        var response = HTTPResponse.json(200, ["a": "b"])
        response.set("X-Evil", "ok\r\nSet-Cookie: x=y")
        let text = String(decoding: response.serialized(head: false), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 9\r\nConnection: close\r\n\r\n{\"a\":\"b\"}"))
        XCTAssertFalse(text.contains("\r\nSet-Cookie"))
        XCTAssertFalse(String(decoding: response.serialized(head: true), as: UTF8.self).contains("{\"a\""))
    }
}

/// A blocking client over BSD sockets, so the tests can send exactly the bytes they like.
func rawExchange(host: String = "127.0.0.1", port: Int, _ pieces: [Data], pause: TimeInterval = 0) -> (reply: String, connected: Bool) {
    #if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, host, &address.sin_addr)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if result != 0 { return ("", false) }
    for piece in pieces {
        _ = piece.withUnsafeBytes { send(fd, $0.baseAddress, piece.count, 0) }
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
    }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count <= 0 { break }
        reply.append(contentsOf: buffer[0..<count])
    }
    return (String(decoding: reply, as: UTF8.self), true)
}

#if canImport(Network)
final class PhoneServerTests: XCTestCase {
    private func started(_ rig: PhoneRig) async throws -> PhoneServer {
        let server = PhoneServer(router: rig.router, port: 0)
        try await server.start()
        addTeardownBlock { server.stop() }
        return server
    }

    private func request(_ rig: PhoneRig, _ method: String, _ path: String, body: String = "", extra: [String: String] = [:], paired: Bool = false, host: String? = nil) -> String {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "\(phoneHost):\(Phone.phonePort)")", "Tailscale-User-Login: \(phoneOwner)"]
        if method == "POST" { lines += ["Origin: \(rig.origin)", "Content-Type: application/json", "Content-Length: \(body.utf8.count)"] }
        if paired { lines.append("Cookie: black_team_phone=\(rig.sessionSecret)") }
        for (name, value) in extra { lines.append("\(name): \(value)") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    func testItAnswersOnLoopbackAndNowhereElse() async throws {
        let rig = try PhoneRig(self)
        let server = try await started(rig)
        XCTAssertTrue(server.isRunning)
        XCTAssertGreaterThan(server.port, 0)
        let shell = rawExchange(port: server.port, [Data(request(rig, "GET", "/").utf8)])
        XCTAssertTrue(shell.reply.hasPrefix("HTTP/1.1 200 OK\r\n"), shell.reply)
        XCTAssertTrue(shell.reply.hasSuffix("<html>shell</html>"))
        XCTAssertTrue(shell.reply.contains("Connection: close"))
        XCTAssertTrue(shell.reply.contains("Content-Security-Policy:"))
        // Every other address of this Mac refuses the connection: the listener is bound to 127.0.0.1 only.
        var seen = 0
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        XCTAssertEqual(getifaddrs(&interfaces), 0)
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var raw = $0.pointee.sin_addr; inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) }
            let ip = String(cString: text)
            if ip == "127.0.0.1" { continue }
            seen += 1
            XCTAssertFalse(rawExchange(host: ip, port: server.port, [Data(request(rig, "GET", "/").utf8)]).connected, "\(ip) accepted a connection")
        }
        print("checked \(seen) non-loopback IPv4 addresses")
    }

    func testAPairedPhoneAndAStrangerOverTheSocket() async throws {
        let rig = try PhoneRig(self)
        let server = try await started(rig)
        let status = rawExchange(port: server.port, [Data(request(rig, "GET", "/api/status", paired: true).utf8)])
        XCTAssertTrue(status.reply.hasPrefix("HTTP/1.1 200 OK"), status.reply)
        XCTAssertTrue(status.reply.hasSuffix("{\"access\":\"phone\",\"config\":{\"model\":{\"name\":\"Fixture model\"}},\"phone\":{\"enabled\":true}}"))
        let stranger = rawExchange(port: server.port, [Data(request(rig, "GET", "/api/status").utf8)])
        XCTAssertTrue(stranger.reply.hasPrefix("HTTP/1.1 401 Unauthorized"), stranger.reply)
        let local = rawExchange(port: server.port, [Data(request(rig, "GET", "/", paired: true, host: "127.0.0.1:\(server.port)").utf8)])
        XCTAssertTrue(local.reply.hasPrefix("HTTP/1.1 401"), local.reply)
        let wrongHost = rawExchange(port: server.port, [Data(request(rig, "GET", "/", paired: true, host: "evil.test").utf8)])
        XCTAssertTrue(wrongHost.reply.hasPrefix("HTTP/1.1 403"), wrongHost.reply)
        let pair = rawExchange(port: server.port, [Data(request(rig, "POST", "/api/pair", body: "{\"key\":\"\(rig.pairSecret)\"}").utf8)])
        XCTAssertTrue(pair.reply.hasPrefix("HTTP/1.1 200 OK"), pair.reply)
        XCTAssertTrue(pair.reply.contains("Set-Cookie: black_team_phone="))
        // A body that arrives in pieces is put together; HEAD has the length and no body.
        let whole = request(rig, "POST", "/api/cancel", body: "{}", paired: true)
        let split = rawExchange(port: server.port, [Data(whole.utf8.prefix(60)), Data(whole.utf8.dropFirst(60))], pause: 0.1)
        XCTAssertTrue(split.reply.hasSuffix("{\"stopping\":false}"), split.reply)
        let head = rawExchange(port: server.port, [Data(request(rig, "HEAD", "/", paired: true).utf8)])
        XCTAssertTrue(head.reply.contains("Content-Length: 18"))
        XCTAssertTrue(head.reply.hasSuffix("\r\n\r\n"))
    }

    func testMalformedAndOversizedRequestsOverTheSocket() async throws {
        let rig = try PhoneRig(self)
        let server = try await started(rig)
        func status(_ bytes: Data) -> String { rawExchange(port: server.port, [bytes]).reply.split(separator: "\r\n").first.map(String.init) ?? "" }
        XCTAssertTrue(status(Data("garbage\r\n\r\n".utf8)).contains("400"))
        XCTAssertTrue(status(Data("PUT / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)).contains("405"))
        XCTAssertTrue(status(Data(("GET / HTTP/1.1\r\nHost: a\r\nX: " + String(repeating: "a", count: 20000) + "\r\n\r\n").utf8)).contains("431"))
        XCTAssertTrue(status(Data("POST /api/chat HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)).contains("501"))
        let huge = request(rig, "POST", "/api/chat", body: "", extra: ["Content-Length": "9"]).replacingOccurrences(of: "Content-Length: 0", with: "")
        _ = huge
        let tooBig = "POST /api/chat HTTP/1.1\r\nHost: \(phoneHost):8449\r\nTailscale-User-Login: \(phoneOwner)\r\nOrigin: \(rig.origin)\r\nContent-Type: application/json\r\nContent-Length: 70000\r\nCookie: black_team_phone=\(rig.sessionSecret)\r\n\r\n"
        XCTAssertTrue(status(Data(tooBig.utf8)).contains("413"))
        // Fewer body bytes than promised: the connection ends with an error, nothing is run.
        let short = "POST /api/chat HTTP/1.1\r\nHost: \(phoneHost):8449\r\nTailscale-User-Login: \(phoneOwner)\r\nOrigin: \(rig.origin)\r\nContent-Type: application/json\r\nContent-Length: 50\r\nCookie: black_team_phone=\(rig.sessionSecret)\r\n\r\n{}"
        let shortReply = rawExchange(port: server.port, [Data(short.utf8)])
        XCTAssertFalse(shortReply.reply.contains(" 202 "))
        XCTAssertEqual(rig.backend.calls, [])
    }

    func testAPortInUseIsReportedAndStopClosesTheListener() async throws {
        let rig = try PhoneRig(self)
        let first = try await started(rig)
        let second = PhoneServer(router: rig.router, port: first.port)
        do { try await second.start(); XCTFail("bound twice") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("in use") ?? false) }
        XCTAssertFalse(second.isRunning)
        let port = first.port
        first.stop()
        XCTAssertFalse(first.isRunning)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rawExchange(port: port, [Data(request(rig, "GET", "/").utf8)]).connected)
    }

    func testThePeerAddressIsReadFromTheConnection() {
        XCTAssertEqual(PhoneServer.peerAddress(.hostPort(host: .ipv4(.loopback), port: 1)), "127.0.0.1")
        XCTAssertEqual(PhoneServer.peerAddress(.hostPort(host: .ipv6(.loopback), port: 1)), "::1")
        XCTAssertEqual(PhoneServer.peerAddress(.hostPort(host: IPv4Address("100.64.1.2").map { .ipv4($0) } ?? "x", port: 1)), "100.64.1.2")
        XCTAssertNil(PhoneServer.peerAddress(.hostPort(host: "example.com", port: 1)))
    }
}
#else
final class PhoneServerTests: XCTestCase {
    func testItAnswersOnLoopbackAndNowhereElse() throws { throw XCTSkip("The phone server needs Network.framework; its Linux version comes later") }
    func testAPairedPhoneAndAStrangerOverTheSocket() throws { throw XCTSkip("The phone server needs Network.framework; its Linux version comes later") }
    func testMalformedAndOversizedRequestsOverTheSocket() throws { throw XCTSkip("The phone server needs Network.framework; its Linux version comes later") }
    func testAPortInUseIsReportedAndStopClosesTheListener() throws { throw XCTSkip("The phone server needs Network.framework; its Linux version comes later") }
    func testThePeerAddressIsReadFromTheConnection() throws { throw XCTSkip("The phone server needs Network.framework; its Linux version comes later") }
}
#endif

/// A phone against a real Backend: nothing private leaves, and a chat reaches the model and comes back.
final class PhoneBackendTests: XCTestCase {
    func testThePhoneStatusHoldsNoKeyNoPathAndNoDesktopConfiguration() async throws {
        let fixture = try BackendFixture(self, server: true)
        let backend = try fixture.make()
        let rig = try PhoneRig(self)
        let router = PhoneRouter(backend: BackendPhone(backend), config: rig.store, keys: rig.keys, webRoot: rig.web, isConnected: { true })
        let answer = await router.respond(rig.head("GET", "/api/status", headers: ["cookie": "black_team_phone=\(rig.sessionSecret)"]), peer: "127.0.0.1", readBody: { Data() })
        XCTAssertEqual(answer.status, 200)
        let text = rig.text(answer)
        let json = try JSONValue.parse(text)
        XCTAssertEqual(Set(json.object!.keys), ["access", "version", "setupComplete", "runtime", "threads", "job", "agentEnabled", "hermesEnabled", "projects", "memory", "dictation",
                                                 "codeMap", "performance", "config", "phone"])
        XCTAssertEqual(json["access"]?.string, "phone")
        XCTAssertEqual(json["config"], ["model": ["name": "Fixture model"]])
        XCTAssertEqual(json["phone"], ["enabled": true])
        XCTAssertEqual(json["dictation"], false)
        for secret in ["private-server-credential", "apiKey", "local-test-key", fixture.stateDir, "endpoint", "127.0.0.1:5555", "a-custom-model", phoneOwner, phoneHost,
                       "hardware", "integrations", "serverKeyConfigured", "models", "workspace\":\"/", "phone.key"] {
            XCTAssertFalse(text.contains(secret), "phone status contains \(secret)")
        }
        // The same holds for a model file setup.
        let local = try BackendFixture(self)
        let localBackend = try local.make()
        let other = PhoneRouter(backend: BackendPhone(localBackend), config: rig.store, keys: rig.keys, webRoot: rig.web, isConnected: { true })
        let reply = await other.respond(rig.head("GET", "/api/status", headers: ["cookie": "black_team_phone=\(rig.sessionSecret)"]), peer: "127.0.0.1", readBody: { Data() })
        let body = rig.text(reply)
        for secret in [local.files.config.model.file, local.files.config.model.runtime, local.files.config.workspace, local.stateDir, ".gguf", "llama-server"] where !secret.isEmpty {
            XCTAssertFalse(body.contains(secret), "phone status contains \(secret)")
        }
        XCTAssertEqual(reply.status, 200)
    }

    func testAPhoneChatsThroughTheRealBackend() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let rig = try PhoneRig(self)
        let router = PhoneRouter(backend: BackendPhone(backend), config: rig.store, keys: rig.keys, webRoot: rig.web, isConnected: { true })
        let cookie = ["cookie": "black_team_phone=\(rig.sessionSecret)"]
        func call(_ method: String, _ path: String, _ json: JSONValue? = nil) async -> HTTPResponse {
            let body = Data((json?.text() ?? "").utf8)
            return await router.respond(rig.head(method, path, headers: cookie, length: body.count), body: body, peer: "127.0.0.1")
        }
        let id = newID()
        let sent = await call("POST", "/api/chat", ["message": "Hello from the phone", "requestId": .string(id)])
        XCTAssertEqual(sent.status, 202)
        let thread = try XCTUnwrap(try JSONValue.parse(sent.body)["threadId"]?.string)
        await backend.waitForIdle()
        let saved = await call("GET", "/api/thread/\(thread)")
        XCTAssertEqual(saved.status, 200)
        let messages = try XCTUnwrap(try JSONValue.parse(saved.body)["messages"]?.array)
        XCTAssertEqual(messages.last?["content"]?.string, "Private \u{1F5A4} caf\u{00E9}")
        XCTAssertEqual(messages.last?["state"]?.string, "done")
        let request = await call("GET", "/api/request/\(id)")
        XCTAssertEqual(try JSONValue.parse(request.body)["state"]?.string, "done")
        // The same request ID again starts nothing; another message with it is a conflict.
        let again = await call("POST", "/api/chat", ["message": "Hello from the phone", "requestId": .string(id)])
        XCTAssertEqual(again.status, 202)
        let clash = await call("POST", "/api/chat", ["message": "Different", "requestId": .string(id)])
        XCTAssertEqual(clash.status, 409)
        XCTAssertEqual(fixture.requests.count, 1)
        // A phone cannot choose the folder Code works in: `workspace` is ignored.
        let code = await call("POST", "/api/chat", ["message": "make a file", "requestId": .string(newID()), "kind": "agent", "workspace": "/tmp"])
        XCTAssertEqual(code.status, 202)
        await backend.waitForIdle()
        XCTAssertEqual(fixture.engine.runs.last?.workspace, fixture.files.config.workspace)
    }
}
