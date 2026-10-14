import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Optimizing a model for this computer. Black Team starts a model file a few times with different
// settings, reads the speeds the server itself reports for a fixed short test, and keeps the fastest
// settings for that model. Nothing is guessed: the numbers are measured here, and they are only
// kept for this computer, this llama.cpp program and this model file. A model on somebody else's
// server is only measured (its settings belong to that server), and a cloud model has nothing to tune.
//
// Everything that touches the system (processes, network, memory, the clock) is passed in with a
// real default, so tests use the fake runtime and fetch patterns of ModelRuntime.

private let GiB = 1024 * 1024 * 1024

// MARK: Settings and results

/// The launch settings the tuner chooses between. `gpuLayers` 0 means "the build's own choice" (every layer on Apple silicon, none elsewhere).
public struct TuneSettings: Codable, Equatable, Sendable {
    public var threads: Int
    public var context: Int
    public var gpuLayers: Int
    /// Whether the draft / MTP model found beside the model file is used.
    public var draft: Bool
    public init(threads: Int, context: Int, gpuLayers: Int = 0, draft: Bool = false) {
        self.threads = threads; self.context = context; self.gpuLayers = gpuLayers; self.draft = draft
    }
}

/// What one test run measured. `memoryBytes` is the model process's resident memory (0 where there is no process of ours).
public struct TuneSpeed: Codable, Equatable, Sendable {
    public var promptTokensPerSecond: Double
    public var generationTokensPerSecond: Double
    public var memoryBytes: Int
    /// True when the server gave no timings of its own and the speed was worked out from the clock.
    public var approximate: Bool?
    public init(promptTokensPerSecond: Double, generationTokensPerSecond: Double, memoryBytes: Int = 0, approximate: Bool? = nil) {
        self.promptTokensPerSecond = promptTokensPerSecond; self.generationTokensPerSecond = generationTokensPerSecond
        self.memoryBytes = memoryBytes; self.approximate = approximate
    }
}

/// What a result was measured with. If any part changes, the result is out of date.
public struct TuneFingerprint: Codable, Equatable, Sendable {
    /// The llama-server program: path, size and modification time.
    public var runtime: String
    public var hardware: String
    public var modelBytes: Int
    public var draftBytes: Int
    public init(runtime: String, hardware: String, modelBytes: Int, draftBytes: Int = 0) {
        self.runtime = runtime; self.hardware = hardware; self.modelBytes = modelBytes; self.draftBytes = draftBytes
    }
}

/// One launch the tuner tried, kept so the result can be explained.
public struct TuneTrial: Codable, Equatable, Sendable {
    public var label: String
    public var promptTokensPerSecond: Double?
    public var generationTokensPerSecond: Double?
    /// Why it was not used: it did not start, did not fit, or was not faster.
    public var note: String?
}

/// A stored result. `kind` is "tuned" (settings chosen by trying) or "measured" (a speed readout of a server we do not control).
public struct TuneEntry: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var kind: String
    public var settings: TuneSettings?
    public var speed: TuneSpeed
    public var fingerprint: TuneFingerprint?
    public var date: String
    public var launches: Int
    public var tried: [TuneTrial]
}

/// This computer, as far as the choice of settings cares.
public struct TuneHardware: Codable, Equatable, Sendable {
    public var cpu: String
    public var cores: Int
    public var threads: Int
    /// Performance cores on Apple silicon (and any CPU that reports them); nil where the CPU is not hybrid or does not say.
    public var performanceCores: Int?
    public var memoryTotal: Int
    public var memoryAvailable: Int
    public var appleSilicon: Bool
    /// A GPU llama.cpp can use: always on Apple silicon; elsewhere an NVIDIA or AMD compute device.
    public var gpu: Bool

    public init(cpu: String = "CPU", cores: Int, threads: Int? = nil, performanceCores: Int? = nil, memoryTotal: Int, memoryAvailable: Int? = nil,
                appleSilicon: Bool = false, gpu: Bool = false) {
        self.cpu = cpu; self.cores = cores; self.threads = threads ?? cores; self.performanceCores = performanceCores
        self.memoryTotal = memoryTotal; self.memoryAvailable = memoryAvailable ?? memoryTotal; self.appleSilicon = appleSilicon; self.gpu = gpu || appleSilicon
    }

    public static func current(appleSilicon: Bool = SystemInfo.isAppleSilicon) -> TuneHardware {
        let cpu = SystemInfo.cpuTopology(), memory = SystemInfo.memoryInfo()
        #if os(Linux)
        let compute = CoreFS.exists("/dev/nvidia0") || CoreFS.exists("/dev/kfd")
        #else
        let compute = false
        #endif
        return TuneHardware(cpu: cpu.name, cores: max(1, cpu.cores), threads: cpu.threads, performanceCores: cpu.performanceCores,
                            memoryTotal: memory.total, memoryAvailable: memory.available, appleSilicon: appleSilicon, gpu: compute)
    }

    /// What identifies the machine for a stored result. Free memory is left out: it changes all day.
    public var fingerprint: String {
        "\(cpu)|\(cores)c|\(threads)t|\(performanceCores.map(String.init) ?? "-")p|\(Int((Double(memoryTotal) / Double(GiB)).rounded()))GiB|gpu:\(gpu ? 1 : 0)"
    }
}

// MARK: Fingerprint and staleness

private func fileBuild(_ path: String) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    let modified = (attributes?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
    return "\(path)|\(size)|\(modified)"
}

/// The fingerprint a result for `model` would carry on this computer now.
public func tuneFingerprint(model: ModelConfig, hardware: TuneHardware) -> TuneFingerprint {
    let size = CoreFS.stat(model.file), draft = model.draft.isEmpty ? nil : CoreFS.stat(model.draft)
    return TuneFingerprint(runtime: fileBuild(model.runtime), hardware: hardware.fingerprint, modelBytes: size.error == 0 ? size.size : 0,
                           draftBytes: draft.map { $0.error == 0 ? $0.size : 0 } ?? 0)
}

/// Why a stored result no longer applies, in plain words; empty when it still does.
public func tuneStaleReasons(_ stored: TuneFingerprint, now: TuneFingerprint) -> [String] {
    var reasons: [String] = []
    if stored.runtime != now.runtime { reasons.append("The llama.cpp program changed.") }
    if stored.modelBytes != now.modelBytes { reasons.append("The model file changed.") }
    if stored.draftBytes != now.draftBytes { reasons.append("The draft model changed.") }
    if stored.hardware != now.hardware { reasons.append("The hardware of \(Place.this) changed.") }
    return reasons
}

// MARK: The stored results

/// `tuning.json` in the data folder: one entry per model key. Private to the user (0600), written atomically.
public final class TuningStore: @unchecked Sendable {
    public let stateDir: String
    private let filename: String
    private let lock = NSLock()
    private static let limit = 64

    private struct Document: Codable { var version: Int; var models: [String: TuneEntry] }

    public init(stateDir: String) {
        self.stateDir = stateDir
        self.filename = stateDir + "/tuning.json"
    }

    // A missing or damaged file means no results, never a failed start.
    private func load() -> [String: TuneEntry] {
        let info = CoreFS.stat(filename)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= 512 * 1024,
              let data = FileManager.default.contents(atPath: filename),
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return [:] }
        return document.models
    }

    public func all() -> [String: TuneEntry] { lock.lock(); defer { lock.unlock() }; return load() }
    public func entry(_ key: String) -> TuneEntry? { lock.lock(); defer { lock.unlock() }; return load()[key] }

    public func save(_ entry: TuneEntry) throws {
        lock.lock(); defer { lock.unlock() }
        var models = load()
        models[entry.key] = entry
        if models.count > Self.limit {
            for key in models.sorted(by: { $0.value.date < $1.value.date }).prefix(models.count - Self.limit).map(\.key) where key != entry.key { models[key] = nil }
        }
        try write(models)
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var models = load()
        if models.removeValue(forKey: key) != nil { try write(models) }
    }

    private func write(_ models: [String: TuneEntry]) throws {
        try privateDirectory(stateDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(version: 1, models: models)) + Data("\n".utf8)
        try CoreFS.writeAtomic(filename, data, temporary: "\(stateDir)/.tuning-\(CoreFS.hex(12)).tmp")
    }
}

/// The model with a stored result applied, when the result is a tuned one and still current. Anything else leaves the model as it was.
/// The context is not applied here: it is saved into the model's own setting when the result is made, so the conversation
/// budget (which reads that setting) and the running model agree.
func applyTuning(_ model: ModelConfig, entry: TuneEntry?, hardware: @autoclosure () -> TuneHardware) -> ModelConfig {
    guard model.source == "gguf", let entry, entry.kind == "tuned", let settings = entry.settings, let stored = entry.fingerprint else { return model }
    guard tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: hardware())).isEmpty else { return model }
    var tuned = model
    tuned.threads = settings.threads
    tuned.gpuLayers = settings.gpuLayers
    if !settings.draft { tuned.draft = "" }
    return tuned
}

/// What `ModelRuntime` is given to use a stored result when it starts a model file.
public func tunedLaunch(store: TuningStore, hardware: @escaping @Sendable () -> TuneHardware = { TuneHardware.current() }) -> @Sendable (ModelConfig) -> ModelConfig {
    { model in
        guard model.source == "gguf" else { return model }
        return applyTuning(model, entry: store.entry(keyOf(model)), hardware: hardware())
    }
}

// MARK: Choosing what to try

/// One change from the best settings so far.
public enum TuneChange: Equatable, Sendable {
    case gpu(Int)
    case draft(Bool)
    case threads(Int)

    public func applied(to settings: TuneSettings) -> TuneSettings {
        var next = settings
        switch self {
        case .gpu(let layers): next.gpuLayers = layers
        case .draft(let on): next.draft = on
        case .threads(let count): next.threads = count
        }
        return next
    }

    /// "Trying 6 threads…" style wording for the progress line.
    public var label: String {
        switch self {
        case .gpu(let layers): return layers > 0 ? "the graphics chip" : "the processor only"
        case .draft(let on): return on ? "the draft model" : "no draft model"
        case .threads(let count): return "\(count) threads"
        }
    }
}

/// Whether the draft file beside the model can be used by this build, as `planLaunch` decides it.
func tuneDraftUsable(_ draft: String, support: LlamaSupport) -> Bool {
    guard !draft.isEmpty, support.specType else { return false }
    let name = (draft as NSString).lastPathComponent
    let mtp = name.range(of: #"(^|[-_.])mtp([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    if support.draft && (!mtp || support.mtp) { return true }
    return mtp && support.mtpHeads
}

/// The settings a launch uses today, with `context` filled in: the first thing the tuner measures.
public func tuneBaseline(model: ModelConfig, support: LlamaSupport, hardware: TuneHardware, context: Int) -> TuneSettings {
    TuneSettings(threads: max(1, hardware.cores), context: context, gpuLayers: 0,
                 draft: tuneDraftUsable(model.draft, support: support) && CoreFS.exists(model.draft))
}

/// The changes worth trying, best bet first, only where this build and this computer allow them. The tuner takes as many as its launch limit leaves.
public func tuneCandidates(base: TuneSettings, support: LlamaSupport, hardware: TuneHardware, layers: Int? = nil) -> [TuneChange] {
    var changes: [TuneChange] = []
    // Apple silicon already puts every layer on the GPU; elsewhere a GPU is worth one try.
    if !hardware.appleSilicon, hardware.gpu, !support.gpuLayers.isEmpty, base.gpuLayers == 0 { changes.append(.gpu(999)) }
    if base.draft { changes.append(.draft(false)) }
    if let performance = hardware.performanceCores, performance >= 1, performance < hardware.cores, performance != base.threads { changes.append(.threads(performance)) }
    if hardware.cores > 2, base.threads == hardware.cores { changes.append(.threads(hardware.cores - 1)) }
    return changes
}

/// The standard context sizes to try, largest first: capped by the model's training length, and by a first guess of the memory they
/// need (about 1 GiB per 8,192 tokens with the eight-bit cache), so the first launch is not hopeless. Never empty.
public func tuneContextSteps(training: Int?, modelBytes: Int, available: Int) -> [Int] {
    let standard = [65536, 32768, 16384, 8192]
    let cap = training.map { $0 >= 512 ? $0 : 65536 } ?? 65536
    if cap < 8192 { return [max(512, cap)] }
    let room = max(GiB, available - modelBytes - 2 * GiB)
    let fitting = standard.filter { $0 <= cap && ($0 / 8192) * GiB <= room }
    return fitting.isEmpty ? [8192] : fitting
}

/// Whether a measured resident size leaves headroom on a computer with `total` memory: at least 2 GiB or an eighth, whichever is more.
public func tuneFits(resident: Int, total: Int) -> Bool { total - resident >= max(2 * GiB, total / 8) }

/// How much better `candidate` is than `best`: writing speed counts most, reading speed the rest. 1.0 is equal.
public func tuneGain(candidate: TuneSpeed, over best: TuneSpeed) -> Double {
    let writing = best.generationTokensPerSecond > 0 ? candidate.generationTokensPerSecond / best.generationTokensPerSecond : 1
    let reading = best.promptTokensPerSecond > 0 ? candidate.promptTokensPerSecond / best.promptTokensPerSecond : 1
    return 0.7 * writing + 0.3 * reading
}

/// A fixed text of about `words * 1.3` tokens. Deterministic, varied enough that a draft model is not flattered by repetition.
public func tunePrompt(words: Int = 750) -> String {
    let vocabulary = ["the", "river", "carried", "small", "boats", "past", "old", "stone", "bridges", "while", "people", "walked", "along", "quiet", "streets",
                      "and", "talked", "about", "weather", "markets", "trains", "music", "gardens", "a", "long", "winter", "bread", "lamps", "windows", "slowly",
                      "opened", "morning", "light", "on", "roofs", "of", "town", "children", "ran", "toward", "harbour", "where", "ships", "waited", "for", "tide"]
    var state: UInt64 = 0x2545F4914F6CDD1D
    var out: [String] = []
    for index in 0..<words {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out.append(vocabulary[Int((state >> 33) % UInt64(vocabulary.count))])
        if index % 14 == 13 { out[out.count - 1] += "." }
    }
    return "Here is a description of a town.\n\n" + out.joined(separator: " ") + "\n\nIn two sentences, say what the town is like.\n"
}

/// Reading and writing speed from a llama-server reply's own `timings`.
public func tuneTimings(_ reply: JSONValue) -> (prompt: Double, generation: Double)? {
    guard let timings = reply["timings"] else { return nil }
    func speed(_ perSecond: String, _ count: String, _ milliseconds: String) -> Double? {
        if let value = timings[perSecond]?.double, value > 0 { return value }
        if let n = timings[count]?.double, let ms = timings[milliseconds]?.double, n > 0, ms > 0 { return n / ms * 1000 }
        return nil
    }
    guard let prompt = speed("prompt_per_second", "prompt_n", "prompt_ms"), let generation = speed("predicted_per_second", "predicted_n", "predicted_ms") else { return nil }
    return (prompt, generation)
}

func tuneSpeedText(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value) }

/// 32768 as "32,768".
func tuneGrouped(_ value: Int) -> String {
    let grouped = NumberFormatter()
    grouped.numberStyle = .decimal; grouped.locale = Locale(identifier: "en_US")
    return grouped.string(from: NSNumber(value: value)) ?? String(value)
}

// MARK: Describing a result

extension TuneEntry {
    /// "6 threads · 32,768 context · MTP draft · reads 54 tokens/s, writes 12", the line the window shows.
    public func summary(draftFile: String = "") -> String {
        var parts: [String] = []
        if let settings {
            parts.append("\(settings.threads) threads")
            parts.append("\(tuneGrouped(settings.context)) context")
            if settings.gpuLayers > 0 { parts.append("graphics chip") }
            if settings.draft {
                let name = (draftFile as NSString).lastPathComponent
                parts.append(name.range(of: #"(^|[-_.])mtp([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil ? "MTP draft" : "draft model")
            }
        }
        let reads = tuneSpeedText(speed.promptTokensPerSecond), writes = tuneSpeedText(speed.generationTokensPerSecond)
        parts.append("reads \(reads) tokens/s, writes \(writes)")
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: The tuner

/// Said when the tuner will not run now. `reason` is short and stable ("busy").
public struct TuneSkipped: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

public struct TuneOptions: Sendable {
    /// Model starts, in all: the first measurement plus the changes tried after it.
    public var maxLaunches = 4
    public var budgetSeconds: Double = 180
    public var generateTokens = 64
    public var promptWords = 750
    /// A change is kept only when it is at least this much better (3%), so noise does not pick the winner.
    public var minimumGain = 1.03
    /// A launch is not begun with less time than this left.
    public var minimumLaunchSeconds: Double = 20
    public init() {}
}

public struct TuneEnvironment: Sendable {
    public var help: @Sendable (String) -> String
    public var hardware: @Sendable () -> TuneHardware
    /// Resident memory (with anything swapped out) of a process.
    public var memory: @Sendable (Int) -> Int?
    public var uptime: @Sendable () -> Double
    public var now: @Sendable () -> Date
    public init(help: @escaping @Sendable (String) -> String = { readHelpText($0) },
                hardware: @escaping @Sendable () -> TuneHardware = { TuneHardware.current() },
                memory: @escaping @Sendable (Int) -> Int? = { pid in SystemInfo.processMemory(pid).map { $0.resident + $0.swapped } },
                uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.help = help; self.hardware = hardware; self.memory = memory; self.uptime = uptime; self.now = now
    }
}

public typealias TuneReport = @Sendable (String) -> Void

public final class ModelTuner: @unchecked Sendable {
    private let main: BackendRuntime
    private let configStore: ConfigStore
    private let store: TuningStore
    private let trial: @Sendable (ConfigStore, Int) -> BackendRuntime
    private let fetch: HTTPFetch
    private let environment: TuneEnvironment
    private let options: TuneOptions
    private let isBusy: @Sendable () -> Bool
    private let preflight: (@Sendable () throws -> Void)?

    /// `main` is the app's own runtime (stopped while a test model runs, and started again after if it was running);
    /// `trial` makes a separate runtime for one test launch from a private configuration and a start-up time limit in milliseconds.
    public init(main: BackendRuntime, configStore: ConfigStore, store: TuningStore, trial: @escaping @Sendable (ConfigStore, Int) -> BackendRuntime,
                fetch: @escaping HTTPFetch = LocalHTTP.fetch, environment: TuneEnvironment = TuneEnvironment(), options: TuneOptions = TuneOptions(),
                isBusy: @escaping @Sendable () -> Bool = { false }, preflight: (@Sendable () throws -> Void)? = nil) {
        self.main = main; self.configStore = configStore; self.store = store; self.trial = trial; self.fetch = fetch
        self.environment = environment; self.options = options; self.isBusy = isBusy; self.preflight = preflight
    }

    private struct Attempt { var speed: TuneSpeed?; var failure: String? }

    // MARK: Model files

    /// Tries settings for a model file Black Team starts itself, and stores the fastest. Throws `TuneSkipped("busy")` while a conversation
    /// runs; `CancellationError` when cancelled. Either way the model is left as it was found (stopped, or running again).
    @discardableResult
    public func optimize(_ model: ModelConfig, report: @escaping TuneReport = { _ in }, apply: (@Sendable (TuneEntry) throws -> Void)? = nil) async throws -> TuneEntry {
        guard model.source == "gguf" else {
            throw BlackTeamError(model.source == "cloud" ? "A cloud model runs at its service, so there is nothing to optimize on \(Place.this)."
                                 : "This model runs on a server of its own, so its settings belong to that server. Black Team can only measure its speed.")
        }
        _ = try validateModelFiles(model, cloud: configStore.cloud)
        if isBusy() { throw TuneSkipped("busy") }
        let before = await main.status()
        if before.busy { throw TuneSkipped("busy") }
        try preflight?()

        let started = environment.uptime()
        let deadline = started + options.budgetSeconds
        let wasRunning = before.state == .ready || before.state == .starting
        let probe = environment.help, executable = model.runtime
        let help = await Task.detached { probe(executable) }.value
        let support = supportOf(help)
        let hardware = environment.hardware()
        let described = try? describeModel(model.file)
        let modelBytes = CoreFS.stat(model.file).size

        var entry: TuneEntry?
        var failure: Error?
        do {
            if before.state != .off {
                report("Stopping the model for a moment\u{2026}")
                try await main.stop(force: false)
            }
            entry = try await search(model, support: support, hardware: hardware, layers: described?.layers, training: described?.trainingContext,
                                     modelBytes: modelBytes, deadline: deadline, report: report)
            if let found = entry {
                try store.save(found)
                try? apply?(found)
            }
        } catch {
            failure = error
        }
        // Put things back whatever happened: an unstructured task, so a cancelled run still restores.
        if wasRunning {
            report("Starting the model again\u{2026}")
            let runtime = main
            await Task { _ = try? await runtime.start() }.value
        }
        if let failure {
            let thrown: Error = failure is CancellationError || Task.isCancelled ? CancellationError() : failure
            throw thrown
        }
        return entry!
    }

    private func search(_ model: ModelConfig, support: LlamaSupport, hardware: TuneHardware, layers: Int?, training: Int?, modelBytes: Int,
                        deadline: Double, report: TuneReport) async throws -> TuneEntry {
        var launches = 0
        var tried: [TuneTrial] = []

        // 1. The settings used today, at the largest context that fits.
        var best: (settings: TuneSettings, speed: TuneSpeed)?
        var fallback: (settings: TuneSettings, speed: TuneSpeed)?
        var lastFailure = ""
        for context in tuneContextSteps(training: training, modelBytes: modelBytes, available: hardware.memoryAvailable) {
            try Task.checkCancellation()
            guard canLaunch(launches, deadline) else { break }
            let settings = tuneBaseline(model: model, support: support, hardware: hardware, context: context)
            launches += 1
            report("Trying \(settings.threads) threads with \(tuneGrouped(context)) tokens of context\u{2026}")
            let attempt = try await run(model, settings, deadline: deadline, report: report)
            if let speed = attempt.speed {
                if tuneFits(resident: speed.memoryBytes, total: hardware.memoryTotal) {
                    tried.append(TuneTrial(label: "\(settings.threads) threads, \(context) context", promptTokensPerSecond: speed.promptTokensPerSecond,
                                           generationTokensPerSecond: speed.generationTokensPerSecond, note: nil))
                    best = (settings, speed); break
                }
                tried.append(TuneTrial(label: "\(context) context", promptTokensPerSecond: speed.promptTokensPerSecond, generationTokensPerSecond: speed.generationTokensPerSecond,
                                       note: "Too little memory left beside it."))
                if fallback == nil || context < fallback!.settings.context { fallback = (settings, speed) }
                lastFailure = "Too little memory is left on \(Place.this) beside the model."
            } else {
                tried.append(TuneTrial(label: "\(context) context", promptTokensPerSecond: nil, generationTokensPerSecond: nil, note: attempt.failure))
                lastFailure = attempt.failure ?? "The model did not start."
            }
        }
        // Even the smallest context left little headroom: still the best that works here.
        if best == nil, let fallback { best = fallback }
        guard var chosen = best else { throw BlackTeamError(lastFailure.isEmpty ? "The time limit was reached before the model could be measured." : lastFailure) }

        // 2. One change at a time from the best so far, as many as the limits leave.
        for change in tuneCandidates(base: chosen.settings, support: support, hardware: hardware, layers: layers) {
            try Task.checkCancellation()
            guard canLaunch(launches, deadline) else { break }
            let settings = change.applied(to: chosen.settings)
            if settings == chosen.settings { continue }
            launches += 1
            report("Trying \(change.label)\u{2026}")
            var attempt = try await run(model, settings, deadline: deadline, report: report)
            var used = settings
            // A graphics chip that cannot hold every layer gets half of them.
            if case .gpu = change, attempt.speed == nil, let layers, layers > 1, canLaunch(launches, deadline) {
                tried.append(TuneTrial(label: change.label, promptTokensPerSecond: nil, generationTokensPerSecond: nil, note: attempt.failure))
                try Task.checkCancellation()
                used = TuneChange.gpu(layers / 2).applied(to: chosen.settings)
                launches += 1
                report("Trying half of the layers on the graphics chip\u{2026}")
                attempt = try await run(model, used, deadline: deadline, report: report)
            }
            guard let speed = attempt.speed else {
                tried.append(TuneTrial(label: change.label, promptTokensPerSecond: nil, generationTokensPerSecond: nil, note: attempt.failure))
                continue
            }
            let gain = tuneGain(candidate: speed, over: chosen.speed)
            let fits = tuneFits(resident: speed.memoryBytes, total: hardware.memoryTotal)
            let wins = fits && gain >= options.minimumGain
            tried.append(TuneTrial(label: change.label, promptTokensPerSecond: speed.promptTokensPerSecond, generationTokensPerSecond: speed.generationTokensPerSecond,
                                   note: wins ? nil : fits ? "Not faster." : "Too little memory left beside it."))
            if wins { chosen = (used, speed) }
        }

        let result = TuneEntry(key: keyOf(model), name: model.name, kind: "tuned", settings: chosen.settings, speed: chosen.speed,
                               fingerprint: tuneFingerprint(model: model, hardware: hardware), date: EText.iso(environment.now()), launches: launches, tried: tried)
        report("Done: reads \(tuneSpeedText(chosen.speed.promptTokensPerSecond)) tokens/s, writes \(tuneSpeedText(chosen.speed.generationTokensPerSecond)) tokens/s.")
        return result
    }

    private func canLaunch(_ launches: Int, _ deadline: Double) -> Bool {
        launches < options.maxLaunches && deadline - environment.uptime() >= options.minimumLaunchSeconds
    }

    /// One test launch: start a runtime of our own with `settings`, run the fixed test, read memory, stop it.
    private func run(_ model: ModelConfig, _ settings: TuneSettings, deadline: Double, report: TuneReport) async throws -> Attempt {
        var tuned = model
        tuned.threads = settings.threads; tuned.context = settings.context; tuned.gpuLayers = settings.gpuLayers
        if !settings.draft { tuned.draft = "" }
        let scratch = NSTemporaryDirectory() + "black-team-tune-" + CoreFS.hex(6)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let workspace = (try? configStore.read().workspace) ?? NSHomeDirectory()
        let attempt: Attempt
        do {
            try privateDirectory(scratch)
            let scratchStore = try ConfigStore(stateDir: scratch, defaultWorkspace: workspace, cloud: configStore.cloud)
            try scratchStore.save(Config(model: tuned, workspace: workspace))
            let remaining = max(1, deadline - environment.uptime())
            let runtime = trial(scratchStore, Int(min(120, remaining) * 1000))
            attempt = try await measureOwned(runtime, deadline: deadline, report: report)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Attempt(speed: nil, failure: messageOf(error))
        }
        return attempt
    }

    private func measureOwned(_ runtime: BackendRuntime, deadline: Double, report: TuneReport) async throws -> Attempt {
        var result = Attempt(speed: nil, failure: nil)
        do {
            let endpoint = try await withTaskCancellationHandler { try await runtime.start() } onCancel: { Task { try? await runtime.stop(force: true) } }
            try Task.checkCancellation()
            let pid = await runtime.modelPid()
            let headers = try await runtime.requestHeaders()
            let timings = try await complete(endpoint: endpoint, headers: headers, deadline: deadline)
            let memory = pid.flatMap { environment.memory($0) } ?? 0
            report("Reading speed: \(tuneSpeedText(timings.prompt)) tokens/s")
            report("Writing speed: \(tuneSpeedText(timings.generation)) tokens/s")
            result.speed = TuneSpeed(promptTokensPerSecond: timings.prompt, generationTokensPerSecond: timings.generation, memoryBytes: memory)
        } catch is CancellationError {
            await Task { try? await runtime.stop(force: true) }.value
            throw CancellationError()
        } catch {
            result.failure = messageOf(error)
        }
        await Task { try? await runtime.stop(force: true) }.value
        if Task.isCancelled { throw CancellationError() }
        return result
    }

    /// The fixed test: a ~1,000 token prompt and 64 tokens written, with no cache, timed by the server.
    private func complete(endpoint: String, headers: [String: String], deadline: Double) async throws -> (prompt: Double, generation: Double) {
        let root = endpoint.hasSuffix("/v1") ? String(endpoint.dropLast(3)) : endpoint
        guard let url = URL(string: root + "/completion") else { throw BlackTeamError("The test address is not valid.") }
        let limit = max(5, min(150, deadline - environment.uptime()))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = limit
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let body: JSONValue = ["prompt": .string(tunePrompt(words: options.promptWords)), "n_predict": .number(Double(options.generateTokens)), "temperature": 0,
                               "cache_prompt": false, "stream": false]
        request.httpBody = Data(body.text().utf8)
        let sent = request, fetch = self.fetch
        let (data, http) = try await withDeadline(ms: Int(limit * 1000)) { try await fetch(sent) }
        guard (200..<300).contains(http.statusCode) else { throw BlackTeamError("The model answered the speed test with an error (\(http.statusCode)).") }
        guard let reply = try? JSONValue.parse(data), let timings = tuneTimings(reply) else { throw BlackTeamError("The model did not report its speed. Choose a current llama.cpp release.") }
        return timings
    }

    // MARK: A server somebody else runs

    /// A speed readout of a model on a server we do not control. Nothing is restarted and no setting is changed or stored beyond the readout.
    @discardableResult
    public func measureServer(_ model: ModelConfig, report: @escaping TuneReport = { _ in }) async throws -> TuneEntry {
        guard model.source == "server" else { throw BlackTeamError("Only a model on a server of its own is measured this way.") }
        if isBusy() { throw TuneSkipped("busy") }
        if await main.status().busy { throw TuneSkipped("busy") }
        let base = try localEndpoint(model.endpoint)
        var request = URLRequest(url: URL(string: base + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try serverHeaders(model.apiKey) { request.setValue(value, forHTTPHeaderField: name) }
        let body: JSONValue = ["model": .string(model.id), "messages": [["role": "user", "content": .string(tunePrompt(words: options.promptWords))]],
                               "max_tokens": .number(Double(options.generateTokens)), "temperature": 0, "stream": false]
        request.httpBody = Data(body.text().utf8)
        report("Measuring \(model.name)\u{2026}")
        let began = environment.uptime()
        let sent = request, fetch = self.fetch
        let (data, http) = try await withDeadline(ms: 150_000) { try await fetch(sent) }
        try Task.checkCancellation()
        guard (200..<300).contains(http.statusCode) else { throw BlackTeamError("The server answered the speed test with an error (\(http.statusCode)).") }
        let reply = try JSONValue.parse(data)
        let speed: TuneSpeed
        if let timings = tuneTimings(reply) {
            speed = TuneSpeed(promptTokensPerSecond: timings.prompt, generationTokensPerSecond: timings.generation)
        } else if let written = reply["usage"]?["completion_tokens"]?.double, let read = reply["usage"]?["prompt_tokens"]?.double, written > 0 {
            // No timings of its own: the whole round trip is what the clock gives, so these are lower bounds.
            let seconds = max(0.001, environment.uptime() - began)
            speed = TuneSpeed(promptTokensPerSecond: read / seconds, generationTokensPerSecond: written / seconds, approximate: true)
        } else {
            throw BlackTeamError("The server did not report how many tokens it used, so its speed cannot be measured.")
        }
        report("Reading speed: \(tuneSpeedText(speed.promptTokensPerSecond)) tokens/s")
        report("Writing speed: \(tuneSpeedText(speed.generationTokensPerSecond)) tokens/s")
        let entry = TuneEntry(key: keyOf(model), name: model.name, kind: "measured", settings: nil, speed: speed, fingerprint: nil,
                              date: EText.iso(environment.now()), launches: 0, tried: [])
        try store.save(entry)
        return entry
    }
}
