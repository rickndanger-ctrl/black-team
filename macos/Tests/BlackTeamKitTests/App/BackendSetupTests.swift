import XCTest
@testable import BlackTeamKit

// The desktop window's setup actions (main.cjs and tests/native.test.cjs) and the Mac's starter setup.
final class BackendSetupTests: XCTestCase {
    func ggufFile(_ path: String, bytes: Int = 300 * 1024 * 1024) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var header = [UInt8](repeating: 0, count: 24)
        header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
        FileManager.default.createFile(atPath: path, contents: Data(header))
        let handle = FileHandle(forWritingAtPath: path)!
        try! handle.truncate(atOffset: UInt64(bytes))
        try! handle.close()
    }

    func testSavingAModelAddsItToTheListAndSwitchingAndRemovingReachTheList() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let other = fixture.files.dir + "/Other model.gguf"
        ggufFile(other, bytes: 64)
        // The model set up at the start is already in the list.
        XCTAssertEqual(backend.savedModels.read().map(\.name), ["Fixture model"])
        let saved = try await backend.saveSetup(["model": ["source": "gguf", "file": .string(other), "name": "Other", "runtime": .string(fixture.files.runtime), "context": 8192]])
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(backend.savedModels.read().map(\.name).sorted(), ["Fixture model", "Other"])
        XCTAssertEqual(try backend.configStore.read().model.name, "Other")
        let first = backend.savedModels.read().first { $0.name == "Fixture model" }!
        let switched = try await backend.switchTo(key: keyOf(first))
        XCTAssertEqual(switched, SwitchResult(switched: true, name: "Fixture model"))
        XCTAssertEqual(try backend.configStore.read().model.name, "Fixture model")
        XCTAssertEqual(fixture.runtime.stops, [false])
        do { try await backend.forget(key: keyOf(first)); XCTFail("in use") } catch { assertMatch(messageOf(error), "in use") }
        let otherModel = backend.savedModels.read().first { $0.name == "Other" }!
        try await backend.forget(key: keyOf(otherModel))
        XCTAssertEqual(backend.savedModels.read().map(\.name), ["Fixture model"])
        do { _ = try await backend.saveSetup(["model": [:], "extra": 1]); XCTFail("unsupported") } catch { assertMatch(messageOf(error), "Unsupported setup setting") }
    }

    func testSavingIsRefusedWhileTheModelRunsOrAJobIsActive() async throws {
        let fixture = try BackendFixture(self)
        fixture.runtime.state = .ready
        let backend = try fixture.make()
        do { _ = try await backend.saveSetup(["model": ["name": "X"]]); XCTFail("running") } catch {
            XCTAssertEqual(messageOf(error), "Stop the model before changing its configuration.")
        }
        do { _ = try await backend.saveIntegrations([:]) } catch { XCTFail("no job is active: \(error)") }
    }

    func testAModelFileWithNoRuntimeUsesTheDownloadedOne() async throws {
        let fixture = try BackendFixture(self)
        let installer = StubInstaller(fixture.files.dir)
        fixture.installer = installer
        installer.current = try installer.writeRuntime()
        let backend = try fixture.make()
        let file = fixture.files.dir + "/x.gguf"
        ggufFile(file, bytes: 64)
        _ = try await backend.saveSetup(["model": ["source": "gguf", "file": .string(file), "name": "Plain", "runtime": ""]])
        XCTAssertEqual(try backend.configStore.read().model.runtime, installer.current?.executable)
        let added = try await backend.add(models: [["source": "gguf", "file": .string(fixture.files.model), "name": "Found one"]])
        XCTAssertEqual(added.added, ["Found one"])
        XCTAssertEqual(backend.savedModels.read().first { $0.name == "Found one" }?.runtime, installer.current?.executable)
    }

    func testAChosenModelFileIsDescribedWithItsCompanions() throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let file = fixture.files.dir + "/models/Pretty-7B-Q4.gguf"
        ggufFile(file, bytes: 4096)
        ggufFile(fixture.files.dir + "/models/mmproj-F16.gguf", bytes: 64)
        let described = try backend.inspectModelFile(file)
        XCTAssertEqual(described.bytes, 4096)
        XCTAssertEqual(described.mmproj, fixture.files.dir + "/models/mmproj-F16.gguf")
        XCTAssertEqual(described.draft, "")
        XCTAssertGreaterThanOrEqual(described.context, 512)
        XCTAssertThrowsError(try backend.inspectModelFile(fixture.files.dir + "/nothing.gguf"))
    }

    func testAModelFoundAfterSetupJoinsTheListAndARemovedOneStaysOut() async throws {
        let fixture = try BackendFixture(self)
        // A found file needs a llama.cpp to run it; the downloaded one, so the test does not lean on a server running here.
        let installer = StubInstaller(fixture.files.dir)
        fixture.installer = installer
        installer.current = try installer.writeRuntime()
        let backend = try fixture.make()
        ggufFile(backend.dataFolder + "/models/Found-3B-Q4.gguf")
        let report = await backend.findMyModels()
        let item = try XCTUnwrap(report.files.first { $0.file.file.hasSuffix("Found-3B-Q4.gguf") })
        XCTAssertEqual(item.key, keyOf(ModelConfig(source: "gguf", file: item.file.file)))
        // It works like the model chosen at setup: in the list with no step of its own, and the model in use is unchanged.
        XCTAssertTrue(item.saved)
        XCTAssertEqual(report.added, [item.file.name])
        XCTAssertEqual(backend.savedModels.read().map(\.name).sorted(), ["Fixture model", item.file.name].sorted())
        XCTAssertEqual(try backend.configStore.read().model.name, "Fixture model")
        let again = await backend.findMyModels()
        XCTAssertEqual(again.added, [])
        // Removing it is remembered: the next look does not put it back.
        try await backend.forget(key: item.key)
        let after = await backend.findMyModels()
        XCTAssertEqual(after.added, [])
        let left = try XCTUnwrap(after.files.first { $0.key == item.key })
        XCTAssertFalse(left.saved)
        XCTAssertTrue(left.ignored)
        XCTAssertEqual(backend.savedModels.read().map(\.name), ["Fixture model"])
    }

    func testAFoundModelThatWasPassedOverIsMarkedAndStaysOut() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let file = backend.dataFolder + "/models/Found-3B-Q4.gguf"
        ggufFile(file)
        let ignoredNow = try await backend.ignore(key: keyOf(ModelConfig(source: "gguf", file: file)))
        XCTAssertTrue(ignoredNow)
        let report = await backend.findMyModels()
        let item = try XCTUnwrap(report.files.first { $0.file.file.hasSuffix("Found-3B-Q4.gguf") })
        XCTAssertFalse(item.saved)
        XCTAssertTrue(item.ignored)
        XCTAssertEqual(report.added, [])
    }

    func testSetupActionsDoNotOverlap() async throws {
        let fixture = try BackendFixture(self)
        let gate = BackendGate()
        fixture.runtime.stopAction = { await gate.wait() }
        let backend = try fixture.make()
        let key = keyOf(try backend.configStore.read().model)
        let slow = Task { try await backend.switchTo(key: key) }
        try await Task.sleep(nanoseconds: 100_000_000)
        do { try await backend.startModel(); XCTFail("overlap") } catch { XCTAssertEqual(messageOf(error), "Another setup action is still running.") }
        await gate.open()
        _ = try await slow.value
        try await backend.startModel()
        let began = await waitUntil { fixture.runtime.starts == 1 }
        XCTAssertTrue(began)
    }

    func testStoppingTheModelNeedsNoRunningResponse() async throws {
        let fixture = try BackendFixture(self)
        let gate = BackendGate()
        fixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        let backend = try fixture.make()
        try backend.submit(message: "hello", requestId: newID())
        do { try await backend.stopModel(); XCTFail("busy") } catch { XCTAssertEqual(messageOf(error), "Stop the response before stopping the model.") }
        await gate.open()
        await backend.waitForIdle()
        try await backend.stopModel()
        XCTAssertEqual(fixture.runtime.stops, [false])
    }

    func testHelpLinksAreFixedAndChoosersAreOnlyTheKnownKinds() throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.helpLink(topic: "https://example.com")) { assertMatch(messageOf($0), "Unsupported") }
        XCTAssertEqual(try backend.helpLink(topic: "ollama"), "https://ollama.com/download/mac")
        XCTAssertThrowsError(try backend.pickerRequest("arbitrary-file")) { assertMatch(messageOf($0), "Unsupported chooser") }
        XCTAssertEqual(try backend.pickerRequest("model").extensions, ["gguf"])
        XCTAssertTrue(try backend.pickerRequest("workspace").directory)
        XCTAssertEqual(try backend.dataFolderPath(), backend.dataFolder)
    }

    func testIntegrationsAreSavedAndRefusedWhileATaskRuns() async throws {
        let fixture = try BackendFixture(self)
        let gate = BackendGate()
        fixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        let backend = try fixture.make()
        _ = try await backend.saveIntegrations(["engine": "black-team"])
        try backend.submit(message: "hello", requestId: newID())
        do { _ = try await backend.saveIntegrations([:]); XCTFail("busy") } catch { assertMatch(messageOf(error), "Wait for the current task") }
        do { _ = try await backend.connect(harness: "claude") ; XCTFail("busy") } catch { assertMatch(messageOf(error), "Wait for the current task") }
        do { _ = try await backend.launch(harness: "claude"); XCTFail("busy") } catch { assertMatch(messageOf(error), "Wait for the current task") }
        await gate.open()
        await backend.waitForIdle()
    }

    // MARK: Starter setup

    func testSettingUpAStarterDownloadsTheRuntimeAndModelThenSavesAndRemembersTheModel() async throws {
        let fixture = try BackendFixture(self)
        fixture.files.config.model = ModelConfig()
        let installer = StubInstaller(fixture.files.dir)
        let downloader = StubDownloader()
        fixture.installer = installer
        fixture.downloader = downloader
        try FileManager.default.removeItem(atPath: fixture.stateDir + "/config.json")
        let backend = try fixture.make()
        let before = try await backend.status()
        XCTAssertFalse(before.setupComplete)
        XCTAssertNil(before.downloadedRuntime)
        let seen = SetupProgresses()
        let result = try await backend.setUpStarter(modelID: "qwen3.5-0.8b") { seen.add($0) }
        let model = try XCTUnwrap(StarterModels.model(id: "qwen3.5-0.8b"))
        XCTAssertEqual(result.modelName, model.name)
        XCTAssertEqual(result.file, backend.dataFolder + "/models/" + model.filename)
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(downloader.requests.map(\.url), [model.url])
        let config = try backend.configStore.read()
        XCTAssertEqual(config.model.file, result.file)
        XCTAssertEqual(config.model.runtime, installer.current?.executable)
        XCTAssertEqual(config.model.context, model.contextSize)
        XCTAssertEqual(config.model.name, model.name)
        XCTAssertEqual(config.model.source, "gguf")
        XCTAssertEqual(backend.savedModels.read().map(\.name), [model.name])
        let after = try await backend.status()
        XCTAssertTrue(after.setupComplete)
        XCTAssertEqual(after.downloadedRuntime?.tag, "b9999")
        let stages = seen.all.map(\.stage)
        XCTAssertTrue(stages.contains("Downloading the llama.cpp runtime"))
        XCTAssertTrue(stages.contains("Downloading \(model.name)"))
        XCTAssertEqual(stages.last, "Ready")
        XCTAssertTrue(seen.all.contains { $0.fraction == 0.5 && $0.bytesPerSecond == 1000 })
        let catalogue = backend.starterModels()
        XCTAssertTrue(catalogue.models.first { $0.id == "qwen3.5-0.8b" }?.installed ?? false)
        XCTAssertFalse(catalogue.models.first { $0.id == "qwen3.5-4b" }?.installed ?? true)
        XCTAssertEqual(catalogue.models.filter(\.recommended).count, 1)
        XCTAssertEqual(catalogue.runtime?.tag, "b9999")
    }

    func testTheWindowListsStartersStartsADownloadAndReadsItsProgressFromStatus() async throws {
        let fixture = try BackendFixture(self)
        fixture.files.config.model = ModelConfig()
        let installer = StubInstaller(fixture.files.dir)
        let downloader = StubDownloader()
        fixture.installer = installer
        fixture.downloader = downloader
        try FileManager.default.removeItem(atPath: fixture.stateDir + "/config.json")
        let backend = try fixture.make()
        let control = DesktopControl(backend)
        let list = try await control.handle("starter-list")
        XCTAssertEqual(list["models"]?.array?.count, StarterModels.all.count)
        XCTAssertEqual(list["models"]?.array?.filter { $0["recommended"]?.bool == true }.count, 1)
        XCTAssertEqual(list["models"]?.array?.first?["installed"]?.bool, false)
        let before = try await control.handle("status")
        XCTAssertEqual(before["starterInstall"]?["running"]?.bool, false)
        let started = try await control.handle("starter-install", ["id": "qwen3.5-0.8b"])
        XCTAssertEqual(started["started"]?.bool, true)
        var last: JSONValue = .null
        for _ in 0..<200 {
            last = try await control.handle("status")
            if last["starterInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["starterInstall"]?["error"]?.string, "")
        XCTAssertEqual(last["starterInstall"]?["done"]?.bool, true)
        XCTAssertEqual(last["setupComplete"]?.bool, true)
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(try backend.configStore.read().model.name, StarterModels.model(id: "qwen3.5-0.8b")?.name)
        let after = try await control.handle("starter-list")
        XCTAssertEqual(after["models"]?.array?.first { $0["model"]?["id"]?.string == "qwen3.5-0.8b" }?["installed"]?.bool, true)
        // An id that is not in the list fails in the engine's words; a phone is refused; extra settings are refused.
        _ = try await control.handle("starter-install", ["id": "nope"])
        for _ in 0..<200 {
            last = try await control.handle("status")
            if last["starterInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["starterInstall"]?["error"]?.string, "That starter model is not in the list.")
        do { _ = try await control.handle("starter-install", ["id": "qwen3.5-0.8b"], access: .phone); XCTFail("a phone must be refused") } catch {}
        do { _ = try await control.handle("starter-install", ["id": "qwen3.5-0.8b", "url": "https://example.com"]); XCTFail("should refuse") } catch { XCTAssertEqual(messageOf(error), "Unsupported setup setting.") }
        let stopped = try await control.handle("starter-cancel")
        XCTAssertEqual(stopped["stopped"]?.bool, true)
    }

    func testASecondSetupSkipsWhatIsAlreadyInstalledAndFollowsFindMyModels() async throws {
        let fixture = try BackendFixture(self)
        let installer = StubInstaller(fixture.files.dir)
        let downloader = StubDownloader()
        fixture.installer = installer
        fixture.downloader = downloader
        let backend = try fixture.make()
        try await backend.setUpStarter(modelID: "qwen3.5-0.8b")
        try await backend.setUpStarter(modelID: "qwen3.5-0.8b")
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(downloader.requests.count, 1)
        // "Find my models" now offers the downloaded runtime and sees the downloaded file as saved.
        let report = await backend.findMyModels()
        XCTAssertEqual(report.runtime, installer.current?.executable)
        XCTAssertTrue(report.files.first { $0.file.file.hasSuffix("Qwen3.5-0.8B-Q4_K_M.gguf") }?.saved ?? false)
    }

    func testStarterSetupRefusesAnUnknownModelARunningModelAndAFailedDownload() async throws {
        let fixture = try BackendFixture(self)
        let installer = StubInstaller(fixture.files.dir)
        let downloader = StubDownloader()
        fixture.installer = installer
        fixture.downloader = downloader
        let backend = try fixture.make()
        do { try await backend.setUpStarter(modelID: "nope"); XCTFail("unknown") } catch { XCTAssertEqual(messageOf(error), "That starter model is not in the list.") }
        fixture.runtime.state = .ready
        do { try await backend.setUpStarter(modelID: "qwen3.5-0.8b"); XCTFail("running") } catch { assertMatch(messageOf(error), "Stop the model") }
        XCTAssertEqual(installer.installs, 0)
        fixture.runtime.state = .off
        downloader.failure = BlackTeamError("Not enough free space.")
        do { try await backend.setUpStarter(modelID: "qwen3.5-0.8b"); XCTFail("download") } catch { XCTAssertEqual(messageOf(error), "Not enough free space.") }
        // The setup lock is released after a failure, and the config is untouched.
        XCTAssertEqual(try backend.configStore.read().model.name, "Fixture model")
        downloader.failure = nil
        try await backend.setUpStarter(modelID: "qwen3.5-0.8b")
    }
}

final class SetupProgresses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SetupProgress] = []
    func add(_ item: SetupProgress) { lock.lock(); items.append(item); lock.unlock() }
    var all: [SetupProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

final class StubInstaller: RuntimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    let dir: String
    private var _current: InstalledRuntime?
    private var _installs = 0
    init(_ dir: String) { self.dir = dir }
    var current: InstalledRuntime? { get { lock.lock(); defer { lock.unlock() }; return _current } set { lock.lock(); _current = newValue; lock.unlock() } }
    var installs: Int { lock.lock(); defer { lock.unlock() }; return _installs }

    /// A llama-server that looks like a native executable to the checks.
    func writeRuntime() throws -> InstalledRuntime {
        let folder = dir + "/runtime/b9999"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let exe = nativeProgramHeader()
        let path = folder + "/llama-server"
        FileManager.default.createFile(atPath: path, contents: Data(exe), attributes: [.posixPermissions: 0o700])
        return InstalledRuntime(tag: "b9999", executable: path, architecture: .current, installedAt: "2026-10-11T00:00:00Z", previousTag: nil, versionOutput: nil)
    }

    private func bump() { lock.lock(); _installs += 1; lock.unlock() }
    func installedRuntime() -> InstalledRuntime? { current }
    func installLatest(progress: (@Sendable (RuntimeInstallEvent) -> Void)?) async throws -> InstalledRuntime {
        bump()
        progress?(.checking)
        progress?(.downloading(DownloadProgress(bytesReceived: 6, totalBytes: 12, bytesPerSecond: 1000)))
        let made = try writeRuntime()
        current = made
        progress?(.done(made))
        return made
    }
    func cancel() {}
}

final class StubDownloader: FileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [DownloadRequest] = []
    var failure: Error?
    var requests: [DownloadRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ request: DownloadRequest) { lock.lock(); _requests.append(request); lock.unlock() }

    func download(_ request: DownloadRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> URL {
        record(request)
        if let failure { throw failure }
        progress?(DownloadProgress(bytesReceived: 100, totalBytes: 200, bytesPerSecond: 1000))
        try FileManager.default.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header = [UInt8](repeating: 0, count: 24)
        header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
        FileManager.default.createFile(atPath: request.destination.path, contents: Data(header))
        // As large as the real model on paper, a few bytes on disk.
        let handle = try FileHandle(forWritingTo: request.destination)
        try handle.truncate(atOffset: UInt64(request.expectedSize ?? 24))
        try handle.close()
        return request.destination
    }
    func cancel() {}
}
