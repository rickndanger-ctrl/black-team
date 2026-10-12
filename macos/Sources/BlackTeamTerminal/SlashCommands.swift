import Foundation

public struct SlashCommand: Equatable {
    public var name: String
    public var usage: String
    public var summary: String
}

/// The commands that start with a slash in the interactive session: what they are, how a line is read, and Tab completion.
public enum Slash {
    public static let all: [SlashCommand] = [
        SlashCommand(name: "help", usage: "/help", summary: "list these commands"),
        SlashCommand(name: "chat", usage: "/chat", summary: "talk with the model (a new conversation)"),
        SlashCommand(name: "code", usage: "/code", summary: "let the model work in your folder (a new conversation)"),
        SlashCommand(name: "new", usage: "/new", summary: "start a new conversation, same mode"),
        SlashCommand(name: "resume", usage: "/resume [number]", summary: "list recent conversations; a number opens one"),
        SlashCommand(name: "model", usage: "/model [number]", summary: "list saved models; a number switches"),
        SlashCommand(name: "agent", usage: "/agent claude|codex|off", summary: "use a subscription agent for this conversation"),
        SlashCommand(name: "permission", usage: "/permission ask|edit|auto", summary: "how much the agent may do on its own"),
        SlashCommand(name: "pace", usage: "/pace fast|balanced|deep|extended", summary: "how long and careful the replies are"),
        SlashCommand(name: "project", usage: "/project [name|number|none]", summary: "list projects, choose one, or leave it"),
        SlashCommand(name: "image", usage: "/image <path>|clear", summary: "attach a picture to your next chat message"),
        SlashCommand(name: "undo", usage: "/undo", summary: "undo the last file change, or roll back the last agent task"),
        SlashCommand(name: "team", usage: "/team \"<goal>\"", summary: "have the project's team work on a goal"),
        SlashCommand(name: "status", usage: "/status", summary: "model, mode, conversation and folder"),
        SlashCommand(name: "memory", usage: "/memory <query>", summary: "search what Black Team remembers"),
        SlashCommand(name: "quit", usage: "/quit", summary: "leave (Ctrl-D on an empty line works too)"),
    ]

    public static let aliases = ["exit": "quit", "?": "help"]

    public enum Parsed: Equatable {
        case notCommand
        case unknown(String)
        case command(String, argument: String)
    }

    /// A line that starts with a slash and a command name. A line that starts like a file path ("/home/me/x") is just text.
    public static func parse(_ line: String) -> Parsed {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .notCommand }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        let argument = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .unknown("") }
        if name.contains("/") { return .notCommand }
        let lowered = name.lowercased()
        let resolved = aliases[lowered] ?? lowered
        return all.contains { $0.name == resolved } ? .command(resolved, argument: argument) : .unknown(name)
    }

    /// Splits an argument on spaces, keeping quoted pieces together ("a b" and 'a b' are one piece).
    public static func words(_ argument: String) -> [String] {
        var out: [String] = [], current = "", quote: Character?, started = false
        for c in argument {
            if let q = quote { if c == q { quote = nil } else { current.append(c) } }
            else if c == "\"" || c == "'" { quote = c; started = true }
            else if c.isWhitespace { if started || !current.isEmpty { out.append(current); current = ""; started = false } }
            else { current.append(c) }
        }
        if started || !current.isEmpty { out.append(current) }
        return out
    }

    static let arguments: [String: [String]] = [
        "agent": ["claude", "codex", "off"], "permission": ["ask", "edit", "auto"], "pace": ["fast", "balanced", "deep", "extended"],
        "image": ["clear"], "project": ["none"],
    ]

    /// Tab: the buffer completed as far as it is certain, or nil when there is nothing to add.
    public static func complete(_ buffer: String) -> String? {
        guard buffer.hasPrefix("/") else { return nil }
        let body = String(buffer.dropFirst())
        if let space = body.firstIndex(where: { $0 == " " }) {
            let name = String(body[..<space])
            let typed = String(body[body.index(after: space)...])
            guard let options = arguments[aliases[name] ?? name], !typed.contains(" ") else { return nil }
            return pick(typed, from: options).map { "/\(name) \($0)" }
        }
        let names = all.map(\.name)
        guard let hit = pick(body, from: names) else { return nil }
        let takesArgument = all.first { $0.name == hit }?.usage.contains(" ") == true
        return "/" + hit + (names.contains(hit) && takesArgument && names.filter({ $0.hasPrefix(hit) }).count == 1 ? " " : "")
    }

    /// The only option that starts with `typed`, or the longest start shared by several; nil when it adds nothing.
    private static func pick(_ typed: String, from options: [String]) -> String? {
        let matches = options.filter { $0.hasPrefix(typed.lowercased()) }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] == typed ? nil : matches[0] }
        var common = matches[0]
        for m in matches.dropFirst() { while !m.hasPrefix(common) { common.removeLast() } }
        return common.count > typed.count ? common : nil
    }

    public static func helpText() -> String {
        let width = all.map { $0.usage.count }.max() ?? 0
        return all.map { "  " + $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }.joined(separator: "\n")
    }
}
