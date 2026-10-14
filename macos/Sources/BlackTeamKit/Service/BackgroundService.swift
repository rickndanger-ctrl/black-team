import Foundation
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// The always-running service: the desktop service's engine and loopback server (Desktop/DesktopService.swift) with no window attached,
// plus the scheduler, the idle timer and the helpers. Windows and the command find it through `<data>/service.json`
// (Service/ServiceConnection.swift). `black-team service run` is the command-line part (BlackTeamCLI/ServiceCommand.swift).
//
// One engine owns a data folder (Core/EngineLock.swift). The service refuses to start while another Black Team has the folder's engine, so
// it never runs a second model beside it; systemd tries again later.

public final class BackgroundService: @unchecked Sendable {
    public let desktop: DesktopService
    public let hooks: ServiceHooks
    private let options: DesktopServiceOptions
    private var connection: ServiceConnection?

    /// Opens the data folder (taking the engine lock). Nothing listens yet.
    public init(options: DesktopServiceOptions, backend: Backend? = nil, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
                manager: ServiceManager? = nil) throws {
        self.options = options
        // The engine lock names its holder, so a second program is told "in use by the Black Team background service".
        let engine = try backend ?? Backend(dataFolder: options.dataFolder, version: options.version, discover: { discoverLinux().result },
                                            program: "the Black Team background service")
        desktop = try DesktopService(options: options, backend: engine)
        hooks = ServiceHooks(backend: desktop.backend, mode: .background, manager: manager, now: now, calendar: calendar)
        desktop.backend.service = hooks
        hooks.control = desktop.control
        hooks.controlKey = desktop.session.controlKey
    }

    public var backend: Backend { desktop.backend }
    public var port: Int { desktop.port }

    /// Starts listening, then the scheduler, idle timer and helpers, then writes the connection file. Throws plain words when it cannot.
    @discardableResult
    public func start(startLoops: Bool = true) async throws -> ServiceConnection {
        let lock = desktop.backend.engineLock
        if !lock.isHeld, let other = lock.otherHolder() {
            if other.program.contains("background service") { throw BlackTeamError("The Black Team background service is already running for this data folder.") }
            throw BlackTeamError("Black Team is already open in \(other.program), and only one can run your model. Close it; the background service will start after that.")
        }
        _ = try await desktop.start()
        do { try hooks.startBackgroundParts(scripts: options.scripts, startLoops: startLoops) }
        catch { await desktop.shutdown(); throw error }
        let made = ServiceConnection(version: options.version, pid: getpid(), port: desktop.port, secret: desktop.session.sessionKey,
                                     bootstrap: desktop.session.bootstrapKey, control: desktop.session.controlKey, started: Date().timeIntervalSince1970, dataFolder: options.dataFolder)
        do { try made.write() } catch { await shutdown(); throw error }
        connection = made
        return made
    }

    /// Stops the scheduler and helpers, removes the connection file, and stops the model and the server.
    public func shutdown() async {
        ServiceConnection.remove(in: options.dataFolder)
        await hooks.stopBackgroundParts()
        await desktop.shutdown()
    }
}
