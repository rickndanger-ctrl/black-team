import Foundation

// The Linux desktop service: what the Electron window starts instead of `lib/`. It serves the web app and the API on 127.0.0.1
// (the same server as phone access, plus the desktop window's session) and answers the window's actions, one JSON object per line.
// The command-line part (arguments, standard input, signals) is `black-team desktop-service` in BlackTeamCLI.

public struct DesktopServiceOptions: Sendable {
    /// The folder of built web files (`dist`).
    public var web: String
    /// The version of the app, reported in the status.
    public var version: String
    public var port: Int = Phone.localPort
    public var dataFolder: String = AppPaths.dataFolder()
    /// Runs `tailscale`. Only tests replace it.
    public var tailscale: PhoneCommandRunner = Tailscale.run
    /// The app's scripts folder (agent-runner.py). Nil: Hermes stays unavailable.
    public var scripts: String?
    public init(web: String, version: String, port: Int = Phone.localPort, dataFolder: String = AppPaths.dataFolder(),
                tailscale: @escaping PhoneCommandRunner = Tailscale.run, scripts: String? = nil) {
        self.web = web; self.version = version; self.port = port; self.dataFolder = dataFolder; self.tailscale = tailscale; self.scripts = scripts
    }
}

public final class DesktopService: @unchecked Sendable {
    public let backend: Backend
    /// Answers the control channel's actions. Tests replace it to control what "installed on this computer" means.
    public var control: DesktopControl
    public let session: DesktopSession
    private let options: DesktopServiceOptions

    /// Opens the data folder (taking the engine lock like the other programs) but listens on nothing yet.
    public init(options: DesktopServiceOptions, backend given: Backend? = nil) throws {
        self.options = options
        session = DesktopSession()
        backend = try given ?? Backend(dataFolder: options.dataFolder, version: options.version,
                                       discover: { discoverLinux().result }, program: "the Black Team app")
        control = DesktopControl(backend)
    }

    /// The port it listens on (the real one when started on port 0).
    public var port: Int { backend.phone().server?.port ?? options.port }

    /// Starts listening. Returns the first line of the control channel: `{"ready":true,...}`.
    public func start() async throws -> String {
        backend.configureDesktop(DesktopOptions(scripts: options.scripts))
        var phone = PhoneOptions()
        phone.webRoot = options.web; phone.port = options.port; phone.desktop = session; phone.runner = options.tailscale
        backend.configurePhone(phone)
        do { try await backend.phone().start() }
        catch {
            // Whatever stopped the server from listening: something answering on the port means it is taken.
            if Self.somethingListens(on: options.port) {
                throw BlackTeamError("Black Team\u{2019}s local port \(options.port) is already in use. Close the other copy or free this port, then reopen Black Team.")
            }
            throw BlackTeamError("Black Team could not open its local service. Check your system permissions.")
        }
        let origin = "http://127.0.0.1:\(port)"
        var ready: [String: JSONValue] = ["ready": true, "origin": .string(origin), "bootstrapURL": .string(session.bootstrapURL(port: port)),
                                          "dataFolder": .string(backend.dataFolder), "version": .string(options.version)]
        // Another Black Team on this data folder runs the local model; this one still serves everything else.
        if let notice = backend.engineLock.noticeOnce() { ready["notice"] = .string(notice) }
        return JSONValue.object(ready).text()
    }

    public static func notReady(_ error: Error) -> String {
        JSONValue.object(["ready": false, "error": .string(messageOf(error))]).text()
    }

    private static func somethingListens(on port: Int) -> Bool {
        #if os(Linux)
        let fd = socket(AF_INET, posixSockStream, 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// One line of the control channel in, its reply line out (nil for a blank line).
    public func respond(toLine line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        func reply(_ id: JSONValue, _ result: JSONValue?, error: String? = nil) -> String {
            if let error { return JSONValue.object(["id": id, "ok": false, "error": .string(error)]).text() }
            return JSONValue.object(["id": id, "ok": true, "result": result ?? .null]).text()
        }
        guard let request = (try? JSONValue.parse(trimmed))?.object else { return reply(.null, nil, error: "Invalid desktop request.") }
        let id = request["id"] ?? .null
        guard let action = request["action"]?.string, request["data"].map({ $0.object != nil }) ?? true else {
            return reply(id, nil, error: "Invalid desktop request.")
        }
        do { return reply(id, try await control.handle(action, request["data"])) }
        catch { return reply(id, nil, error: messageOf(error)) }
    }

    /// Stops everything: the response, the model server, the phone server. The engine lock is given up.
    public func shutdown() async { await backend.shutdown() }
}
