import Foundation

/// A few restrained colours and dim text. Off when output is not a terminal, NO_COLOR is set, or TERM is dumb.
public struct Style: Equatable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    public static func decide(isTerminal: Bool, environment: [String: String]) -> Bool {
        if !isTerminal { return false }
        if environment["NO_COLOR"] != nil { return false }
        if let term = environment["TERM"], term == "dumb" || term.isEmpty { return false }
        return true
    }

    private func wrap(_ code: String, _ text: String) -> String { enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    public func dim(_ text: String) -> String { wrap("2", text) }
    public func bold(_ text: String) -> String { wrap("1", text) }
    public func cyan(_ text: String) -> String { wrap("36", text) }
    public func green(_ text: String) -> String { wrap("32", text) }
    public func yellow(_ text: String) -> String { wrap("33", text) }
    public func red(_ text: String) -> String { wrap("31", text) }
}

/// The prompt: the mode and who answers, for example `chat · Ornith 1.5 9B ›` or `code · Claude Code [edit] ›`.
public enum PromptText {
    public static func plain(mode: String, who: String, permission: String? = nil) -> String {
        "\(mode) \u{00B7} \(who)" + (permission.map { " [\($0)]" } ?? "") + " \u{203A} "
    }

    public static func styled(mode: String, who: String, permission: String? = nil, style: Style) -> String {
        style.cyan(mode) + style.dim(" \u{00B7} ") + who + (permission.map { style.dim(" [\($0)]") } ?? "") + style.cyan(" \u{203A} ")
    }
}
