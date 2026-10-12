import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BlackTeamKit

/// A pretend HTTPS server living inside URLSession, so tests need no network.
final class StubServer: URLProtocol {
    enum Reply {
        case data(status: Int, headers: [String: String] = [:], body: Data)
        case redirect(to: URL)
        /// Sends `body.prefix(sent)` and then waits until the client gives up (for cancel tests).
        case stall(headers: [String: String], body: Data, sent: Int)
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); self.handler = handler; requests = []; lock.unlock()
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let handler = Self.handler; Self.lock.unlock()
        guard let reply = handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        switch reply {
        case .data(let status, let headers, let body):
            var all = headers; all["Content-Length"] = all["Content-Length"] ?? "\(body.count)"
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var index = 0
            while index < body.count {   // several chunks, like a real connection
                let end = min(body.count, index + 16 * 1024)
                client?.urlProtocol(self, didLoad: body.subdata(in: index..<end)); index = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .stall(let headers, let body, let sent):
            var all = headers; all["Content-Length"] = "\(body.count)"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.prefix(sent)))
        }
    }
}

#if os(Linux)
import Glibc

/// A real HTTP server on 127.0.0.1 for Linux tests. swift-corelibs-foundation aborts when a URLProtocol stub simulates a
/// redirect, so the redirect tests talk to this instead: URLSession really connects, gets a real 302, and really follows
/// (or refuses) it. It answers one request per connection and closes.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String) -> StubServer.Reply
    private let handler: Handler
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _requests: [String] = []
    private(set) var port = 0

    init(_ handler: @escaping Handler) throws {
        self.handler = handler
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listener >= 0 else { throw BlackTeamError("No socket.") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); throw BlackTeamError("Could not listen.") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = Int(UInt16(bigEndian: actual.sin_port))
        fd = listener
        Thread { [self] in acceptLoop(listener) }.start()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    /// The request paths seen so far.
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    func stop() {
        lock.lock(); let listener = fd; fd = -1; lock.unlock()
        if listener >= 0 { shutdown(listener, Int32(SHUT_RDWR)) }
    }
    deinit { stop() }

    private func acceptLoop(_ listener: Int32) {
        defer { close(listener) }
        while true {
            lock.lock(); let open = fd >= 0; lock.unlock()
            if !open { return }
            var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 100) <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return }   // not an HTTP request (for example a TLS hello): nothing to answer
            head.append(contentsOf: buffer[0..<count])
            if head.count > 65_536 { return }
        }
        let line = String(decoding: head.prefix(while: { $0 != 13 }), as: UTF8.self).split(separator: " ")
        guard line.count >= 2 else { return }
        let path = String(line[1])
        lock.lock(); _requests.append(path); lock.unlock()
        var out: Data
        switch handler(path) {
        case .data(let status, let headers, let body):
            var all = headers; all["Content-Length"] = "\(body.count)"
            out = Data(("HTTP/1.1 \(status) X\r\n" + all.map { "\($0.key): \($0.value)\r\n" }.joined() + "Connection: close\r\n\r\n").utf8) + body
        case .redirect(let target):
            out = Data("HTTP/1.1 302 Found\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        case .stall: return
        }
        var offset = 0
        while offset < out.count {
            let wrote = out.withUnsafeBytes { send(client, $0.baseAddress! + offset, out.count - offset, Int32(MSG_NOSIGNAL)) }
            if wrote <= 0 { return }
            offset += wrote
        }
    }
}
#endif
