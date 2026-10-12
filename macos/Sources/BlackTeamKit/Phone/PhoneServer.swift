import Foundation
#if canImport(Network)
import Network

/// The HTTP server the Tailscale route points at. It listens on 127.0.0.1 only (never any other interface), takes
/// connections from loopback only, and runs only while phone access is on.
public final class PhoneServer: @unchecked Sendable {
    private let router: PhoneRouter
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "black-team.phone-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var running = false
    private var _port = 0
    static let maxConnections = 64

    init(router: PhoneRouter, port: Int = Phone.localPort) {
        self.router = router
        requestedPort = UInt16(clamping: port)
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// The port it listens on (the real one when started with port 0).
    public var port: Int { lock.lock(); defer { lock.unlock() }; return _port }

    public func start() async throws {
        if isRunning { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false
        guard let wanted = NWEndpoint.Port(rawValue: requestedPort) else { throw BlackTeamError("The phone server port is not valid.") }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: wanted)
        let made: NWListener
        do { made = try NWListener(using: parameters) } catch { throw Self.busy(requestedPort) }
        made.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = PhoneOnce()
            made.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume() }
                case .failed, .waiting, .cancelled:
                    // An address that is taken shows up as failed or waiting: either way nothing is listening for us.
                    if once.first() { made.cancel(); continuation.resume(throwing: Self.busy(self?.requestedPort ?? 0)) }
                    else { self?.markStopped(made) }
                default: break
                }
            }
            made.start(queue: queue)
        }
        lock.withLock { listener = made; running = true; _port = Int(made.port?.rawValue ?? requestedPort) }
        router.localPort = port
    }

    private static func busy(_ port: UInt16) -> BlackTeamError {
        BlackTeamError("Port \(port) on this Mac is in use, so phone access cannot start. Quit the program using it and try again.")
    }

    private func markStopped(_ made: NWListener) {
        lock.lock()
        if listener === made { running = false }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let current = listener, open = Array(connections.values)
        listener = nil; running = false; connections = [:]
        lock.unlock()
        current?.cancel()
        open.forEach { $0.cancel() }
    }

    // MARK: Connections

    /// The address of the other end in the form `authorize` compares.
    static func peerAddress(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        func clean(_ text: String) -> String { String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
        switch host {
        case .ipv4(let address): return clean("\(address)")
        case .ipv6(let address):
            if address.isLoopback { return "::1" }
            if let mapped = address.asIPv4 { return "::ffff:" + clean("\(mapped)") }
            return clean("\(address)")
        default: return nil
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Self.peerAddress(connection.endpoint)
        lock.lock()
        let full = connections.count >= Self.maxConnections || !running
        if !full { connections[ObjectIdentifier(connection)] = connection }
        lock.unlock()
        // Only loopback may connect (Tailscale Serve proxies from 127.0.0.1); the listener is bound there as well.
        guard !full, let peer, ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains(peer) else { connection.cancel(); forget(connection); return }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.forget(connection) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        Task { [router] in await Self.serve(connection, peer: peer, router: router) }
    }

    private func forget(_ connection: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(connection)] = nil; lock.unlock()
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// Reads one request (headers within 10 s, the whole request within 15 s), answers it and closes.
    private static func serve(_ connection: NWConnection, peer: String, router: PhoneRouter) async {
        let state = PhoneOnce()
        let headTimer = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled && !state.isSet { connection.cancel() } }
        let totalTimer = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { connection.cancel() } }
        defer { headTimer.cancel(); totalTimer.cancel(); connection.cancel() }
        var buffer = Data()
        var response: HTTPResponse
        var isHead = false
        do {
            var end: Int?
            while end == nil {
                end = try HTTPParser.headEnd(in: buffer)
                if end != nil { break }
                guard let chunk = try await receive(connection) else { return }
                buffer.append(chunk)
            }
            let head = try HTTPParser.parseHead(buffer.prefix(end! - 4))
            _ = state.first()
            headTimer.cancel()
            isHead = head.method == "HEAD"
            var rest = Data(buffer.dropFirst(end!))
            response = await router.respond(head, peer: peer, readBody: {
                while rest.count < head.contentLength {
                    guard let chunk = try await receive(connection) else { throw HTTPFailure("The request ended early.") }
                    rest.append(chunk)
                }
                return Data(rest.prefix(head.contentLength))
            })
        } catch let failure as HTTPFailure {
            response = PhoneRouter.secured(.error(failure.status, failure.message))
        } catch {
            return
        }
        await send(connection, response.serialized(head: isHead))
    }
}
#else
/// Phone access needs Network.framework; the Linux version comes later.
public final class PhoneServer: @unchecked Sendable {
    init(router: PhoneRouter, port: Int = Phone.localPort) {}
    public var isRunning: Bool { false }
    public var port: Int { 0 }
    public func start() async throws { throw BlackTeamError("Phone access is not available on Linux in this build yet.") }
    public func stop() {}
}
#endif

/// A flag that can be taken once.
final class PhoneOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
}
