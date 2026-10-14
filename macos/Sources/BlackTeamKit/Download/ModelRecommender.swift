import Foundation

// "Which models are best for this computer?" A model's file size and this computer's memory and processor give three honest answers: does it
// fit, how fast will it write, and what is it good for. Nothing is measured, so the speed is always labelled an estimate.

public enum FitLevel: String, Codable, Sendable, Equatable {
    /// Fits with room to spare for the rest of what is open.
    case comfortable
    /// Fits, but little is left over; close other programs, or expect it to be slower.
    case tight
    /// Does not fit.
    case tooBig
}

/// How fast a model is expected to write on this computer.
public struct SpeedEstimate: Codable, Sendable, Equatable {
    /// Tokens (about three quarters of a word) per second, as a band around the estimate.
    public var low: Double
    public var high: Double
    /// "fast", "good", "steady", "slow" or "very slow".
    public var label: String
    /// Always says it is an estimate.
    public var text: String
}

public struct ModelFitReport: Codable, Sendable, Equatable {
    public var fit: FitLevel
    /// Memory the model needs, with room for its working memory.
    public var neededBytes: Int64
    /// Whether it runs on the graphics card (or Apple silicon's graphics), the processor, or both.
    public var runsOn: String
    public var speed: SpeedEstimate
}

public struct ModelAssessment: Codable, Sendable, Equatable, Identifiable {
    public var model: StarterModel
    public var installed: Bool
    public var fit: FitLevel
    public var neededBytes: Int64
    /// False when there is not enough free disk space to download it.
    public var fitsDisk: Bool
    public var runsOn: String
    public var speed: SpeedEstimate
    /// "Chat", "Code agent (tools)", "Images".
    public var goodFor: [String]
    /// One plain sentence.
    public var reason: String
    /// "best", "code" and "fastest", for the picks this model is.
    public var picks: [String]
    public var id: String { model.id }
}

public struct ModelRecommendations: Codable, Sendable, Equatable {
    public var hardware: HardwareProfile
    /// One plain line about this computer.
    public var summary: String
    /// Best first: models that fit, then the tight ones, then those that do not fit.
    public var models: [ModelAssessment]
    public var bestID: String?
    public var codeID: String?
    /// Set only when the fastest good model is not already the best.
    public var fastestID: String?
    /// Said when a graphics card was found but will not be used, and why.
    public var note: String?
    public var runtime: InstalledRuntime?
}

public enum ModelRecommender {
    private static let gib: Int64 = 1 << 30

    // MARK: Fit

    /// Memory a model needs: its file plus working memory. On the processor (or Apple silicon's shared memory) that is the rule the starter
    /// list already used, the larger of 2 GiB and a quarter of the file; on a graphics card's own memory it is 1.5 GiB for the context.
    public static func neededMemory(bytes: Int64, onGPU: Bool) -> Int64 {
        onGPU ? bytes + gib * 3 / 2 : StarterModels.estimatedMemory(modelBytes: bytes)
    }

    /// Fit, expected speed and where it runs, for a model file of `bytes`. `activeFraction` is the share of weights read per word
    /// (a mixture-of-experts model), or nil for a dense one.
    public static func assess(bytes: Int64, activeFraction: Double?, on hardware: HardwareProfile) -> ModelFitReport {
        let activeBytes = Double(bytes) * min(1, max(0.01, activeFraction ?? 1))
        let total = hardware.totalMemory

        if let card = hardware.gpuMemory, hardware.gpuUsable {
            if hardware.appleSilicon {
                // One pool of memory shared with everything else: comfortable up to 60% of it, tight up to what the GPU may wire.
                let needed = neededMemory(bytes: bytes, onGPU: false)
                let fit: FitLevel = needed <= total / 10 * 6 && needed <= hardware.availableMemory ? .comfortable : needed <= card ? .tight : .tooBig
                return ModelFitReport(fit: fit, neededBytes: needed, runsOn: "the graphics of this Mac",
                                      speed: speed(bandwidthGBs: appleBandwidth(hardware.cpuName) * 0.75, bytesPerWord: activeBytes))
            }
            // A card with its own memory: the weights go there; a model slightly too big for it spills the rest into memory.
            let needed = neededMemory(bytes: bytes, onGPU: true)
            let spillRoom = hardware.availableMemory / 10 * 6
            let fit: FitLevel = Double(needed) <= Double(card) * 0.92 ? .comfortable : (needed <= card ? .tight : (needed <= card + spillRoom ? .tight : .tooBig))
            let onCard = min(1, Double(card) * 0.92 / Double(max(1, needed)))
            let cardBW = gpuBandwidth(vram: card), cpuBW = cpuBandwidth(cores: hardware.cores)
            // Time for one word is the time to read the part on the card plus the time to read the rest from memory.
            let seconds = (activeBytes * onCard) / (cardBW * 1e9) + (activeBytes * (1 - onCard)) / (cpuBW * 1e9)
            return ModelFitReport(fit: fit, neededBytes: needed, runsOn: onCard >= 1 ? "the graphics card" : "the graphics card and memory",
                                  speed: speed(seconds: seconds))
        }

        let needed = neededMemory(bytes: bytes, onGPU: false)
        let fit: FitLevel
        if needed <= total / 10 * 6 && needed <= hardware.availableMemory { fit = .comfortable }
        else if needed <= total / 100 * 85 { fit = .tight }
        else { fit = .tooBig }
        return ModelFitReport(fit: fit, neededBytes: needed, runsOn: "the processor",
                              speed: speed(bandwidthGBs: cpuBandwidth(cores: hardware.cores), bytesPerWord: activeBytes))
    }

    // MARK: Speed (a documented estimate)
    //
    // Writing one token means reading the weights that are used for it from memory once, so the speed is about
    //     usable memory bandwidth / bytes read per token.
    // Bandwidth is not measured; it is estimated from the hardware, and the answer is shown as a band (0.7x to 1.4x the estimate):
    //   * processor: 4 GB/s per physical core, up to 45 GB/s (a dual-channel desktop or laptop);
    //   * Apple silicon: the chip family's memory bandwidth (base 100, Pro 200, Max 400, Ultra 800 GB/s) at 75%;
    //   * a graphics card with its own memory: 450 GB/s at 20 GiB or more, 250 at 12 GiB or more, 150 below that.
    // It ignores reading the prompt, which is slower, and a very long context, which slows every word.

    static func cpuBandwidth(cores: Int) -> Double { min(45, Double(max(1, cores)) * 4) }

    static func appleBandwidth(_ chip: String) -> Double {
        let name = chip.lowercased()
        return name.contains("ultra") ? 800 : name.contains("max") ? 400 : name.contains("pro") ? 200 : 100
    }

    static func gpuBandwidth(vram: Int64) -> Double { vram >= 20 * gib ? 450 : vram >= 12 * gib ? 250 : 150 }

    static func speed(bandwidthGBs: Double, bytesPerWord: Double) -> SpeedEstimate {
        speed(seconds: bytesPerWord / (bandwidthGBs * 1e9))
    }

    static func speed(seconds: Double) -> SpeedEstimate {
        let middle = seconds > 0 ? 1 / seconds : 0
        let low = middle * 0.7, high = middle * 1.4
        let label = middle >= 20 ? "fast" : middle >= 8 ? "good" : middle >= 4 ? "steady" : middle >= 2 ? "slow" : "very slow"
        func shown(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value) }
        // A token is about three quarters of a word.
        let text = middle <= 0 ? "speed unknown (estimated)"
            : "about \(shown(low * 0.75)) to \(shown(high * 0.75)) words a second (estimated)"
        return SpeedEstimate(low: low, high: high, label: label, text: text)
    }

    // MARK: Ranking

    /// What the model is good for, from what the catalogue knows about it.
    public static func goodFor(_ model: StarterModel) -> [String] {
        var out = ["Chat"]
        if model.toolCalling && model.bytes >= 5_000_000_000 { out.append("Code agent (tools)") }
        if model.vision != nil { out.append("Images") }
        return out
    }

    /// How capable a model is for ranking: its size, with a mixture-of-experts model counted between the weights it uses and all of them,
    /// times the maintainers' `quality` weight. A rule of thumb for ordering, not a benchmark.
    static func capability(_ model: StarterModel) -> Double {
        let size = Double(model.bytes) / 1e9
        let used = size * (model.activeFraction ?? 1)
        return model.quality * (used >= size ? size : (size * used).squareRoot())
    }

    /// Ranks `models` for this computer. `installed` says which are already downloaded.
    public static func recommend(models: [StarterModel] = ModelCatalogue.all, hardware: HardwareProfile, installed: (StarterModel) -> Bool = { _ in false },
                                 runtime: InstalledRuntime? = nil, note: String? = nil) -> ModelRecommendations {
        struct Row { var model: StarterModel; var report: ModelFitReport; var diskOK: Bool; var installed: Bool }
        let rows = models.map { model -> Row in
            let have = installed(model)
            let diskOK = have || hardware.freeDisk.map { $0 >= model.bytes } ?? true
            return Row(model: model, report: assess(bytes: model.bytes, activeFraction: model.activeFraction, on: hardware), diskOK: diskOK, installed: have)
        }
        func middle(_ row: Row) -> Double { (row.report.speed.low + row.report.speed.high) / 2 }
        func usable(_ row: Row, minimumSpeed: Double) -> Bool { row.report.fit != .tooBig && row.diskOK && middle(row) >= minimumSpeed }

        // Best: the most capable model that fits comfortably and writes at a comfortable reading speed; if none, relax in steps.
        func bestOf(_ pool: [Row]) -> Row? {
            for (fits, speed) in [([FitLevel.comfortable], 5.0), ([.comfortable, .tight], 4.0), ([.comfortable, .tight], 1.5)] {
                let found = pool.filter { fits.contains($0.report.fit) && usable($0, minimumSpeed: speed) }
                if let top = found.max(by: { capability($0.model) < capability($1.model) }) { return top }
            }
            return nil
        }
        let best = bestOf(rows)
        // Code agent: a model with tools that is big enough to use them reliably.
        let codePool = rows.filter { $0.model.toolCalling && $0.model.bytes >= 5_000_000_000 }
        let code = bestOf(codePool)
        // Fastest: not the tiny test model, which is quick because it says little.
        let fastest = rows.filter { usable($0, minimumSpeed: 1.5) && $0.model.bytes >= 2_000_000_000 }.max { middle($0) < middle($1) }

        func order(_ a: Row, _ b: Row) -> Bool {
            func tier(_ row: Row) -> Int { !row.diskOK && row.report.fit != .tooBig ? 3 : row.report.fit == .comfortable ? 0 : row.report.fit == .tight ? 1 : 2 }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let aSlow = middle(a) < 1.5, bSlow = middle(b) < 1.5
            if aSlow != bSlow { return !aSlow }
            return capability(a.model) > capability(b.model)
        }
        let ranked = rows.sorted(by: order)

        let assessed = ranked.map { row -> ModelAssessment in
            var picks: [String] = []
            if row.model.id == best?.model.id { picks.append("best") }
            if row.model.id == code?.model.id { picks.append("code") }
            if row.model.id == fastest?.model.id, fastest?.model.id != best?.model.id { picks.append("fastest") }
            return ModelAssessment(model: row.model, installed: row.installed, fit: row.report.fit, neededBytes: row.report.neededBytes, fitsDisk: row.diskOK,
                                   runsOn: row.report.runsOn, speed: row.report.speed, goodFor: goodFor(row.model),
                                   reason: reason(row.model, report: row.report, diskOK: row.diskOK, hardware: hardware, isBest: picks.contains("best")),
                                   picks: picks)
        }
        return ModelRecommendations(hardware: hardware, summary: describe(hardware), models: assessed, bestID: best?.model.id, codeID: code?.model.id,
                                    fastestID: fastest.flatMap { $0.model.id == best?.model.id ? nil : $0.model.id }, note: note, runtime: runtime)
    }

    /// One plain sentence about the model on this computer.
    static func reason(_ model: StarterModel, report: ModelFitReport, diskOK: Bool, hardware: HardwareProfile, isBest: Bool) -> String {
        if !diskOK, let free = hardware.freeDisk {
            return "Needs \(format(model.bytes)) of free disk space and only \(format(free)) is free."
        }
        let need = format(report.neededBytes)
        let pool = report.runsOn == "the processor" || hardware.appleSilicon ? "memory" : "graphics memory"
        switch report.fit {
        case .tooBig:
            return "Needs about \(need) of \(pool), more than this \(Place.kind) can give it."
        case .tight:
            return "Fits, but only just: it needs about \(need) of \(pool). Close other programs first; it may be slower."
        case .comfortable:
            switch report.speed.label {
            case "fast": return isBest ? "Fits with room to spare and writes fast on \(report.runsOn)." : "Fits with room to spare and writes fast."
            case "good": return isBest ? "The most capable model that fits with room to spare and still writes at a good speed." : "Fits with room to spare and writes at a good speed."
            case "steady": return "Fits with room to spare; it writes at a steady pace, about as fast as you read."
            default: return "Fits with room to spare, but it writes slowly on \(report.runsOn)."
            }
        }
    }

    static func describe(_ hardware: HardwareProfile) -> String {
        let memory = String(format: "%.0f GB", Double(hardware.totalMemory) / Double(gib))
        var line = "\(hardware.cores) \(hardware.cores == 1 ? "core" : "cores"), \(memory) of memory"
        if hardware.appleSilicon { line += ", Apple silicon (the graphics share that memory)" }
        else if let gpu = hardware.gpu {
            let card = gpu.vramBytes.map { String(format: "%.0f GB", Double($0) / Double(gib)) }
            line += ", \(gpu.name)" + (card.map { " with about \($0)" } ?? "")
        }
        if let free = hardware.freeDisk { line += ", \(format(free)) free for models" }
        return line
    }

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
