import XCTest
@testable import BlackTeamKit

final class ModelRuntimeTests: XCTestCase {
    struct Harness {
        let files: RuntimeFixture
        let runtime: ModelRuntime
        let spawned: RuntimeBox<[Spawned]>
        let requests: RuntimeBox<[String]>
    }

    /// A runtime with a fake process and a fake network that answers like a healthy llama-server.
    func harness(exitsOn: Set<Int32> = [SIGTERM, SIGKILL], startupTimeoutMs: Int = 5000, stopTimeoutMs: Int = 20, killTimeoutMs: Int = 20,
                 fetch custom: HTTPFetch? = nil, spawn custom_spawn: ProcessSpawner? = nil, reservePort: (@Sendable () async throws -> Int)? = nil,
                 help: @escaping @Sendable (String) -> String = { _ in "" },
                 environment: @escaping @Sendable () -> [String: String] = { runtimeEnvironment() }) throws -> Harness {
        let files = try RuntimeFixture(self)
        try files.store.save(files.config)
        let spawned = RuntimeBox<[Spawned]>([])
        let requests = RuntimeBox<[String]>([])
        let key = RuntimeBox("")
        let spawn: ProcessSpawner = custom_spawn ?? { launch, onExit in
            let child = FakeChild(exitsOn: exitsOn, onExit: onExit)
            let keyFile = launch.arguments[launch.arguments.firstIndex(of: "--api-key-file")! + 1]
            key.value = (try! String(contentsOfFile: keyFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            spawned.update { $0.append(Spawned(launch: launch, child: child)) }
            return child
        }
        let model = files.model
        let fetch: HTTPFetch = custom ?? { request in
            let url = request.url!
            requests.update { $0.append(url.absoluteString) }
            if url.path == "/health" { return (Data(#"{"status":"ok"}"#.utf8), response(url)) }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer \(key.value)" { return (Data("{}".utf8), response(url, 401)) }
            return (Data(#"{"model_path":"\#(model)","total_slots":1}"#.utf8), response(url))
        }
        let runtime = ModelRuntime(configStore: files.store, spawn: spawn, fetch: fetch, reservePort: reservePort ?? { 45231 }, help: help,
                                   environment: environment, appleSilicon: true, cores: { 4 },
                                   startupTimeoutMs: startupTimeoutMs, pollIntervalMs: 1, stopTimeoutMs: stopTimeoutMs, killTimeoutMs: killTimeoutMs)
        addTeardownBlock { try? await runtime.dispose() }
        return Harness(files: files, runtime: runtime, spawned: spawned, requests: requests)
    }

    func testEnvironmentKeepsOnlyHardwareAndLocaleSettings() {
        let kept = runtimeEnvironment(["PATH": "/usr/bin", "HOME": "/Users/a", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TMPDIR": "/tmp/x",
                                       "LD_LIBRARY_PATH": "/x", "DYLD_LIBRARY_PATH": "/x", "LLAMA_ARG_HOST": "0.0.0.0", "CUDA_VISIBLE_DEVICES": "0",
                                       "XDG_CACHE_HOME": "/x", "OPENAI_API_KEY": "secret"])
        XCTAssertEqual(Set(kept.keys), ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"])
    }

    func testReservedPortIsALoopbackPort() async throws {
        let port = try await reserveLoopbackPort()
        XCTAssertTrue((1024...65535).contains(port))
    }

    func testStartsOneOwnedAuthenticatedLoopbackModelWithNoInheritedOverride() async throws {
        let h = try harness(environment: { runtimeEnvironment(["LLAMA_ARG_HOST": "0.0.0.0", "PATH": "/usr/bin"]) })
        async let first = h.runtime.start()
        async let second = h.runtime.start()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, "http://127.0.0.1:45231/v1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(h.spawned.value.count, 1)
        let launch = h.spawned.value[0].launch, child = h.spawned.value[0].child
        func value(_ flag: String) -> String { launch.arguments[launch.arguments.firstIndex(of: flag)! + 1] }
        XCTAssertEqual(value("--host"), "127.0.0.1")
        XCTAssertEqual(value("--model"), h.files.model)
        XCTAssertEqual(value("--parallel"), "1")
        XCTAssertEqual(launch.executable, h.files.runtime)
        XCTAssertNil(launch.environment["LLAMA_ARG_HOST"])
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        // Apple Silicon puts every layer on the GPU unless the model sets a count.
        XCTAssertEqual(value("--n-gpu-layers"), "999")
        let token = try await h.runtime.requestHeaders()["Authorization"]!
        let status = try JSONEncoder().encode(await h.runtime.status())
        XCTAssertFalse(String(decoding: status, as: UTF8.self).contains(String(token.dropFirst(7))))
        XCTAssertFalse(launch.arguments.contains("--api-key"))
        XCTAssertFalse(launch.arguments.contains { $0.contains(String(token.dropFirst(7))) })
        let keyFile = value("--api-key-file")
        XCTAssertEqual(mode(keyFile), 0o600)
        XCTAssertEqual(mode((keyFile as NSString).deletingLastPathComponent), 0o700)
        XCTAssertEqual(h.requests.value.filter { $0.hasSuffix("/props") }.count, 2)
        let pid = await h.runtime.modelPid()
        XCTAssertEqual(pid, 4242)
        try await h.runtime.setBusy(true)
        do { try await h.runtime.stop(); XCTFail("stop should wait for the response") } catch { XCTAssertTrue(messageOf(error).contains("response to finish")) }
        XCTAssertEqual(child.signals, [])
        try await h.runtime.stop(force: true)
        XCTAssertEqual(child.signals, [SIGTERM])
        XCTAssertFalse(FileManager.default.fileExists(atPath: (keyFile as NSString).deletingLastPathComponent))
        let after = await h.runtime.status()
        XCTAssertEqual(after.state, .off)
        do { _ = try await h.runtime.requestHeaders(); XCTFail("not ready") } catch { XCTAssertTrue(messageOf(error).contains("not ready")) }
        try await h.runtime.start()
        let second2 = try await h.runtime.requestHeaders()["Authorization"]!
        XCTAssertNotEqual(second2, token)
    }

    func testLaunchPlanUsesOnlyFlagsTheBuildKnows() async throws {
        let h = try harness(help: { _ in "--port --host --jinja --threads-batch" })
        try await h.runtime.start()
        let args = h.spawned.value[0].launch.arguments
        XCTAssertTrue(args.contains("--jinja"))
        XCTAssertTrue(args.contains("--threads-batch"))
        XCTAssertFalse(args.contains("--cache-ram"))
        XCTAssertFalse(args.contains("--alias"))
        let features = await h.runtime.status().features; XCTAssertEqual(features, ["4 threads"])
    }

    func testStartupFailureKillsOnlyTheSpawnedChild() async throws {
        let fetch: HTTPFetch = { request in (Data("{}".utf8), response(request.url!, 503)) }
        let h = try harness(startupTimeoutMs: 40, fetch: fetch)
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("did not become ready in time")) }
        let status = await h.runtime.status()
        XCTAssertEqual(status.state, .error)
        XCTAssertNil(status.port)
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM])
    }

    func testExistingServiceIsNeverAdopted() async throws {
        let fetch: HTTPFetch = { request in
            let url = request.url!
            return (Data((url.path == "/health" ? #"{"status":"ok"}"# : "{}").utf8), response(url, url.path == "/health" ? 200 : 401))
        }
        let h = try harness(fetch: fetch)
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("Another process")) }
        let status = await h.runtime.status()
        XCTAssertEqual(status.state, .error)
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM])
    }

    func testRuntimeThatIgnoresAuthenticationIsRejected() async throws {
        let box = RuntimeBox("")
        let fetch: HTTPFetch = { request in
            let url = request.url!
            return (Data(url.path == "/health" ? #"{"status":"ok"}"# .utf8 : #"{"model_path":"\#(box.value)"}"#.utf8), response(url))
        }
        let h = try harness(fetch: fetch)
        box.value = h.files.model
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("did not enforce private authentication")) }
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM])
    }

    func testDifferentModelIdentityIsRejected() async throws {
        let box = RuntimeBox("")
        let fetch: HTTPFetch = { request in
            let url = request.url!
            return (Data(url.path == "/health" ? #"{"status":"ok"}"# .utf8 : #"{"model_path":"\#(box.value)"}"#.utf8), response(url))
        }
        let h = try harness(fetch: fetch)
        box.value = h.files.dir + "/different.gguf"
        try Data("different".utf8).write(to: URL(fileURLWithPath: box.value))
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("different model")) }
    }

    func testUnexpectedExitClearsReadyBusyAndAuthenticationState() async throws {
        let h = try harness()
        try await h.runtime.start()
        try await h.runtime.setBusy(true)
        h.spawned.value[0].child.onExit(ProcessExit(code: 1))
        let failed = await waitUntil { await h.runtime.status().state == .error }
        XCTAssertTrue(failed)
        let status = await h.runtime.status()
        XCTAssertFalse(status.ready)
        XCTAssertFalse(status.busy)
        XCTAssertNil(status.port)
        XCTAssertTrue(status.error?.contains("code 1") == true)
        do { _ = try await h.runtime.requestHeaders(); XCTFail("not ready") } catch { XCTAssertTrue(messageOf(error).contains("not ready")) }
    }

    func testStopDuringPortSelectionPreventsAnyProcessFromLaunching() async throws {
        let release = RuntimeBox<CheckedContinuation<Int, Error>?>(nil)
        let h = try harness(reservePort: { try await withCheckedThrowingContinuation { release.value = $0 } })
        let start = Task { try await h.runtime.start() }
        let waiting = await waitUntil { release.value != nil }
        XCTAssertTrue(waiting)
        let stop = Task { try await h.runtime.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        release.value!.resume(returning: 45231)
        do { _ = try await start.value; XCTFail("cancelled") } catch { XCTAssertTrue(messageOf(error).contains("cancelled")) }
        try await stop.value
        XCTAssertEqual(h.spawned.value.count, 0)
        let finalState = await h.runtime.status().state; XCTAssertEqual(finalState, .off)
    }

    func testStopAbortsAnInFlightReadinessRequestAndWaitsForItsOwnProcess() async throws {
        let entered = RuntimeBox(false)
        let fetch: HTTPFetch = { _ in
            entered.value = true
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw URLError(.timedOut)
        }
        let h = try harness(fetch: fetch)
        let start = Task { try await h.runtime.start() }
        let waiting = await waitUntil { entered.value }
        XCTAssertTrue(waiting)
        try await h.runtime.stop()
        do { _ = try await start.value; XCTFail("cancelled") } catch { XCTAssertTrue(messageOf(error).contains("cancelled")) }
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM])
        let finalState = await h.runtime.status().state; XCTAssertEqual(finalState, .off)
    }

    func testSpawnErrorsAreReportedWithoutCrashing() async throws {
        let h = try harness(fetch: { _ in throw URLError(.cannotConnectToHost) }, spawn: { _, _ in throw SpawnError(code: "ENOENT") })
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("Could not start llama-server (ENOENT)")) }
        let finalState = await h.runtime.status().state; XCTAssertEqual(finalState, .error)
    }

    func testSigkillEscalationIsConfinedToTheOwnedProcess() async throws {
        let fetch: HTTPFetch = { request in (Data("{}".utf8), response(request.url!, 503)) }
        let h = try harness(exitsOn: [SIGKILL], startupTimeoutMs: 30, stopTimeoutMs: 5, killTimeoutMs: 5, fetch: fetch)
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("did not become ready")) }
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM, SIGKILL])
    }

    func testFailedTerminationNeverTreatsSilenceAsProofTheProcessExited() async throws {
        let fetch: HTTPFetch = { request in (Data("{}".utf8), response(request.url!, 503)) }
        let h = try harness(exitsOn: [], startupTimeoutMs: 30, stopTimeoutMs: 5, killTimeoutMs: 5, fetch: fetch)
        do { try await h.runtime.start(); XCTFail("should fail") } catch { XCTAssertTrue(messageOf(error).contains("owned model process did not stop")) }
        let finalState = await h.runtime.status().state; XCTAssertEqual(finalState, .error)
        XCTAssertEqual(h.spawned.value[0].child.signals, [SIGTERM, SIGKILL])
        do { try await h.runtime.start(); XCTFail("should refuse") } catch { XCTAssertTrue(messageOf(error).contains("previous model process has not stopped")) }
        h.spawned.value[0].child.onExit(ProcessExit(code: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        try await h.runtime.dispose()
        let endState = await h.runtime.status().state; XCTAssertEqual(endState, .off)
    }

    func testConnectsToAnExistingLocalServer() async throws {
        let files = try RuntimeFixture(self)
        var config = files.config
        config.model = ModelConfig(source: "server", endpoint: "http://127.0.0.1:18081/v1", id: "ornith", apiKey: "local-key", name: "Ornith")
        try files.store.save(config)
        let seen = RuntimeBox<[String?]>([])
        let fetch: HTTPFetch = { request in
            seen.update { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
            return (Data(#"{"data":[{"id":"ornith"}]}"#.utf8), response(request.url!))
        }
        let runtime = ModelRuntime(configStore: files.store, spawn: { _, _ in XCTFail("no process for a server"); throw SpawnError(code: "EPERM") }, fetch: fetch)
        let endpoint = try await runtime.start()
        XCTAssertEqual(endpoint, "http://127.0.0.1:18081/v1")
        XCTAssertEqual(seen.value, ["Bearer local-key"])
        let headers = try await runtime.requestHeaders(); XCTAssertEqual(headers, ["Authorization": "Bearer local-key"])
        let status = await runtime.status()
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.features, [])
        let pid = await runtime.modelPid()
        XCTAssertNil(pid)
        try await runtime.stop()
        let finalState = await runtime.status().state; XCTAssertEqual(finalState, .off)

        config.model.id = "gone"
        try files.store.save(config)
        do { try await runtime.start(); XCTFail("model gone") } catch { XCTAssertTrue(messageOf(error).contains("no longer available")) }
    }

    func testCrashSafetyWatcherSpawnsAndEndsARealProcess() async throws {
        // The real spawner on a harmless program: it reports its exit and ends when signalled.
        let exited = RuntimeBox<ProcessExit?>(nil)
        let child = try systemSpawn(ProcessLaunch(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"])) { exited.value = $0 }
        XCTAssertGreaterThan(child.pid, 0)
        child.send(signal: SIGTERM)
        let done = await waitUntil { exited.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(exited.value?.signal, SIGTERM)
        XCTAssertThrowsError(try systemSpawn(ProcessLaunch(executable: "/nonexistent/llama-server", arguments: [], environment: [:])) { _ in }) {
            XCTAssertEqual(($0 as? SpawnError)?.code, "ENOENT")
        }
    }
}
