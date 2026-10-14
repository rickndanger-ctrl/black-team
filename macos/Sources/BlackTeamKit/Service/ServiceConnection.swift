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

// How the window and the command find the background service for a data folder. The service writes `<data>/service.json` (0600, in the
// private data folder) once it listens, and removes it when it stops:
//
//   { "protocol": 1, "version": "0.1.0-alpha.29", "pid": 4242, "port": 18199, "secret": "<session key>", "bootstrap": "<bootstrap key>",
//     "control": "<control key>", "started": 1760000000, "dataFolder": "/home/me/.local/share/black-team-data" }
//
// The secret is the desktop session key of that run of the service (Desktop/DesktopSession.swift): whoever can read the file can do what
// the window does, which is why the file is private and why a new one is made for every start. A reader trusts the file only when it is
// private and ours, its process is alive, and the service answers `GET /api/service/ping` with
// the same process id when given the secret. A file left behind by a crash fails those checks and is ignored.

public struct ServiceConnection: Codable, Equatable, Sendable {
    /// Bumped when the way a window or command talks to the service changes, so an old service and a new window refuse each other plainly.
    public static let currentProtocol = 1
    public static let fileName = "service.json"

    public var `protocol`: Int
    public var version: String
    public var pid: Int32
    public var port: Int
    public var secret: String
    public var bootstrap: String
    /// Needed besides the secret for `POST /api/service/control`: the window\u{2019}s page has the secret (its cookie) but never this.
    public var control: String
    public var started: Double
    public var dataFolder: String

    public init(version: String, pid: Int32, port: Int, secret: String, bootstrap: String, control: String = "", started: Double, dataFolder: String, protocolVersion: Int = ServiceConnection.currentProtocol) {
        self.protocol = protocolVersion; self.version = version; self.pid = pid; self.port = port; self.secret = secret; self.bootstrap = bootstrap; self.control = control
        self.started = started; self.dataFolder = dataFolder
    }

    public static func file(in dataFolder: String) -> String { dataFolder + "/" + fileName }

    public var origin: String { "http://127.0.0.1:\(port)" }
    public var bootstrapURL: String { origin + "/bootstrap?key=\(bootstrap)" }

    /// Writes it, private and in one piece.
    public func write() throws {
        try privateDirectory(dataFolder)
        try writeJSON(Self.file(in: dataFolder), self)
    }

    /// Removes the file, but only if it is this process's.
    public static func remove(in dataFolder: String, pid: Int32 = getpid()) {
        let file = Self.file(in: dataFolder)
        if let data = FileManager.default.contents(atPath: file), let saved = try? JSONDecoder().decode(ServiceConnection.self, from: data), saved.pid == pid {
            unlink(file)
        }
    }
}

/// What looking for the service found.
public enum ServiceFinding: Equatable, Sendable {
    /// No file: no service for this data folder.
    case none
    /// A file from a process that is gone, or one that cannot be trusted. Ignore it.
    case stale(String)
    /// A service answers for this folder.
    case running(ServiceConnection)
    /// A service is there but this program may not use it (the secret was refused, or the file is open to others).
    case refused(String)
    /// A service of another version or protocol: it must be restarted.
    case mismatch(ServiceConnection, String)
}

public enum ServiceLocator {
    /// The words for a window or command that finds a service of another version.
    public static func mismatchMessage(service: String, mine: String) -> String {
        "Black Team\u{2019}s background service is version \(service), but this is version \(mine). Restart the background service (black-team service restart), then try again."
    }

    /// Looks for the service. `ask` makes the ping request (`secret` and `port` in, the reply's process id out or nil when refused or silent);
    /// tests replace it. `version` is the caller's own, compared when given.
    public static func find(dataFolder: String, version: String? = nil,
                            alive: @Sendable (Int32) -> Bool = EngineLock.processExists,
                            ping: @Sendable (ServiceConnection) async -> PingResult) async -> ServiceFinding {
        let file = ServiceConnection.file(in: dataFolder)
        var info = stat()
        guard lstat(file, &info) == 0 else { return .none }
        // Only a plain file we own, closed to everyone else.
        if (info.st_mode & S_IFMT) != S_IFREG || info.st_uid != getuid() { return .stale("The connection file is not ours.") }
        if (info.st_mode & 0o077) != 0 { return .refused("The connection file is open to other users, so it is not trusted.") }
        guard let data = FileManager.default.contents(atPath: file), let connection = try? JSONDecoder().decode(ServiceConnection.self, from: data),
              connection.port > 0, connection.port < 65536, !connection.secret.isEmpty else { return .stale("The connection file is damaged.") }
        if connection.dataFolder != dataFolder { return .stale("The connection file is for another data folder.") }
        if !alive(connection.pid) { return .stale("The service that wrote it is gone.") }
        switch await ping(connection) {
        case .unreachable: return .stale("The service does not answer.")
        case .refused: return .refused("The background service refused this program\u{2019}s secret.")
        case .answered(let pid, let theirVersion, let theirProtocol):
            if pid != connection.pid { return .stale("Something else answers on the service\u{2019}s port.") }
            if theirProtocol != ServiceConnection.currentProtocol || (version != nil && theirVersion != version) {
                return .mismatch(connection, mismatchMessage(service: theirVersion, mine: version ?? ServiceConnection.currentProtocol.description))
            }
            return .running(connection)
        }
    }

    public enum PingResult: Equatable, Sendable {
        case unreachable
        case refused
        case answered(pid: Int32, version: String, protocolVersion: Int)
    }
}
