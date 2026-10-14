import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The command's way to talk to a running background service: the same loopback address, session cookie and same-origin header the
// window uses (Phone/PhoneRouter.swift checks them for every route). It marks itself as the command, so a `black-team inbox` does not
// count as an open window when the service decides whether the computer is idle.

public struct ServiceClient: Sendable {
    public static let clientHeader = "X-Black-Team-Client"
    public let connection: ServiceConnection
    private let fetch: HTTPFetch

    public init(_ connection: ServiceConnection, fetch: @escaping HTTPFetch = LocalHTTP.fetch) {
        self.connection = connection; self.fetch = fetch
    }

    private func request(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: URL(string: connection.origin + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("\(DesktopSession.cookieName)=\(connection.secret)", forHTTPHeaderField: "Cookie")
        request.setValue("cli", forHTTPHeaderField: Self.clientHeader)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(connection.origin, forHTTPHeaderField: "Origin")
            request.httpBody = Data(body.text().utf8)
        }
        return request
    }

    /// One request; the reply's JSON. A refusal from the service becomes an error with its own words.
    public func send(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 20) async throws -> JSONValue {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await fetch(request(method, path, body: body, timeout: timeout)) }
        catch { throw BlackTeamError("The background service did not answer. Check it with: black-team service status") }
        let json = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains(response.statusCode) else {
            throw BlackTeamError(json["error"]?.string ?? "The background service could not do that (\(response.statusCode)).")
        }
        return json
    }

    public func get(_ path: String) async throws -> JSONValue { try await send("GET", path) }
    public func post(_ path: String, _ body: JSONValue = [:]) async throws -> JSONValue { try await send("POST", path, body: body) }

    /// What the locator needs: does the service answer with this secret, and who is it?
    public static func ping(_ connection: ServiceConnection, fetch: @escaping HTTPFetch = LocalHTTP.fetch) async -> ServiceLocator.PingResult {
        let client = ServiceClient(connection, fetch: fetch)
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await fetch(client.request("GET", "/api/service/ping", timeout: 4)) } catch { return .unreachable }
        if response.statusCode == 401 || response.statusCode == 403 { return .refused }
        guard response.statusCode == 200, let json = try? JSONValue.parse(data), let pid = json["pid"]?.int, let version = json["version"]?.string else { return .unreachable }
        return .answered(pid: Int32(truncatingIfNeeded: pid), version: version, protocolVersion: json["protocol"]?.int ?? 0)
    }

    /// Looks for the service of this data folder.
    public static func find(dataFolder: String, version: String? = nil, fetch: @escaping HTTPFetch = LocalHTTP.fetch) async -> ServiceFinding {
        await ServiceLocator.find(dataFolder: dataFolder, version: version, ping: { await ping($0, fetch: fetch) })
    }
}
