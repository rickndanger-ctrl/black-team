import XCTest
@testable import BlackTeamKit

private let GiB = 1024 * 1024 * 1024

// Optimizing as the window, the command line and the download flow reach it: through the Backend, with a fake runtime and network.
final class TuneBackendTests: XCTestCase {
    let hardware = TuneHardware(cpu: "Test CPU", cores: 6, threads: 12, memoryTotal: 32 * GiB, memoryAvailable: 24 * GiB)
    let help = "--port N --threads N --threads-batch N"

    func backend(_ fixture: BackendFixture, _ rig: TuneRig) throws -> Backend {
        fixture.fetch = rig.fetch
        let backend = try fixture.make()
        let machine = hardware, text = help
        backend.tuneEnvironment = TuneEnvironment(help: { _ in text }, hardware: { machine }, memory: { _ in rig.resident }, uptime: { rig.clock })
        backend.tuneTrial = { scratch, _ in TrialRuntime(rig, (try? scratch.read().model) ?? ModelConfig()) }
        return backend
    }

    func testOptimizingStoresTheResultSavesTheContextAndReportsItInTheStatus() async throws {
        let fixture = try BackendFixture(self)
        fixture.runtime.state = .ready
        let rig = TuneRig()
        let backend = try backend(fixture, rig)
        let model = try backend.configStore.read().model
        let key = keyOf(model)
        XCTAssertEqual(backend.tuningInfo(for: model)["state"]?.string, "none")

        let started = try await backend.optimize(key: key)
        XCTAssertEqual(started, .started)
        await backend.waitForOptimize()
        let status = backend.optimizeStatus()
        XCTAssertEqual(status["done"]?.bool, true, "\(status)")
        XCTAssertEqual(status["running"]?.bool, false)
        XCTAssertTrue(status["summary"]?.string?.contains("65,536 context") == true)
        XCTAssertFalse(status["log"]?.array?.isEmpty ?? true)

        // The result is stored, current, and its context is the model's own setting now (in use, and in the list).
        let info = backend.tuningInfo(for: model)
        XCTAssertEqual(info["state"]?.string, "optimized")
        XCTAssertEqual(try backend.configStore.read().model.context, 65536)
        XCTAssertEqual(backend.savedModels.find(key)?.context, 65536)
        XCTAssertEqual(mode(fixture.stateDir + "/tuning.json"), 0o600)
        // The model was running, so it runs again; other setup actions work again.
        XCTAssertEqual(fixture.runtime.stops, [false])
        XCTAssertEqual(fixture.runtime.starts, 1)
        fixture.runtime.state = .off
        let renamed = try await backend.saveSetup(["model": ["name": "Renamed"]])
        XCTAssertTrue(renamed.saved)
        XCTAssertEqual(backend.tuningInfo(for: try backend.configStore.read().model)["state"]?.string, "optimized", "a new name is not a change of settings")

        // A hand edit wins: after the person changes the threads, the stored result is no longer applied.
        let before = try backend.configStore.read().model
        _ = try await backend.saveSetup(["model": ["threads": .number(Double(before.threads == 2 ? 3 : 2))]])
        let edited = try backend.configStore.read().model
        XCTAssertEqual(backend.tuningInfo(for: edited)["state"]?.string, "edited")
        XCTAssertEqual(backend.tuning.entry(key)?.handEdited, true)
        XCTAssertEqual(tunedLaunch(store: backend.tuning, hardware: { self.hardware })(edited).threads, edited.threads)

        // A new llama.cpp program at the same path makes it stale, and the window is told why.
        FileManager.default.createFile(atPath: fixture.files.runtime, contents: Data(nativeProgramHeader() + [9]), attributes: [.posixPermissions: 0o700])
        let stale = backend.tuningInfo(for: try backend.configStore.read().model)
        XCTAssertEqual(stale["state"]?.string, "stale")
        XCTAssertEqual(stale["reasons"]?[0]?.string, "The llama.cpp program changed.")
    }

    func testWhileItRunsNothingElseStartsAndASecondRequestIsSkippedAsBusy() async throws {
        let fixture = try BackendFixture(self)
        let rig = TuneRig()
        rig.blockFetch(number: 1)
        let backend = try backend(fixture, rig)
        let key = keyOf(try backend.configStore.read().model)

        let first = try await backend.optimize(key: key)
        XCTAssertEqual(first, .started)
        // The call meant for the download flow never waits and says why it did nothing.
        let again = await backend.optimizeAfterAdding(modelKey: key)
        XCTAssertEqual(again, .skipped("busy"))
        XCTAssertEqual(again.text, "skipped: busy")
        let busyAgain = try await backend.optimize(key: key)
        XCTAssertEqual(busyAgain, .skipped("busy"))
        // No message, and no change of model or start, while the model is being measured.
        do { _ = try backend.submit(message: "hello", requestId: UUID().uuidString.lowercased()); XCTFail("optimizing") } catch { assertMatch(messageOf(error), "optimizing a model") }
        do { _ = try await backend.startModel(); XCTFail("one setup action at a time") } catch { XCTAssertEqual(messageOf(error), "Another setup action is still running.") }

        let reached = await waitUntil(5) { rig.fetches >= 1 }
        XCTAssertTrue(reached)
        backend.cancelOptimize()
        await backend.waitForOptimize()
        let status = backend.optimizeStatus()
        XCTAssertEqual(status["stopped"]?.bool, true)
        XCTAssertEqual(status["running"]?.bool, false)
        XCTAssertNil(backend.tuning.entry(key))
        // Free again afterwards.
        let after = await backend.optimizeAfterAdding(modelKey: key)
        XCTAssertEqual(after, .started)
        backend.cancelOptimize()
        await backend.waitForOptimize()
    }

    func testAResponseInProgressMeansSkippedBusy() async throws {
        let fixture = try BackendFixture(self)
        fixture.runtime.state = .ready
        let gate = BackendGate()
        fixture.engine.action = { _, _ in await gate.wait() }
        let rig = TuneRig()
        let backend = try backend(fixture, rig)
        let key = keyOf(try backend.configStore.read().model)
        _ = try backend.submit(message: "hello", requestId: UUID().uuidString.lowercased())
        XCTAssertTrue(backend.isBusy)
        let result = await backend.optimizeAfterAdding(modelKey: key)
        XCTAssertEqual(result.text, "skipped: busy")
        XCTAssertEqual(fixture.runtime.stops, [])
        await gate.open()
        await backend.waitForIdle()
    }

    func testAServerIsMeasuredOnlyAndCloudAndUnknownModelsAreRefused() async throws {
        let server = try BackendFixture(self, server: true)
        server.runtime.state = .ready
        server.fetch = { request in (Data(#"{"timings":{"prompt_per_second":80,"predicted_per_second":9.4}}"#.utf8), response(request.url!)) }
        let made = try server.make()
        XCTAssertEqual(made.tuningInfo(for: try made.configStore.read().model)["state"]?.string, "server")
        let serverKey = keyOf(try made.configStore.read().model)
        let measured = try await made.optimize(key: serverKey)
        XCTAssertEqual(measured, .started)
        await made.waitForOptimize()
        XCTAssertEqual(made.optimizeStatus()["done"]?.bool, true)
        XCTAssertEqual(made.tuningInfo(for: try made.configStore.read().model)["state"]?.string, "measured")
        XCTAssertEqual(server.runtime.stops, [])
        XCTAssertEqual(server.runtime.starts, 0)
        // Not for a download flow either.
        let skipped = await made.optimizeAfterAdding(modelKey: serverKey)
        XCTAssertEqual(skipped.text, "skipped: not a model file")
        do { _ = try await made.optimize(key: "0000000000000000"); XCTFail("unknown") } catch { XCTAssertEqual(messageOf(error), "That model is not in your list.") }
    }

    func testTheDesktopActionsStartAndCancelAndRefuseOtherInput() async throws {
        let fixture = try BackendFixture(self)
        let rig = TuneRig()
        rig.blockFetch(number: 1)
        let backend = try backend(fixture, rig)
        let control = DesktopControl(backend)
        let key = keyOf(try backend.configStore.read().model)
        do { _ = try await control.handle("optimize-start", ["key": .string(key), "x": 1]); XCTFail("unsupported") } catch { XCTAssertEqual(messageOf(error), "Unsupported setup setting.") }
        do { _ = try await control.handle("optimize-start", [:]); XCTFail("needs a model") } catch { XCTAssertEqual(messageOf(error), "Choose a model from your list.") }
        do { _ = try await control.handle("optimize-start", ["key": .string(key)], access: .phone); XCTFail("desktop only") } catch {}
        let started = try await control.handle("optimize-start", ["key": .string(key)])
        XCTAssertEqual(started["started"]?.bool, true)
        let second = try await control.handle("optimize-start", ["key": .string(key)])
        XCTAssertEqual(second["result"]?.string, "skipped: busy")
        let status = try await backend.desktopStatusJSON()
        XCTAssertEqual(status["optimize"]?["running"]?.bool, true)
        XCTAssertEqual(status["models"]?[0]?["tuning"]?["state"]?.string, "none")
        let stopped = try await control.handle("optimize-cancel")
        XCTAssertEqual(stopped["stopped"]?.bool, true)
        await backend.waitForOptimize()
        XCTAssertEqual(backend.optimizeStatus()["stopped"]?.bool, true)
    }
}
