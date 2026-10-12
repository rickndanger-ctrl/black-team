import XCTest
@testable import BlackTeamKit

final class AgentToolsTests: XCTestCase {
    func testAServiceErrorInJSONIsShownAsItsSentence() {
        let raw = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'x' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#
        XCTAssertEqual(AgentTurn.plain(raw), "The 'x' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again.")
        XCTAssertEqual(AgentTurn.plain("Codex stopped."), "Codex stopped.")
        XCTAssertEqual(AgentTurn.plain(#"{"unrelated":true}"#), #"{"unrelated":true}"#)
    }

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

    func testClaudeCodeLevelsPickTheToolsOwnModes() {
        func mode(_ level: AgentPermission) -> String {
            let args = AgentTools.arguments(service: .claudeCode, task: "t", session: nil, workspace: "/w", permission: level)
            return args[args.firstIndex(of: "--permission-mode")! + 1]
        }
        XCTAssertEqual(mode(.ask), "manual"); XCTAssertEqual(mode(.edit), "acceptEdits"); XCTAssertEqual(mode(.auto), "auto")
        let allowed = AgentTools.arguments(service: .claudeCode, task: "t", session: "s", workspace: "/w", permission: .ask,
                                           allowedTools: ["Bash(touch a.txt)", "Edit(/w/b.txt)"])
        XCTAssertEqual(Array(allowed.dropFirst(7)), ["--allowedTools", "Bash(touch a.txt)", "Edit(/w/b.txt)", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--resume", "s"])
    }

    func testCodexLevelsAndTheirResumeForms() {
        func args(_ level: AgentPermission, _ session: String?) -> [String] {
            AgentTools.arguments(service: .codex, task: "t", session: session, workspace: "/w", permission: level)
        }
        XCTAssertEqual(args(.ask, nil), ["exec", "--json", "--skip-git-repo-check", "-C", "/w", "-s", "read-only", "t"])
        XCTAssertEqual(args(.edit, nil), ["exec", "--json", "--skip-git-repo-check", "-C", "/w", "-s", "workspace-write", "t"])
        XCTAssertEqual(args(.auto, nil), ["exec", "--json", "--skip-git-repo-check", "-C", "/w", "--approve-for-me", "t"])
        XCTAssertEqual(args(.ask, "x"), ["exec", "resume", "x", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\"", "t"])
        XCTAssertEqual(args(.edit, "x"), ["exec", "resume", "x", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "t"])
        XCTAssertEqual(args(.auto, "x"), ["exec", "resume", "x", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"",
                                          "-c", "approval_policy=\"on-request\"", "-c", "approvals_reviewer=\"auto_review\"", "t"])
    }

    func testNoLevelEverSkipsPermissions() {
        for service in AgentService.allCases {
            for level in AgentPermission.allCases {
                for session in [nil, "x"] {
                    let joined = AgentTools.arguments(service: service, task: "t", session: session, workspace: "/w", permission: level,
                                                      allowedTools: ["Bash(ls)"]).joined(separator: " ")
                    for banned in ["dangerously", "bypass", "skip-permissions", "danger-full-access", "dontAsk"] {
                        XCTAssertFalse(joined.contains(banned), "\(banned) in \(joined)")
                    }
                }
            }
        }
    }

    func testAThreadWithoutALevelIsEdit() {
        XCTAssertEqual(AgentPermission.of(thread: ["id": "a"]), .edit)
        XCTAssertEqual(AgentPermission.of(thread: ["agentPermission": "auto"]), .auto)
        XCTAssertEqual(AgentPermission.of(thread: ["agentPermission": "nonsense"]), .edit)
    }
}
