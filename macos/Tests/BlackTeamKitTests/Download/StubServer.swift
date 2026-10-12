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
