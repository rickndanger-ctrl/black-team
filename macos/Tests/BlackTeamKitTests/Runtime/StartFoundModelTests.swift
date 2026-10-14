import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BlackTeamKit

/// A model Black Team found running (a saved "server" entry whose id is the file) is started from its file when
/// nobody is listening any more, and a start that would squeeze out another model server asks first.
final class StartFoundModelTests: XCTestCase {
    struct Rig {
        let files: RuntimeFixture
        let runtime: ModelRuntime
        let spawned: RuntimeBox<[Spawned]>
        let requests: RuntimeBox<[String]>
    }

    let help = "--port --threads --parallel --alias --api-key-file --mmproj --spec-type --spec-draft-model --n-gpu-layers"

    /// The found server's port; the model Black Team starts itself is on 45231.
    func rig(id: String? = nil, server: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse) = { _ in throw URLError(.cannotConnectToHost) },
             runtimePath: String? = nil, noRuntime: Bool = false, memoryGuard: MemoryGuard? = nil) throws -> Rig {
        let files = try RuntimeFixture(self)
        var config = files.config
        config.model = ModelConfig(source: "server", endpoint: "http://127.0.0.1:18081/v1", id: id ?? files.model, apiKey: "", name: "Found model",
                                   context: 8192, threads: 3)
        try files.store.save(config)
        let spawned = RuntimeBox<[Spawned]>([])
        let requests = RuntimeBox<[String]>([])
        let key = RuntimeBox("")
        let model = files.model
        let spawn: ProcessSpawner = { launch, onExit in
            let child = FakeChild(onExit: onExit)
            let keyFile = launch.arguments[launch.arguments.firstIndex(of: "--api-key-file")! + 1]
            key.value = (try! String(contentsOfFile: keyFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            spawned.update { $0.append(Spawned(launch: launch, child: child)) }
            return child
        }
        let fetch: HTTPFetch = { request in
            let url = request.url!
            requests.update { $0.append(url.absoluteString) }
            if url.port == 18081 { return try server(request) }
            if url.path == "/health" { return (Data(#"{"status":"ok"}"#.utf8), response(url)) }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer \(key.value)" { return (Data("{}".utf8), response(url, 401)) }
            return (Data(#"{"model_path":"\#(model)","total_slots":1}"#.utf8), response(url))
        }
        let program = noRuntime ? "" : (runtimePath ?? files.runtime)
        let runtime = ModelRuntime(configStore: files.store, spawn: spawn, fetch: fetch, reservePort: { 45231 }, help: { [help] _ in help },
                                   appleSilicon: false, cores: { 4 }, startupTimeoutMs: 5000, pollIntervalMs: 1, stopTimeoutMs: 20, killTimeoutMs: 20,
                                   fallbackRuntime: { program }, memoryGuard: memoryGuard)
        addTeardownBlock { try? await runtime.dispose() }
        return Rig(files: files, runtime: runtime, spawned: spawned, requests: requests)
    }

    func argument(_ launch: ProcessLaunch, _ name: String) -> String? {
        launch.arguments.firstIndex(of: name).map { launch.arguments[$0 + 1] }
    }

    // MARK: Starting the file

    func testStartsTheFileItselfWhenNobodyIsListening() async throws {
        let r = try rig()
        // Files that belong beside the model are picked up, as they are for a model file.
        FileManager.default.createFile(atPath: r.files.dir + "/test model-mmproj-F16.gguf", contents: Data())
        FileManager.default.createFile(atPath: r.files.dir + "/test model-draft.gguf", contents: Data())
        let endpoint = try await r.runtime.start()
        XCTAssertEqual(endpoint, "http://127.0.0.1:45231/v1")
        XCTAssertEqual(r.spawned.value.count, 1)
        let launch = r.spawned.value[0].launch
        XCTAssertEqual(launch.executable, r.files.runtime)
        XCTAssertEqual(argument(launch, "--model"), r.files.model)
        XCTAssertEqual(argument(launch, "--ctx-size"), "8192")
        XCTAssertEqual(argument(launch, "--threads"), "3")
        XCTAssertEqual(argument(launch, "--mmproj"), r.files.dir + "/test model-mmproj-F16.gguf")
        XCTAssertEqual(argument(launch, "--spec-draft-model"), r.files.dir + "/test model-draft.gguf")
        // The reply path, status readout and stop work as for an owned model.
        let status = await r.runtime.status()
        XCTAssertTrue(status.ready)
        XCTAssertTrue(status.features.contains("vision"))
        XCTAssertEqual(status.name, "Found model")
        let pid = await r.runtime.modelPid()
        XCTAssertEqual(pid, 4242)
        let headers = try await r.runtime.requestHeaders()
        XCTAssertTrue(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        // The saved entry stays one entry, a server one.
        let saved = try r.files.store.read().model
        XCTAssertEqual(saved.source, "server")
        XCTAssertEqual(saved.file, "")
        try await r.runtime.stop(force: true)
        XCTAssertEqual(r.spawned.value[0].child.signals, [SIGTERM])
    }

    func testConnectsAgainWhenTheServerComesBack() async throws {
        let model = RuntimeBox("")
        let r = try rig(server: { request in
            (Data(#"{"data":[{"id":"\#(model.value)"}]}"#.utf8), response(request.url!))
        })
        model.value = r.files.model
        let endpoint = try await r.runtime.start()
        XCTAssertEqual(endpoint, "http://127.0.0.1:18081/v1")
        XCTAssertTrue(r.spawned.value.isEmpty)
    }

    func testDoesNotStartAnythingWhenTheServerAnswersWithoutTheModel() async throws {
        let r = try rig(server: { request in (Data(#"{"data":[{"id":"something-else"}]}"#.utf8), response(request.url!)) })
        do { _ = try await r.runtime.start(); XCTFail("refused") }
        catch { XCTAssertTrue(messageOf(error).hasPrefix("The selected model is no longer available")) }
        XCTAssertTrue(r.spawned.value.isEmpty)
        // An answer that is an error is no "nobody is listening" either.
        let broken = try rig(server: { request in (Data("{}".utf8), response(request.url!, 500)) })
        do { _ = try await broken.runtime.start(); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).hasPrefix("Local model discovery failed")) }
        XCTAssertTrue(broken.spawned.value.isEmpty)
    }

    func testDoesNotStartAnythingForASlowServer() async throws {
        let r = try rig(server: { _ in throw URLError(.timedOut) })
        do { _ = try await r.runtime.start(); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).hasPrefix("Cannot reach the local model server")) }
        XCTAssertTrue(r.spawned.value.isEmpty)
    }

    func testDoesNotStartAFileThatIsNotThere() async throws {
        let r = try rig(id: "/no/such/place/model.gguf")
        do { _ = try await r.runtime.start(); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).hasPrefix("Cannot reach the local model server")) }
        XCTAssertTrue(r.spawned.value.isEmpty)
        // A name a server made up (not a path) is the same.
        let named = try rig(id: "ornith")
        do { _ = try await named.runtime.start(); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).hasPrefix("Cannot reach the local model server")) }
        XCTAssertTrue(named.spawned.value.isEmpty)
    }

    func testSaysWhatToDoWhenThereIsNoLlamaCpp() async throws {
        let r = try rig(noRuntime: true)
        do { _ = try await r.runtime.start(); XCTFail("refused") } catch {
            let text = messageOf(error)
            XCTAssertEqual(text, "Found model is not running and Black Team has no llama.cpp to start it with. Download llama.cpp under Settings, Models, Get a starter model, then choose it again.")
        }
        XCTAssertTrue(r.spawned.value.isEmpty)
        // A program that is not a llama-server is not used either.
        let wrong = try rig(runtimePath: "/bin/ls")
        do { _ = try await wrong.runtime.start(); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).contains("no llama.cpp")) }
        XCTAssertTrue(wrong.spawned.value.isEmpty)
    }

    // MARK: Memory

    /// One other llama-server (pid 777) holding 12 GiB, on a computer with 16 GiB of which 1 GiB is free.
    func guardWith(free: RuntimeBox<Int> = RuntimeBox(1 << 30), owner: UInt32 = 1000, alive: RuntimeBox<Bool> = RuntimeBox(true),
                   signals: RuntimeBox<[[Int32]]> = RuntimeBox([]), running: RuntimeBox<Bool> = RuntimeBox(true)) -> MemoryGuard {
        MemoryGuard(
            processes: {
                running.value ? AnySequence([ProcessEntry(pid: 777, argv: ["/opt/llama/llama-server", "--port", "18080", "-m", "/models/Other Model Q4.gguf"]),
                                             ProcessEntry(pid: 888, argv: ["/usr/bin/sleep", "100"])]) : AnySequence([])
            },
            executablePath: { $0 == 777 ? "/opt/llama/llama-server" : nil },
            owner: { _ in owner }, user: { 1000 },
            memory: { MemoryFigures(total: 16 << 30, free: free.value) },
            held: { $0 == 777 ? 12 << 30 : nil },
            signal: { pid, number in
                signals.update { $0.append([pid, number]) }
                if number == SIGTERM { alive.value = false; running.value = false; free.value = 13 << 30 }
            },
            alive: { _ in alive.value })
    }

    func ggufRig(memoryGuard: MemoryGuard) throws -> Rig {
        let r = try rig(memoryGuard: memoryGuard)
        var config = r.files.config
        config.model = ModelConfig(name: "Test model", file: r.files.model, runtime: r.files.runtime)
        try r.files.store.save(config)
        return r
    }

    func testAsksBeforeStartingWhenAnotherModelHoldsTheMemory() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let r = try ggufRig(memoryGuard: guardWith(signals: signals))
        do { _ = try await r.runtime.start(); XCTFail("asks first") } catch let question as NeedsApprovalError {
            XCTAssertEqual(question.approval.pid, 777)
            XCTAssertEqual(question.approval.question, "Other Model Q4 is using 12.0 GB. Stop it to start Test model?")
            XCTAssertEqual(messageOf(question), question.approval.question)
        }
        // Nothing was started or stopped, and the question is in the status for the window.
        XCTAssertTrue(r.spawned.value.isEmpty)
        XCTAssertTrue(signals.value.isEmpty)
        let status = await r.runtime.status()
        XCTAssertEqual(status.state, .off)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.approval?.pid, 777)
    }

    func testTheFoundModelFallbackAsksToo() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let r = try rig(memoryGuard: guardWith(signals: signals))
        do { _ = try await r.runtime.start(); XCTFail("asks first") } catch let question as NeedsApprovalError {
            XCTAssertEqual(question.approval.modelName, "Found model")
        }
        XCTAssertTrue(r.spawned.value.isEmpty)
        XCTAssertTrue(signals.value.isEmpty)
    }

    func testApprovalStopsOnlyThatServerThenTheModelStarts() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let r = try ggufRig(memoryGuard: guardWith(signals: signals))
        let asked = try await r.runtime.startApproval()
        XCTAssertEqual(asked?.pid, 777)
        XCTAssertTrue(signals.value.isEmpty, "asking stops nothing")
        // A different process id is not the one asked about.
        do { try await r.runtime.approveStop(pid: 888); XCTFail("refused") } catch { XCTAssertTrue(messageOf(error).contains("nothing waiting")) }
        XCTAssertTrue(signals.value.isEmpty)
        try await r.runtime.approveStop(pid: 777)
        XCTAssertEqual(signals.value, [[777, SIGTERM]])
        let endpoint = try await r.runtime.start()
        XCTAssertEqual(endpoint, "http://127.0.0.1:45231/v1")
        XCTAssertEqual(r.spawned.value.count, 1)
        let after = await r.runtime.status().approval
        XCTAssertNil(after)
        // The answer is used once.
        do { try await r.runtime.approveStop(pid: 777); XCTFail("used") } catch {}
        XCTAssertEqual(signals.value.count, 1)
    }

    func testRefusalLeavesEverythingUntouched() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let r = try ggufRig(memoryGuard: guardWith(signals: signals))
        _ = try await r.runtime.startApproval()
        await r.runtime.declineStop()
        let after = await r.runtime.status().approval
        XCTAssertNil(after)
        XCTAssertTrue(signals.value.isEmpty)
        XCTAssertTrue(r.spawned.value.isEmpty)
        do { try await r.runtime.approveStop(pid: 777); XCTFail("declined") } catch {}
        XCTAssertTrue(signals.value.isEmpty)
    }

    func testOnlyAServerOfThisUserIsEverOfferedOrStopped() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        // Someone else's server is not ours to stop, so the model just starts.
        let theirs = try ggufRig(memoryGuard: guardWith(owner: 0, signals: signals))
        _ = try await theirs.runtime.start()
        XCTAssertEqual(theirs.spawned.value.count, 1)
        XCTAssertTrue(signals.value.isEmpty)
        // A process that stopped being a model server between the question and the answer is not signalled.
        let running = RuntimeBox(true)
        let moved = try ggufRig(memoryGuard: guardWith(signals: signals, running: running))
        _ = try await moved.runtime.startApproval()
        running.value = false
        do { try await moved.runtime.approveStop(pid: 777); XCTFail("gone") } catch { XCTAssertTrue(messageOf(error).contains("no longer running")) }
        XCTAssertTrue(signals.value.isEmpty)
    }

    func testNoQuestionWhenTheModelFits() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let r = try ggufRig(memoryGuard: guardWith(free: RuntimeBox(8 << 30), signals: signals))
        let asked = try await r.runtime.startApproval()
        XCTAssertNil(asked)
        _ = try await r.runtime.start()
        XCTAssertEqual(r.spawned.value.count, 1)
        XCTAssertTrue(signals.value.isEmpty)
    }

    func testAServerThatDoesNotStopInTimeIsReported() async throws {
        let signals = RuntimeBox<[[Int32]]>([])
        let alive = RuntimeBox(true)
        let files = try RuntimeFixture(self)
        try files.store.save(files.config)
        let stuck = MemoryGuard(
            processes: { AnySequence([ProcessEntry(pid: 777, argv: ["/opt/llama/llama-server", "-m", "/m/a.gguf"])]) },
            executablePath: { _ in "/opt/llama/llama-server" }, owner: { _ in 1000 }, user: { 1000 },
            memory: { MemoryFigures(total: 16 << 30, free: 1 << 30) }, held: { _ in 12 << 30 },
            signal: { pid, number in signals.update { $0.append([pid, number]) } }, alive: { _ in alive.value })
        let runtime = ModelRuntime(configStore: files.store, spawn: { _, _ in XCTFail("not started"); throw SpawnError(code: "EPERM") },
                                   fetch: { r in (Data("{}".utf8), response(r.url!)) }, reservePort: { 45231 }, memoryGuard: stuck, approvalStopTimeoutMs: 60)
        _ = try await runtime.startApproval()
        do { try await runtime.approveStop(pid: 777); XCTFail("did not stop") } catch { XCTAssertTrue(messageOf(error).contains("did not stop in time")) }
        XCTAssertEqual(signals.value, [[777, SIGTERM]])
    }
}
