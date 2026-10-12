import XCTest
@testable import BlackTeamKit

// The Linux desktop's Hermes host (lib/agent.cjs, and the Hermes tests of tests/integrations.test.cjs and tests/server.test.cjs).
// No Hermes and no model: the runner is a fake shell script in a temporary folder, started with /bin/sh as its interpreter.

/// A fake agent-runner.py that prints the events of a turn; the test reads what it recorded in the scripts folder.
private let approvalRunner = #"""
#!/bin/sh
DIR=$(dirname "$0")
printf '%s\n' "$@" >> "$DIR/runs.txt"
echo "--- run" >> "$DIR/runs.txt"
env > "$DIR/env.txt"
case " $* " in
  *" --resume "*)
    echo '{"type":"companion_artifact","id":"0123456789abcdef0123456789abcdef","name":"/work/report.txt"}'
    echo '{"type":"companion_artifact","id":"../escape","name":"x"}'
    echo '{"type":"result","text":"Resumed","session_id":"session-fixture","exit_code":0}'
    exit 0 ;;
esac
echo '{"type":"system","session_id":"session-fixture"}'
expires=$(( $(date +%s) * 1000 + 60000 ))
echo "{\"type\":\"companion_approval\",\"id\":\"a\",\"digest\":\"d\",\"command\":\"test local-test-key\",\"description\":\"Approve?\",\"expires\":$expires}"
read answer
printf '%s\n' "$answer" > "$DIR/answer.txt"
echo '{"type":"tool_use","name":"file_write","input":{"path":"example.txt"}}'
echo '{"type":"result","text":"Done","session_id":"session-fixture","exit_code":0}'
"""#

/// A fake runner that reports it is ready, then runs until it is stopped; on SIGINT it records that and exits.
private let waitingRunner = #"""
#!/bin/sh
DIR=$(dirname "$0")
trap 'echo stopped > "$DIR/signal.txt"; exit 130' INT
echo '{"type":"camp_status","message":"ready"}'
while :; do sleep 0.05; done
"""#

/// A backend the desktop service would have, with a fake Hermes: a scripts folder holding the runner, and a source folder.
final class HermesRig {
    let fixture: BackendFixture
    let backend: Backend
    let root: String
    let scripts: String
    let source: String
    var data: String { fixture.stateDir }

    init(_ test: XCTestCase, runner: String, enabled: Bool = true, withScripts: Bool = true) throws {
        fixture = try BackendFixture(test, server: true)
        root = fixture.files.dir + "/hermes"
        scripts = root + "/scripts"
        source = root + "/source"
        try FileManager.default.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/plugins/companion-tools", withIntermediateDirectories: true)
        try "".write(toFile: source + "/hermes_bootstrap.py", atomically: true, encoding: .utf8)
        try runner.write(toFile: scripts + "/agent-runner.py", atomically: true, encoding: .utf8)
        backend = try fixture.make()
        backend.configureDesktop(DesktopOptions(scripts: withScripts ? scripts : nil))
        _ = try backend.integrations.save(.object([
            "hermes": .object(["enabled": .bool(enabled), "python": "/bin/sh", "source": .string(source), "coding": true, "browser": false, "desktop": false]),
            "engine": "hermes",
        ]))
    }

    func recorded(_ name: String) throws -> String { try String(contentsOfFile: scripts + "/" + name, encoding: .utf8) }

    /// The value of one variable in the environment the runner was started with.
    func environment(_ name: String) throws -> String? {
        try recorded("env.txt").split(separator: "\n").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}

/// Waits until `condition` holds, polling every 20 ms for up to `timeout` seconds.
func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

final class HermesRunnerTests: XCTestCase {
    func testTheHostPinsTheModelHandlesApprovalsRedactsAndKeepsASession() async throws {
        let rig = try HermesRig(self, runner: approvalRunner)
        let backend = rig.backend
        let sent = try backend.submit(message: "Make a file", kind: "agent", requestId: newID())
        await waitUntil("the approval") { (try? await backend.status())?.job?.approval != nil }
        let pending = try await backend.status().job?.approval
        let waiting = try XCTUnwrap(pending)
        // What the person sees is redacted: the model's key never shows.
        XCTAssertEqual(waiting.command, "test [redacted]")
        XCTAssertEqual(waiting.description, "Approve?")
        XCTAssertThrowsError(try backend.approve(id: "wrong", digest: "d", choice: "once")) { XCTAssertEqual(messageOf($0), "No matching active approval.") }
        try backend.approve(id: waiting.id, digest: waiting.digest, choice: "once")
        await backend.waitForIdle()
        let answer = try JSONValue.parse(try rig.recorded("answer.txt"))
        XCTAssertEqual(answer, ["id": "a", "digest": "d", "choice": "once"])
        let open = try await backend.status().job?.approval
        XCTAssertNil(open)

        let thread = try XCTUnwrap(backend.history.get(sent.threadId))
        XCTAssertEqual(thread["engine"]?.string, "hermes")
        XCTAssertEqual(thread["hermesSession"]?.string, "session-fixture")
        XCTAssertTrue(thread["agentModel"]?.string?.hasPrefix("[\"server\",\"http://127.0.0.1:5555/v1\",\"a-custom-model\",") == true)
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["content"]?.string, "Done")
        XCTAssertEqual(reply["state"]?.string, "done")
        XCTAssertEqual(reply["events"]?[0]?["type"]?.string, "tool_use")
        XCTAssertEqual(reply["events"]?[0]?["name"]?.string, "file_write")

        // The conversation's own profile pins the local model, and the query file is gone when the turn ends.
        let profile = rig.data + "/hermes/" + sent.threadId
        let config = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: profile + "/config.yaml")))
        XCTAssertEqual(config["model"]?["default"]?.string, "a-custom-model")
        XCTAssertEqual(config["model"]?["base_url"]?.string, "http://127.0.0.1:5555/v1")
        XCTAssertEqual(config["auxiliary"]?["compression"]?["base_url"]?.string, "http://127.0.0.1:5555/v1")
        XCTAssertEqual(config["auxiliary"]?["compression"]?["fallback_chain"]?.array?.count, 0)
        XCTAssertEqual(config["plugins"]?["enabled"]?[0]?.string, "companion-tools")
        XCTAssertEqual(config["security"]?["approval"]?["transport"]?.string, "companion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile + "/SOUL.md"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: profile).contains { $0.hasPrefix("query-") })
        XCTAssertEqual(try rig.environment("CUA_DRIVER_RS_ENABLE_WAYLAND"), "0")
        XCTAssertEqual(try rig.environment("HERMES_HOME"), profile)
        XCTAssertEqual(try rig.environment("OPENAI_API_KEY"), "local-test-key")
        let runs = try rig.recorded("runs.txt")
        XCTAssertTrue(runs.contains("companion,terminal,file,todo"))
        XCTAssertFalse(runs.contains("local-test-key"))

        // A later message resumes the same Hermes session, and an artifact the runner wrote is listed; a bad id is ignored.
        let artifact = "0123456789abcdef0123456789abcdef"
        try FileManager.default.createDirectory(atPath: rig.data + "/artifacts", withIntermediateDirectories: true)
        try "hello".write(toFile: rig.data + "/artifacts/" + artifact, atomically: true, encoding: .utf8)
        _ = try backend.submit(message: "Continue", kind: "agent", requestId: newID(), threadId: sent.threadId)
        await backend.waitForIdle()
        XCTAssertTrue(try rig.recorded("runs.txt").contains("--resume"))
        let resumed = lastMessage(backend, sent.threadId)
        XCTAssertEqual(resumed["content"]?.string, "Resumed")
        XCTAssertEqual(resumed["artifacts"]?.array, [["id": .string(artifact), "name": "report.txt", "size": 5]])

        // The model changed: the conversation is not moved to it.
        try rig.fixture.rewriteConfig { $0.model.id = "another-model" }
        _ = try backend.submit(message: "Again", kind: "agent", requestId: newID(), threadId: sent.threadId)
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, sent.threadId)["error"]?.string, "Start a new Agent conversation after changing models or workspace.")
    }

    func testStopSignalsTheWholeRunnerAndTheTurnIsInterrupted() async throws {
        let rig = try HermesRig(self, runner: waitingRunner)
        let backend = rig.backend
        let sent = try backend.submit(message: "Work", kind: "agent", requestId: newID())
        await waitUntil("the runner to report ready") { (try? await backend.status())?.job?.progress == "ready" }
        _ = backend.cancel()
        await backend.waitForIdle()
        XCTAssertEqual(try rig.recorded("signal.txt"), "stopped\n")
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "interrupted")
        let open = try await backend.status().job?.approval
        XCTAssertNil(open)
    }

    func testHermesRunsOnlyInTheDesktopServiceWithItsScriptsAndWhenEnabled() async throws {
        // The Mac and the terminal program: no scripts, so Hermes is unavailable whatever the settings say.
        let plain = try HermesRig(self, runner: approvalRunner, withScripts: false)
        let plainStatus = try await plain.backend.desktopStatusJSON()
        XCTAssertEqual(plainStatus["hermesEnabled"]?.bool, false)
        var old = plain.backend.history.create("Old Hermes task")
        old = old.setting("kind", "agent").setting("hermesSession", "saved").setting("messages", [
            ["id": .string(newID()), "role": "user", "content": "x", "state": "done"],
            ["id": .string(newID()), "role": "assistant", "content": "y", "state": "done"],
        ])
        try plain.backend.history.save(old)
        XCTAssertThrowsError(try plain.backend.submit(message: "continue", kind: "agent", requestId: newID(), threadId: old["id"]!.string!)) {
            XCTAssertEqual(messageOf($0), "This conversation uses Hermes. Enable it in desktop Settings, or start a new Code conversation.")
        }
        // A new Code conversation still goes to Black Team's own engine, as before.
        let plainSent = try plain.backend.submit(message: "Edit", kind: "agent", requestId: newID())
        await plain.backend.waitForIdle()
        XCTAssertEqual(plain.backend.history.get(plainSent.threadId)?["engine"]?.string, "black-team")
        XCTAssertEqual(plain.fixture.engine.runs.count, 1)

        // Scripts present but Hermes switched off: the same as not enabled, and the runner never starts.
        let off = try HermesRig(self, runner: approvalRunner, enabled: false)
        let offStatus = try await off.backend.desktopStatusJSON()
        XCTAssertEqual(offStatus["hermesEnabled"]?.bool, false)
        let offSent = try off.backend.submit(message: "Edit", kind: "agent", requestId: newID())
        await off.backend.waitForIdle()
        XCTAssertEqual(off.backend.history.get(offSent.threadId)?["engine"]?.string, "black-team")
        XCTAssertEqual(off.fixture.engine.runs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.scripts + "/runs.txt"))

        // Scripts and Hermes enabled: the status says so, and a new Code conversation uses Hermes.
        let on = try HermesRig(self, runner: approvalRunner)
        let onStatus = try await on.backend.desktopStatusJSON()
        XCTAssertEqual(onStatus["hermesEnabled"]?.bool, true)
        let onSent = try on.backend.submit(message: "Make a file", kind: "agent", requestId: newID())
        await waitUntil("the approval") { (try? await on.backend.status())?.job?.approval != nil }
        XCTAssertEqual(on.backend.history.get(onSent.threadId)?["engine"]?.string, "hermes")
        XCTAssertEqual(on.fixture.engine.runs.count, 0)
        if let waiting = try await on.backend.status().job?.approval { try on.backend.approve(id: waiting.id, digest: waiting.digest, choice: "deny") }
        await on.backend.waitForIdle()
    }

    func testTheServiceOptionTurnsHermesOnInItsStatus() async throws {
        let rig = try HermesRig(self, runner: approvalRunner, withScripts: false)
        let service = try DesktopService(options: DesktopServiceOptions(web: rig.root, version: "1.2.3", port: 0, dataFolder: rig.data,
                                                                       tailscale: { _, _, _ in throw PhoneCommandError(notFound: true) },
                                                                       scripts: rig.scripts), backend: rig.backend)
        _ = try await service.start()
        addTeardownBlock { await service.shutdown() }
        let reply = try JSONValue.parse(await service.respond(toLine: "{\"id\":1,\"action\":\"status\"}") ?? "null")
        XCTAssertEqual(reply["result"]?["hermesEnabled"]?.bool, true)
    }
}
