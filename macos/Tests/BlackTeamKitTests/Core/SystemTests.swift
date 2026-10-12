import XCTest
@testable import BlackTeamKit

final class SystemTests: XCTestCase {
    func testTopologyCleansTheNameAndKeepsCoreKinds() {
        let intel = SystemInfo.makeTopology(brand: "Intel(R) Core(TM) i7-10810U CPU @ 1.10GHz", logical: 12, physical: 6, packages: 1, hertz: 2_400_000_000, performance: nil, efficiency: nil)
        XCTAssertEqual(intel, CPUInfo(name: "Intel Core i7-10810U", threads: 12, cores: 6, sockets: 1, mhz: 2400, performanceCores: nil, efficiencyCores: nil))
        let apple = SystemInfo.makeTopology(brand: "Apple M2 Pro", logical: 12, physical: 12, packages: nil, hertz: nil, performance: 8, efficiency: 4)
        XCTAssertEqual(apple.name, "Apple M2 Pro"); XCTAssertEqual(apple.sockets, 1); XCTAssertNil(apple.mhz)
        XCTAssertEqual(apple.performanceCores, 8); XCTAssertEqual(apple.efficiencyCores, 4)
        // Without figures the count falls back to threads rather than claiming a number.
        let bare = SystemInfo.makeTopology(brand: nil, logical: 8, physical: nil, packages: nil, hertz: nil, performance: nil, efficiency: nil)
        XCTAssertEqual(bare.cores, bare.threads); XCTAssertEqual(bare.sockets, 1); XCTAssertEqual(bare.name, "Unknown CPU")
    }

    func testAvailableMemoryAddsWhatTheSystemCanReuse() {
        let page = 16384
        let memory = SystemInfo.makeMemory(total: 16 * 1024 * 1024 * 1024, pageSize: page, freePages: 1000, inactivePages: 2000, purgeablePages: 300, speculativePages: 200, swapTotal: 4096, swapUsed: 1024)
        XCTAssertEqual(memory.free, 1000 * page)
        XCTAssertEqual(memory.available, 3500 * page)
        XCTAssertEqual(memory.used, 16 * 1024 * 1024 * 1024 - 3500 * page)
        XCTAssertEqual(memory.swapUsed, 1024)
        // Available can never exceed the installed memory.
        XCTAssertEqual(SystemInfo.makeMemory(total: 100, pageSize: 10, freePages: 50, inactivePages: 50, purgeablePages: 0, speculativePages: 0, swapTotal: 0, swapUsed: 0).available, 100)
    }

    func testProcessArgumentsAreReadFromTheKernelBuffer() {
        var buffer: [UInt8] = [4, 0, 0, 0]
        buffer += Array("/opt/llama/llama-server".utf8) + [0, 0, 0]
        for arg in ["/opt/llama/llama-server", "-m", "/m/a.gguf", "--port", "18081"] { buffer += Array(arg.utf8) + [0] }
        buffer += Array("HOME=/Users/x".utf8) + [0]
        // Only argc (4) arguments are returned, never the environment.
        XCTAssertEqual(SystemInfo.parseProcessArguments(buffer), ["/opt/llama/llama-server", "-m", "/m/a.gguf", "--port"])
        buffer[0] = 5
        XCTAssertEqual(SystemInfo.parseProcessArguments(buffer).last, "18081")
        XCTAssertEqual(SystemInfo.parseProcessArguments([]), [])
    }

    func testFindsTheModelServerOnAPort() {
        let processes = AnySequence([
            ProcessEntry(pid: 41, argv: ["/opt/llama/llama-server", "-m", "/m/a.gguf", "--port", "18081"]),
            ProcessEntry(pid: 42, argv: ["ollama", "serve"]),
            ProcessEntry(pid: 43, argv: ["/usr/bin/python3", "fake-server", "--port", "18080"]),
            ProcessEntry(pid: 44, argv: ["llama-server", "--port=18090"]),
        ])
        XCTAssertEqual(SystemInfo.serverProcess(18081, processes: { processes }), 41)
        XCTAssertEqual(SystemInfo.serverProcess(11434, processes: { processes }), 42)
        XCTAssertNil(SystemInfo.serverProcess(18080, processes: { processes }))
        XCTAssertEqual(SystemInfo.serverProcess(18090, processes: { processes }), 44)
        XCTAssertNil(SystemInfo.serverProcess(0, processes: { processes }))
    }

    func testCPUUseIsMeasuredBetweenReadingsAtLeastASecondApart() {
        // Kernel counters only grow: busy and idle time each add up to the clock.
        var clock = 0.0, busy = 0.0
        let sampler = CPUSampler(ticks: { [CPUTicks(user: UInt64(busy), idle: UInt64(clock - busy))] }, now: { clock })
        XCTAssertEqual(sampler.sample(), 0)
        // Half a second later the previous figure is repeated; a second later the delta is measured.
        clock = 500; busy = 250; XCTAssertEqual(sampler.sample(), 0)
        clock = 1000; XCTAssertEqual(sampler.sample(), 25)
        clock = 2000; busy = 1000; XCTAssertEqual(sampler.sample(), 75)
        clock = 3000; XCTAssertEqual(sampler.sample(), 0, "a quiet second reads as idle")
    }

    func testLiveReadingsAreSane() throws {
        let cpu = SystemInfo.cpuTopology()
        XCTAssertGreaterThanOrEqual(cpu.cores, 1)
        XCTAssertGreaterThanOrEqual(cpu.threads, cpu.cores)
        XCTAssertFalse(cpu.name.isEmpty)
        let memory = SystemInfo.memoryInfo()
        XCTAssertGreaterThan(memory.total, 1024 * 1024 * 1024)
        XCTAssertGreaterThan(memory.available, 0)
        XCTAssertLessThanOrEqual(memory.available, memory.total)
        XCTAssertNil(SystemInfo.cpuTemperature())
        let me = SystemInfo.processMemory(Int(getpid()))
        XCTAssertGreaterThan(me?.resident ?? 0, 0)
        XCTAssertNil(SystemInfo.processMemory(0))
        let disk = try XCTUnwrap(SystemInfo.diskSpace(at: NSTemporaryDirectory() + "does-not-exist-yet"))
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertGreaterThanOrEqual(disk.available, 0)
        let sampler = CPUSampler()
        XCTAssertTrue((0...100).contains(sampler.sample()))
        // This test process is among those listed; its own arguments are readable.
        let mine = SystemInfo.runningProcesses().first { $0.pid == Int(getpid()) }
        XCTAssertNotNil(mine)
        XCTAssertFalse(mine?.argv.isEmpty ?? true)
    }
}
