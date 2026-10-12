import Foundation

/// Something Claude Code wanted to do that needed an approval it cannot ask for under `-p`.
public struct AgentDenial: Equatable, Sendable {
    public var id: String
    public var tool: String
    /// The tool's own input (empty until the end-of-run list arrives).
    public var input: JSONValue
    /// The tool's own words about why it needs approval.
    public var message: String
    public init(id: String, tool: String, input: JSONValue = .null, message: String = "") {
        self.id = id; self.tool = tool; self.input = input; self.message = message
    }
}

/// One thing a subscription agent said or did, read from one line of its output.
public enum AgentEvent: Equatable, Sendable {
    /// The tool's own session id, which a later message continues.
    case session(String)
    /// Text the agent wrote for the person.
    case text(String)
    /// A tool step starting: its name and what it was asked to do.
    case toolUse(id: String, name: String, input: String)
    /// A tool step finished: what it printed, and whether it failed.
    case toolResult(id: String, output: String, isError: Bool)
    /// The end of a turn. `text` is the tool's final answer when it gives one.
    case finished(text: String, isError: Bool)
    /// The tool reported an error in its own words.
    case failed(String)
    /// A step that needed approval and was not done.
    case denied(AgentDenial)
    /// A line that is not needed (or not understood): skipped, never an error.
    case ignored
}

/// Reads the JSON lines that Claude Code (`--output-format stream-json`) and Codex (`exec --json`) print.
/// Every line is optional: an unknown or broken line gives `.ignored`, and nothing here throws.
public enum AgentEventParser {
    public static func parse(_ line: String, service: AgentService) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let json = try? JSONValue.parse(trimmed), json.object != nil else { return [.ignored] }
        switch service {
        case .claudeCode: return claude(json)
        case .codex: return codex(json)
        }
    }

    // MARK: Claude Code

    private static func claude(_ json: JSONValue) -> [AgentEvent] {
        switch json["type"]?.string {
        case "system":
            // The first event of a run: the session id a later run resumes.
            if json["subtype"]?.string == "init", let id = json["session_id"]?.string, !id.isEmpty { return [.session(id)] }
            if json["subtype"]?.string == "permission_denied" {
                return [.denied(AgentDenial(id: json["tool_use_id"]?.string ?? "", tool: json["tool_name"]?.string ?? "tool",
                                            message: json["message"]?.string ?? ""))]
            }
        case "assistant":
            var out: [AgentEvent] = []
            for block in json["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "text": if let text = block["text"]?.string, !text.isEmpty { out.append(.text(text)) }
                case "tool_use":
                    let input = block["input"].map { $0.text() } ?? ""
                    out.append(.toolUse(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "tool", input: input))
                default: break
                }
            }
            return out.isEmpty ? [.ignored] : out
        case "user":
            var out: [AgentEvent] = []
            for block in json["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                out.append(.toolResult(id: block["tool_use_id"]?.string ?? "", output: claudeText(block["content"]),
                                       isError: block["is_error"]?.bool ?? false))
            }
            return out.isEmpty ? [.ignored] : out
        case "result":
            var out: [AgentEvent] = []
            if let id = json["session_id"]?.string, !id.isEmpty { out.append(.session(id)) }
            for denial in json["permission_denials"]?.array ?? [] {
                out.append(.denied(AgentDenial(id: denial["tool_use_id"]?.string ?? "", tool: denial["tool_name"]?.string ?? "tool",
                                               input: denial["tool_input"] ?? .null)))
            }
            let isError = json["is_error"]?.bool ?? false
            out.append(.finished(text: json["result"]?.string ?? "", isError: isError))
            return out
        default: break
        }
        return [.ignored]
    }

    /// A tool result is a string or a list of text blocks.
    private static func claudeText(_ content: JSONValue?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }

    // MARK: Codex

    private static func codex(_ json: JSONValue) -> [AgentEvent] {
        switch json["type"]?.string {
        case "thread.started":
            if let id = json["thread_id"]?.string, !id.isEmpty { return [.session(id)] }
        case "turn.completed":
            return [.finished(text: "", isError: false)]
        case "turn.failed":
            return [.failed(json["error"]?["message"]?.string ?? json["message"]?.string ?? "Codex stopped with an error.")]
        case "item.started", "item.completed":
            let started = json["type"]?.string == "item.started"
            guard let item = json["item"], let id = item["id"]?.string else { return [.ignored] }
            switch item["type"]?.string {
            case "agent_message":
                if !started, let text = item["text"]?.string, !text.isEmpty { return [.text(text)] }
            case "command_execution":
                let command = item["command"]?.string ?? ""
                if started { return [.toolUse(id: id, name: "shell", input: command)] }
                let exit = item["exit_code"]?.double
                let failed = item["status"]?.string == "failed" || (exit != nil && exit != 0)
                return [.toolResult(id: id, output: item["aggregated_output"]?.string ?? "", isError: failed)]
            case "file_change":
                guard !started else { return [.ignored] }
                let paths = (item["changes"]?.array ?? []).compactMap { $0["path"]?.string }.joined(separator: "\n")
                let failed = item["status"]?.string == "failed"
                return [.toolUse(id: id, name: "file change", input: paths), .toolResult(id: id, output: item["status"]?.string ?? "", isError: failed)]
            case "mcp_tool_call":
                let name = [item["server"]?.string, item["tool"]?.string].compactMap { $0 }.joined(separator: ".")
                if started { return [.toolUse(id: id, name: name.isEmpty ? "tool" : name, input: item["arguments"].map { $0.text() } ?? "")] }
                return [.toolResult(id: id, output: item["error"]?["message"]?.string ?? "", isError: item["status"]?.string == "failed")]
            default: break
            }
        default: break
        }
        return [.ignored]
    }
}
