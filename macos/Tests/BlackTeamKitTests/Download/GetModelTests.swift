import XCTest
@testable import BlackTeamKit

/// Download -> saved -> ready, with a fake downloader, a fake runtime installer and a pretend huggingface.co.
final class GetModelTests: XCTestCase {
    let gib: Int64 = 1 << 30

    func rig(firstRun: Bool = true) throws -> (BackendFixture, Backend, StubInstaller, StubDownloader, HubSpy) {
        let fixture = try BackendFixture(self)
        let installer = StubInstaller(fixture.files.dir)
        let downloader = StubDownloader()
        fixture.installer = installer
        fixture.downloader = downloader
        if firstRun {
            fixture.files.config.model = ModelConfig()
            try FileManager.default.removeItem(atPath: fixture.stateDir + "/config.json")
        }
        let backend = try fixture.make()
        let spy = HubSpy.recorded()
        backend.hubFetch = spy.fetch
        backend.hardwareOverride = HardwareProfile(cpuName: "Test", cores: 8, totalMemory: 32 * gib, availableMemory: 28 * gib, freeDisk: 500 * gib)
        return (fixture, backend, installer, downloader, spy)
    }

    func testCatalogueModelDownloadsInstallsRuntimeSavesAndIsReady() async throws {
        let (_, backend, installer, downloader, spy) = try rig()
        let complete1229 = try await backend.status().setupComplete
        XCTAssertFalse(complete1229)
        let seen = SetupProgresses()
        let result = try await backend.getModel(.catalogue(id: "gemma-4-12b", vision: true, draft: true)) { seen.add($0) }
        let model = try XCTUnwrap(ModelCatalogue.model(id: "gemma-4-12b"))
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.message, "Ready. Start chatting.")
        XCTAssertTrue(result.inUse)
        XCTAssertTrue(result.thirdParty)
        XCTAssertEqual(result.license, "Apache-2.0")
        XCTAssertEqual(installer.installs, 1)
        XCTAssertEqual(downloader.requests.map(\.url), [model.url, model.vision!.url, model.draft!.url])
        XCTAssertEqual(downloader.requests.map(\.expectedSHA256), [model.sha256, model.vision!.sha256, model.draft!.sha256])
        let config = try backend.configStore.read().model
        XCTAssertEqual(config.file, backend.dataFolder + "/models/" + model.filename)
        XCTAssertEqual(config.name, model.name)
        XCTAssertEqual(config.runtime, installer.current?.executable)
        XCTAssertEqual(config.mmproj, backend.dataFolder + "/models/" + model.vision!.localName)
        XCTAssertEqual(config.draft, backend.dataFolder + "/models/" + model.draft!.localName)
        XCTAssertLessThanOrEqual(config.context, model.contextSize)
        XCTAssertEqual(result.key, keyOf(config))
        XCTAssertEqual(backend.savedModels.read().map(\.name), [model.name])
        let complete2685 = try await backend.status().setupComplete
        XCTAssertTrue(complete2685)
        XCTAssertEqual(seen.all.last?.stage, "Ready")
        XCTAssertTrue(seen.all.contains { $0.stage.hasPrefix("Downloading Gemma 4 12B") })
        XCTAssertTrue(spy.requests.isEmpty, "a catalogue download asks Hugging Face for nothing but the file")
        // Asking again downloads nothing more.
        let again = try await backend.getModel(.catalogue(id: "gemma-4-12b", vision: true, draft: true))
        XCTAssertTrue(again.ready)
        XCTAssertEqual(downloader.requests.count, 3)
    }

    func testAnyHuggingFaceFileIsCheckedAgainstTheApiAndSaved() async throws {
        let (_, backend, _, downloader, spy) = try rig()
        let result = try await backend.getModel(.hub(repo: "unsloth/gemma-4-12b-it-GGUF", path: "gemma-4-12b-it-Q4_K_M.gguf", vision: true, draft: false))
        let request = try XCTUnwrap(downloader.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf")
        XCTAssertEqual(request.expectedSHA256, "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42")
        XCTAssertEqual(request.expectedSize, 7_121_861_440)
        XCTAssertEqual(request.allowedHostSuffixes, DownloadHosts.huggingFace)
        XCTAssertEqual(downloader.requests.count, 2)
        XCTAssertEqual(downloader.requests[1].destination.lastPathComponent, "gemma-4-12b-it-Q4_K_M-mmproj.gguf")
        XCTAssertEqual(downloader.requests[1].expectedSHA256, "91f086971e56d7a7d8d39e271873fccdb49541bd259d6e02c401a4f1cb7a219e")
        XCTAssertEqual(result.message, "Ready. Start chatting.")
        XCTAssertEqual(result.repo, "unsloth/gemma-4-12b-it-GGUF")
        XCTAssertEqual(result.license, "apache-2.0")
        let config = try backend.configStore.read().model
        XCTAssertTrue(config.mmproj.hasSuffix("-mmproj.gguf"))
        XCTAssertEqual(config.draft, "")
        XCTAssertTrue(spy.requests.allSatisfy { $0.url?.host == "huggingface.co" })
    }

    func testAModelWhenOneIsAlreadySetUpJoinsTheListWithoutReplacingIt() async throws {
        let (_, backend, _, _, _) = try rig(firstRun: false)
        let before = try backend.configStore.read().model
        let result = try await backend.getModel(.catalogue(id: "qwen3.5-4b"))
        XCTAssertFalse(result.inUse)
        assertMatch(result.message, "added to your models")
        XCTAssertEqual(try backend.configStore.read().model, before)
        XCTAssertTrue(backend.savedModels.read().contains { $0.name == "Qwen3.5 4B (small)" })
        // Asked to use it now: it becomes the model in use.
        let now = try await backend.getModel(.catalogue(id: "qwen3.5-4b"), makeCurrent: true)
        XCTAssertTrue(now.inUse)
        XCTAssertEqual(try backend.configStore.read().model.name, "Qwen3.5 4B (small)")
    }

    func testRefusalsAreInPlainWords() async throws {
        let (fixture, backend, installer, downloader, spy) = try rig()
        do { _ = try await backend.getModel(.catalogue(id: "nope")); XCTFail("unknown") } catch { XCTAssertEqual(messageOf(error), "That model is not in the list.") }
        do { _ = try await backend.getModel(.hub(repo: "../x", path: "a.gguf")); XCTFail("repo") } catch { assertMatch(messageOf(error), "not a model file on Hugging Face") }
        do { _ = try await backend.getModel(.hub(repo: "a/b", path: "../a.gguf")); XCTFail("path") } catch { assertMatch(messageOf(error), "not a model file on Hugging Face") }
        do { _ = try await backend.getModel(.hub(repo: "unsloth/gemma-4-12b-it-GGUF", path: "nothing.gguf")); XCTFail("missing") } catch { assertMatch(messageOf(error), "not in the repository") }
        do { _ = try await backend.getModel(.hub(repo: "unsloth/gemma-4-12b-it-GGUF", path: "mmproj-F16.gguf")); XCTFail("helper") } catch { assertMatch(messageOf(error), "not in the repository") }
        do { _ = try await backend.getModel(.hub(repo: "unsloth/Qwen3.5-122B-A10B-GGUF", path: "Q4_K_M/Qwen3.5-122B-A10B-Q4_K_M-00001-of-00003.gguf")); XCTFail("split") } catch { assertMatch(messageOf(error), "split into several parts") }
        // Gated.
        spy.routes["/api/models/g/gated"] = (200, #"{"id":"g/gated","gated":"manual","tags":[]}"#)
        spy.routes["/api/models/g/gated/tree/main"] = (200, "[]")
        do { _ = try await backend.getModel(.hub(repo: "g/gated", path: "x.gguf")); XCTFail("gated") } catch { assertMatch(messageOf(error), "accept its terms") }
        spy.routes["/api/models/g/private"] = (401, "{}")
        do { _ = try await backend.getModel(.hub(repo: "g/private", path: "x.gguf")); XCTFail("private") } catch { assertMatch(messageOf(error), "does not sign in") }
        // Not enough disk.
        backend.hardwareOverride?.freeDisk = 1_000_000_000
        do { _ = try await backend.getModel(.catalogue(id: "gemma-4-12b")); XCTFail("disk") } catch { assertMatch(messageOf(error), "Not enough free disk space") }
        backend.hardwareOverride?.freeDisk = 500 * gib
        // A model that is running is not swapped for another.
        fixture.runtime.state = .ready
        do { _ = try await backend.getModel(.catalogue(id: "qwen3.5-4b")); XCTFail("running") } catch { assertMatch(messageOf(error), "Stop the model") }
        fixture.runtime.state = .off
        XCTAssertEqual(installer.installs, 0)
        XCTAssertTrue(downloader.requests.isEmpty)
        // A failed download leaves the setup lock free and the config untouched.
        downloader.failure = BlackTeamError("The download was interrupted.")
        do { _ = try await backend.getModel(.catalogue(id: "qwen3.5-4b")); XCTFail("download") } catch { XCTAssertEqual(messageOf(error), "The download was interrupted.") }
        let complete8446 = try await backend.status().setupComplete
        XCTAssertFalse(complete8446)
        downloader.failure = nil
        _ = try await backend.getModel(.catalogue(id: "qwen3.5-4b"))
    }

    func testTheRecommendationIsServedFromThisComputersProfile() async throws {
        let (_, backend, _, _, spy) = try rig()
        let list = backend.modelRecommendations()
        XCTAssertEqual(list.models.count, ModelCatalogue.all.count)
        XCTAssertNotNil(list.bestID)
        XCTAssertTrue(spy.requests.isEmpty, "ranking is local")
        backend.hardwareOverride = HardwareProfile(cores: 8, totalMemory: 32 * gib, freeDisk: 500 * gib,
                                                   gpu: .init(name: "NVIDIA card", vendor: "NVIDIA", vramBytes: 24 * gib, vramSource: "pci-window"), gpuUsable: false)
        assertMatch(backend.modelRecommendations().note ?? "", "uses the processor only")
    }

    func testTheWindowSearchesListsFilesDownloadsAndReadsProgressFromStatus() async throws {
        let (_, backend, _, _, spy) = try rig()
        let control = DesktopControl(backend)
        let ranked = try await control.handle("models-recommend")
        XCTAssertEqual(ranked["models"]?.array?.count, ModelCatalogue.all.count)
        XCTAssertNotNil(ranked["bestID"]?.string)
        let found = try await control.handle("models-search", ["query": "ornith"])
        XCTAssertEqual(found["results"]?.array?.first?["repo"]?.string, "ornith-ai/Ornith-1.5-9B-GGUF")
        let repo = try await control.handle("models-repo", ["repo": "unsloth/gemma-4-12b-it-GGUF"])
        XCTAssertEqual(repo["license"]?.string, "apache-2.0")
        XCTAssertEqual(repo["files"]?.array?.first?["suggested"]?.bool, true)
        XCTAssertFalse(spy.requests.isEmpty)

        let before = try await control.handle("status")
        XCTAssertEqual(before["modelInstall"]?["running"]?.bool, false)
        let started = try await control.handle("model-get", ["source": "catalogue", "id": "qwen3.5-4b"])
        XCTAssertEqual(started["started"]?.bool, true)
        var last: JSONValue = .null
        for _ in 0..<300 {
            last = try await control.handle("status")
            if last["modelInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["modelInstall"]?["error"]?.string, "")
        XCTAssertEqual(last["modelInstall"]?["done"]?.bool, true)
        XCTAssertEqual(last["modelInstall"]?["result"]?["message"]?.string, "Ready. Start chatting.")
        XCTAssertEqual(last["setupComplete"]?.bool, true)

        // Bad input is refused; a phone is refused; extra settings are refused.
        do { _ = try await control.handle("model-get", ["source": "hub", "repo": "../x", "file": "a.gguf"]); XCTFail("repo") } catch { assertMatch(messageOf(error), "not a model file") }
        do { _ = try await control.handle("model-get", [:]); XCTFail("nothing") } catch { assertMatch(messageOf(error), "Choose a model") }
        do { _ = try await control.handle("model-get", ["source": "catalogue", "id": "qwen3.5-4b", "url": "https://x.test"]); XCTFail("extra") } catch { XCTAssertEqual(messageOf(error), "Unsupported setup setting.") }
        do { _ = try await control.handle("models-search", ["query": "x"], access: .phone); XCTFail("phone") } catch {}
        do { _ = try await control.handle("model-get", ["source": "catalogue", "id": "qwen3.5-4b"], access: .phone); XCTFail("phone") } catch {}
        // A failure arrives in modelInstall.error, in its words.
        _ = try await control.handle("model-get", ["source": "catalogue", "id": "nope"])
        for _ in 0..<300 {
            last = try await control.handle("status")
            if last["modelInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["modelInstall"]?["error"]?.string, "That model is not in the list.")
        let stopped = try await control.handle("model-get-stop", ["discard": true])
        XCTAssertEqual(stopped["stopped"]?.bool, true)
    }

    func testPausingKeepsThePartialFileAndCancellingDeletesIt() async throws {
        let (_, backend, _, downloader, _) = try rig()
        let model = try XCTUnwrap(ModelCatalogue.model(id: "qwen3.5-4b"))
        let part = backend.dataFolder + "/models/" + model.filename + ".part"
        try FileManager.default.createDirectory(atPath: backend.dataFolder + "/models", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: part, contents: Data(repeating: 1, count: 10))
        downloader.failure = CancellationError()
        let control = DesktopControl(backend)
        _ = try await control.handle("model-get", ["source": "catalogue", "id": "qwen3.5-4b"])
        var last: JSONValue = .null
        for _ in 0..<300 {
            last = try await control.handle("status")
            if last["modelInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["modelInstall"]?["paused"]?.bool, true)
        XCTAssertEqual(last["modelInstall"]?["error"]?.string, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part), "pause keeps what arrived")
        _ = try await control.handle("model-get-stop", ["discard": true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: part), "cancel throws it away")
        last = try await control.handle("status")
        XCTAssertEqual(last["modelInstall"]?["paused"]?.bool, false)
    }
}
