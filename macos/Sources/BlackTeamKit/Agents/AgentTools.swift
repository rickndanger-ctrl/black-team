import Foundation

extension AgentService {
    /// The command-line program's name.
    public var program: String { self == .claudeCode ? "claude" : "codex" }
    /// The engine name saved on a conversation.
    public var engine: String { self == .claudeCode ? "claude-code" : "codex" }

    /// The service a saved conversation's engine names, or nil for any other conversation.
    public static func forEngine(_ name: String?) -> AgentService? {
        allCases.first { $0.engine == name }
    }
}

/// How the subscription agents are found, started and told what to do. Everything here is a pure function of its inputs,
/// so the tests can check the command lines and the environment without starting a tool.
public enum AgentTools {
    /// Keys that would make the tool bill a provider key instead of the person's subscription login. Removed when present.
    static let keysRemoved = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "OPENROUTER_API_KEY"]
    /// A run is stopped after this long.
    public static let timeout: TimeInterval = 30 * 60
    /// The most text one reply keeps, as for a Chat reply.
    public static let replyLimit = 256 * 1024

    /// The program in the first folder of the harness search path that has it, as an absolute path.
    public static func locate(_ name: String, search: [String]? = nil) -> String? {
        for folder in search ?? harnessSearchPaths() {
            let path = folder + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, access(path, X_OK) == 0 {
                return path
            }
        }
        return nil
    }

    /// The environment for the tool: the harness environment, the usual PATH, and no provider keys.
    public static func environment(source: [String: String] = ProcessInfo.processInfo.environment, search: [String]? = nil) -> [String: String] {
        var env = localEnvironment(source)
        for key in keysRemoved { env[key] = nil }
        var folders = (search ?? harnessSearchPaths(env: source)) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        folders = folders.filter { seen.insert($0).inserted }
        env["PATH"] = folders.joined(separator: ":")
        return env
    }

    /// The arguments for a run. A new session gets the task text; a resumed one gets the person's new message only.
    /// Permissions stay at the tool's modest defaults: Claude Code accepts edits, Codex may write inside the workspace.
    /// Nothing here skips permissions.
    public static func arguments(service: AgentService, task: String, session: String?, workspace: String) -> [String] {
        switch service {
        case .claudeCode:
            // The person's own Claude Code setup may have connectors to mail, calendars and the like. A task handed
            // over by Black Team is about the project folder, so those are left out of this run.
            var args = ["-p", task, "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
            if let session { args += ["--resume", session] }
            return args
        case .codex:
            if let session {
                return ["exec", "resume", session, "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", task]
            }
            return ["exec", "--json", "--skip-git-repo-check", "-C", workspace, "-s", "workspace-write", task]
        }
    }
}
