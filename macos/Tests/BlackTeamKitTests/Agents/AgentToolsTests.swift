import XCTest
@testable import BlackTeamKit

final class AgentToolsTests: XCTestCase {
    func testClaudeCodeArgumentsKeepTheModestDefaults() {
        let args = AgentTools.arguments(service: .claudeCode, task: "fix it", session: nil, workspace: "/w")
        XCTAssertEqual(args, ["-p", "fix it", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"])
        let resumed = AgentTools.arguments(service: .claudeCode, task: "again", session: "s1", workspace: "/w")
        XCTAssertEqual(Array(resumed.suffix(2)), ["--resume", "s1"])
    }

    func testCodexArgumentsRunInTheWorkspaceWithWriteAccessOnly() {
        let args = AgentTools.arguments(service: .codex, task: "fix it", session: nil, workspace: "/w")
        XCTAssertEqual(args, ["exec", "--json", "--skip-git-repo-check", "-C", "/w", "-s", "workspace-write", "fix it"])
        let resumed = AgentTools.arguments(service: .codex, task: "again", session: "t1", workspace: "/w")
        XCTAssertEqual(resumed, ["exec", "resume", "t1", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "again"])
    }

    func testNoArgumentSkipsPermissions() {
        for service in AgentService.allCases {
            for session in [nil, "x"] {
                let joined = AgentTools.arguments(service: service, task: "t", session: session, workspace: "/w").joined(separator: " ")
                XCTAssertFalse(joined.contains("dangerously"), joined)
                XCTAssertFalse(joined.contains("bypass"), joined)
                XCTAssertFalse(joined.contains("skip-permissions"), joined)
            }
        }
    }

    func testEnvironmentLosesProviderKeysAndUsesTheToolPath() {
        let source = ["PATH": "/usr/bin", "HOME": "/Users/t", "ANTHROPIC_API_KEY": "sk-ant-secret-value", "ANTHROPIC_AUTH_TOKEN": "token-value",
                      "OPENAI_API_KEY": "sk-openai-secret", "OPENROUTER_API_KEY": "or-secret", "OPENAI_BASE_URL": "http://x", "LANG": "en_US.UTF-8"]
        let env = AgentTools.environment(source: source, search: ["/opt/tools/bin", "/usr/bin"])
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "OPENAI_BASE_URL"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertEqual(env["HOME"], "/Users/t")
        XCTAssertEqual(env["PATH"], "/opt/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testLocateFindsOnlyAnExecutableFile() throws {
        let dir = NSTemporaryDirectory() + "agent-locate-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/codex", contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        FileManager.default.createFile(atPath: dir + "/claude", contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertNil(AgentTools.locate("codex", search: [dir]))
        XCTAssertEqual(AgentTools.locate("claude", search: [dir]), dir + "/claude")
        XCTAssertNil(AgentTools.locate("claude", search: [dir + "/missing"]))
    }

    func testEngineNamesMapBothWays() {
        XCTAssertEqual(AgentService.claudeCode.engine, "claude-code")
        XCTAssertEqual(AgentService.forEngine("codex"), .codex)
        XCTAssertNil(AgentService.forEngine("black-team"))
        XCTAssertNil(AgentService.forEngine(nil))
    }
}
