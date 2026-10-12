import Foundation
import BlackTeamKit

// The conversation as the screens read it: typed views over the loose JSON the Backend keeps.

struct FileChange: Equatable, Identifiable {
    var id: String
    var path: String
    var created: Bool
    var added: Int
    var removed: Int
    var diff: String

    init?(_ json: JSONValue?) {
        guard let json, let path = json["path"]?.string else { return nil }
        self.path = path
        id = json["id"]?.string ?? path
        created = json["created"]?.bool ?? false
        added = json["added"]?.int ?? 0
        removed = json["removed"]?.int ?? 0
        diff = json["diff"]?.string ?? ""
    }
}

struct ToolEvent: Equatable, Identifiable {
    var id: Int
    var type: String
    var name: String
    var output: String
    var error: Bool
    var change: FileChange?
}

struct TodoEntry: Equatable, Identifiable {
    var id: Int
    var text: String
    var done: Bool
}

struct PublishedFile: Equatable, Identifiable {
    var id: String
    var name: String
    var size: Int
}

struct ContextInfo: Equatable {
    var measured: Int
    var context: Int
    var maxTokens: Int?
    var omitted: Int
    var estimated: Bool
    /// Tokens set aside for pictures, counted in `measured`.
    var imageReserve: Int?

    init?(_ json: JSONValue?) {
        guard let json, let measured = json["measuredInputTokens"]?.int, let context = json["context"]?.int, context > 0 else { return nil }
        self.measured = measured; self.context = context
        maxTokens = json["maxTokens"]?.int
        omitted = json["omittedMessages"]?.int ?? 0
        estimated = json["method"]?.string == "estimated-bytes"
        imageReserve = json["imageReserveTokens"]?.int
    }
}

struct SpeedInfo: Equatable {
    var read: Int?
    var write: Int
    var used: Int?
    var budget: Int?
    var window: Int?
    var trims: Int?

    init?(_ meter: JobMeter?) {
        guard let meter, let write = meter.write, write > 0 else { return nil }
        read = meter.read; self.write = write; used = meter.used; budget = meter.budget; window = meter.window; trims = meter.trims
    }

    init?(_ json: JSONValue?) {
        guard let json, let write = json["write"]?.int, write > 0 else { return nil }
        read = json["read"]?.int; self.write = write; used = json["used"]?.int; budget = json["budget"]?.int
        window = json["window"]?.int; trims = json["trims"]?.int
    }

    /// How full the working budget is, 0 to 100.
    var share: Int? {
        guard let budget, budget > 0 else { return nil }
        return min(100, Int((Double(used ?? 0) / Double(budget) * 100).rounded()))
    }

    var detail: String {
        var text = read != nil ? "Reading \(read!) tokens/s, writing \(write) tokens/s." : "Writing \(write) tokens/s."
        if let share, let budget {
            text += " \(Fmt.number(used ?? 0)) of a \(Fmt.number(budget))-token working budget (model window \(Fmt.number(window ?? 0)))."
            _ = share
        }
        if let trims, trims > 0 { text += " Trimmed \(trims) time\(trims > 1 ? "s" : "")." }
        return text
    }
}

struct ChatMessage: Equatable, Identifiable {
    var id: String
    var role: String
    var content: String
    var state: String
    var model: String
    var thinking: String
    var recalled: [(title: String, text: String)]
    var context: ContextInfo?
    var events: [ToolEvent]
    var artifacts: [PublishedFile]
    var note: String
    var error: String?
    var finishReason: String
    var meter: SpeedInfo?
    var images: [ImageRef]
    /// A subscription-agent reply: the run it belongs to, whether its files can be rolled back, and whether they were.
    var run: String?
    var rollbackReady = false
    var rolledBack = false
    var rollbackNote = ""
    /// A subscription-agent reply that failed because the tool is signed out: "claude-code" or "codex".
    var needsSignIn: String?
    /// A subscription-agent reply that failed because the tool must be updated first: "claude-code" or "codex".
    var needsUpdate: String?

    var isUser: Bool { role == "user" }
    var changes: [FileChange] { events.compactMap(\.change) }

    /// The latest todo list the model wrote with its todo tool.
    var todo: [TodoEntry] {
        guard let last = events.last(where: { $0.type == "tool_use" && $0.name == "todo" }),
              let items = (try? JSONValue.parse(last.output))?["items"]?.array else { return [] }
        return items.enumerated().compactMap { index, item in
            guard let text = item["text"]?.string else { return nil }
            return TodoEntry(id: index, text: text, done: item["done"]?.bool ?? false)
        }
    }

    var toolActions: Int { events.filter { $0.type == "tool_use" }.count }

    static func == (a: ChatMessage, b: ChatMessage) -> Bool {
        a.id == b.id && a.role == b.role && a.content == b.content && a.state == b.state && a.model == b.model && a.thinking == b.thinking
            && a.context == b.context && a.events == b.events && a.artifacts == b.artifacts && a.note == b.note && a.error == b.error
            && a.finishReason == b.finishReason && a.meter == b.meter && a.images == b.images && a.recalled.map(\.title) == b.recalled.map(\.title)
            && a.run == b.run && a.rollbackReady == b.rollbackReady && a.rolledBack == b.rolledBack && a.rollbackNote == b.rollbackNote
            && a.needsSignIn == b.needsSignIn && a.needsUpdate == b.needsUpdate
    }

    init(_ json: JSONValue, index: Int) {
        id = json["id"]?.string ?? "message-\(index)"
        role = json["role"]?.string ?? "assistant"
        content = json["content"]?.string ?? ""
        state = json["state"]?.string ?? ""
        model = json["model"]?.string ?? ""
        thinking = json["thinking"]?.string ?? ""
        recalled = (json["recalled"]?.array ?? []).compactMap { item in
            guard let title = item["title"]?.string else { return nil }
            return (title, item["text"]?.string ?? "")
        }
        context = ContextInfo(json["context"])
        events = (json["events"]?.array ?? []).enumerated().map { offset, event in
            ToolEvent(id: offset, type: event["type"]?.string ?? "", name: event["name"]?.string ?? "", output: event["output"]?.string ?? "",
                      error: event["error"]?.bool ?? false, change: FileChange(event["change"]))
        }
        artifacts = (json["artifacts"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.string else { return nil }
            return PublishedFile(id: id, name: item["name"]?.string ?? id, size: item["size"]?.int ?? 0)
        }
        note = json["note"]?.string ?? ""
        error = json["error"]?.string
        finishReason = json["finishReason"]?.string ?? ""
        meter = SpeedInfo(json["meter"])
        images = (json["images"]?.array ?? []).compactMap { ImageRef($0) }
        run = json["run"]?.string
        rollbackReady = json["rollback"]?.bool == true
        rolledBack = json["rolledBack"]?.bool == true
        rollbackNote = json["rollbackNote"]?.string ?? ""
        needsSignIn = json["needsSignIn"]?.string
        needsUpdate = json["needsUpdate"]?.string
    }

    static func messages(of thread: JSONValue?) -> [ChatMessage] {
        (thread?["messages"]?.array ?? []).enumerated().map { ChatMessage($1, index: $0) }
    }
}

enum ChatKind: String {
    case chat, agent
    var label: String { self == .chat ? "Chat" : "Code" }
}
