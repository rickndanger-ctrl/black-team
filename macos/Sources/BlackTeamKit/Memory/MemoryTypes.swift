import Foundation

/// Limits for what the models write, so memory stays quick to search and cheap to read.
public struct MemoryLimits: Codable, Equatable, Sendable {
    public var noteChars: Int
    public var journalEntries: Int
    public var totalChars: Int
    public init(noteChars: Int = 6000, journalEntries: Int = 30, totalChars: Int = 400_000) {
        self.noteChars = noteChars; self.journalEntries = journalEntries; self.totalChars = totalChars
    }
    public static let `default` = MemoryLimits()
}

public enum NoteKind: String, Codable, Sendable { case core, note, project, archive, missing }

/// One note in the vault (the `notes()` entries). `updated` is milliseconds since 1970, as JavaScript's `mtimeMs`.
public struct NoteInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var updated: Double
    public var size: Int
    public var links: [String]
    public var kind: NoteKind
}

public struct GraphNode: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var kind: NoteKind
    public var project: String
    public var updated: Double
    public var missing: Bool
}

public struct GraphEdge: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
}

public struct MemoryGraph: Codable, Equatable, Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
}

public struct NoteContent: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var updated: Double
}

public struct SearchHit: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var line: Int
    public var text: String
    public var score: Int
}

public struct LookupHit: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String
}

public struct MemoryUsage: Codable, Equatable, Sendable {
    public var notes: Int
    public var chars: Int
    public var limit: Int
    public var percent: Int
    public var oversized: [String]
    public var archived: Int
}

/// What `condense` hands to the model it delegates to.
public struct CondenseRequest: Equatable, Sendable {
    public var title: String
    public var content: String
    public var target: Int
}

public typealias CondenseDelegate = (CondenseRequest) async throws -> String

public enum MemoryConstants {
    public static let CORE = "Core"
    public static let NOTES = "Notes"
    public static let PROJECTS = "Projects"
    public static let ARCHIVE = "Archive"
    public static let LIMITS = MemoryLimits.default
    public static let TOOLS = MEMORY_TOOLS
}

/// The tool schemas given to the model (`MEMORY_TOOLS` in memory.cjs).
public let MEMORY_TOOLS: JSONValue = [
    [
        "type": "function",
        "function": [
            "name": "remember",
            "description": "Save one lasting fact or decision to memory for future conversations. Only things you have verified or the user has told you.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short topic, e.g. \"Deploy steps\""],
                    "text": ["type": "string"],
                    "project": ["type": "boolean", "description": "true if it is about this project only; false for something true everywhere"],
                ],
                "required": ["title", "text"],
            ],
        ],
    ],
    [
        "type": "function",
        "function": [
            "name": "recall",
            "description": "Search memory from earlier conversations. Use it when a task refers to past work, preferences or decisions.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A few keywords"],
                    "note": ["type": "string", "description": "Optional: a note name from an earlier recall, to get the whole note"],
                ],
            ],
        ],
    ],
]
