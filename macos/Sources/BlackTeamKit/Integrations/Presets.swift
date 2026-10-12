import Foundation

/// What each known harness needs to talk to the model Black Team is using.
/// A preset only supplies arguments, environment and, for two harnesses, a small settings
/// file in Black Team's own data folder. It never edits the harness's own configuration.

private let hours = 6 * 60 * 60 * 1000

/// The values a preset is built from. `dir` is the preset's own folder under `harnesses/`.
public struct PresetValues: Sendable {
    public var endpoint: String
    public var model: String
    public var key: String
    public var context: Int
    public var name: String
    public var dir: String
    public init(endpoint: String = "", model: String = "", key: String = "", context: Int = 4096, name: String = "", dir: String = "") {
        self.endpoint = endpoint; self.model = model; self.key = key; self.context = context; self.name = name; self.dir = dir
    }
}

public struct PresetBuild: Sendable {
    public var args: [String]
    public var env: [String: String]
    /// Settings files to write privately into `dir`, by file name.
    public var files: [(name: String, content: JSONValue)]
    public init(args: [String] = [], env: [String: String] = [:], files: [(name: String, content: JSONValue)] = []) {
        self.args = args; self.env = env; self.files = files
    }
}

public struct HarnessPreset: Sendable {
    public let id: String
    public let name: String
    public let command: String
    public let build: @Sendable (PresetValues) -> PresetBuild
}

/// What the launcher adds for one launch.
public struct AppliedPreset: Equatable, Sendable {
    public var args: [String]
    public var env: [String: String]
}

private func maxTokens(_ context: Int) -> JSONValue { .number(Double(min(8192, context / 4))) }

private func stripV1(_ endpoint: String) -> String {
    endpoint.replacingOccurrences(of: "/v1/?$", with: "", options: .regularExpression)
}

/// In the order the interface lists them.
public let PRESETS: [HarnessPreset] = [
    HarnessPreset(id: "claude", name: "Claude Code", command: "claude") { v in
        // Needs a server that also speaks the Anthropic Messages API: llama.cpp, Ollama and LM Studio do.
        PresetBuild(args: [], env: [
            "ANTHROPIC_BASE_URL": stripV1(v.endpoint), "ANTHROPIC_AUTH_TOKEN": v.key, "ANTHROPIC_MODEL": v.model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": v.model, "ANTHROPIC_DEFAULT_SONNET_MODEL": v.model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": v.model,
            "ANTHROPIC_SMALL_FAST_MODEL": v.model, "CLAUDE_CODE_SUBAGENT_MODEL": v.model,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_PROMPT_CACHING": "1",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(v.context), "CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(min(8192, v.context / 4)),
            // A local model can take minutes to read a long prompt; the stock deadlines assume a data centre.
            "API_TIMEOUT_MS": String(hours), "CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS": "1800000",
            "CLAUDE_ENABLE_BYTE_WATCHDOG": "0", "CLAUDE_ENABLE_STREAM_WATCHDOG": "0", "API_FORCE_IDLE_TIMEOUT": "0",
        ])
    },
    HarnessPreset(id: "codex", name: "Codex", command: "codex") { v in
        let pairs: [(String, JSONValue)] = [
            ("model_provider", "black_team"), ("model_providers.black_team.name", "Black Team"),
            ("model_providers.black_team.base_url", .string(v.endpoint)), ("model_providers.black_team.wire_api", "responses"),
            ("model_providers.black_team.env_key", "OPENAI_API_KEY"), ("model_providers.black_team.stream_idle_timeout_ms", .number(Double(hours))),
            ("model", .string(v.model)), ("model_context_window", .number(Double(v.context))), ("web_search", "disabled"),
        ]
        return PresetBuild(args: pairs.flatMap { ["-c", "\($0.0)=\($0.1.text())"] })
    },
    HarnessPreset(id: "pi", name: "Pi", command: "pi") { v in
        let model: JSONValue = ["id": .string(v.model), "name": .string(v.name), "reasoning": false, "input": ["text"],
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
            "contextWindow": .number(Double(v.context)), "maxTokens": maxTokens(v.context)]
        let provider: JSONValue = ["baseUrl": .string(v.endpoint), "api": "openai-completions", "apiKey": .string(v.key),
            "compat": ["supportsDeveloperRole": false, "maxTokensField": "max_tokens"], "models": [model]]
        return PresetBuild(args: ["--provider", "black-team", "--model", v.model],
            env: ["PI_CODING_AGENT_DIR": v.dir, "PI_OFFLINE": "1", "PI_TELEMETRY": "0"],
            files: [("models.json", ["providers": ["black-team": provider]])])
    },
    HarnessPreset(id: "opencode", name: "OpenCode", command: "opencode") { v in
        let config: JSONValue = ["$schema": "https://opencode.ai/config.json", "model": .string("black-team/\(v.model)"),
            "provider": ["black-team": ["npm": "@ai-sdk/openai-compatible", "name": "Black Team",
                "options": ["baseURL": .string(v.endpoint), "apiKey": .string(v.key)],
                "models": [v.model: ["name": .string(v.name)]]]]]
        return PresetBuild(args: [], env: ["OPENCODE_CONFIG_CONTENT": config.text()])
    },
    HarnessPreset(id: "dsh", name: "DeepSeek Harness", command: "dsh") { v in
        // The patch switches its hosted providers off, so this launch can only reach the local model.
        let provider: JSONValue = ["apiKeyEnv": "OPENAI_API_KEY", "api": "openai-completions", "baseURL": .string(v.endpoint),
            "models": [["id": .string(v.model), "name": .string(v.name), "contextWindow": .number(Double(v.context)),
                        "maxTokens": maxTokens(v.context), "input": ["text"]]],
            "compat": ["supportsStore": false, "supportsDeveloperRole": false, "maxTokensField": "max_tokens"],
            "timeoutMs": 1800000, "streamIdleTimeoutMs": 1800000]
        let patch: JSONValue = [
            ["id": "llm-deepseek", "disabled": true], ["id": "llm-deepseek-account", "disabled": true],
            ["id": "llm-pi-ai", "config": ["providers": ["black-team": provider]]],
            ["id": "agent-default-model", "config": ["provider": "black-team", "model": .string(v.model)]],
            ["id": "session-title-llm", "disabled": true],
        ]
        return PresetBuild(args: ["--profile", "terminal", "--patch", v.dir + "/black-team.patch.json"],
            env: ["DSH_HOME": v.dir], files: [("black-team.patch.json", patch)])
    },
    HarnessPreset(id: "aider", name: "Aider", command: "aider") { v in
        PresetBuild(args: ["--openai-api-base", v.endpoint, "--model", "openai/\(v.model)"], env: [:])
    },
]

public func preset(_ id: String) -> HarnessPreset? { PRESETS.first { $0.id == id } }

/// Turns a preset into what the launcher adds. Files are written privately: one can hold the model's key.
public func applyPreset(_ id: String, _ values: PresetValues, stateDir: String) throws -> AppliedPreset {
    guard let found = preset(id) else {
        throw BlackTeamError("This harness uses a connection Black Team does not know. Remove it and connect it again.")
    }
    let dir = stateDir + "/harnesses/" + id
    var values = values
    values.dir = dir
    let built = found.build(values)
    if !built.files.isEmpty {
        try privateDirectory(dir)
        for (name, content) in built.files {
            let file = dir + "/" + name
            let data = Data((content.text(pretty: true) + "\n").utf8)
            try CoreFS.writeAtomic(file, data, temporary: "\(file).\(CoreFS.hex(10)).tmp")
        }
    }
    return AppliedPreset(args: built.args, env: built.env)
}
