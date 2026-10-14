import XCTest
@testable import BlackTeamKit

final class ModelRecommenderTests: XCTestCase {
    let gib: Int64 = 1 << 30

    // The four computers the ranking is checked on.
    var laptop8: HardwareProfile { HardwareProfile(cpuName: "Intel Core i5", cores: 4, totalMemory: 8 * gib, availableMemory: 5 * gib, freeDisk: 200 * gib) }
    var mac16: HardwareProfile {
        HardwareProfile(cpuName: "Apple M2", cores: 8, totalMemory: 16 * gib, availableMemory: 10 * gib, freeDisk: 200 * gib, appleSilicon: true,
                        gpu: .init(name: "Apple M2", vendor: "Apple", vramBytes: nil, vramSource: "shared"), gpuUsable: true)
    }
    var cpu46: HardwareProfile { HardwareProfile(cpuName: "AMD Ryzen 7", cores: 8, totalMemory: 46 * gib, availableMemory: 40 * gib, freeDisk: 500 * gib) }
    var gpu24: HardwareProfile {
        HardwareProfile(cpuName: "AMD Ryzen 9", cores: 12, totalMemory: 32 * gib, availableMemory: 28 * gib, freeDisk: 500 * gib,
                        gpu: .init(name: "NVIDIA GeForce RTX 4090", vendor: "NVIDIA", vramBytes: 24 * gib, vramSource: "pci-window"), gpuUsable: true)
    }

    func recommend(_ hardware: HardwareProfile) -> ModelRecommendations { ModelRecommender.recommend(hardware: hardware) }
    func entry(_ list: ModelRecommendations, _ id: String) throws -> ModelAssessment { try XCTUnwrap(list.models.first { $0.id == id }, id) }

    func testEightGigabyteLaptopGetsASmallModel() throws {
        let list = recommend(laptop8)
        XCTAssertEqual(list.bestID, "qwen3.5-4b")
        XCTAssertEqual(try entry(list, "qwen3.5-4b").fit, .comfortable)
        // The 9B is too big for 8 GB; so is everything larger.
        XCTAssertEqual(try entry(list, "ornith-1.5-9b").fit, .tooBig)
        XCTAssertEqual(try entry(list, "gpt-oss-120b").fit, .tooBig)
        XCTAssertNil(list.codeID, "no tool-calling model of 5 GB or more fits comfortably in 8 GB")
        // Everything that does not fit is last.
        let fits = list.models.map { $0.fit == .tooBig }
        XCTAssertEqual(fits, fits.sorted { !$0 && $1 })
    }

    func testSixteenGigabyteMacPicksOrnithNineBForCode() throws {
        let list = recommend(mac16)
        XCTAssertEqual(list.bestID, "ornith-1.5-9b")   // the model Rick chose for a 16 GB Mac
        XCTAssertEqual(list.codeID, "ornith-1.5-9b")
        XCTAssertEqual(try entry(list, "ornith-1.5-9b").runsOn, "the graphics of this Mac")
        XCTAssertEqual(try entry(list, "qwen3.8-27b").fit, .tooBig)
        // The old rule (60% of memory) agrees.
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 16 * gib).id, "ornith-1.5-9b")
    }

    func testFortySixGigabyteCpuOnlyPrefersTheFastBigModelOverASlowDenseOne() throws {
        let list = recommend(cpu46)
        let best = try entry(list, try XCTUnwrap(list.bestID))
        XCTAssertEqual(best.id, "ornith-1.5-35b-a3b")
        XCTAssertEqual(best.fit, .comfortable)
        XCTAssertEqual(best.runsOn, "the processor")
        // A 27B dense model fits in memory but writes too slowly to be the pick.
        let dense = try entry(list, "qwen3.8-27b")
        XCTAssertEqual(dense.fit, .comfortable)
        XCTAssertLessThan(dense.speed.high, 5)
        XCTAssertNotEqual(list.bestID, "qwen3.8-27b")
        XCTAssertEqual(list.codeID, "ornith-1.5-35b-a3b")
        XCTAssertEqual(try entry(list, "gpt-oss-120b").fit, .tooBig)
    }

    func testTwentyFourGigabyteGraphicsCardRunsLargeModelsOnTheCard() throws {
        let list = recommend(gpu24)
        XCTAssertEqual(list.bestID, "qwen3.8-27b")
        let card = try entry(list, "qwen3.8-27b")
        XCTAssertEqual(card.runsOn, "the graphics card")
        XCTAssertEqual(card.fit, .comfortable)
        XCTAssertGreaterThan(card.speed.low, 10)   // on the card, not at processor speed
        XCTAssertEqual(list.codeID, "qwen3.8-27b")
        XCTAssertEqual(try entry(list, "gpt-oss-120b").fit, .tooBig)
        // A GPU that will not be used (the downloaded llama.cpp is processor-only) ranks on the processor.
        var unused = gpu24; unused.gpuUsable = false
        let onCPU = recommend(unused)
        XCTAssertEqual(try entry(onCPU, "qwen3.8-27b").runsOn, "the processor")
        XCTAssertLessThan(try entry(onCPU, "qwen3.8-27b").speed.high, 6)
    }

    func testFastestIsOnlyNamedWhenItIsAnotherModel() throws {
        for hardware in [laptop8, mac16, cpu46, gpu24] {
            let list = recommend(hardware)
            if let fastest = list.fastestID {
                XCTAssertNotEqual(fastest, list.bestID)
                let top = try entry(list, fastest)
                XCTAssertTrue(top.picks.contains("fastest"))
                XCTAssertGreaterThanOrEqual(top.model.bytes, 2_000_000_000, "the tiny test model is not a recommendation")
            }
            XCTAssertEqual(list.models.filter { $0.picks.contains("best") }.count, list.bestID == nil ? 0 : 1)
        }
    }

    func testNotEnoughDiskKeepsAModelOutOfThePicks() throws {
        var hardware = cpu46
        hardware.freeDisk = 10 * 1_000_000_000
        let list = recommend(hardware)
        XCTAssertFalse(try entry(list, "ornith-1.5-35b-a3b").fitsDisk)
        XCTAssertNotEqual(list.bestID, "ornith-1.5-35b-a3b")
        assertMatch(try entry(list, "ornith-1.5-35b-a3b").reason, "free disk space")
        // Already downloaded needs no space.
        let have = ModelRecommender.recommend(hardware: hardware, installed: { $0.id == "ornith-1.5-35b-a3b" })
        XCTAssertTrue(try entry(have, "ornith-1.5-35b-a3b").fitsDisk)
        XCTAssertTrue(try entry(have, "ornith-1.5-35b-a3b").installed)
    }

    func testSpeedIsAlwaysLabelledAnEstimateAndIsMonotonic() {
        let slow = ModelRecommender.speed(bandwidthGBs: 16, bytesPerWord: 16e9)
        let fast = ModelRecommender.speed(bandwidthGBs: 450, bytesPerWord: 2e9)
        XCTAssertTrue(slow.text.hasSuffix("(estimated)"))
        XCTAssertTrue(fast.text.hasSuffix("(estimated)"))
        XCTAssertLessThan(slow.high, fast.low)
        XCTAssertEqual(slow.label, "very slow")
        XCTAssertEqual(fast.label, "fast")
        XCTAssertEqual(ModelRecommender.speed(bandwidthGBs: 32, bytesPerWord: 5.78e9).label, "steady")   // 9B on 8 cores
        // 1 core against 12: a dense model gets faster with cores up to the memory limit.
        XCTAssertLessThan(ModelRecommender.cpuBandwidth(cores: 1), ModelRecommender.cpuBandwidth(cores: 12))
        XCTAssertEqual(ModelRecommender.cpuBandwidth(cores: 64), 45)
        XCTAssertEqual(ModelRecommender.appleBandwidth("Apple M3 Max"), 400)
        XCTAssertEqual(ModelRecommender.appleBandwidth("Apple M4"), 100)
    }

    func testGoodForAndReasonsArePlain() throws {
        let list = recommend(mac16)
        XCTAssertEqual(try entry(list, "qwen3.5-0.8b").goodFor, ["Chat", "Images"])
        XCTAssertEqual(try entry(list, "ornith-1.5-9b").goodFor, ["Chat", "Code agent (tools)", "Images"])
        XCTAssertEqual(try entry(list, "gpt-oss-20b").goodFor, ["Chat", "Code agent (tools)"])
        for item in list.models { XCTAssertFalse(item.reason.isEmpty); XCTAssertTrue(item.reason.hasSuffix("."), item.reason) }
        XCTAssertTrue(try entry(list, "gpt-oss-120b").reason.hasPrefix("Needs about"))
        assertMatch(list.summary, "8 cores, 16 GB of memory, Apple silicon")
    }

    func testTightWhenOnlyJustFittingAndComfortableNeedsFreeMemory() throws {
        // 12 GB total: the 9B model needs 7.9 GB, above 60% (7.2) but within 85%.
        let small = HardwareProfile(cpuName: "x", cores: 8, totalMemory: 12 * gib, availableMemory: 10 * gib, freeDisk: 100 * gib)
        XCTAssertEqual(try entry(recommend(small), "ornith-1.5-9b").fit, .tight)
        // Plenty of memory in total, but other programs are using it: not comfortable.
        let busy = HardwareProfile(cpuName: "x", cores: 8, totalMemory: 64 * gib, availableMemory: 4 * gib, freeDisk: 100 * gib)
        XCTAssertEqual(try entry(recommend(busy), "ornith-1.5-9b").fit, .tight)
    }

    func testEveryCatalogueModelIsRanked() {
        XCTAssertEqual(recommend(cpu46).models.count, ModelCatalogue.all.count)
        XCTAssertEqual(Set(recommend(cpu46).models.map(\.id)), Set(ModelCatalogue.all.map(\.id)))
    }

    // MARK: Graphics cards from a pretend /sys and /proc

    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bt-gpu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func card(_ name: String, vendor: String, kind: String = "0x030000", files: [String: String] = [:]) throws {
        let device = root.appendingPathComponent("sys/class/drm/\(name)/device", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try vendor.write(to: device.appendingPathComponent("vendor"), atomically: true, encoding: .utf8)
        try kind.write(to: device.appendingPathComponent("class"), atomically: true, encoding: .utf8)
        for (file, text) in files { try text.write(to: device.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }
    func detect() -> HardwareProfile.GPU? { HardwareProfile.linuxGPU(sysRoot: root.path + "/sys", procRoot: root.path + "/proc") }

    func testAmdCardReportsItsExactMemory() throws {
        try card("card0", vendor: "0x1002", files: ["mem_info_vram_total": "25753026560\n"])
        let gpu = try XCTUnwrap(detect())
        XCTAssertEqual(gpu.vendor, "AMD")
        XCTAssertEqual(gpu.vramBytes, 25_753_026_560)
        XCTAssertEqual(gpu.vramSource, "driver")
    }

    func testAmdIntegratedChipIsIgnored() throws {
        try card("card0", vendor: "0x1002", files: ["mem_info_vram_total": "536870912\n"])
        XCTAssertNil(detect())
    }

    func testNvidiaMemoryIsEstimatedFromTheLargestPrefetchableWindow() throws {
        // A 24 GiB card with resizable BAR has a 32 GiB window; three quarters of it is 24 GiB.
        let window = "0x0000000000000000 0x00000007ffffffff 0x000000000014220c\n"
        try card("card1", vendor: "0x10de", kind: "0x030000", files: [
            "resource": "0x00000000ec000000 0x00000000ecffffff 0x0000000000040200\n" + window,
            "uevent": "DRIVER=nvidia\nPCI_SLOT_NAME=0000:01:00.0\n"])
        let info = root.appendingPathComponent("proc/driver/nvidia/gpus/0000:01:00.0", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "Model: \t\t NVIDIA GeForce RTX 4090\nIRQ: 1\n".write(to: info.appendingPathComponent("information"), atomically: true, encoding: .utf8)
        let gpu = try XCTUnwrap(detect())
        XCTAssertEqual(gpu.vendor, "NVIDIA")
        XCTAssertEqual(gpu.name, "NVIDIA GeForce RTX 4090")
        XCTAssertEqual(gpu.vramBytes, 24 * gib)
        XCTAssertEqual(gpu.vramSource, "pci-window")
    }

    func testNvidiaWithoutResizableBarHasUnknownMemory() throws {
        // This laptop: a 256 MiB window says nothing about the card's memory.
        try card("card1", vendor: "0x10de", kind: "0x030200", files: [
            "resource": "0x00000000c0000000 0x00000000cfffffff 0x000000000014220c\n", "uevent": "DRIVER=nvidia\n"])
        let gpu = try XCTUnwrap(detect())
        XCTAssertNil(gpu.vramBytes)
        XCTAssertEqual(gpu.vramSource, "unknown")
        let profile = HardwareProfile(cores: 4, totalMemory: 8 * gib, gpu: gpu)
        XCTAssertFalse(profile.gpuUsable)
        XCTAssertNil(profile.gpuMemory)
    }

    func testTheBiggestCardWinsAndIntelAndNonDisplayDevicesAreNeverCounted() throws {
        try card("card0", vendor: "0x8086")
        try card("card1", vendor: "0x1002", files: ["mem_info_vram_total": "17163091968"])
        try card("card2", vendor: "0x10de", kind: "0x028000")   // a network card
        try card("card0-eDP-1", vendor: "0x1002", files: ["mem_info_vram_total": "99999999999"])   // a connector, not a card
        XCTAssertEqual(detect()?.vramBytes, 17_163_091_968)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sys/class/drm/card1"))
        let intel = try XCTUnwrap(detect())
        XCTAssertEqual(intel.vendor, "Intel")
        XCTAssertNil(intel.vramBytes)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sys/class/drm"))
        XCTAssertNil(detect())
    }

    func testAppleSiliconMemoryBudgetFollowsTheWiredLimit() {
        let small = HardwareProfile(cpuName: "Apple M2", cores: 8, totalMemory: 16 * gib, appleSilicon: true)
        XCTAssertEqual(small.gpuMemory, 16 * gib / 3 * 2)
        let big = HardwareProfile(cpuName: "Apple M3 Max", cores: 12, totalMemory: 64 * gib, appleSilicon: true)
        XCTAssertEqual(big.gpuMemory, 48 * gib)
    }

    func testDetectReadsThisComputerWithoutRunningAnything() {
        let profile = HardwareProfile.detect(dataFolder: root.path)
        XCTAssertGreaterThan(profile.cores, 0)
        XCTAssertGreaterThan(profile.totalMemory, 0)
        XCTAssertNotNil(profile.freeDisk)
        XCTAssertFalse(profile.gpuUsable && !profile.appleSilicon, "a card is not used unless a GPU build of llama.cpp is")
    }
}
