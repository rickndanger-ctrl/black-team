#if os(Linux)
import XCTest
@testable import BlackTeamKit

/// The Linux readout, fed made-up /proc and /sys trees (the cases of tests/system.test.cjs).
final class SystemLinuxTests: XCTestCase {
    private func put(_ file: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func testCountsPhysicalCoresSeparatelyFromThreadsAndReadsTheChipNameAndSpeed() throws {
        let root = makeTemporaryFolder(self), sys = root + "/sys", proc = root + "/proc"
        // Two cores with two threads each, one thread offline, plus a second socket with one core.
        for (cpu, socket, core) in [(0, 0, 0), (1, 0, 0), (2, 0, 1), (3, 0, 1), (4, 1, 0)] {
            let base = "\(sys)/devices/system/cpu/cpu\(cpu)"
            try put(base + "/topology/core_id", "\(core)\n")
            try put(base + "/topology/physical_package_id", "\(socket)\n")
            try put(base + "/cpufreq/scaling_cur_freq", cpu == 3 ? "0\n" : "2400000\n")
        }
        try put(sys + "/devices/system/cpu/cpu3/online", "0\n")
        try put(proc + "/cpuinfo", "processor\t: 0\nmodel name\t: Intel(R) Core(TM) i7-10810U CPU @ 1.10GHz\ncpu MHz\t\t: 900.000\n")
        let cpu = SystemInfo.cpuTopology(sysRoot: sys, procRoot: proc)
        XCTAssertEqual(cpu.name, "Intel Core i7-10810U")
        XCTAssertEqual(cpu.cores, 3)
        XCTAssertEqual(cpu.sockets, 2)
        XCTAssertEqual(cpu.mhz, 2400)
        XCTAssertEqual(cpu.threads, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertNil(cpu.performanceCores)
        // Without the sysfs layout the count falls back to threads rather than claiming a number.
        let bare = SystemInfo.cpuTopology(sysRoot: root + "/none", procRoot: root + "/none")
        XCTAssertEqual(bare.cores, bare.threads)
        XCTAssertEqual(bare.sockets, 1)
        XCTAssertEqual(bare.name, "Unknown CPU")
        // The speed falls back to the figures in cpuinfo when cpufreq is missing.
        let onlyInfo = root + "/info"
        try put(onlyInfo + "/cpuinfo", "model name\t: AMD Ryzen 7\ncpu MHz\t\t: 1000.0\ncpu MHz\t\t: 3000.0\n")
        XCTAssertEqual(SystemInfo.cpuTopology(sysRoot: root + "/none", procRoot: onlyInfo).mhz, 2000)
    }

    func testMemoryComesFromMeminfoWithAvailableMeaningWhatTheKernelCanHandOut() throws {
        let proc = makeTemporaryFolder(self) + "/proc"
        try put(proc + "/meminfo", "MemTotal:       48914564 kB\nMemFree:         4186292 kB\nMemAvailable:   12820388 kB\nSwapTotal:      81362636 kB\nSwapFree:       79079244 kB\n")
        XCTAssertEqual(SystemInfo.memoryInfo(procRoot: proc), MemoryInfo(total: 48914564 * 1024, available: 12820388 * 1024, free: 4186292 * 1024,
                                                                          used: (48914564 - 12820388) * 1024, swapTotal: 81362636 * 1024, swapUsed: (81362636 - 79079244) * 1024))
        let fallback = SystemInfo.memoryInfo(procRoot: proc + "/none")
        XCTAssertEqual(fallback.total, Int(ProcessInfo.processInfo.physicalMemory))
        XCTAssertEqual(fallback.swapUsed, 0)
    }

    func testCPUTemperaturePrefersThePackageSensorAndOtherwiseACPUThermalZone() throws {
        let sys = makeTemporaryFolder(self) + "/sys"
        try put(sys + "/class/hwmon/hwmon0/name", "acpitz\n")
        try put(sys + "/class/hwmon/hwmon0/temp1_input", "25000\n")
        try put(sys + "/class/hwmon/hwmon1/name", "coretemp\n")
        try put(sys + "/class/hwmon/hwmon1/temp1_label", "Package id 0\n")
        try put(sys + "/class/hwmon/hwmon1/temp1_input", "41000\n")
        try put(sys + "/class/hwmon/hwmon1/temp2_label", "Core 0\n")
        try put(sys + "/class/hwmon/hwmon1/temp2_input", "39000\n")
        XCTAssertEqual(SystemInfo.cpuTemperature(sysRoot: sys), CPUTemperature(celsius: 41, source: "cpu"))
        let arm = sys + "/arm"
        try put(arm + "/class/thermal/thermal_zone0/type", "cpu-thermal\n")
        try put(arm + "/class/thermal/thermal_zone0/temp", "52500\n")
        XCTAssertEqual(SystemInfo.cpuTemperature(sysRoot: arm), CPUTemperature(celsius: 53, source: "cpu"))
        XCTAssertNil(SystemInfo.cpuTemperature(sysRoot: sys + "/none"))
    }

    func testFindsTheModelServerOnAPortAndReadsHowMuchMemoryItHolds() throws {
        let proc = makeTemporaryFolder(self) + "/proc"
        try put(proc + "/41/cmdline", ["/opt/llama/llama-server", "-m", "/m/a.gguf", "--port", "18081"].joined(separator: "\0") + "\0")
        try put(proc + "/41/status", "Name:\tllama-server\nVmRSS:\t27658952 kB\nVmSwap:\t  677328 kB\n")
        try put(proc + "/42/cmdline", ["ollama", "serve"].joined(separator: "\0") + "\0")
        try put(proc + "/43/cmdline", ["/usr/bin/python3", "fake-server", "--port", "18080"].joined(separator: "\0") + "\0")
        try put(proc + "/self/cmdline", "ignored\0")
        let processes: () -> AnySequence<ProcessEntry> = { SystemInfo.runningProcesses(procRoot: proc) }
        XCTAssertEqual(SystemInfo.serverProcess(18081, processes: processes), 41)
        XCTAssertEqual(SystemInfo.serverProcess(11434, processes: processes), 42)
        XCTAssertNil(SystemInfo.serverProcess(18080, processes: processes))
        XCTAssertNil(SystemInfo.serverProcess(0, processes: processes))
        XCTAssertEqual(SystemInfo.processMemory(41, procRoot: proc), ProcessMemory(pid: 41, resident: 27658952 * 1024, swapped: 677328 * 1024))
        XCTAssertNil(SystemInfo.processMemory(99, procRoot: proc))
        XCTAssertNil(SystemInfo.processMemory(0, procRoot: proc))
        XCTAssertNil(SystemInfo.processMemory(-5, procRoot: proc))
        let found = runningServers(processes: processes, executablePath: { $0 == 41 ? "/opt/llama/llama-server" : nil })
        XCTAssertEqual(found.first { $0.port == 18081 }, RunningServer(port: 18081, file: "/m/a.gguf", executable: "/opt/llama/llama-server"))
    }

    func testCPUTicksAreReadFromTheAggregateLineOfProcStat() throws {
        let proc = makeTemporaryFolder(self) + "/proc"
        try put(proc + "/stat", "cpu  100 20 30 400 50 6 7 0 0 0\ncpu0 50 10 15 200 25 3 3 0 0 0\nintr 1\n")
        XCTAssertEqual(SystemInfo.cpuTicks(procRoot: proc), [CPUTicks(user: 100, nice: 20, system: 43, idle: 400)])
        XCTAssertEqual(SystemInfo.cpuTicks(procRoot: proc + "/none"), [])
    }
}
#endif
