import Foundation

/// What the engine keeps for one conversation, in `engine/<thread id>.json`: the messages sent to
/// the model (only ever appended to between trims), the work log and the todo list.
public struct EngineMemory: Equatable, Sendable {
    public var messages: [JSONValue]
    public var requests: [String]
    public var log: [String]
    public var todo: [TodoItem]
    public var readSpeed: Double
    public var writeSpeed: Double
    public var promptTokens: Int
    public var trims: Int
    /// How many messages the server's last prompt count covered.
    public var counted: Int?
    /// The user's Core memory, read once per conversation so the cached prompt stays valid.
    public var core: String?
    /// Where the run is (phase, steps, tool, tokens): what a restart needs to show and continue it.
    public var run = RunRecord()
    /// What the model was told about the skills it has, read once per conversation like `core`; nil until read, empty when there are none.
    public var skills: String?
    /// A note, written when earlier steps were trimmed, of what they did. Kept with the conversation.
    public var summary: String?

    public init(messages: [JSONValue] = [], requests: [String] = [], log: [String] = [], todo: [TodoItem] = [],
                readSpeed: Double = 40, writeSpeed: Double = 12, promptTokens: Int = 0, trims: Int = 0, counted: Int? = nil, core: String? = nil,
                run: RunRecord = RunRecord(), skills: String? = nil, summary: String? = nil) {
        self.messages = messages; self.requests = requests; self.log = log; self.todo = todo
        self.readSpeed = readSpeed; self.writeSpeed = writeSpeed; self.promptTokens = promptTokens; self.trims = trims
        self.counted = counted; self.core = core; self.run = run; self.skills = skills; self.summary = summary
    }

    /// Reads a saved record, tolerating missing fields.
    init(json: JSONValue, readSpeed: Double, writeSpeed: Double) {
        self.init(
            messages: json["messages"]?.array ?? [],
            requests: (json["requests"]?.array ?? []).compactMap(\.string),
            log: (json["log"]?.array ?? []).compactMap(\.string),
            todo: (json["todo"]?.array ?? []).compactMap { item in
                guard let text = item["text"]?.string else { return nil }
                return TodoItem(text: text, done: item["done"]?.bool == true)
            },
            readSpeed: json["readSpeed"]?.double ?? readSpeed, writeSpeed: json["writeSpeed"]?.double ?? writeSpeed,
            promptTokens: json["promptTokens"]?.int ?? 0, trims: json["trims"]?.int ?? 0,
            counted: json["counted"]?.int, core: json["core"]?.string, run: RunRecord(json: json["run"]), skills: json["skills"]?.string, summary: json["summary"]?.string)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "messages": .array(messages), "requests": .array(requests.map { .string($0) }), "log": .array(log.map { .string($0) }),
            "todo": .array(todo.map { ["text": .string($0.text), "done": .bool($0.done)] }),
            "readSpeed": .number(readSpeed), "writeSpeed": .number(writeSpeed),
            "promptTokens": .number(Double(promptTokens)), "trims": .number(Double(trims)),
        ]
        if let counted { object["counted"] = .number(Double(counted)) }
        if let core { object["core"] = .string(core) }
        if let skills { object["skills"] = .string(skills) }
        if let summary { object["summary"] = .string(summary) }
        object["run"] = run.json
        return .object(object)
    }
}

public struct Budgets: Equatable, Sendable {
    public var working: Int
    public var resultChars: Int
}

extension Engine {
    public static let MAX_STEPS = 48, RUN_SECONDS = 1800, APPROVAL_SECONDS = 300
    /// The note on a Code turn that stopped at a limit with the task not finished (the room keeps such a task open).
    public static let UNFINISHED_NOTE = "This turn stopped before the task was finished."
    /// What a scheduled run ends with when its question was not answered in time (Service/Scheduler.swift reads it back).
    public static let notApprovedMessage = "Not approved: nobody answered the question in time, so the task was stopped."
    public static let MIN_CONTEXT = 8192
    static let OUTPUT_TOKENS: [String: Int] = ["fast": 2048, "balanced": 4096, "deep": 6144, "extended": 8192]
    static let CHARS_PER_TOKEN = 3.5

    /// The system prompt. The sentences are the Linux app's, word for word.
    public static func SYSTEM(_ workspace: String, cloud: Bool = false) -> String {
        if cloud {
            return """
            You are Black Team Code, a coding agent. Your tools run on the user's own computer; your workspace is \(workspace). What you read and write is processed by a cloud service.

            Work with the tools. Never state a result you have not seen in a tool result.
            Give file paths relative to the workspace, such as notes.txt or src/app.js.
            Search before you read, and read only the lines you need.
            Keep your todo list current. As a task grows, older tool output is trimmed from your memory; your todo list and a log of what you did are what remain, and you can read any file again.
            After a change, run its check and read the result. When the task is done, reply with a short summary of what changed and what you verified.
            """
        }
        return """
        You are Black Team Code, a coding agent running on the user's own computer. Your workspace is \(workspace).

        Work with the tools. Never state a result you have not seen in a tool result.
        Give file paths relative to the workspace, such as notes.txt or src/app.js.
        Reading is slow on this machine: search before you read, and read only the lines you need.
        Keep your todo list current. As a task grows, older tool output is trimmed from your memory; your todo list and a log of what you did are what remain, and you can read any file again.
        After a change, run its check and read the result. When the task is done, reply with a short summary of what changed and what you verified.
        """
    }

    /// Budgets derived from how fast this model reads. Twelve minutes is the longest cold re-read
    /// worth risking; one minute is the most a single tool result should cost. The working budget
    /// never passes 60% of the model's window, whatever the speed.
    ///
    /// A cloud model is not rationed by reading speed (that exists because local models read slowly): the working budget is the
    /// 60% ceiling of its configured window, and one tool result may be larger, in proportion to that window.
    public static func budgets(_ readSpeed: Double, _ contextWindow: Int, cloud: Bool = false) -> Budgets {
        if cloud {
            let working = EText.round(Double(contextWindow) * 0.6)
            return Budgets(working: working, resultChars: EText.round(min(400_000, max(12_000, Double(working) * CHARS_PER_TOKEN * 0.25))))
        }
        let working = EText.round(min(Double(contextWindow) * 0.6, max(12000, readSpeed * 720)))
        // A single tool result is also kept to under a third of the working budget.
        let result = EText.round(min(max(6000, min(readSpeed * 60 * CHARS_PER_TOKEN, 48000)), Double(working) * CHARS_PER_TOKEN * 0.3))
        return Budgets(working: working, resultChars: result)
    }

    public static func estimate(_ messages: [JSONValue]) -> Int {
        var sum = 0
        for message in messages {
            sum += 12 + EText.length(message["content"]?.string ?? "")
            if let calls = message["tool_calls"], calls != .null { sum += EText.length(calls.text()) }
        }
        return Int((Double(sum) / CHARS_PER_TOKEN).rounded(.up))
    }

    /// Replace the oldest steps with the record kept so far. Cuts only at a step boundary, so a tool
    /// call is never separated from its result.
    /// Where `trim` would cut: the messages before this index are the ones dropped. Below 1 means nothing can be trimmed.
    static func cutPoint(_ messages: [JSONValue], _ budget: Int) -> Int {
        let keepTokens = budget / 4
        // A step starts at a user or assistant message; its tool results follow it.
        var cut = -1, kept = 0
        var index = messages.count - 1
        while index >= 1 {
            kept += estimate([messages[index]])
            if messages[index]["role"]?.string != "tool" {
                if kept > keepTokens && cut != -1 { break }
                cut = index // The newest step is always kept, even when it alone is over the allowance.
            }
            index -= 1
        }
        return cut
    }

    @discardableResult
    public static func trim(_ memory: inout EngineMemory, _ budget: Int) -> Bool {
        let messages = memory.messages
        let cut = cutPoint(messages, budget)
        if cut < 1 { return false }
        let dropped = messages[0..<cut]
        // The record itself is sized to the budget, so a small context window is not refilled by its own summary.
        let lines = max(10, min(80, budget / 150)), each = max(300, min(2000, budget / 8))
        let earlier = memory.requests.count > 8 ? ["- (\(memory.requests.count - 8) earlier requests not listed)"] : []
        let requests = (earlier + memory.requests.suffix(8).map { "- \(EText.length($0) > each ? EText.prefix($0, each) + "\u{2026}" : $0)" }).joined(separator: "\n")
        let notes = dropped.filter { $0["role"]?.string == "assistant" && !EText.trim($0["content"]?.string ?? "").isEmpty }
            .suffix(3).map { "- \(EText.prefix(EText.trim($0["content"]?.string ?? ""), 400))" }.joined(separator: "\n")
        let log = memory.log.count > lines ? ["(\(memory.log.count - lines) earlier steps not listed)"] + memory.log.suffix(lines) : memory.log
        let written = (memory.summary ?? "").isEmpty ? "" : "A summary of the trimmed steps:\n\(memory.summary!)\n\n"
        let record = """
        [Earlier steps were trimmed to keep you fast. This record is what you keep. Files can be read again.]

        \(written)The user's requests in this conversation:
        \(requests.isEmpty ? "- (none recorded)" : requests)

        Your todo list:
        \(Tools.renderTodo(memory.todo))

        What you have done so far, oldest first:
        \(log.isEmpty ? "(nothing yet)" : log.joined(separator: "\n"))\(notes.isEmpty ? "" : "\n\nYour recent notes:\n\(notes)")
        """
        let rest = Array(messages[cut...])
        if let first = rest.first, first["role"]?.string == "user" {
            memory.messages = [["role": "user", "content": .string("\(record)\n\n[Latest request]\n\(first["content"]?.string ?? "undefined")")]] + rest.dropFirst()
        } else {
            memory.messages = [["role": "user", "content": .string(record)]] + rest
        }
        memory.trims += 1
        return true
    }
}
