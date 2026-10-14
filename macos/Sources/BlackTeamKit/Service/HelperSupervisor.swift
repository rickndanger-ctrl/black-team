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

// Long-running helper programs the background service keeps alive: started with the service, checked, restarted with a growing wait
// when they stop, and stopped with the service. A helper is described by a `HelperSpec`; the one place that lists them is
// `ServiceHelpers.specs` (Service/ServiceHelpers.swift). Each helper's output goes to `<data>/run/<id>.log`; the folder is private (0700)
// and so are the logs (0600). A helper is started with an executable and an argument list, never through a shell.

public struct HelperSpec: Sendable {
    /// Lower case letters, digits and dashes: used in file names and the screens.
    public var id: String
    /// Plain words for the screens.
    public var name: String
    public var executable: String
    public var arguments: [String]
    /// Added to the service's own environment.
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Says the helper is working, beyond "its process is alive". Nil: alive is healthy.
    public var health: (@Sendable () async -> Bool)?
    public var healthEvery: TimeInterval
    /// This many failed checks in a row restart it.
    public var healthFailures: Int
    /// The wait before the first restart; it doubles after each quick failure, up to `maxBackoff`.
    public var initialBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    /// A helper that ran this long counts as healthy again: the next failure waits `initialBackoff`.
    public var stableAfter: TimeInterval

    public init(id: String, name: String, executable: String, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil,
                health: (@Sendable () async -> Bool)? = nil, healthEvery: TimeInterval = 30, healthFailures: Int = 3,
                initialBackoff: TimeInterval = 2, maxBackoff: TimeInterval = 300, stableAfter: TimeInterval = 60) {
        self.id = id; self.name = name; self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.health = health; self.healthEvery = healthEvery; self.healthFailures = max(1, healthFailures)
        self.initialBackoff = initialBackoff; self.maxBackoff = maxBackoff; self.stableAfter = stableAfter
    }
}

public struct HelperStatus: Equatable, Sendable {
    public var id: String
    public var name: String
    /// "starting", "running", "waiting" (to restart), "stopped" or "failed" (could not be started at all).
    public var state: String
    public var pid: Int32?
    public var restarts: Int
    /// What the last exit looked like, in words.
    public var lastExit: String
    public var backoff: TimeInterval

    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "state": .string(state), "pid": pid.map { .number(Double($0)) } ?? .null,
         "restarts": .number(Double(restarts)), "lastExit": .string(lastExit), "backoff": .number(backoff)]
    }
}

public final class HelperSupervisor: @unchecked Sendable {
    public let folder: String
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let poll: TimeInterval
    private let grace: TimeInterval
    private let lock = NSLock()
    private var specs: [String: HelperSpec] = [:]
    private var order: [String] = []
    private var statuses: [String: HelperStatus] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: Process] = [:]
    private var stopping = false
    private var started = false

    /// `sleep` waits out a restart delay (tests make it instant); `poll` is how often a running helper is looked at; `grace` is how long a
    /// helper has to end after being asked to before it is killed.
    public init(dataFolder: String, sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                poll: TimeInterval = 0.2, grace: TimeInterval = 3) {
        folder = dataFolder + "/run"
        self.sleep = sleep; self.poll = poll; self.grace = grace
    }

    public func logFile(_ id: String) -> String { folder + "/" + id + ".log" }

    /// Adds a helper. If the supervisor is already running, it starts at once.
    public func register(_ spec: HelperSpec) throws {
        guard spec.id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { throw BlackTeamError("A helper\u{2019}s id uses lower case letters, digits and dashes.") }
        guard spec.executable.hasPrefix("/") else { throw BlackTeamError("A helper is started from an absolute path.") }
        lock.lock()
        if specs[spec.id] != nil { lock.unlock(); throw BlackTeamError("A helper named \(spec.id) is already registered.") }
        specs[spec.id] = spec; order.append(spec.id)
        statuses[spec.id] = HelperStatus(id: spec.id, name: spec.name, state: "stopped", pid: nil, restarts: 0, lastExit: "", backoff: 0)
        let run = started && !stopping
        lock.unlock()
        if run { launch(spec.id) }
    }

    /// Starts every registered helper.
    public func start() throws {
        try privateDirectory(folder)
        lock.lock(); started = true; stopping = false; let ids = order; lock.unlock()
        for id in ids { launch(id) }
    }

    /// Ends every helper (asks, then kills what does not end) and waits for them.
    public func stop() async {
        lock.lock(); stopping = true; let running = Array(tasks.values); let live = Array(processes.values); lock.unlock()
        for process in live where process.isRunning { process.terminate() }
        for task in running { task.cancel() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, live.contains(where: { $0.isRunning }) { try? await Task.sleep(nanoseconds: 20_000_000) }
        for process in live where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for task in running { await task.value }
        lock.lock()
        for id in order { statuses[id]?.state = "stopped"; statuses[id]?.pid = nil }
        tasks = [:]; processes = [:]; started = false
        lock.unlock()
    }

    public func status() -> [HelperStatus] { lock.lock(); defer { lock.unlock() }; return order.compactMap { statuses[$0] } }

    /// The last lines a helper wrote.
    public func tail(_ id: String, lines: Int = 100) -> String {
        guard let data = FileManager.default.contents(atPath: logFile(id)) else { return "" }
        let text = String(decoding: data.suffix(256 * 1024), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(max(1, min(lines, 2000))).joined(separator: "\n")
    }

    // MARK: One helper's life

    private func update(_ id: String, _ change: (inout HelperStatus) -> Void) {
        lock.lock(); if var current = statuses[id] { change(&current); statuses[id] = current }; lock.unlock()
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private func launch(_ id: String) {
        lock.lock()
        guard let spec = specs[id], tasks[id] == nil else { lock.unlock(); return }
        let task = Task<Void, Never> { [weak self] in if let self { await self.live(spec) } }
        tasks[id] = task
        lock.unlock()
    }

    /// Opens the helper's log for appending (private); a log over 1 MB is moved aside first.
    private func openLog(_ id: String) -> FileHandle? {
        let path = logFile(id)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_048_576 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Ended, by Foundation's account or the system's (the exit can be reaped before Foundation sees it).
    private static func gone(_ process: Process) -> Bool {
        if !process.isRunning { return true }
        return kill(process.processIdentifier, 0) != 0 && errno == ESRCH
    }

    private func live(_ spec: HelperSpec) async {
        var backoff = spec.initialBackoff
        while !Task.isCancelled && !isStopping {
            update(spec.id) { $0.state = "starting"; $0.pid = nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: spec.executable)
            process.arguments = spec.arguments
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in spec.environment { environment[key] = value }
            process.environment = environment
            if let directory = spec.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            process.standardInput = FileHandle.nullDevice
            let log = openLog(spec.id)
            if let log { process.standardOutput = log; process.standardError = log } else { process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice }
            let began = Date()
            do { try process.run() }
            catch {
                update(spec.id) { $0.state = "waiting"; $0.lastExit = "It could not be started."; $0.restarts += 1; $0.backoff = backoff }
                await sleep(backoff)
                backoff = min(backoff * 2, spec.maxBackoff)
                continue
            }
            lock.lock(); processes[spec.id] = process; lock.unlock()
            update(spec.id) { $0.state = "running"; $0.pid = process.processIdentifier; $0.backoff = 0 }
            var failures = 0
            var lastCheck = Date()
            var unhealthy = false
            while !Self.gone(process) && !Task.isCancelled && !isStopping {
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                if let health = spec.health, Date().timeIntervalSince(lastCheck) >= spec.healthEvery {
                    lastCheck = Date()
                    if await health() { failures = 0 } else {
                        failures += 1
                        if failures >= spec.healthFailures { unhealthy = true; process.terminate(); break }
                    }
                }
            }
            if !Self.gone(process) {
                // Asked to end (stop, or unhealthy): give it a moment, then kill it.
                let deadline = Date().addingTimeInterval(grace)
                while !Self.gone(process), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                if !Self.gone(process) { kill(process.processIdentifier, SIGKILL) }
            }
            // Not waitUntilExit: it blocks a shared thread, and on macOS it never returns when Foundation misses the exit.
            while !Self.gone(process) { try? await Task.sleep(nanoseconds: 20_000_000) }
            lock.lock(); processes[spec.id] = nil; lock.unlock()
            if Task.isCancelled || isStopping { break }
            let ran = Date().timeIntervalSince(began)
            if ran >= spec.stableAfter { backoff = spec.initialBackoff }
            let how = unhealthy ? "It stopped answering and was restarted." : process.isRunning ? "It ended." : process.terminationReason == .exit ? "It ended with status \(process.terminationStatus)." : "It was stopped by signal \(process.terminationStatus)."
            update(spec.id) { $0.state = "waiting"; $0.pid = nil; $0.lastExit = how; $0.restarts += 1; $0.backoff = backoff }
            await sleep(backoff)
            backoff = min(backoff * 2, spec.maxBackoff)
        }
        update(spec.id) { $0.state = "stopped"; $0.pid = nil }
    }
}
