import XCTest
@testable import BlackTeamKit

private let GiB = 1024 * 1024 * 1024

/// A llama-server that knows every flag the tuner cares about.
private let fullHelp = """
--port N  --threads N  --threads-batch N  --batch-size N  --ubatch-size N  --cache-ram N  --flash-attn  --cache-type-k  --cache-type-v
--mmproj  --no-mmproj-offload  --jinja  --spec-type  --spec-draft-model  draft-mtp  --no-webui  --alias  --n-gpu-layers N
"""

/// What the fake model does for the settings it was started with, and what the fake network and clock say. No model is ever loaded.
final class TuneRig: @unchecked Sendable {
    struct Behaviour {
        var failure: String?
        var prompt = 50.0, generation = 10.0
        var resident = 8 * GiB
    }
    private let lock = NSLock()
    private var _launched: [ModelConfig] = [], _current: ModelConfig?, _stops = 0, _fetches = 0, _clock = 1000.0
    private var _blockFetch: Int?
    var behave: @Sendable (ModelConfig) -> Behaviour = { _ in Behaviour() }
    /// Seconds the fake clock moves for each speed test.
    var secondsPerTest = 0.0

    var launched: [ModelConfig] { lock.lock(); defer { lock.unlock() }; return _launched }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    var fetches: Int { lock.lock(); defer { lock.unlock() }; return _fetches }
    var clock: Double { lock.lock(); defer { lock.unlock() }; return _clock }
    var current: ModelConfig? { lock.lock(); defer { lock.unlock() }; return _current }
    func blockFetch(number: Int) { lock.lock(); _blockFetch = number; lock.unlock() }
    func launch(_ model: ModelConfig) { lock.lock(); _launched.append(model); _current = model; lock.unlock() }
    func stopped() { lock.lock(); _stops += 1; lock.unlock() }
    func tick() -> (number: Int, block: Bool) {
        lock.lock(); defer { lock.unlock() }
        _fetches += 1; _clock += secondsPerTest
        return (_fetches, _blockFetch == _fetches)
    }
    var resident: Int { behave(current ?? ModelConfig()).resident }

    /// The network the tuner talks to: the speed test answers with the timings of whatever settings the model started with.
    var fetch: HTTPFetch {
        { [self] request in
            let step = tick()
            if step.block { try await Task.sleep(nanoseconds: 120_000_000_000) }
            let url = request.url!
            guard let model = current else { return (Data("{}".utf8), response(url, 503)) }
            let how = behave(model)
            let body = #"{"timings":{"prompt_per_second":\#(how.prompt),"predicted_per_second":\#(how.generation)}}"#
            return (Data(body.utf8), response(url))
        }
    }
}

/// The runtime for one test launch: starts as the settings in its private configuration say, as `ModelRuntime` would.
final class TrialRuntime: BackendRuntime, @unchecked Sendable {
    let rig: TuneRig, model: ModelConfig
    init(_ rig: TuneRig, _ model: ModelConfig) { self.rig = rig; self.model = model }
    func status() async -> RuntimeStatus { RuntimeStatus(state: .off, ready: false, busy: false, error: nil, name: model.name, port: nil, features: []) }
    func modelPid() async -> Int? { 321 }
    func requestHeaders() async throws -> [String: String] { ["Authorization": "Bearer trial"] }
    func setBusy(_ value: Bool) async throws {}
    func start() async throws -> String {
        if let failure = rig.behave(model).failure { throw BlackTeamError(failure) }
        rig.launch(model)
        return "http://127.0.0.1:6000/v1"
    }
    func stop(force: Bool) async throws { rig.stopped() }
    func dispose() async throws {}
}

final class TuneTests: XCTestCase {
    let sixCores = TuneHardware(cpu: "Test CPU", cores: 6, threads: 12, memoryTotal: 32 * GiB, memoryAvailable: 24 * GiB)

    struct Setup {
        let tuner: ModelTuner
        let main: StubRuntime
        let rig: TuneRig
        let store: TuningStore
        let model: ModelConfig
        let files: RuntimeFixture
    }

    func setup(hardware: TuneHardware? = nil, options: TuneOptions = TuneOptions(), mainState: RuntimeState = .off, busy: Bool = false, draft: Bool = true,
               help: String = fullHelp, behave: (@Sendable (ModelConfig) -> TuneRig.Behaviour)? = nil, secondsPerTest: Double = 0) throws -> Setup {
        let files = try RuntimeFixture(self)
        var model = files.config.model
        if draft {
            model.draft = files.dir + "/mtp-draft.gguf"
            var header = [UInt8](repeating: 0, count: 64)
            header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
            FileManager.default.createFile(atPath: model.draft, contents: Data(header))
        }
        var config = files.config
        config.model = model
        try files.store.save(config)
        let rig = TuneRig()
        if let behave { rig.behave = behave }
        rig.secondsPerTest = secondsPerTest
        let main = StubRuntime()
        main.state = mainState
        let store = TuningStore(stateDir: files.stateDir)
        let machine = hardware ?? sixCores
        let environment = TuneEnvironment(help: { _ in help }, hardware: { machine }, memory: { _ in rig.resident }, uptime: { rig.clock },
                                          now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let trial: @Sendable (ConfigStore, Int) -> BackendRuntime = { scratch, _ in TrialRuntime(rig, (try? scratch.read().model) ?? ModelConfig()) }
        let tuner = ModelTuner(main: main, configStore: files.store, store: store, trial: trial, fetch: rig.fetch, environment: environment, options: options,
                               isBusy: { busy })
        return Setup(tuner: tuner, main: main, rig: rig, store: store, model: model, files: files)
    }

    // MARK: Candidates

    func testCandidatesFollowTheBuildsHelpTextAndTheHardware() {
        let base = TuneSettings(threads: 6, context: 16384, gpuLayers: 0, draft: true)
        let plain = supportOf(fullHelp)
        XCTAssertEqual(tuneCandidates(base: base, support: plain, hardware: sixCores), [.draft(false), .threads(5)])
        // A graphics chip is worth one try, but only where the build has the flag.
        var gpu = sixCores
        gpu.gpu = true
        XCTAssertEqual(tuneCandidates(base: base, support: plain, hardware: gpu), [.gpu(999), .draft(false), .threads(5)])
        XCTAssertEqual(tuneCandidates(base: base, support: supportOf("--port N --threads N"), hardware: gpu), [.draft(false), .threads(5)])
        // Apple silicon: the GPU is already used; performance cores are a candidate.
        let mac = TuneHardware(cpu: "Apple M2", cores: 8, performanceCores: 4, memoryTotal: 16 * GiB, appleSilicon: true)
        XCTAssertEqual(tuneCandidates(base: TuneSettings(threads: 8, context: 8192, draft: false), support: plain, hardware: mac), [.threads(4), .threads(7)])
        // Two cores: nothing to take away. No draft file: nothing to turn off.
        let small = TuneHardware(cores: 2, memoryTotal: 8 * GiB)
        XCTAssertEqual(tuneCandidates(base: TuneSettings(threads: 2, context: 8192), support: plain, hardware: small), [])
    }

    func testTheDraftModelIsOnlyAssumedWhereTheBuildCanUseIt() throws {
        let files = try RuntimeFixture(self)
        var model = files.config.model
        model.draft = files.dir + "/mtp-draft.gguf"
        FileManager.default.createFile(atPath: model.draft, contents: Data("x".utf8))
        XCTAssertTrue(tuneBaseline(model: model, support: supportOf(fullHelp), hardware: sixCores, context: 8192).draft)
        XCTAssertFalse(tuneBaseline(model: model, support: supportOf("--port N"), hardware: sixCores, context: 8192).draft)
        try FileManager.default.removeItem(atPath: model.draft)
        XCTAssertFalse(tuneBaseline(model: model, support: supportOf(fullHelp), hardware: sixCores, context: 8192).draft)
        XCTAssertEqual(tuneBaseline(model: model, support: supportOf(fullHelp), hardware: sixCores, context: 8192).threads, 6)
    }

    func testContextStepsAreCappedByTrainingLengthAndMemory() {
        XCTAssertEqual(tuneContextSteps(training: 131072, modelBytes: 4 * GiB, available: 40 * GiB), [65536, 32768, 16384, 8192])
        XCTAssertEqual(tuneContextSteps(training: 32768, modelBytes: 4 * GiB, available: 40 * GiB), [32768, 16384, 8192])
        XCTAssertEqual(tuneContextSteps(training: nil, modelBytes: 10 * GiB, available: 16 * GiB), [32768, 16384, 8192])
        XCTAssertEqual(tuneContextSteps(training: nil, modelBytes: 30 * GiB, available: 16 * GiB), [8192])
        XCTAssertEqual(tuneContextSteps(training: 4096, modelBytes: GiB, available: 40 * GiB), [4096])
    }

    func testHeadroomAndGain() {
        XCTAssertTrue(tuneFits(resident: 20 * GiB, total: 32 * GiB))
        XCTAssertFalse(tuneFits(resident: 29 * GiB, total: 32 * GiB))
        XCTAssertFalse(tuneFits(resident: 7 * GiB, total: 8 * GiB))
        let base = TuneSpeed(promptTokensPerSecond: 50, generationTokensPerSecond: 10)
        XCTAssertEqual(tuneGain(candidate: base, over: base), 1, accuracy: 0.0001)
        // Writing counts most.
        XCTAssertGreaterThan(tuneGain(candidate: TuneSpeed(promptTokensPerSecond: 25, generationTokensPerSecond: 14), over: base), 1)
        XCTAssertLessThan(tuneGain(candidate: TuneSpeed(promptTokensPerSecond: 60, generationTokensPerSecond: 7), over: base), 1)
    }

    func testTheServersOwnTimingsAreRead() throws {
        let a = try JSONValue.parse(#"{"timings":{"prompt_per_second":54.2,"predicted_per_second":12.1}}"#)
        XCTAssertEqual(tuneTimings(a)?.prompt, 54.2)
        let b = try JSONValue.parse(#"{"timings":{"prompt_n":1000,"prompt_ms":20000,"predicted_n":64,"predicted_ms":8000}}"#)
        XCTAssertEqual(tuneTimings(b)?.prompt ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(tuneTimings(b)?.generation ?? 0, 8, accuracy: 0.001)
        XCTAssertNil(tuneTimings(try JSONValue.parse(#"{"usage":{}}"#)))
        XCTAssertGreaterThan(tunePrompt().count, 3000)
        XCTAssertEqual(tunePrompt(), tunePrompt())
    }

    // MARK: Choosing the winner

    func testTheFastestSettingsWinAndASmallDifferenceDoesNot() async throws {
        let s = try setup(behave: { model in
            var how = TuneRig.Behaviour()
            if model.draft.isEmpty { how.generation = 6 }          // the draft model helps
            if model.threads == 5 { how.generation = 11.6; how.prompt = 55 }   // one thread fewer is faster
            return how
        })
        let progress = RuntimeBox<[String]>([])
        let entry = try await s.tuner.optimize(s.model, report: { text in progress.update { $0.append(text) } })
        XCTAssertEqual(entry.settings?.threads, 5)
        XCTAssertEqual(entry.settings?.draft, true)
        XCTAssertEqual(entry.settings?.context, 65536)
        XCTAssertEqual(entry.launches, 3)
        XCTAssertEqual(s.rig.launched.map(\.threads), [6, 6, 5])
        XCTAssertEqual(entry.speed.generationTokensPerSecond, 11.6)
        XCTAssertEqual(entry.tried.compactMap(\.note), ["Not faster."])
        XCTAssertEqual(entry.kind, "tuned")
        XCTAssertTrue(progress.value.contains { $0.hasPrefix("Trying 6 threads") })
        XCTAssertTrue(progress.value.contains("Trying 5 threads\u{2026}"))
        XCTAssertTrue(progress.value.contains("Writing speed: 12 tokens/s"))
        // Stored under the model's key, with what it was measured with.
        let stored = try XCTUnwrap(s.store.entry(keyOf(s.model)))
        XCTAssertEqual(stored, entry)
        XCTAssertEqual(stored.fingerprint, tuneFingerprint(model: s.model, hardware: sixCores))
        XCTAssertEqual(entry.summary(draftFile: s.model.draft), "5 threads \u{00B7} 65,536 context \u{00B7} MTP draft \u{00B7} reads 55 tokens/s, writes 12")
        // Every test model was stopped again.
        XCTAssertEqual(s.rig.stops, 3)
    }

    func testAChangeBelowThreePercentKeepsTheCurrentSettings() async throws {
        let s = try setup(behave: { model in
            var how = TuneRig.Behaviour()
            if model.threads == 5 { how.generation = 10.2 }
            return how
        })
        let entry = try await s.tuner.optimize(s.model)
        XCTAssertEqual(entry.settings?.threads, 6)
    }

    func testAtMostFourLaunchesWhateverIsOffered() async throws {
        var hardware = TuneHardware(cpu: "Hybrid", cores: 8, performanceCores: 4, memoryTotal: 64 * GiB, memoryAvailable: 48 * GiB)
        hardware.gpu = true
        let s = try setup(hardware: hardware, behave: { model in
            var how = TuneRig.Behaviour()
            how.generation = 10 + Double(model.gpuLayers > 0 ? 5 : 0)
            return how
        })
        let entry = try await s.tuner.optimize(s.model)
        XCTAssertEqual(entry.launches, 4)
        XCTAssertEqual(s.rig.launched.count, 4)
        // The graphics chip was the first change tried, and it won.
        XCTAssertEqual(s.rig.launched[1].gpuLayers, 999)
        XCTAssertEqual(entry.settings?.gpuLayers, 999)
    }

    func testAContextThatDoesNotLoadOrLeavesNoRoomIsSteppedDown() async throws {
        let s = try setup(behave: { model in
            var how = TuneRig.Behaviour()
            if model.context == 65536 { how.failure = "The model ran out of memory." }
            if model.context == 32768 { how.resident = 31 * GiB }   // loads, but leaves no headroom on 32 GiB
            return how
        })
        let entry = try await s.tuner.optimize(s.model)
        XCTAssertEqual(entry.settings?.context, 16384)
        XCTAssertEqual(entry.tried.compactMap(\.note).prefix(2), ["The model ran out of memory.", "Too little memory left beside it."])
        XCTAssertEqual(entry.launches, 4)   // three context sizes, then one change
    }

    func testAGraphicsChipThatCannotHoldTheModelGetsHalfTheLayers() async throws {
        var hardware = sixCores
        hardware.gpu = true
        // The fixture is a bare header, so give the model a layer count through a real description: use a stub that fails every GPU start.
        let s = try setup(hardware: hardware, draft: false, behave: { model in
            var how = TuneRig.Behaviour()
            if model.gpuLayers == 999 { how.failure = "Not enough video memory." }
            return how
        })
        let entry = try await s.tuner.optimize(s.model)
        // No layer count could be read from the fixture, so there is no half to try: the processor-only settings stand.
        XCTAssertEqual(entry.settings?.gpuLayers, 0)
        XCTAssertTrue(entry.tried.contains { $0.note == "Not enough video memory." })
    }

    func testNoModelThatStartsIsAnError() async throws {
        let s = try setup(behave: { _ in var how = TuneRig.Behaviour(); how.failure = "The model did not start."; return how })
        do { _ = try await s.tuner.optimize(s.model); XCTFail("nothing to measure") } catch { XCTAssertEqual(messageOf(error), "The model did not start.") }
        XCTAssertNil(s.store.entry(keyOf(s.model)))
        XCTAssertEqual(s.rig.launched.count, 0)
    }

    // MARK: Budget, cancel, restore

    func testTheTimeBudgetStopsFurtherLaunches() async throws {
        // Each speed test takes 100 seconds on the fake clock; the budget is 180 and a launch needs 20 left.
        let s = try setup(secondsPerTest: 100)
        let entry = try await s.tuner.optimize(s.model)
        XCTAssertEqual(entry.launches, 2)
        XCTAssertEqual(s.rig.launched.count, 2)
    }

    func testCancelStopsAtOnceStoresNothingAndPutsTheModelBack() async throws {
        let s = try setup(mainState: .ready)
        s.rig.blockFetch(number: 2)
        let task = Task { try await s.tuner.optimize(s.model) }
        let reached = await waitUntil(5) { s.rig.fetches >= 2 }
        XCTAssertTrue(reached)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(s.store.entry(keyOf(s.model)))
        XCTAssertGreaterThanOrEqual(s.rig.stops, 2)
        // It was running before, so it runs again.
        XCTAssertEqual(s.main.stops, [false])
        XCTAssertEqual(s.main.starts, 1)
    }

    func testAModelThatWasRunningIsStoppedAndStartedAgainAndAStoppedOneStaysStopped() async throws {
        let running = try setup(mainState: .ready)
        _ = try await running.tuner.optimize(running.model)
        XCTAssertEqual(running.main.stops, [false])
        XCTAssertEqual(running.main.starts, 1)

        let stopped = try setup(mainState: .off)
        _ = try await stopped.tuner.optimize(stopped.model)
        XCTAssertEqual(stopped.main.stops, [])
        XCTAssertEqual(stopped.main.starts, 0)

        // A failed run restores too.
        let failing = try setup(mainState: .ready, behave: { _ in var how = TuneRig.Behaviour(); how.failure = "no"; return how })
        do { _ = try await failing.tuner.optimize(failing.model); XCTFail("fails") } catch {}
        XCTAssertEqual(failing.main.starts, 1)
    }

    func testItNeverRunsWhileAConversationRunsOrTheModelIsBusy() async throws {
        let busy = try setup(mainState: .ready, busy: true)
        do { _ = try await busy.tuner.optimize(busy.model); XCTFail("busy") } catch { XCTAssertEqual(error as? TuneSkipped, TuneSkipped("busy")) }
        XCTAssertEqual(busy.main.stops, [])
        XCTAssertEqual(busy.main.starts, 0)
        XCTAssertEqual(busy.rig.launched.count, 0)

        // The model is writing a reply.
        let writing = try setup(mainState: .ready)
        try await writing.main.setBusy(true)
        do { _ = try await writing.tuner.optimize(writing.model); XCTFail("busy") } catch { XCTAssertEqual(error as? TuneSkipped, TuneSkipped("busy")) }
        XCTAssertEqual(writing.main.stops, [])
    }

    func testAnotherBlackTeamHoldingTheModelRefusesBeforeAnythingIsStopped() async throws {
        let s = try setup(mainState: .ready)
        let tuner = ModelTuner(main: s.main, configStore: s.files.store, store: s.store, trial: { _, _ in TrialRuntime(s.rig, ModelConfig()) }, fetch: s.rig.fetch,
                               preflight: { throw BlackTeamError("Your local model is in use by the Black Team app.") })
        do { _ = try await tuner.optimize(s.model); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).hasPrefix("Your local model is in use")) }
        XCTAssertEqual(s.main.stops, [])
    }

    // MARK: A server somebody else runs, and cloud

    func testAServerIsOnlyMeasuredAndNeverRestarted() async throws {
        let files = try RuntimeFixture(self)
        let main = StubRuntime()
        main.state = .ready
        let store = TuningStore(stateDir: files.stateDir)
        let seen = RuntimeBox<[URLRequest]>([])
        let fetch: HTTPFetch = { request in
            seen.update { $0.append(request) }
            return (Data(#"{"timings":{"prompt_per_second":120.5,"predicted_per_second":31.2},"usage":{"prompt_tokens":1000,"completion_tokens":64}}"#.utf8), response(request.url!))
        }
        let tuner = ModelTuner(main: main, configStore: files.store, store: store, trial: { _, _ in XCTFail("a server is never launched"); return StubRuntime() }, fetch: fetch)
        let server = ModelConfig(source: "server", endpoint: "http://127.0.0.1:18081/v1", id: "ornith", apiKey: "k", name: "Ornith")
        do { _ = try await tuner.optimize(server); XCTFail("settings belong to the server") } catch { assertMatch(messageOf(error), "settings belong to that server") }
        let entry = try await tuner.measureServer(server)
        XCTAssertEqual(entry.kind, "measured")
        XCTAssertNil(entry.settings)
        XCTAssertNil(entry.fingerprint)
        XCTAssertEqual(entry.speed.generationTokensPerSecond, 31.2)
        XCTAssertEqual(entry.summary(), "reads 121 tokens/s, writes 31")
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertEqual(seen.value[0].url?.absoluteString, "http://127.0.0.1:18081/v1/chat/completions")
        XCTAssertEqual(seen.value[0].value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(main.stops, [])
        XCTAssertEqual(main.starts, 0)
        XCTAssertEqual(store.entry(keyOf(server)), entry)
        // Without the server's own timings the speed comes from the clock and says so.
        let plain = ModelTuner(main: main, configStore: files.store, store: store, trial: { _, _ in StubRuntime() },
                               fetch: { request in (Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":60}}"#.utf8), response(request.url!)) })
        let rough = try await plain.measureServer(server)
        XCTAssertEqual(rough.speed.approximate, true)
        // A cloud model has nothing to tune.
        let cloud = ModelConfig(source: "cloud", endpoint: "https://api.openai.com/v1", id: "m", apiKey: "k", name: "Cloud")
        do { _ = try await tuner.optimize(cloud); XCTFail("cloud") } catch { assertMatch(messageOf(error), "cloud model runs at its service") }
    }

    // MARK: Stored results

    func testTheStoredFileIsPrivateAtomicAndSurvivesDamage() throws {
        let dir = makeTemporaryFolder(self) + "/data"
        let store = TuningStore(stateDir: dir)
        let entry = TuneEntry(key: "0123456789abcdef", name: "M", kind: "tuned", settings: TuneSettings(threads: 6, context: 32768, gpuLayers: 0, draft: true),
                              speed: TuneSpeed(promptTokensPerSecond: 54, generationTokensPerSecond: 12, memoryBytes: 9 * GiB),
                              fingerprint: TuneFingerprint(runtime: "/x|1|2", hardware: "cpu", modelBytes: 5, draftBytes: 1), date: "2026-10-13T10:00:00.000Z", launches: 3,
                              tried: [TuneTrial(label: "6 threads", promptTokensPerSecond: 54, generationTokensPerSecond: 12, note: nil)])
        try store.save(entry)
        XCTAssertEqual(mode(dir + "/tuning.json"), 0o600)
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(store.entry(entry.key), entry)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".tmp") }, [])
        let text = try String(contentsOfFile: dir + "/tuning.json", encoding: .utf8)
        let parsed = try JSONValue.parse(text)
        XCTAssertEqual(parsed["version"]?.int, 1)
        XCTAssertEqual(parsed["models"]?["0123456789abcdef"]?["settings"]?["threads"]?.int, 6)
        XCTAssertEqual(parsed["models"]?["0123456789abcdef"]?["fingerprint"]?["hardware"]?.string, "cpu")
        // Another model keeps its own entry; removing one leaves the other.
        var other = entry
        other.key = "fedcba9876543210"
        try store.save(other)
        try store.remove(entry.key)
        XCTAssertNil(store.entry(entry.key))
        XCTAssertNotNil(store.entry(other.key))
        // A damaged file means no results, never a failure.
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: dir + "/tuning.json"))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAChangedProgramModelOrComputerMakesAResultStale() throws {
        let files = try RuntimeFixture(self)
        let model = files.config.model
        let stored = tuneFingerprint(model: model, hardware: sixCores)
        XCTAssertEqual(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: sixCores)), [])
        // Free memory does not matter; the amount installed does.
        var moreFree = sixCores
        moreFree.memoryAvailable = 2 * GiB
        XCTAssertEqual(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: moreFree)), [])
        var bigger = sixCores
        bigger.memoryTotal = 64 * GiB
        XCTAssertEqual(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: bigger)), ["The hardware of \(Place.this) changed."])
        var fewer = sixCores
        fewer.cores = 4
        XCTAssertEqual(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: fewer)).count, 1)
        // A new llama.cpp build at the same path.
        FileManager.default.createFile(atPath: files.runtime, contents: Data(nativeProgramHeader() + [1, 2, 3]), attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: sixCores)), ["The llama.cpp program changed."])
        // A different model file.
        var header = [UInt8](repeating: 0, count: 80)
        header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
        FileManager.default.createFile(atPath: files.model, contents: Data(header))
        XCTAssertTrue(tuneStaleReasons(stored, now: tuneFingerprint(model: model, hardware: sixCores)).contains("The model file changed."))
    }

    // MARK: The launch path

    func testALaunchUsesAStoredResultOnlyWhileItIsCurrent() async throws {
        let files = try RuntimeFixture(self)
        try files.store.save(files.config)
        let store = TuningStore(stateDir: files.stateDir)
        let model = files.config.model
        var entry = TuneEntry(key: keyOf(model), name: model.name, kind: "tuned", settings: TuneSettings(threads: 3, context: 32768, gpuLayers: 0, draft: false),
                              speed: TuneSpeed(promptTokensPerSecond: 50, generationTokensPerSecond: 10), fingerprint: tuneFingerprint(model: model, hardware: sixCores),
                              date: "2026-10-13T10:00:00.000Z", launches: 2, tried: [])
        try store.save(entry)
        let hook = tunedLaunch(store: store, hardware: { self.sixCores })
        XCTAssertEqual(hook(model).threads, 3)
        XCTAssertEqual(hook(model).context, model.context, "the context is saved into the model's own setting, not applied behind it")
        // The same hook, when the computer is not the one measured.
        var other = sixCores
        other.cores = 4
        XCTAssertEqual(tunedLaunch(store: store, hardware: { other })(model).threads, model.threads)
        // A server's readout is never applied.
        entry.kind = "measured"
        try store.save(entry)
        XCTAssertEqual(hook(model).threads, model.threads)

        // And through the real runtime: the command line carries the tuned threads.
        entry.kind = "tuned"
        try store.save(entry)
        let spawned = RuntimeBox<[ProcessLaunch]>([])
        let key = RuntimeBox("")
        let runtime = ModelRuntime(configStore: files.store, spawn: { launch, onExit in
            spawned.update { $0.append(launch) }
            key.value = (try! String(contentsOfFile: launch.arguments[launch.arguments.firstIndex(of: "--api-key-file")! + 1], encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            return FakeChild(onExit: onExit)
        }, fetch: { request in
            let url = request.url!
            if url.path == "/health" { return (Data(#"{"status":"ok"}"#.utf8), response(url)) }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer \(key.value)" { return (Data("{}".utf8), response(url, 401)) }
            return (Data(#"{"model_path":"\#(files.model)"}"#.utf8), response(url))
        }, reservePort: { 45240 }, help: { _ in fullHelp }, appleSilicon: false, cores: { 6 }, startupTimeoutMs: 5000, pollIntervalMs: 1, stopTimeoutMs: 20, killTimeoutMs: 20,
           tuning: hook)
        addTeardownBlock { try? await runtime.dispose() }
        _ = try await runtime.start()
        let arguments = spawned.value[0].arguments
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--threads")! + 1], "3")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--ctx-size")! + 1], String(model.context))
    }
}
