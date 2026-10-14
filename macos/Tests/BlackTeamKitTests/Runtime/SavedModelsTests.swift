import XCTest
@testable import BlackTeamKit

private func server(_ id: String, _ port: Int = 18081, context: Int = 32768, apiKey: String = "") -> ModelConfig {
    ModelConfig(source: "server", endpoint: "http://127.0.0.1:\(port)/v1", id: id, apiKey: apiKey, name: id, file: "", runtime: "", context: context, gpuLayers: 0, threads: 4)
}

final class SavedModelsTests: XCTestCase {
    func testKeepsEachModelOnceHidesKeysAndMarksTheOneInUse() throws {
        let saved = try createSavedModels(makeTemporaryFolder(self))
        XCTAssertEqual(saved.list(), [])
        let first = try saved.remember(server("ornith", 18081, apiKey: "local-secret"))
        let second = try saved.remember(server("qwen", 18080))
        XCTAssertNotEqual(first, second)
        // Saving the same model again updates it in place.
        XCTAssertEqual(try saved.remember(server("ornith", 18081, context: 65536, apiKey: "local-secret")), first)
        let list = saved.list(active: server("qwen", 18080))
        XCTAssertEqual(list.map { [$0.name, String($0.active), $0.location, String($0.context)] },
                       [["qwen", "true", "127.0.0.1:18080", "32768"], ["ornith", "false", "127.0.0.1:18081", "65536"]])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(list), as: UTF8.self).contains("local-secret"))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(list), as: UTF8.self).contains("\"where\""))
        XCTAssertEqual(saved.find(first)?.apiKey, "local-secret")
    }

    func testKeysAreSixteenHexDigitsOfTheIdentityHash() {
        // The Linux app: sha256 of JSON ["gguf", file] (or ["server", endpoint, id]), first 16 hex digits.
        let key = keyOf(ModelConfig(source: "gguf", file: "/m/a.gguf"))
        XCTAssertEqual(key, "7c48e190cf8a1c96") // computed with sha256sum from the JavaScript's JSON text
        XCTAssertNotNil(key.range(of: "^[a-f0-9]{16}$", options: .regularExpression))
        XCTAssertNotEqual(key, keyOf(ModelConfig(source: "gguf", file: "/m/b.gguf")))
        XCTAssertEqual(key, keyOf(ModelConfig(source: "gguf", name: "Other name", file: "/m/a.gguf", context: 999)))
    }

    func testTheListFileIsPrivateAndADamagedOneIsAnEmptyList() throws {
        let dir = makeTemporaryFolder(self)
        let saved = try createSavedModels(dir)
        try saved.remember(server("ornith"))
        let file = dir + "/saved-models.json"
        XCTAssertEqual(mode(file), 0o600)
        func entry(_ id: String) throws -> JSONValue { try JSONValue.parse(JSONEncoder().encode(server(id))) }
        var bad = try entry("bad").object!
        bad["context"] = "big"
        let good: JSONValue = ["models": [try entry("ok"), ["source": "cloud", "name": "x"], .object(bad), try entry("ok")]]
        try Data(good.text().utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(saved.list().map(\.name), ["ok"])
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(saved.list(), [])
        XCTAssertThrowsError(try saved.remember(ModelConfig(source: "server", name: ""))) { XCTAssertTrue(messageOf($0).contains("cannot be saved")) }
    }

    func testSwitchingStopsTheLoadedModelAndMakesTheChosenOneCurrent() async throws {
        let dir = makeTemporaryFolder(self)
        let saved = try createSavedModels(dir), configStore = try ConfigStore(stateDir: dir)
        try configStore.save(Config(model: server("ornith"), workspace: dir))
        try saved.remember(server("ornith"))
        let qwen = try saved.remember(server("qwen", 18080, context: 16384))
        let calls = RuntimeBox<[String]>([])
        let busy = RuntimeBox(true)
        do { _ = try await switchModel(key: qwen, saved: saved, configStore: configStore, stop: { calls.update { $0.append("stop") } }, busy: { busy.value }); XCTFail("busy") }
        catch { XCTAssertTrue(messageOf(error).contains("current response")) }
        XCTAssertEqual(calls.value, [])
        busy.value = false
        let result = try await switchModel(key: qwen, saved: saved, configStore: configStore, stop: { calls.update { $0.append("stop") } }, busy: { busy.value })
        XCTAssertEqual(result, SwitchResult(switched: true, name: "qwen"))
        XCTAssertEqual(calls.value, ["stop"])
        let now = try configStore.read().model
        XCTAssertEqual([now.id, now.endpoint, String(now.context)], ["qwen", "http://127.0.0.1:18080/v1", "16384"])
        XCTAssertEqual(saved.list(active: now).filter(\.active).map(\.name), ["qwen"])
        do { _ = try await switchModel(key: "nope", saved: saved, configStore: configStore, stop: {}, busy: { false }); XCTFail("unknown") }
        catch { XCTAssertTrue(messageOf(error).contains("not in your list")) }
    }

    func testAModelWhoseFileHasGoneIsRefusedAndTheCurrentOneStays() async throws {
        let dir = makeTemporaryFolder(self)
        let saved = try createSavedModels(dir), configStore = try ConfigStore(stateDir: dir)
        try configStore.save(Config(model: server("ornith"), workspace: dir))
        let gone = try saved.remember(ModelConfig(source: "gguf", name: "Gone", file: dir + "/gone.gguf", runtime: dir + "/llama-server"))
        let stopped = RuntimeBox(false)
        do { _ = try await switchModel(key: gone, saved: saved, configStore: configStore, stop: { stopped.value = true }, busy: { false }); XCTFail("gone") }
        catch { XCTAssertTrue(messageOf(error).contains("Gone cannot be used right now")) }
        XCTAssertFalse(stopped.value)
        XCTAssertEqual(try configStore.read().model.id, "ornith")
    }

    func testTheModelInUseCannotBeRemovedOthersCan() throws {
        let dir = makeTemporaryFolder(self)
        let saved = try createSavedModels(dir), configStore = try ConfigStore(stateDir: dir)
        try configStore.save(Config(model: server("ornith"), workspace: dir))
        let ornith = try saved.remember(server("ornith")), qwen = try saved.remember(server("qwen", 18080))
        XCTAssertThrowsError(try forgetModel(key: ornith, saved: saved, configStore: configStore)) { XCTAssertTrue(messageOf($0).contains("in use")) }
        try forgetModel(key: qwen, saved: saved, configStore: configStore)
        XCTAssertEqual(saved.list().map(\.name), ["ornith"])
        XCTAssertThrowsError(try forgetModel(key: qwen, saved: saved, configStore: configStore)) { XCTAssertTrue(messageOf($0).contains("not in your list")) }
    }

    func testAFoundModelPassedOverStaysOutOfTheOfferUntilItIsAdded() throws {
        let saved = try createSavedModels(makeTemporaryFolder(self))
        XCTAssertEqual(saved.ignored(), [])
        let key = "abcdef0123456789"
        XCTAssertTrue(try saved.ignore(key))
        try saved.ignore(key)
        XCTAssertEqual(saved.ignored(), [key])
        XCTAssertThrowsError(try saved.ignore("nope")) { XCTAssertTrue(messageOf($0).contains("found model")) }
        // Saving a model keeps the passed-over keys. Removing one passes it over too, so finding it again does not
        // put it back; adding it again clears its key.
        let ornith = try saved.remember(server("ornith"))
        XCTAssertEqual(saved.ignored(), [key])
        try saved.forget(ornith)
        XCTAssertEqual(saved.ignored(), [key, ornith])
        try saved.remember(server("ornith"))
        XCTAssertEqual(saved.ignored(), [key])
    }

    func testAddingFoundModelsFillsTheListAndPutsTheFirstOneInUseOnANewInstall() throws {
        let dir = makeTemporaryFolder(self), state = dir + "/state"
        let saved = try createSavedModels(state), configStore = try ConfigStore(stateDir: state, defaultWorkspace: dir)
        try configStore.save(Config(workspace: dir))
        let items: [JSONValue] = [
            ["source": "server", "endpoint": "http://localhost:18081/v1", "id": "ornith", "name": "Ornith", "context": 65536],
            ["source": "server", "endpoint": "https://example.com/v1", "id": "remote", "name": "Remote", "context": 4096],
            ["source": "gguf", "file": .string(dir + "/missing.gguf"), "runtime": "/usr/bin/llama-server", "name": "Missing", "context": 8192],
            ["source": "server", "endpoint": "http://127.0.0.1:11434/v1", "id": "llama3:8b", "name": "Llama", "context": 9e9],
        ]
        let result = try addModels(items: items, saved: saved, configStore: configStore, threads: 6)
        XCTAssertEqual(result.added, ["Ornith", "Llama"])
        XCTAssertEqual(result.inUse, "Ornith")
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertTrue(result.skipped[0].hasPrefix("Remote: Use a loopback"))
        let now = try configStore.read().model
        XCTAssertEqual([now.id, now.endpoint, String(now.context), String(now.threads)], ["ornith", "http://127.0.0.1:18081/v1", "65536", "6"])
        XCTAssertEqual(saved.list(active: now).map { [$0.name, String($0.active), String($0.context)] }, [["Ornith", "true", "65536"], ["Llama", "false", "131072"]])
        // With a model already in use, adding more leaves it alone.
        let more = try addModels(items: [["source": "server", "endpoint": "http://127.0.0.1:1234/v1", "id": "phi", "name": "Phi", "context": 8192]], saved: saved, configStore: configStore)
        XCTAssertEqual(more.inUse, "Ornith")
        XCTAssertEqual(try configStore.read().model.id, "ornith")
        XCTAssertThrowsError(try addModels(items: [], saved: saved, configStore: configStore)) { XCTAssertTrue(messageOf($0).contains("at least one")) }
        XCTAssertThrowsError(try addModels(items: [["source": "server", "endpoint": "ftp://x", "id": "a", "name": "Bad"]], saved: saved, configStore: configStore)) {
            XCTAssertTrue(messageOf($0).hasPrefix("No model could be added. Bad:"))
        }
    }
}
