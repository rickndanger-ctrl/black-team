import XCTest
@testable import BlackTeamKit

// Runs one turn through the real HermesRunner and a real, installed Hermes, against a fake OpenAI-compatible server on a loopback
// port (no model). Skipped unless BT_LIVE_HERMES_PORT is set, so the ordinary suite never starts Hermes:
//   BT_LIVE_HERMES_PORT=<fake server port> BT_LIVE_HERMES_SOURCE=<hermes checkout> BT_LIVE_HERMES_SCRIPTS=<scripts folder>
//   BT_LIVE_ABILITIES=<folder with hermes-abilities.json and hermes-keys.json> BT_LIVE_OUT=<folder for the profile>
final class HermesLiveTests: XCTestCase {
    func testARealHermesLoadsTheProfileBlackTeamBuilds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["BT_LIVE_HERMES_PORT"], let source = env["BT_LIVE_HERMES_SOURCE"], let scripts = env["BT_LIVE_HERMES_SCRIPTS"],
              let abilities = env["BT_LIVE_ABILITIES"], let out = env["BT_LIVE_OUT"] else { throw XCTSkip("Set BT_LIVE_HERMES_* to run against a real Hermes.") }
        let rig = try HermesRig(self, runner: "")
        for name in ["hermes-abilities.json", "hermes-keys.json"] where CoreFS.exists(abilities + "/" + name) {
            try FileManager.default.copyItem(atPath: abilities + "/" + name, toPath: rig.data + "/" + name)
        }
        try rig.fixture.rewriteConfig { $0.model.endpoint = "http://127.0.0.1:\(port)/v1"; $0.model.context = 70000 }
        rig.fixture.runtime.startAction = { "http://127.0.0.1:\(port)/v1" }
        rig.backend.configureDesktop(DesktopOptions(scripts: scripts))
        _ = try rig.backend.integrations.save(.object(["hermes": .object(["enabled": true, "python": .string(source + "/venv/bin/python"), "source": .string(source),
                                                                          "coding": true, "browser": false, "desktop": false])]))
        let sent = try rig.backend.submit(message: "Say hello", kind: "agent", requestId: newID())
        await rig.backend.waitForIdle()
        let reply = lastMessage(rig.backend, sent.threadId)
        try? FileManager.default.removeItem(atPath: out)
        try FileManager.default.copyItem(atPath: rig.data + "/hermes", toPath: out)
        print("LIVE state=\(reply["state"]?.string ?? "?") content=\(reply["content"]?.string ?? "") error=\(reply["error"]?.string ?? "")")
        XCTAssertEqual(reply["state"]?.string, "done", reply["error"]?.string ?? "")
    }
}
