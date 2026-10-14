import XCTest
@testable import BlackTeamKit

// What the conversation's private Hermes profile holds, and what the Hermes process is started with, once abilities are switched on.
// The runner is a fake shell script (as in HermesRunnerTests), so no Hermes starts.

private let reportingRunner = #"""
#!/bin/sh
DIR=$(dirname "$0")
printf '%s\n' "$@" >> "$DIR/runs.txt"
env > "$DIR/env.txt"
echo '{"type":"black_team_tools","tools":{"mcp__notes__read":1200,"mcp__notes__write":800,"terminal":4000}}'
echo '{"type":"result","text":"Done","session_id":"session-fixture","exit_code":0}'
"""#

final class HermesProfileTests: XCTestCase {
    func testTheProfileCarriesWhatWasSwitchedOnAndKeysAreOnlyInTheEnvironment() async throws {
        let rig = try HermesRig(self, runner: reportingRunner)
        let backend = rig.backend
        let service = HermesAbilitiesService(dataFolder: rig.data, integrations: backend.integrations, scripts: rig.scripts)
        // An install with a skill and a plugin, written in Hermes's shape.
        try FileManager.default.createDirectory(atPath: rig.source + "/skills/devops/deploy", withIntermediateDirectories: true)
        try "---\nname: deploy\ndescription: Ship it.\n---\n".write(toFile: rig.source + "/skills/devops/deploy/SKILL.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: rig.source + "/plugins/disk-cleanup", withIntermediateDirectories: true)
        try "name: disk-cleanup\ndescription: Clean up.\n".write(toFile: rig.source + "/plugins/disk-cleanup/plugin.yaml", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: rig.source + "/plugins/web/searxng", withIntermediateDirectories: true)
        try "name: web-searxng\nkind: backend\ndescription: \"Self-hosted. Requires SEARXNG_URL.\"\nprovides_web_providers:\n  - searxng\n"
            .write(toFile: rig.source + "/plugins/web/searxng/plugin.yaml", atomically: true, encoding: .utf8)
        // The tool table comes from the saved answer of the install; use the same fixture the abilities tests use.
        let line = JSONValue.object(AbilityRig.answer).text()
        try "#!/bin/sh\nprintf 'BT_ABILITIES=%s\\n' '\(line)'\n".write(toFile: rig.scripts + "/hermes-abilities.py", atomically: true, encoding: .utf8)
        _ = try await service.save(["toolsets": ["terminal", "web"], "skills": ["devops/deploy"], "plugins": ["disk-cleanup"], "webSearch": "searxng",
                                    "mcp": [["name": "notes", "command": "/bin/sh", "args": ["-c", "cat"], "envNames": ["API_TOKEN"], "enabled": true]]])
        try await service.setKey(name: "SEARXNG_URL", value: "http://127.0.0.1:8888")
        try await service.setKey(name: "mcp.notes.API_TOKEN", value: "profile-test-secret")

        let sent = try backend.submit(message: "Work", kind: "agent", requestId: newID())
        await backend.waitForIdle()
        let profile = rig.data + "/hermes/" + sent.threadId
        // Fixed groups are passed in order: companion first, then the choice, the skills group because skills are linked, then MCP.
        let runs = try rig.recorded("runs.txt")
        XCTAssertTrue(runs.contains("companion,terminal,web,skills,mcp-notes"), runs)

        let text = try String(contentsOfFile: profile + "/config.yaml", encoding: .utf8)
        let config = try JSONValue.parse(text)
        XCTAssertEqual(config["plugins"]?["enabled"]?.array?.compactMap { $0.string }, ["companion-tools", "disk-cleanup"])
        XCTAssertEqual(config["web"]?["search_backend"]?.string, "searxng")
        XCTAssertEqual(config["web"]?["keyless_fallback"]?.bool, false)
        XCTAssertEqual(config["mcp_servers"]?["notes"]?["command"]?.string, "/bin/sh")
        XCTAssertEqual(config["mcp_servers"]?["notes"]?["env"]?["API_TOKEN"]?.string, "${BT_MCP_NOTES_API_TOKEN}")
        // The model settings the app always pins are still there.
        XCTAssertEqual(config["model"]?["base_url"]?.string, "http://127.0.0.1:5555/v1")
        XCTAssertEqual(config["security"]?["approval"]?["transport"]?.string, "companion")
        // No secret is in any file of the profile; the process got them by environment.
        let files = try FileManager.default.subpathsOfDirectory(atPath: profile)
        for file in files {
            let path = profile + "/" + file
            guard !CoreFS.isSymlink(path), let content = FileManager.default.contents(atPath: path) else { continue }
            XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("profile-test-secret"), file)
        }
        XCTAssertEqual(try rig.environment("BT_MCP_NOTES_API_TOKEN"), "profile-test-secret")
        XCTAssertEqual(try rig.environment("SEARXNG_URL"), "http://127.0.0.1:8888")
        let mode = try FileManager.default.attributesOfItem(atPath: profile + "/config.yaml")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // The skill is linked, not copied.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile + "/skills/devops/deploy"), rig.source + "/skills/devops/deploy")
        XCTAssertTrue(CoreFS.isSymlink(profile + "/plugins/companion-tools"))
        // The runner's report of tool sizes became the server's cost.
        XCTAssertEqual(service.store.mcpCosts()["notes"], 2000)
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "done")
    }

    func testAnOldSettingsFileStillRunsTheSameToolGroups() async throws {
        let rig = try HermesRig(self, runner: reportingRunner)
        _ = try rig.backend.integrations.save(.object(["hermes": .object(["enabled": true, "python": "/bin/sh", "source": .string(rig.source),
                                                                          "coding": false, "browser": true, "desktop": true])]))
        let sent = try rig.backend.submit(message: "Work", kind: "agent", requestId: newID())
        await rig.backend.waitForIdle()
        XCTAssertTrue(try rig.recorded("runs.txt").contains("companion,browser,computer_use"))
        XCTAssertEqual(try rig.environment("CUA_DRIVER_RS_ENABLE_WAYLAND"), "1")
        let config = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: rig.data + "/hermes/" + sent.threadId + "/config.yaml")))
        XCTAssertEqual(config["plugins"]?["enabled"]?.array?.compactMap { $0.string }, ["companion-tools"])
        XCTAssertEqual(config["web"]?["keyless_fallback"]?.bool, false)
        XCTAssertNil(config["mcp_servers"])
    }
}
