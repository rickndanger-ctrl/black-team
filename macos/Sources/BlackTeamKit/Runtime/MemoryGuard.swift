import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc) || canImport(Musl)
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// Before Black Team starts a model of its own, it checks that the model will fit beside any other
// model server this user is already running. When it will not, it asks instead of starting (which
// would make the computer swap) and never stops the other server unless the person says so.

private let GiB = 1024 * 1024 * 1024

/// The question put to the person: one running model server holds the memory this model needs.
public struct StopApproval: Codable, Equatable, Sendable {
    /// The one process that would be stopped.
    public var pid: Int
    /// The model that process serves (its file name without .gguf).
    public var otherName: String
    /// The model that cannot start while it runs.
    public var modelName: String
    /// What the other model holds, in GB (one decimal).
    public var gigabytes: Double
    /// "<other model name> is using N GB. Stop it to start <this model>?"
    public var question: String

    public init(pid: Int, otherName: String, modelName: String, gigabytes: Double) {
        self.pid = pid; self.otherName = otherName; self.modelName = modelName; self.gigabytes = gigabytes
        self.question = "\(otherName) is using \(String(format: "%.1f", gigabytes)) GB. Stop it to start \(modelName)?"
    }
}

/// Thrown instead of starting a model that would not fit. It is a question, not a failure: its text is the question.
public struct NeedsApprovalError: LocalizedError, Equatable, Sendable {
    public let approval: StopApproval
    public init(_ approval: StopApproval) { self.approval = approval }
    public var errorDescription: String? { approval.question }
}

/// What the check needs from the computer. Everything has a real default; tests pass fakes.
public struct MemoryGuard: Sendable {
    public var processes: @Sendable () -> AnySequence<ProcessEntry>
    public var executablePath: @Sendable (Int) -> String?
    /// The user id that owns a process, or nil when it cannot be read.
    public var owner: @Sendable (Int) -> UInt32?
    public var user: @Sendable () -> UInt32
    public var memory: @Sendable () -> MemoryFigures
    /// Memory a process holds in RAM and swap, in bytes.
    public var held: @Sendable (Int) -> Int?
    /// The part of a process's memory the system counts as free to reuse although the process is using it: a loaded model's
    /// weights are read straight from its file, so the system reports them as available. In bytes; 0 where it cannot be read.
    public var reusable: @Sendable (Int) -> Int
    public var signal: @Sendable (Int32, Int32) -> Void
    public var alive: @Sendable (Int32) -> Bool

    public init(processes: @escaping @Sendable () -> AnySequence<ProcessEntry> = { SystemInfo.runningProcesses() },
                executablePath: @escaping @Sendable (Int) -> String? = { processExecutablePath($0) },
                owner: @escaping @Sendable (Int) -> UInt32? = { processOwner($0) },
                user: @escaping @Sendable () -> UInt32 = { UInt32(getuid()) },
                memory: @escaping @Sendable () -> MemoryFigures = {
                    let info = SystemInfo.memoryInfo()
                    return MemoryFigures(total: info.total, free: info.available)
                },
                held: @escaping @Sendable (Int) -> Int? = { pid in SystemInfo.processMemory(pid).map { $0.resident + $0.swapped } },
                reusable: @escaping @Sendable (Int) -> Int = { reusableMemory($0) },
                signal: @escaping @Sendable (Int32, Int32) -> Void = { _ = kill($0, $1) },
                alive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.processes = processes; self.executablePath = executablePath; self.owner = owner; self.user = user
        self.memory = memory; self.held = held; self.reusable = reusable; self.signal = signal; self.alive = alive
    }

    /// A model server of this user that is running right now: found by its command line, owned by the same user.
    func server(pid: Int) -> RunningServer? {
        guard owner(pid) == user() else { return nil }
        return runningServerProcesses(processes: processes, executablePath: executablePath).first { $0.pid == pid }?.server
    }

    /// The model server whose memory this model needs, or nil when the model fits as things are (or stopping a server would not help).
    /// `modelBytes` is the model file's size; `ownPid` is a process Black Team started itself, never offered.
    func conflict(modelName: String, modelBytes: Int, ownPid: Int? = nil) -> StopApproval? {
        let figures = memory()
        let servers = runningServerProcesses(processes: processes, executablePath: executablePath).filter { $0.pid != ownPid && owner($0.pid) == user() }
        // What another loaded model is reading from its file is in use, though the system calls it available.
        let free = max(0, figures.free - servers.reduce(0) { $0 + reusable($1.pid) })
        let estimate = estimateMemory(modelBytes, totalBytes: figures.total, freeBytes: free)
        // A model that does not fit this computer at all is not helped by stopping anything.
        if !estimate.exceedsFree || estimate.exceedsTotal { return nil }
        var best: (pid: Int, server: RunningServer, bytes: Int)?
        for (pid, server) in servers {
            guard let bytes = held(pid), bytes > 0, free + bytes >= estimate.estimatedBytes else { continue }
            if best == nil || bytes > best!.bytes { best = (pid, server, bytes) }
        }
        guard let best else { return nil }
        let name = best.server.file.isEmpty ? "Another model" : label(best.server.file)
        return StopApproval(pid: best.pid, otherName: name, modelName: modelName, gigabytes: (Double(best.bytes) / Double(GiB) * 10).rounded() / 10)
    }

    /// Sends SIGTERM to the one process and waits up to `timeoutMs` for it to end. Only a model server of this user is signalled.
    func stop(pid: Int, timeoutMs: Int) async throws {
        guard server(pid: pid) != nil else { throw BlackTeamError("That model server is no longer running, or is not yours to stop.") }
        signal(Int32(pid), SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1000
        while alive(Int32(pid)) && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if alive(Int32(pid)) { throw BlackTeamError("The other model did not stop in time. Close it yourself, then try again.") }
    }
}

/// A process's file-backed and shared resident memory on Linux (`RssFile` + `RssShmem`), which `MemAvailable` counts as free. 0 elsewhere.
public func reusableMemory(_ pid: Int) -> Int {
    #if os(Linux)
    guard let text = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) else { return 0 }
    var total = 0
    for line in text.split(separator: "\n") where line.hasPrefix("RssFile:") || line.hasPrefix("RssShmem:") {
        total += (Int(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first ?? "") ?? 0) * 1024
    }
    return total
    #else
    return 0
    #endif
}

/// The user id that owns a process, from the system.
public func processOwner(_ pid: Int) -> UInt32? {
    #if os(Linux)
    var info = stat()
    return stat("/proc/\(pid)", &info) == 0 ? UInt32(info.st_uid) : nil
    #else
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    #endif
}
