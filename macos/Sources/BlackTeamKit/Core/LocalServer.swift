import Foundation

/// The one way the app talks HTTP, so tests can replace the network. Later areas (runtime,
/// engine, model finder) take these as parameters with the real ones as defaults.
public typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
/// Lines of a streamed reply (server-sent events), empty lines included, without line ends.
public typealias HTTPLines = AsyncThrowingStream<String, Error>
public typealias HTTPStreamFetch = @Sendable (URLRequest) async throws -> (HTTPURLResponse, HTTPLines)

/// Refuses redirects, as the JavaScript does (`redirect: 'error'`), so a key is never sent elsewhere.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The real network. Callers set `timeoutInterval` on the request when they want one other than 60 s.
public enum LocalHTTP {
    private static let session = URLSession(configuration: .ephemeral)
    private static let refuse = RefuseRedirects()

    private static func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if [301, 302, 303, 307, 308].contains(http.statusCode) { throw URLError(.httpTooManyRedirects) }
        return http
    }

    public static let fetch: HTTPFetch = { request in
        let (data, response) = try await session.data(for: request, delegate: refuse)
        return (data, try checked(response))
    }

    public static let stream: HTTPStreamFetch = { request in
        let (bytes, response) = try await session.bytes(for: request, delegate: refuse)
        let http = try checked(response)
        let lines = HTTPLines { continuation in
            let task = Task {
                do {
                    var line = [UInt8]()
                    func emit() {
                        if line.last == 13 { line.removeLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self)); line.removeAll(keepingCapacity: true)
                    }
                    for try await byte in bytes {
                        if byte == 10 { emit() } else { line.append(byte) }
                    }
                    if !line.isEmpty { emit() }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, lines)
    }
}

/// Accepts only a loopback HTTP address with a port and `/v1`, so keys never leave this Mac.
public func localEndpoint(_ value: String) throws -> String {
    guard let parts = URLComponents(string: value), let scheme = parts.scheme else {
        throw BlackTeamError("Enter a local server URL such as http://127.0.0.1:11434/v1.")
    }
    guard scheme.lowercased() == "http", let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
          let port = parts.port, port != 80, ["/v1", "/v1/"].contains(parts.path),
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
        throw BlackTeamError("Use a loopback HTTP address with a port and /v1 (localhost, 127.0.0.1, or [::1]).")
    }
    // Avoid DNS resolution for the common localhost spelling.
    let name = host == "localhost" ? "127.0.0.1" : host.contains(":") ? "[::1]" : host
    return "http://\(name):\(port)/v1"
}

/// The Authorization header for a server key, or none when there is no key.
public func serverHeaders(_ apiKey: String = "") throws -> [String: String] {
    if apiKey.utf16.count > 4096 || apiKey.utf8.contains(where: { $0 < 0x21 || $0 > 0x7e }) {
        throw BlackTeamError("The server API key must contain only printable characters without spaces.")
    }
    return apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
}

public struct DiscoveredModels: Equatable, Sendable {
    public let endpoint: String
    public let models: [String]
}

/// Asks an OpenAI-compatible local server which models it offers.
public func discoverModels(endpoint: String, apiKey: String = "", fetch: HTTPFetch = LocalHTTP.fetch) async throws -> DiscoveredModels {
    let base = try localEndpoint(endpoint)
    let headers = try serverHeaders(apiKey)
    var request = URLRequest(url: URL(string: base + "/models")!)
    request.timeoutInterval = 10
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let result: (Data, HTTPURLResponse)
    do { result = try await fetch(request) } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        throw BlackTeamError("Cannot reach the local model server. Start it, enable its local API, and check the address.")
    }
    let (data, response) = result
    guard (200..<300).contains(response.statusCode) else {
        throw BlackTeamError([401, 403].contains(response.statusCode) ? "The local server requires a valid API key." : "Local model discovery failed (HTTP \(response.statusCode)).")
    }
    guard let value = try? JSONValue.parse(data) else { throw BlackTeamError("The local server returned an invalid model list.") }
    guard let items = value["data"]?.array else { throw BlackTeamError("This server must support OpenAI-compatible GET /v1/models.") }
    var models: [String] = []
    for item in items {
        guard let id = item["id"]?.string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 256,
              !id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }), !models.contains(id) else { continue }
        models.append(id)
    }
    if models.isEmpty { throw BlackTeamError("No models were reported. Download or load a model in your local server first.") }
    return DiscoveredModels(endpoint: base, models: models)
}
