#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif

// The two C libraries Linux builds use (glibc, and musl for the fully static program) differ in a few spellings; these hide that.
#if canImport(Glibc)
let posixSockStream = Int32(SOCK_STREAM.rawValue)
#else
let posixSockStream = Int32(SOCK_STREAM)
#endif
func posixClose(_ fd: Int32) { close(fd) }
func posixSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int { send(fd, buffer, count, flags) }

// The Linux readout: the kernel's own files under /proc and /sys, as lib/system.cjs reads them, so
// the figures match `lscpu`, `free` and `df`. A missing file leaves that value out. The roots can
// be given so tests can feed a made-up tree.

extension SystemInfo {
    /// The bytes of a file read in chunks: /proc and /sys files report a size of 0, so the size cannot be trusted.
    static func readBytes(_ path: String, limit: Int = 1 << 22) -> Data? {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return nil }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while data.count < limit {
            let count = cRead(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return data.isEmpty ? nil : data }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    static func readText(_ path: String) -> String {
        guard let data = readBytes(path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func integer(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first capture group of a multi-line pattern in `text`.
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Physical cores against the threads the scheduler sees.
    public static func cpuTopology(sysRoot: String = "/sys", procRoot: String = "/proc") -> CPUInfo {
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let base = sysRoot + "/devices/system/cpu"
        let listed = listDirectory(base).filter { $0.range(of: #"^cpu\d+$"#, options: .regularExpression) != nil }.sorted()
        var cores = Set<String>(), sockets = Set<String>()
        for cpu in listed {
            if readText("\(base)/\(cpu)/online").trimmingCharacters(in: .whitespacesAndNewlines) == "0" { continue }
            let core = readText("\(base)/\(cpu)/topology/core_id").trimmingCharacters(in: .whitespacesAndNewlines)
            let socket = readText("\(base)/\(cpu)/topology/physical_package_id").trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty { continue }
            cores.insert("\(socket):\(core)")
            sockets.insert(socket)
        }
        let info = readText(procRoot + "/cpuinfo")
        let brand = firstMatch(#"^model name\s*:\s*(.+)$"#, in: info) ?? firstMatch(#"^Model\s*:\s*(.+)$"#, in: info) ?? firstMatch(#"^Hardware\s*:\s*(.+)$"#, in: info)
        // Current speed, averaged over threads; the governor moves it with load.
        var speeds = listed.compactMap { integer(readText("\(base)/\($0)/cpufreq/scaling_cur_freq")) }.filter { $0 > 0 }.map { $0 / 1000 }
        if speeds.isEmpty, let regex = try? NSRegularExpression(pattern: #"^cpu MHz\s*:\s*([\d.]+)"#, options: [.anchorsMatchLines]) {
            speeds = regex.matches(in: info, range: NSRange(info.startIndex..., in: info)).compactMap { match in
                Range(match.range(at: 1), in: info).flatMap { Double(info[$0]) }
            }
        }
        let mhz = speeds.isEmpty ? nil : Int((speeds.reduce(0, +) / Double(speeds.count)).rounded())
        let name = cleanCPUName(brand ?? "")
        return CPUInfo(name: name.isEmpty ? "Unknown CPU" : name, threads: threads, cores: cores.isEmpty ? threads : cores.count,
                       sockets: sockets.isEmpty ? 1 : sockets.count, mhz: mhz, performanceCores: nil, efficiencyCores: nil)
    }

    /// MemAvailable is what the kernel can hand out: free pages plus cache it can drop.
    public static func memoryInfo(procRoot: String = "/proc") -> MemoryInfo {
        let text = readText(procRoot + "/meminfo")
        func kb(_ key: String) -> Int? { firstMatch("^\(key):\\s*(\\d+)", in: text).flatMap { Int($0) }.map { $0 * 1024 } }
        let total = kb("MemTotal") ?? Int(ProcessInfo.processInfo.physicalMemory)
        let available = kb("MemAvailable") ?? kb("MemFree") ?? total / 2
        let swapTotal = kb("SwapTotal") ?? 0, swapFree = kb("SwapFree") ?? 0
        return MemoryInfo(total: total, available: available, free: kb("MemFree") ?? available, used: max(0, total - available),
                          swapTotal: swapTotal, swapUsed: max(0, swapTotal - swapFree))
    }

    /// The CPU package temperature, from the sensor driver Intel and AMD chips expose.
    public static func cpuTemperature(sysRoot: String = "/sys") -> CPUTemperature? {
        let hwmon = sysRoot + "/class/hwmon"
        let sensors: Set<String> = ["coretemp", "k10temp", "zenpower", "cpu_thermal", "cpu-thermal"]
        for device in listDirectory(hwmon).sorted() {
            let dir = hwmon + "/" + device
            guard sensors.contains(readText(dir + "/name").trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let inputs = listDirectory(dir).filter { $0.range(of: #"^temp\d+_input$"#, options: .regularExpression) != nil }.sorted()
            // Prefer the package reading over a single core's.
            let labelled = inputs.first { readText(dir + "/" + $0.replacingOccurrences(of: "_input", with: "_label")).range(of: "package|tctl|tdie", options: [.regularExpression, .caseInsensitive]) != nil }
            if let pick = labelled ?? inputs.first, let value = integer(readText(dir + "/" + pick)) {
                return CPUTemperature(celsius: Int((value / 1000).rounded()), source: "cpu")
            }
        }
        let zones = sysRoot + "/class/thermal"
        for zone in listDirectory(zones).filter({ $0.hasPrefix("thermal_zone") }).sorted() {
            guard readText("\(zones)/\(zone)/type").range(of: "x86_pkg_temp|cpu[-_]thermal|soc[-_]thermal", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            if let value = integer(readText("\(zones)/\(zone)/temp")) { return CPUTemperature(celsius: Int((value / 1000).rounded()), source: "cpu") }
        }
        return nil
    }

    /// Resident and swapped memory of one process, such as the model server.
    public static func processMemory(_ pid: Int, procRoot: String = "/proc") -> ProcessMemory? {
        guard pid > 0 else { return nil }
        let text = readText("\(procRoot)/\(pid)/status")
        if text.isEmpty { return nil }
        func kb(_ key: String) -> Int { (firstMatch("^\(key):\\s*(\\d+)", in: text).flatMap { Int($0) } ?? 0) * 1024 }
        return ProcessMemory(pid: pid, resident: kb("VmRSS"), swapped: kb("VmSwap"))
    }

    /// Running processes with their arguments, found lazily. Processes that cannot be read are skipped.
    public static func runningProcesses() -> AnySequence<ProcessEntry> { runningProcesses(procRoot: "/proc") }

    static func runningProcesses(procRoot: String) -> AnySequence<ProcessEntry> {
        let ids = listDirectory(procRoot).compactMap { Int($0) }.prefix(20000)
        let found = ids.lazy.compactMap { pid -> ProcessEntry? in
            guard let data = readBytes("\(procRoot)/\(pid)/cmdline", limit: 1 << 20) else { return nil }
            let argv = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
            return argv.isEmpty ? nil : ProcessEntry(pid: pid, argv: argv)
        }
        return AnySequence(found)
    }

    /// The user's own model server listening on a port, found by its command line.
    public static func serverProcess(_ port: Int, processes: () -> AnySequence<ProcessEntry> = { SystemInfo.runningProcesses() }) -> Int? {
        guard port > 0 else { return nil }
        return processes().first(where: { serverMatches(argv: $0.argv, port: port) })?.pid
    }

    /// Raw CPU time counters for the whole machine, as one entry (irq time counts as system time).
    public static func cpuTicks() -> [CPUTicks] { cpuTicks(procRoot: "/proc") }

    static func cpuTicks(procRoot: String) -> [CPUTicks] {
        let text = readText(procRoot + "/stat")
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return [] }
        let f = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard f.count >= 4 else { return [] }
        let irq = (f.count > 5 ? f[5] : 0) + (f.count > 6 ? f[6] : 0)
        return [CPUTicks(user: f[0], nice: f[1], system: f[2] + irq, idle: f[3])]
    }

    /// Space on the volume holding `path` (or its nearest existing parent).
    public static func diskSpace(at path: String) -> DiskInfo? {
        var probe = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: probe) && probe != "/" { probe = (probe as NSString).deletingLastPathComponent }
        var stat = statvfs()
        guard statvfs(probe, &stat) == 0 else { return nil }
        let size = Int(stat.f_frsize)
        return DiskInfo(path: probe, total: Int(stat.f_blocks) * size, free: Int(stat.f_bfree) * size, available: Int(stat.f_bavail) * size)
    }
}
#endif
