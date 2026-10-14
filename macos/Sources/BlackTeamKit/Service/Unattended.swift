import Foundation

// How a run with nobody at the window is held to account. A scheduled Code run (Service/Scheduler.swift) carries one of these on its
// job; the Code engine and its tools read it (Engine/Engine.swift, Tools/Tools.swift). A run with a person present has none and
// keeps the usual rules.

/// What a scheduled Code run may do without asking.
public enum UnattendedPermission: String, Codable, CaseIterable, Sendable {
    /// Reads and searches only. It is not offered the tools that change files or run commands, so it never asks.
    case readOnly = "read-only"
    /// Asks before every file change and every terminal command. The default.
    case ask
    /// Changes files inside the project folder without asking. Terminal commands still ask.
    case allowInProject = "allow-in-project"

    /// The words the screens use.
    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .ask: return "Ask me first"
        case .allowInProject: return "Edit files in the project"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly: return "It can read and search the project. It cannot change anything or run commands, and it never asks."
        case .ask: return "It waits for your answer before it changes a file or runs a command."
        case .allowInProject: return "It can change files inside the project folder without asking. It still asks before running a command."
        }
    }
}

public struct UnattendedPolicy: Equatable, Sendable {
    public var permission: UnattendedPermission
    /// How long a question may wait for an answer before the run ends as "not approved".
    public var approvalSeconds: Int
    public init(permission: UnattendedPermission = .ask, approvalSeconds: Int = 24 * 3600) {
        self.permission = permission
        self.approvalSeconds = max(1, approvalSeconds)
    }
}
