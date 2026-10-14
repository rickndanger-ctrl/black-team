import Foundation

/// `black-team -p "<message>"`: one Chat (or Code) turn, the reply on stdout, nothing asked.
public struct OneShotOptions: Equatable {
    public var message: String?
    public var code = false
    public var json = false
    public var approve = "deny"
    public var allowCloud = false
    public var pace = "balanced"
    public var workspace: String?
    public var images: [String] = []
    public var thread: String?

    public enum ParseError: Error, Equatable { case message(String) }

    public static let commandNames: Set<String> = ["status", "hermes", "chat", "code", "agent", "room", "starter", "runtime", "vision", "cloud", "phone", "models", "find",
                                                   "use", "memory", "serve", "install-command", "help", "version"]

    /// True when the arguments ask for one-shot use: -p or --print, with no subcommand first.
    public static func isOneShot(_ arguments: [String]) -> Bool {
        guard arguments.contains(where: { $0 == "-p" || $0 == "--print" }) else { return false }
        if let first = arguments.first, !first.hasPrefix("-"), commandNames.contains(first) { return false }
        return true
    }

    /// Reads the arguments (everything after the program name). Words that are not options make up the message.
    public static func parse(_ arguments: [String]) throws -> OneShotOptions {
        var o = OneShotOptions()
        var words: [String] = []
        var i = 0
        func value(_ name: String) throws -> String {
            guard i + 1 < arguments.count else { throw ParseError.message("\(name) needs a value.") }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "-p", "--print": break
            case "--code": o.code = true
            case "--json": o.json = true
            case "--allow-cloud": o.allowCloud = true
            case "--approve":
                o.approve = try value(a)
                guard ["once", "deny"].contains(o.approve) else { throw ParseError.message("--approve takes once or deny.") }
            case "--mode", "--pace":
                o.pace = try value(a)
                guard ["fast", "balanced", "deep", "extended"].contains(o.pace) else { throw ParseError.message("\(a) takes fast, balanced, deep or extended.") }
            case "--workspace": o.workspace = try value(a)
            case "--image": o.images.append(try value(a))
            case "--thread": o.thread = try value(a)
            case "--": words.append(contentsOf: arguments[(i + 1)...]); i = arguments.count
            default:
                if a.hasPrefix("-"), a.count > 1 { throw ParseError.message("Unknown option \(a). See black-team --help.") }
                words.append(a)
            }
            i += 1
        }
        if !words.isEmpty { o.message = words.joined(separator: " ") }
        if o.code, !o.images.isEmpty { throw ParseError.message("Pictures can be attached to Chat only, not to Code.") }
        if o.workspace != nil, !o.code { throw ParseError.message("--workspace goes with --code.") }
        return o
    }
}
