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
#elseif canImport(Glibc) || canImport(Musl)
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif

/// The Linux version of the phone server, on POSIX sockets. Same rules as the Mac one: it listens on 127.0.0.1 only,
/// takes connections from loopback only, and runs only while phone access is on. The request is read and answered by the
/// same `HTTPParser` and `PhoneRouter`; this file only moves bytes.
public final class PhoneServer: @unchecked Sendable {
    private let router: PhoneRouter
    private let requestedPort: UInt16
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: [Int32: LinuxConnection] = [:]
    private var running = false
    private var _port = 0
    private var acceptDone: DispatchSemaphore?
    static let maxConnections = 64

    init(router: PhoneRouter, port: Int = Phone.localPort) {
        self.router = router
        requestedPort = UInt16(clamping: port)
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// The port it listens on (the real one when started with port 0).
    public var port: Int { lock.lock(); defer { lock.unlock() }; return _port }

    /// The address the listener is bound to, as text (always 127.0.0.1 while running).
    var boundAddress: String? {
        lock.lock(); let fd = listenFD; lock.unlock()
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return result == 0 ? Self.peerAddress(address) : nil
    }

    public func start() async throws {
        if isRunning { return }
        let fd = socket(AF_INET, posixSockStream, 0)
        guard fd >= 0 else { throw Self.busy(requestedPort) }
        var yes: Int32 = 1
        // Lets a restart reuse the port while old connections wind down; it does not let two listeners share a port.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(requestedPort).bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian   // 127.0.0.1, never any other interface
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); throw Self.busy(requestedPort) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let done = DispatchSemaphore(value: 0)
        lock.withLock { listenFD = fd; running = true; _port = Int(UInt16(bigEndian: actual.sin_port)); acceptDone = done }
        router.localPort = port
        let thread = Thread { [weak self] in
            self?.acceptLoop(fd)
            done.signal()
        }
        thread.name = "black-team.phone-server"
        thread.start()
    }

    private static func busy(_ port: UInt16) -> BlackTeamError {
        BlackTeamError("Port \(port) on this computer is in use, so phone access cannot start. Quit the program using it and try again.")
    }

    public func stop() {
        lock.lock()
        let fd = listenFD, open = Array(connections.values), done = acceptDone
        listenFD = -1; running = false; acceptDone = nil
        lock.unlock()
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }   // wakes the accept loop, which closes the listener
        open.forEach { $0.cancel() }
        _ = done?.wait(timeout: .now() + 2)
    }

    // MARK: Connections

    /// The address of the other end in the form `authorize` compares.
    static func peerAddress(_ address: sockaddr_in) -> String {
        var raw = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while isRunning {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 200)
            if !isRunning || (item.revents & Int16(POLLNVAL | POLLERR | POLLHUP)) != 0 { return }
            if ready <= 0 { continue }
            var peerAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peerAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            if client < 0 { continue }
            accepted(client, peer: Self.peerAddress(peerAddress))
        }
    }

    private func accepted(_ client: Int32, peer: String) {
        let connection = LinuxConnection(fd: client)
        lock.lock()
        let full = connections.count >= Self.maxConnections || !running
        if !full { connections[client] = connection }
        lock.unlock()
        // Only loopback may connect (Tailscale Serve proxies from 127.0.0.1); the listener is bound there as well.
        guard !full, peer == "127.0.0.1" else {
            connection.cancel(); connection.close()
            if !full { forget(client) }
            return
        }
        Task.detached { [router, weak self] in
            await Self.serve(connection, peer: peer, router: router)
            connection.close()
            self?.forget(client)
        }
    }

    private func forget(_ fd: Int32) {
        lock.lock(); connections[fd] = nil; lock.unlock()
    }

    /// Reads one request (headers within 10 s, the whole request within 15 s), answers it and closes.
    private static func serve(_ connection: LinuxConnection, peer: String, router: PhoneRouter) async {
        var buffer = Data()
        var response: HTTPResponse
        var isHead = false
        do {
            var end: Int?
            while end == nil {
                end = try HTTPParser.headEnd(in: buffer)
                if end != nil { break }
                guard let chunk = try await connection.receive(headOnly: true) else { return }
                buffer.append(chunk)
            }
            let head = try HTTPParser.parseHead(buffer.prefix(end! - 4))
            isHead = head.method == "HEAD"
            var rest = Data(buffer.dropFirst(end!))
            response = await router.respond(head, peer: peer, readBody: {
                while rest.count < head.contentLength {
                    guard let chunk = try await connection.receive(headOnly: false) else { throw HTTPFailure("The request ended early.") }
                    rest.append(chunk)
                }
                return Data(rest.prefix(head.contentLength))
            })
        } catch let failure as HTTPFailure {
            response = PhoneRouter.secured(.error(failure.status, failure.message))
        } catch {
            return
        }
        await connection.send(response.serialized(head: isHead))
    }
}

/// One accepted socket with its deadlines. Reads and writes block a background thread, never the async pool.
final class LinuxConnection: @unchecked Sendable {
    private struct Timeout: Error {}
    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false
    private let headDeadline: Date
    private let totalDeadline: Date

    init(fd: Int32) {
        self.fd = fd
        let now = Date()
        headDeadline = now.addingTimeInterval(10)
        totalDeadline = now.addingTimeInterval(15)
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Ends any read or write in progress.
    func cancel() {
        lock.lock(); let was = cancelled || closed; cancelled = true; lock.unlock()
        if !was { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    func close() {
        lock.lock(); let was = closed; closed = true; lock.unlock()
        if !was { posixClose(fd) }
    }

    /// Waits for the socket to be ready, in short slices so a cancel is noticed. False when the deadline passed.
    private func wait(for events: Int16, until deadline: Date) -> Bool {
        while !isCancelled {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return false }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&item, 1, Int32(min(left, 0.1) * 1000) + 1)
            if ready > 0 { return true }
            if ready < 0 && errno != EINTR { return false }
        }
        return false
    }

    func receive(headOnly: Bool) async throws -> Data? {
        // The headers must be complete within 10 s of the connection, the whole request within 15 s.
        let deadline = headOnly ? headDeadline : totalDeadline
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            DispatchQueue.global().async {
                guard self.wait(for: Int16(POLLIN), until: deadline) else { continuation.resume(throwing: Timeout()); return }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = recv(self.fd, &buffer, buffer.count, 0)
                if count > 0 { continuation.resume(returning: Data(buffer[0..<count])) }
                else if count == 0 { continuation.resume(returning: nil) }
                else if errno == EINTR || errno == EAGAIN { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: Timeout()) }
            }
        }
    }

    /// Sends everything, then ends the sending side and lets the other side finish reading before the socket closes.
    func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let deadline = self.totalDeadline.addingTimeInterval(5)
                var offset = 0
                data.withUnsafeBytes { raw in
                    while offset < data.count, !self.isCancelled {
                        guard self.wait(for: Int16(POLLOUT), until: deadline) else { return }
                        let wrote = posixSend(self.fd, raw.baseAddress! + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                        if wrote > 0 { offset += wrote }
                        else if wrote < 0 && errno != EINTR && errno != EAGAIN { return }
                    }
                }
                shutdown(self.fd, Int32(SHUT_WR))
                // Unread request bytes (for instance a refused big body) would turn the close into a reset that can
                // wipe out the reply, so read what is still arriving for a moment.
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                let quiet = Date().addingTimeInterval(0.3)
                var drained = 0
                while drained < 1_000_000, self.wait(for: Int16(POLLIN), until: quiet) {
                    let count = recv(self.fd, &scratch, scratch.count, 0)
                    if count <= 0 { break }
                    drained += count
                }
                continuation.resume()
            }
        }
    }
}
#endif

/// A flag that can be taken once.
final class PhoneOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
}
