import Foundation

// What a Code run is doing, shown to the person and saved with the conversation: its phase, the steps taken, the tool in use,
// the tokens and money spent, and the switches that pause it. Nothing here calls a model.

/// Where a Code run is. `planning` lasts until the model's first action; `waiting` is an approval the person must answer.
public enum RunPhase: String, CaseIterable, Sendable {
    case idle, planning, working, checking, waiting, paused, done, stopped, failed

    /// A run left in one of these when Black Team closed was cut off, and can be continued.
    public var isUnfinished: Bool { [.planning, .working, .checking, .waiting, .paused].contains(self) }

    /// The words shown beside the run.
    public var words: String {
        switch self {
        case .idle: return "Idle"
        case .planning: return "Planning"
        case .working: return "Working"
        case .checking: return "Checking the work"
        case .waiting: return "Waiting for your approval"
        case .paused: return "Paused"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

/// A person's price for one cloud model, per million tokens read and written. Black Team knows no prices: the person sets them.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public init(input: Double, output: Double) { self.input = input; self.output = output }

    public func cost(prompt: Int, completion: Int) -> Double { Double(prompt) / 1_000_000 * input + Double(completion) / 1_000_000 * output }

    var json: JSONValue { ["input": .number(input), "output": .number(output)] }
    init?(json: JSONValue?) {
        guard let input = json?["input"]?.double, let output = json?["output"]?.double, input >= 0, output >= 0, input.isFinite, output.isFinite else { return nil }
        self.input = input; self.output = output
    }
}

/// The saved state of one conversation's Code run (`run` in the engine's file, and on the reply the window reads).
public struct RunRecord: Equatable, Sendable {
    public var phase: RunPhase = .idle
    public var todo: [TodoItem] = []
    /// Model requests made in this conversation.
    public var steps = 0
    /// The last few things done, newest last.
    public var recent: [String] = []
    /// The tool in use now (or last), and how it is going: running, done, failed or declined.
    public var tool: String?
    public var toolStatus: String?
    public var promptTokens = 0
    public var completionTokens = 0
    /// True when a service did not report its tokens and Black Team counted them itself.
    public var estimated = false
    /// Review rounds used by the turn in progress.
    public var checks = 0
    /// Why the run stopped, in plain words.
    public var reason: String?
    public var updated = ""

    public init() {}

    public var tokens: Int { promptTokens + completionTokens }

    public mutating func addRecent(_ line: String) {
        recent.append(EText.prefix(line, 120))
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
    }

    /// The money spent at these prices.
    public func cost(_ price: ModelPrice?) -> Double? { price.map { $0.cost(prompt: promptTokens, completion: completionTokens) } }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "phase": .string(phase.rawValue), "steps": .number(Double(steps)),
            "todo": .array(todo.map { ["text": .string($0.text), "done": .bool($0.done)] }),
            "recent": .array(recent.map { .string($0) }),
            "promptTokens": .number(Double(promptTokens)), "completionTokens": .number(Double(completionTokens)),
            "tokens": .number(Double(tokens)), "checks": .number(Double(checks)), "updated": .string(updated),
        ]
        if let tool { object["tool"] = .string(tool) }
        if let toolStatus { object["toolStatus"] = .string(toolStatus) }
        if let reason { object["reason"] = .string(reason) }
        if estimated { object["estimated"] = true }
        return .object(object)
    }

    public init(json: JSONValue?) {
        phase = json?["phase"]?.string.flatMap { RunPhase(rawValue: $0) } ?? .idle
        steps = json?["steps"]?.int ?? 0
        todo = (json?["todo"]?.array ?? []).compactMap { item in item["text"]?.string.map { TodoItem(text: $0, done: item["done"]?.bool == true) } }
        recent = (json?["recent"]?.array ?? []).compactMap(\.string)
        tool = json?["tool"]?.string; toolStatus = json?["toolStatus"]?.string
        promptTokens = json?["promptTokens"]?.int ?? 0; completionTokens = json?["completionTokens"]?.int ?? 0
        estimated = json?["estimated"]?.bool == true
        checks = json?["checks"]?.int ?? 0
        reason = json?["reason"]?.string; updated = json?["updated"]?.string ?? ""
    }

    /// One plain line for the window and the terminal: "Working, step 7, using run. 12,300 tokens."
    public func line(price: ModelPrice? = nil) -> String {
        var text = phase.words
        if steps > 0, phase.isUnfinished { text += ", step \(steps)" }
        if let tool, toolStatus == "running" { text += ", using \(tool)" }
        if tokens > 0 { text += ". \(EText.grouped(tokens)) tokens\(estimated ? " (counted by Black Team)" : "")" }
        if let spent = cost(price) { text += ", \(RunRecord.money(spent)) spent" }
        return text
    }

    /// The running cost as shown: "$0.0123".
    public static func money(_ value: Double) -> String {
        value >= 1 ? String(format: "$%.2f", value) : value >= 0.01 ? String(format: "$%.3f", value) : String(format: "$%.4f", value)
    }
}

/// Pause and resume, asked from any thread and obeyed by the engine between steps, never in the middle of a tool.
public final class PauseControl: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    public init() {}
    public var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return asked }
    func set(_ value: Bool) { lock.lock(); asked = value; lock.unlock() }
}

/// Keeps the run record up to date and tells the interface: the live job, the saved reply and, at steps, the engine's own file.
final class RunTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var record = RunRecord()
    private let job: JobState
    private let now: @Sendable () -> Date
    private let publish: @Sendable (RunRecord) -> Void
    /// The phase to go back to after an approval.
    private var before: RunPhase = .working

    init(job: JobState, now: @escaping @Sendable () -> Date, publish: @escaping @Sendable (RunRecord) -> Void) {
        self.job = job; self.now = now; self.publish = publish
    }

    var current: RunRecord { lock.lock(); defer { lock.unlock() }; return record }

    /// Starts from a saved record (a conversation's earlier turns); the counters carry on, the phase starts again.
    func load(_ saved: RunRecord) { lock.lock(); record = saved; lock.unlock() }

    func update(_ change: (inout RunRecord) -> Void) {
        lock.lock()
        change(&record)
        record.updated = EText.iso(now())
        let copy = record
        lock.unlock()
        job.phase = copy.phase.rawValue
        publish(copy)
    }

    func phase(_ next: RunPhase, reason: String? = nil) {
        update { $0.phase = next; if let reason { $0.reason = reason } else if next.isUnfinished { $0.reason = nil } }
    }

    /// An approval: the phase becomes `waiting`, and goes back to what it was when the answer comes.
    func waiting() {
        lock.lock(); before = record.phase == .waiting ? before : record.phase; lock.unlock()
        phase(.waiting)
    }
    func answered() { lock.lock(); let back = before; lock.unlock(); phase(back) }
}

// MARK: Ceilings and loops

/// The limits on a conversation's spending, as the person set them. Zero means no limit.
struct RunCeilings: Equatable, Sendable {
    var tokens: Int
    var money: Double
    var price: ModelPrice?
    var model: String

    /// The plain sentence that ends a run, or nil while it may go on.
    func reached(_ run: RunRecord) -> String? {
        if tokens > 0, run.tokens >= tokens {
            return "I stopped because this conversation reached its limit of \(EText.grouped(tokens)) tokens (it has used \(EText.grouped(run.tokens))). Raise the limit in this conversation's settings, then send \"continue\"."
        }
        if money > 0 {
            guard let spent = run.cost(price) else {
                return "I stopped before the next step because this conversation has a spending limit of \(RunRecord.money(money)) but no price is set for \(model). Set what it charges per million tokens read and written, then send \"continue\"."
            }
            if spent >= money {
                return "I stopped because this conversation reached its spending limit of \(RunRecord.money(money)) (it has spent \(RunRecord.money(spent)) at the prices you set). Raise the limit in this conversation's settings, then send \"continue\"."
            }
        }
        return nil
    }
}

/// Spots a model that makes the same call and gets the same answer again and again.
struct LoopGuard {
    static let limit = 3
    private var last = ""
    private(set) var count = 0

    /// Notes one finished call; true when it is the `limit`th identical one in a row.
    mutating func note(name: String, arguments: String, output: String) -> Bool {
        let key = "\(name) \(arguments) \(output)"
        if key == last { count += 1 } else { last = key; count = 1 }
        return count >= LoopGuard.limit
    }

    mutating func reset() { last = ""; count = 0 }
}
