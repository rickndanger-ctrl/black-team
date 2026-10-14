import Foundation

// What this computer can run, read from the kernel and sysfs only. Nothing here runs a program: no nvidia-smi, no lspci, no
// system_profiler. A figure that cannot be read is left out, and the recommendation then says so rather than guessing.

public struct HardwareProfile: Codable, Equatable, Sendable {
    /// A graphics processor that could hold a model's weights.
    public struct GPU: Codable, Equatable, Sendable {
        public var name: String
        /// "Apple", "NVIDIA", "AMD" or "Intel".
        public var vendor: String
        /// Memory the card has for itself. Nil on Apple silicon (memory is shared) and when it could not be read.
        public var vramBytes: Int64?
        /// Where `vramBytes` came from: "driver" (read from the driver), "pci-window" (estimated from the card's PCI memory window)
        /// or "shared" (Apple silicon).
        public var vramSource: String
        public init(name: String, vendor: String, vramBytes: Int64?, vramSource: String) {
            self.name = name; self.vendor = vendor; self.vramBytes = vramBytes; self.vramSource = vramSource
        }
    }

    public var cpuName: String
    /// Physical cores, not threads.
    public var cores: Int
    public var totalMemory: Int64
    public var availableMemory: Int64
    /// Free space in the folder models are saved to. Nil when it could not be read.
    public var freeDisk: Int64?
    public var appleSilicon: Bool
    public var gpu: GPU?
    /// Whether the llama.cpp that will run the model can use `gpu`. True on Apple silicon (the Metal build). On Linux the llama.cpp
    /// Black Team downloads is the processor-only build, so a graphics card is only used when the person brought a GPU build.
    public var gpuUsable: Bool

    public init(cpuName: String = "", cores: Int, totalMemory: Int64, availableMemory: Int64? = nil, freeDisk: Int64? = nil,
                appleSilicon: Bool = false, gpu: GPU? = nil, gpuUsable: Bool? = nil) {
        self.cpuName = cpuName; self.cores = max(1, cores); self.totalMemory = totalMemory
        self.availableMemory = availableMemory ?? totalMemory; self.freeDisk = freeDisk
        self.appleSilicon = appleSilicon; self.gpu = gpu
        self.gpuUsable = gpuUsable ?? (appleSilicon || (gpu?.vramBytes ?? 0) > 0)
    }

    /// Memory a model can use on the graphics card: the card's own, or on Apple silicon the share macOS lets the GPU wire
    /// (about two thirds of memory up to 36 GiB, three quarters above). Nil when the GPU is not usable or its memory is unknown.
    public var gpuMemory: Int64? {
        guard gpuUsable else { return nil }
        if appleSilicon {
            let gib: Int64 = 1 << 30
            return totalMemory <= 36 * gib ? totalMemory / 3 * 2 : totalMemory / 4 * 3
        }
        return gpu?.vramBytes
    }

    /// Reads this computer. `dataFolder` is where models are saved (for the free space).
    /// `gpuBuild` says whether a GPU-capable llama.cpp is in use on Linux; the downloaded one is not.
    public static func detect(dataFolder: String, gpuBuild: Bool = false) -> HardwareProfile {
        let cpu = SystemInfo.cpuTopology()
        let memory = SystemInfo.memoryInfo()
        let models = URL(fileURLWithPath: dataFolder).appendingPathComponent("models", isDirectory: true)
        let disk = Downloader.systemFreeSpace(models)
        #if os(macOS) && arch(arm64)
        let apple = true
        #else
        let apple = false
        #endif
        if apple {
            return HardwareProfile(cpuName: cpu.name, cores: cpu.cores, totalMemory: Int64(memory.total), availableMemory: Int64(memory.available),
                                   freeDisk: disk, appleSilicon: true,
                                   gpu: GPU(name: cpu.name, vendor: "Apple", vramBytes: nil, vramSource: "shared"), gpuUsable: true)
        }
        #if os(Linux)
        let card = linuxGPU()
        #else
        let card: GPU? = nil
        #endif
        return HardwareProfile(cpuName: cpu.name, cores: cpu.cores, totalMemory: Int64(memory.total), availableMemory: Int64(memory.available),
                               freeDisk: disk, appleSilicon: false, gpu: card, gpuUsable: gpuBuild && (card?.vramBytes ?? 0) > 0)
    }

    // MARK: Linux graphics cards (sysfs and /proc only)

    private static func text(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The most capable discrete graphics card, read from `/sys/class/drm` and `/proc/driver/nvidia`.
    /// - AMD: the driver publishes `mem_info_vram_total`, which is exact. An integrated chip (under 2 GiB of its own) is ignored.
    /// - NVIDIA: the driver publishes no memory size anywhere in sysfs or /proc, so it is estimated from the card's largest
    ///   prefetchable PCI memory window (which, with resizable BAR, is the next power of two above the card's memory): three
    ///   quarters of the window, which gives the exact size for 12, 24 and 48 GiB cards and an underestimate for others. A window
    ///   under 4 GiB (no resizable BAR) says nothing, so the memory is left unknown.
    /// - Intel: noted, never counted.
    public static func linuxGPU(sysRoot: String = "/sys", procRoot: String = "/proc") -> GPU? {
        let drm = sysRoot + "/class/drm"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: drm)) ?? []).filter { $0.range(of: #"^card\d+$"#, options: .regularExpression) != nil }.sorted()
        var best: GPU?
        for card in names {
            let device = drm + "/" + card + "/device"
            let vendor = text(device + "/vendor").lowercased()
            let kind = text(device + "/class").lowercased()
            guard kind.hasPrefix("0x03") else { continue }   // a display controller or 3D controller
            var found: GPU?
            switch vendor {
            case "0x1002":
                let vram = Int64(text(device + "/mem_info_vram_total")) ?? 0
                guard vram >= 2 << 30 else { continue }
                found = GPU(name: "AMD graphics card", vendor: "AMD", vramBytes: vram, vramSource: "driver")
            case "0x10de":
                let model = nvidiaModel(procRoot: procRoot, slot: slotName(device))
                let window = largestPrefetchableWindow(device + "/resource")
                let vram: Int64? = window >= 4 << 30 ? window / 4 * 3 : nil
                found = GPU(name: model.isEmpty ? "NVIDIA graphics card" : model, vendor: "NVIDIA", vramBytes: vram, vramSource: vram == nil ? "unknown" : "pci-window")
            case "0x8086":
                found = GPU(name: "Intel graphics", vendor: "Intel", vramBytes: nil, vramSource: "unknown")
            default:
                continue
            }
            if let found, (found.vramBytes ?? 0) > (best?.vramBytes ?? -1) || best == nil { best = found }
        }
        return best
    }

    private static func slotName(_ device: String) -> String {
        for line in text(device + "/uevent").split(separator: "\n") where line.hasPrefix("PCI_SLOT_NAME=") { return String(line.dropFirst(14)).lowercased() }
        return ""
    }

    private static func nvidiaModel(procRoot: String, slot: String) -> String {
        let folder = procRoot + "/driver/nvidia/gpus"
        for entry in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where slot.isEmpty || entry.lowercased() == slot {
            for line in text(folder + "/" + entry + "/information").split(separator: "\n") where line.hasPrefix("Model:") {
                return line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// `/sys/.../resource` has one "start end flags" line per window, in hexadecimal. 0x200 in the flags marks memory space and 0x2000 prefetchable memory.
    static func largestPrefetchableWindow(_ path: String) -> Int64 {
        var largest: Int64 = 0
        for line in text(path).split(separator: "\n") {
            let parts = line.split(separator: " ").map { UInt64($0.dropFirst(2), radix: 16) ?? 0 }
            guard parts.count == 3, parts[1] > parts[0], parts[2] & 0x2000 != 0, parts[2] & 0x200 != 0 else { continue }   // memory space, prefetchable
            largest = max(largest, Int64(clamping: parts[1] - parts[0] + 1))
        }
        return largest
    }
}
