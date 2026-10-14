import XCTest
@testable import BlackTeamKit

// "Set up your agents" through the window's control channel: the plan, Not now, one approval, and progress in the status. A folder of
// fake programs stands in for the command path and a fake installer for Hermes: nothing real is run, downloaded or connected.
final class WindowSetupTests: XCTestCase {
    private func rig() async throws -> (WindowRig, FakeHermesInstaller, String) {
        let r = try await WindowRig(self)
        let bin = r.fixture.files.dir + "/fakebin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Programs that would leave a mark if anything ran them.
        for name in ["claude", "xterm"] {
            try "#!/bin/sh\ntouch '\(r.fixture.files.dir)/ran-\(name)'\n".write(toFile: bin + "/" + name, atomically: true, encoding: .utf8)
            chmod(bin + "/" + name, 0o755)
        }
        r.backend.setupEnvironment = ["PATH": bin]
        let installer = FakeHermesInstaller(folder: r.backend.dataFolder + "/hermes/hermes-agent")
        r.backend.hermesInstallerOverride = { _ in installer }
        return (r, installer, bin)
    }

    private func XCTAssertShows(_ r: WindowRig, _ reason: String, _ expected: Bool, _ message: String = "", line: UInt = #line) async {
        let offer = try? await r.result("setup-plan", ["reason": .string(reason)])
        XCTAssertEqual(offer?["show"]?.bool, expected, message, line: line)
    }

    private func waitForRun(_ r: WindowRig) async throws -> JSONValue {
        for _ in 0..<200 {
            let status = try await r.result("status")
            if let run = status["setupRun"], run["done"]?.bool == true || !(run["error"]?.string ?? "").isEmpty { return run }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the run did not finish"); return .null
    }

    func testThePlanIsOnlyAskedForAndNothingRunsOrChanges() async throws {
        let (r, installer, _) = try await rig()
        let offer = try await r.result("setup-plan", ["reason": "model-ready"])
        XCTAssertEqual(offer["show"]?.bool, true)
        let ids = offer["plan"]?["steps"]?.array?.compactMap { $0["id"]?.string } ?? []
        XCTAssertEqual(ids, ["connect:claude", "hermes-install", "hermes-connect", "hermes-tools", "agents-missing"])
        XCTAssertEqual(installer.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.fixture.files.dir + "/ran-claude"), "a found program is never run")
        XCTAssertTrue(try r.backend.integrations.read().harnesses.isEmpty)
        let idle = try await r.result("status")
        XCTAssertEqual(idle["setupRun"]?["running"]?.bool, false)
        await r.expectRefusal("setup-plan", ["reason": "whenever"], exact: "Unsupported setup setting.")
    }

    func testNotNowIsRememberedButAskingAgainStillShows() async throws {
        let (r, _, _) = try await rig()
        _ = try await r.result("setup-dismiss")
        await XCTAssertShows(r, "model-ready", false)
        await XCTAssertShows(r, "found-something-new", false)
        await XCTAssertShows(r, "asked", true, "Settings → Set up everything always shows")
        XCTAssertEqual(r.backend.offerSetupAfterModelReady().show, false)
    }

    func testApprovalRunsTheStepsAndTheStatusShowsEach() async throws {
        let (r, installer, _) = try await rig()
        let ids: JSONValue = ["connect:claude", "hermes-install", "hermes-connect", "hermes-tools"]
        let started = try await r.result("setup-apply", ["ids": ids])
        XCTAssertEqual(started["started"]?.bool, true)
        let run = try await waitForRun(r)
        XCTAssertEqual(run["error"]?.string, "")
        XCTAssertEqual(run["steps"]?.array?.compactMap { $0["status"]?.string }, ["done", "done", "done", "done"])
        XCTAssertEqual(installer.calls, 1)
        let settings = try r.backend.integrations.read()
        XCTAssertEqual(settings.harnesses.map(\.id), ["claude"])
        XCTAssertTrue(settings.hermes.enabled)
        XCTAssertFalse(settings.hermes.browser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.fixture.files.dir + "/ran-claude"), "connecting never runs the agent")
        // Done now: the approved steps are finished. On Linux nothing else is offered; a Mac also looks in fixed folders such as
        // /opt/homebrew/bin, where the computer running the tests may have more agents of its own.
        let after = r.backend.setupPlan().steps.filter { ["connect:claude", "hermes-install", "hermes-connect", "hermes-tools"].contains($0.id) }
        XCTAssertEqual(after.map(\.state), [.done, .done, .done, .done])
        #if os(Linux)
        await XCTAssertShows(r, "model-ready", false)
        #endif
    }

    func testBadApprovalsAreRefused() async throws {
        let (r, _, _) = try await rig()
        await r.expectRefusal("setup-apply", [:], exact: "Choose at least one step to set up.")
        await r.expectRefusal("setup-apply", ["ids": []], exact: "Choose at least one step to set up.")
        await r.expectRefusal("setup-apply", ["ids": ["a", "a"]], exact: "Choose at least one step to set up.")
        await r.expectRefusal("setup-apply", ["ids": ["a"], "more": 1], exact: "Unsupported setup setting.")
        let stopped = try await r.result("setup-cancel")
        XCTAssertEqual(stopped["stopped"]?.bool, true)
    }
}
