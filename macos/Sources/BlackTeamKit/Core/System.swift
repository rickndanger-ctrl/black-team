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

// What this computer is and how hard it is working, read from the kernel (sysctl and the Mach
// host calls) so the readout matches what Activity Monitor would say. A value that cannot be
// read is left out. Parsing and decisions are separate functions so tests can feed them figures.

public struct CPUInfo: Codable, Equatable, Sendable {
    public var name: String
    public var threads: Int
    public var cores: Int
    public var sockets: Int
    public var mhz: Int?
    /// Performance and efficiency cores on Apple Silicon; nil on other Macs.
    public var performanceCores: Int?
    public var efficiencyCores: Int?
}

public struct MemoryInfo: Codable, Equatable, Sendable {
    public var total: Int
    public var available: Int
    public var free: Int
    public var used: Int
    public var swapTotal: Int
    public var swapUsed: Int
}

public struct CPUTemperature: Codable, Equatable, Sendable {
    public var celsius: Int
    public var source: String
}

public struct ProcessMemory: Codable, Equatable, Sendable {
    public var pid: Int
    public var resident: Int
    public var swapped: Int
}

public struct DiskInfo: Codable, Equatable, Sendable {
    public var path: String
    public var total: Int
    public var free: Int
    public var available: Int
}

public struct ProcessEntry: Sendable {
    public var pid: Int
    public var argv: [String]
    public init(pid: Int, argv: [String]) { self.pid = pid; self.argv = argv }
}

/// One CPU's time counters, as the kernel counts them (they only grow).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64, nice: UInt64, system: UInt64, idle: UInt64
    public init(user: UInt64 = 0, nice: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0) {
        self.user = user; self.nice = nice; self.system = system; self.idle = idle
    }
}

/// Whole-system CPU use between two readings. Readings closer than a second apart
/// are too noisy to mean anything, so the last figure is kept until enough time passes.
public final class CPUSampler: @unchecked Sendable {
    private let ticks: () -> [CPUTicks]
    private let now: () -> Double
    private let minimumMs: Double
    private var previous: [CPUTicks]
    private var at: Double
    private var last = 0
    private let lock = NSLock()

    public init(ticks: @escaping () -> [CPUTicks] = SystemInfo.cpuTicks, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, minimumMs: Double = 1000) {
        self.ticks = ticks; self.now = now; self.minimumMs = minimumMs
        previous = ticks(); at = now()
    }

    /// Percent of CPU busy since the last measured reading, 0 to 100.
    public func sample() -> Int {
        lock.lock(); defer { lock.unlock() }
        if now() - at < minimumMs { return last }
        let current = ticks()
        var total = 0.0, idle = 0.0
        for (index, cpu) in current.enumerated() {
            let before = index < previous.count ? previous[index] : CPUTicks()
            let delta: (UInt64, UInt64) -> Double = { new, old in new >= old ? Double(new - old) : 0 }
            let parts = [delta(cpu.user, before.user), delta(cpu.nice, before.nice), delta(cpu.system, before.system), delta(cpu.idle, before.idle)]
            total += parts.reduce(0, +)
            idle += parts[3]
        }
        previous = current; at = now()
        if total > 0 { last = max(0, min(100, Int((100 * (1 - idle / total)).rounded()))) }
        return last
    }
}

public enum SystemInfo {
    // MARK: Pure logic

    /// "Intel(R) Core(TM) i7-10810U CPU @ 1.10GHz" becomes "Intel Core i7-10810U".
    public static func cleanCPUName(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(R\)|\(TM\)|CPU\s+@.*$"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func makeTopology(brand: String?, logical: Int?, physical: Int?, packages: Int?, hertz: Int?, performance: Int?, efficiency: Int?) -> CPUInfo {
        let threads = max(1, logical ?? ProcessInfo.processInfo.activeProcessorCount)
        let name = cleanCPUName(brand ?? "")
        return CPUInfo(name: name.isEmpty ? "Unknown CPU" : name, threads: threads, cores: (physical ?? 0) > 0 ? physical! : threads,
                       sockets: (packages ?? 0) > 0 ? packages! : 1, mhz: (hertz ?? 0) > 0 ? hertz! / 1_000_000 : nil,
                       performanceCores: performance, efficiencyCores: efficiency)
    }

    /// Available stands in for Linux's MemAvailable: free pages plus those the system can reuse
    /// at once (inactive, purgeable and speculative). `freePages` excludes speculative pages.
    public static func makeMemory(total: Int, pageSize: Int, freePages: Int, inactivePages: Int, purgeablePages: Int, speculativePages: Int, swapTotal: Int, swapUsed: Int) -> MemoryInfo {
        let free = min(total, freePages * pageSize)
        let available = min(total, (freePages + inactivePages + purgeablePages + speculativePages) * pageSize)
        return MemoryInfo(total: total, available: available, free: free, used: max(0, total - available), swapTotal: swapTotal, swapUsed: min(swapTotal, swapUsed))
    }

    /// The arguments in a KERN_PROCARGS2 buffer: a 32-bit count, the program path, padding, then the arguments.
    public static func parseProcessArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let count = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var at = 4
        while at < bytes.count && bytes[at] != 0 { at += 1 }
        while at < bytes.count && bytes[at] == 0 { at += 1 }
        var out: [String] = []
        while out.count < count && at < bytes.count {
            var end = at
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            out.append(String(decoding: bytes[at..<end], as: UTF8.self))
            at = end + 1
        }
        return out
    }

    /// Whether a command line is a local model server listening on this port.
    public static func serverMatches(argv: [String], port: Int) -> Bool {
        guard let first = argv.first else { return false }
        let name = (first as NSString).lastPathComponent
        guard ["llama-server", "llama-cpp-server", "ollama", "lms", "koboldcpp", "local-ai", "tabbyapi", "jan"].contains(name) else { return false }
        var value: String?
        if let given = argv.indices.first(where: { $0 > 0 && (argv[$0] == "--port" || argv[$0] == "-p") }) {
            value = given + 1 < argv.count ? argv[given + 1] : nil
        } else {
            value = argv.first(where: { $0.hasPrefix("--port=") }).map { String($0.dropFirst(7)) }
        }
        if let value { return Double(value.trimmingCharacters(in: .whitespaces)) == Double(port) }
        return port == ["ollama": 11434, "lms": 1234][name]
    }

    // MARK: Reading the system

    /// Whether this is an Apple Silicon Mac (the llama.cpp Metal build then runs on the GPU).
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Physical cores against threads, the chip name, and the clock where macOS reports one (Intel only).
    public static func cpuTopology() -> CPUInfo {
        makeTopology(brand: sysctlString("machdep.cpu.brand_string"), logical: sysctlInt("hw.logicalcpu"), physical: sysctlInt("hw.physicalcpu"),
                     packages: sysctlInt("hw.packages"), hertz: sysctlInt("hw.cpufrequency"),
                     performance: sysctlInt("hw.perflevel0.physicalcpu"), efficiency: sysctlInt("hw.perflevel1.physicalcpu"))
    }

    public static func memoryInfo() -> MemoryInfo {
        let total = Int(ProcessInfo.processInfo.physicalMemory)
        var swapTotal = 0, swapUsed = 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { swapTotal = Int(swap.xsu_total); swapUsed = Int(swap.xsu_used) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else {
            return MemoryInfo(total: total, available: total / 2, free: total / 2, used: total / 2, swapTotal: swapTotal, swapUsed: min(swapTotal, swapUsed))
        }
        let page = sysctlInt("hw.pagesize") ?? 16384
        let speculative = Int(stats.speculative_count)
        return makeMemory(total: total, pageSize: page, freePages: max(0, Int(stats.free_count) - speculative), inactivePages: Int(stats.inactive_count),
                          purgeablePages: Int(stats.purgeable_count), speculativePages: speculative, swapTotal: swapTotal, swapUsed: swapUsed)
    }

    /// macOS has no public CPU temperature, so there is none to show.
    public static func cpuTemperature() -> CPUTemperature? { nil }

    /// Resident memory of one process, such as the model server. macOS gives no per-process swap figure.
    public static func processMemory(_ pid: Int) -> ProcessMemory? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V0, $0) }
        }
        guard result == 0 else { return nil }
        return ProcessMemory(pid: pid, resident: Int(info.ri_resident_size), swapped: 0)
    }

    static func processIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 64
        var list = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    /// Running processes with their arguments, found lazily. Processes of other users are skipped.
    public static func runningProcesses() -> AnySequence<ProcessEntry> {
        var maximum = Int32(0)
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return AnySequence([]) }
        let capacity = Int(maximum)
        let found = processIDs().prefix(20000).lazy.compactMap { pid -> ProcessEntry? in
            var buffer = [UInt8](repeating: 0, count: capacity)
            var length = capacity
            var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            guard sysctl(&query, 3, &buffer, &length, nil, 0) == 0 else { return nil }
            return ProcessEntry(pid: Int(pid), argv: parseProcessArguments(Array(buffer.prefix(length))))
        }
        return AnySequence(found)
    }

    /// The user's own model server listening on a port, found by its command line.
    public static func serverProcess(_ port: Int, processes: () -> AnySequence<ProcessEntry> = SystemInfo.runningProcesses) -> Int? {
        guard port > 0 else { return nil }
        return processes().first(where: { serverMatches(argv: $0.argv, port: port) })?.pid
    }

    /// Raw CPU time counters for the whole machine, as one entry.
    public static func cpuTicks() -> [CPUTicks] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return [] }
        return [CPUTicks(user: UInt64(info.cpu_ticks.0), nice: UInt64(info.cpu_ticks.3), system: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2))]
    }

    /// Space on the volume holding `path` (or its nearest existing parent).
    public static func diskSpace(at path: String) -> DiskInfo? {
        var probe = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: probe) && probe != "/" { probe = (probe as NSString).deletingLastPathComponent }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: probe).resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacity ?? 0
        let available = values.volumeAvailableCapacityForImportantUsage.map { Int($0) } ?? free
        return DiskInfo(path: probe, total: total, free: free, available: available)
    }
    #endif
}
