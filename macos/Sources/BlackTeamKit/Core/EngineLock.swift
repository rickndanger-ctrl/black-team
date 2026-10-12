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

/// Two Black Teams (the app and the `black-team` command) can be open on the same data folder. Conversations are files and both
/// read them, but only one of them may run the local model. The first engine process takes `<data>/engine.lock`; a second one
/// still starts, says so once, and refuses to START a local model while the first is alive. A lock whose process is gone is stale
/// and is taken over. Cloud models and subscription agents never need the lock.
public final class EngineLock: @unchecked Sendable {
    public struct Holder: Codable, Equatable, Sendable {
        public var pid: Int32
        public var program: String
        public var started: Double
    }

    public let file: String
    public let program: String
    private let pid: Int32
    private let alive: @Sendable (Int32) -> Bool
    private let mutex = NSLock()
    private var holding = false
    private var announced = false

    public init(dataFolder: String, program: String, pid: Int32 = getpid(), alive: @escaping @Sendable (Int32) -> Bool = EngineLock.processExists) {
        file = dataFolder + "/engine.lock"
        self.program = program; self.pid = pid; self.alive = alive
    }

    /// Whether a process with this id exists (a process we may not signal still exists).
    public static let processExists: @Sendable (Int32) -> Bool = { pid in
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// The program name for this process: the app, or the command.
    public static func defaultProgram() -> String {
        let name = (CommandLine.arguments.first ?? "").split(separator: "/").last.map(String.init) ?? ""
        return name == "BlackTeam" ? "the Black Team app" : name == "black-team" || name == "black-team-cli" ? "the black-team command" : (name.isEmpty ? "Black Team" : name)
    }

    private func read() -> Holder? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: data)
    }

    /// Takes the lock when it is free or stale. Safe to call again. Returns whether this process holds it.
    @discardableResult
    public func acquire() -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        if holding { return true }
        for _ in 0..<3 {
            if let existing = read() {
                if existing.pid == pid && existing.program == program { holding = true; return true }
                if alive(existing.pid) && existing.pid != pid { return false }
                // Stale (its process is gone) or from this same process under another name: take it over.
                if read() == existing { unlink(file) }
            } else if FileManager.default.fileExists(atPath: file) {
                unlink(file) // unreadable: a half-written or damaged lock is stale
            }
            if create() { holding = true; return true }
        }
        return false
    }

    private func create() -> Bool {
        let mine = Holder(pid: pid, program: program, started: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(mine) else { return false }
        let temporary = file + ".\(pid).\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
        defer { unlink(temporary) }
        guard written == data.count else { return false }
        // link() fails if the lock appeared meanwhile, so exactly one process wins.
        return link(temporary, file) == 0
    }

    /// Who else holds the lock now, if anyone alive does.
    public func otherHolder() -> Holder? {
        mutex.lock(); defer { mutex.unlock() }
        if holding { return nil }
        guard let existing = read(), existing.pid != pid, alive(existing.pid) else { return nil }
        return existing
    }

    /// The one-time notice for the second process; nil when this process holds the lock or the notice was already given.
    public func noticeOnce() -> String? {
        guard let other = otherHolder() else { return nil }
        mutex.lock(); defer { mutex.unlock() }
        if announced { return nil }
        announced = true
        return "Black Team is also open in \(other.program). Only one of them can run your local model at a time."
    }

    /// Called before a local model is started. Retries the lock (the other program may have closed). Returns the refusal, or nil to go on.
    public func refusalForLocalModel() -> String? {
        if acquire() { return nil }
        guard let other = otherHolder() else { return nil }
        return "Your local model is in use by \(other.program). Stop it there, or use a cloud model or a subscription agent here."
    }

    /// Gives the lock up (only if this process holds it). Called when the engine shuts down.
    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard holding else { return }
        holding = false
        if let existing = read(), existing.pid == pid { unlink(file) }
    }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return holding }
}
