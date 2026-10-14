import Foundation

// A driven run: a PAID member (a cloud model, Claude Code or Codex) works on the goal and, while it works, hands real pieces of it to the
// room's other members through two tools, `team` and `delegate`, and waits for each result. The paid driver spends its tokens on planning,
// decisions and review; the local members do the bulk. This file holds the values and the text. The running of it is App/BackendDriver.swift.

public enum DriveLimits {
    /// Delegations one run may make. They also count toward `TeamLimits.runs` (member runs).
    public static let delegations = 12
    /// Most delegations kept on the run for the screens.
    public static let kept = 40
    public static let files = 20
    public static let task = 4000
    /// The most of a member's result handed back to the driver.
    public static let result = 6000
    /// Paid tokens (read plus written, by every paid member) after which the run is stopped. Checked on every tool call and every second;
    /// a subscription agent reports its usage when it finishes, so for it the cap is met only at the end.
    public static let paidTokens = 400_000
}

public enum DelegationStatus: String, Codable, Sendable { case queued, running, done, failed, stopped }

/// One piece of work the driver handed to a member: who got what, how it went, and what it cost.
public struct Delegation: Codable, Equatable, Sendable {
    public var id: String
    public var memberId: String
    public var memberName: String
    /// The task on the room's board.
    public var taskId: String
    public var title: String
    /// Whether the driver allowed the member to change files.
    public var write: Bool
    public var status: DelegationStatus
    public var started: String
    public var finished: String?
    public var changed: Int?
    /// The start of the member's result (the board task holds the whole of it).
    public var result: String
    public var error: String
    /// The member runs on a paid service.
    public var paid: Bool
    /// Tokens read and written, when the engine or the tool reported them; nil means not measured.
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var seconds: Int

    enum CodingKeys: String, CodingKey {
        case id, memberId, memberName, taskId, title, write, status, started, finished, changed, result, error, paid, promptTokens, completionTokens, seconds
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(memberId, forKey: .memberId); try c.encode(memberName, forKey: .memberName)
        try c.encode(taskId, forKey: .taskId); try c.encode(title, forKey: .title); try c.encode(write, forKey: .write)
        try c.encode(status, forKey: .status); try c.encode(started, forKey: .started); try c.encode(finished, forKey: .finished)
        try c.encode(changed, forKey: .changed); try c.encode(result, forKey: .result); try c.encode(error, forKey: .error)
        try c.encode(paid, forKey: .paid); try c.encode(promptTokens, forKey: .promptTokens); try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(seconds, forKey: .seconds)
    }
}

/// What one member (or the driver) did in a run, for the ledger.
public struct LedgerLine: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var paid: Bool
    public var prompt: Int?
    public var completion: Int?
    public var seconds: Int
    public var runs: Int

    /// Whether the tokens were reported. A line that was not measured is never filled in with a guess.
    public var measured: Bool { prompt != nil && completion != nil }
    public var tokens: Int { (prompt ?? 0) + (completion ?? 0) }

    enum CodingKeys: String, CodingKey { case name, role, paid, prompt, completion, seconds, runs, measured, tokens }
    public init(name: String, role: String, paid: Bool, prompt: Int?, completion: Int?, seconds: Int, runs: Int) {
        self.name = name; self.role = role; self.paid = paid; self.prompt = prompt; self.completion = completion; self.seconds = seconds; self.runs = runs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        paid = try c.decode(Bool.self, forKey: .paid); prompt = try c.decodeIfPresent(Int.self, forKey: .prompt)
        completion = try c.decodeIfPresent(Int.self, forKey: .completion); seconds = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(role, forKey: .role); try c.encode(paid, forKey: .paid)
        try c.encode(prompt, forKey: .prompt); try c.encode(completion, forKey: .completion); try c.encode(seconds, forKey: .seconds)
        try c.encode(runs, forKey: .runs); try c.encode(measured, forKey: .measured); try c.encode(tokens, forKey: .tokens)
    }
}

/// Per run and per member: tokens read and written and time, grouped paid and local, with one plain sentence.
public struct RunLedger: Codable, Equatable, Sendable {
    public var lines: [LedgerLine]
    public var localTokens: Int
    public var paidTokens: Int
    /// Lines whose tokens were not reported by the engine or the tool.
    public var notMeasured: [String]
    public var summary: String

    public init(lines: [LedgerLine]) {
        self.lines = lines
        localTokens = lines.filter { !$0.paid }.reduce(0) { $0 + $1.tokens }
        paidTokens = lines.filter { $0.paid }.reduce(0) { $0 + $1.tokens }
        notMeasured = lines.filter { !$0.measured }.map(\.name)
        var text = "Local agents did \(EText.grouped(localTokens)) tokens of work; paid agents used \(EText.grouped(paidTokens))."
        if !notMeasured.isEmpty { text += " Not measured: \(notMeasured.joined(separator: ", ")) (no usage was reported)." }
        summary = text
    }
}

// MARK: Tools

public struct RoomToolReply: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

/// What answers the driver's `team` and `delegate` calls: the Backend, for one run. The Code engine calls it directly (a cloud model
/// driver) and the MCP server calls it through the run's private channel (Claude Code and Codex).
public protocol RoomToolHost: AnyObject, Sendable {
    /// The driver's rules of the room, as the first part of what it is told.
    var brief: String { get }
    func callTool(_ name: String, _ arguments: JSONValue) async -> RoomToolReply
}

public enum RoomTools {
    public static let names = ["team", "delegate"]

    static let teamDescription = "List the other members of this room: who they are, whether they run on this computer, what work they do, whether they have tools and vision, "
        + "and how fast each local one reads and writes. Call it once before you delegate, and size each job to the member."
    static let delegateDescription = "Give one member a real, self-contained job and wait for its result. Say exactly what to produce and when it is done. "
        + "A local member reads files in the project folder itself, so name the files instead of pasting them. It cannot see this conversation."

    /// The two tools as OpenAI-style function schemas, for the Code engine.
    public static var schemas: [JSONValue] {
        [["type": "function", "function": ["name": "team", "description": .string(teamDescription), "parameters": ["type": "object", "properties": [:]]]],
         ["type": "function", "function": ["name": "delegate", "description": .string(delegateDescription), "parameters": inputSchema(for: "delegate")]]]
    }

    static func inputSchema(for tool: String) -> JSONValue {
        guard tool == "delegate" else { return ["type": "object", "properties": [:]] }
        return ["type": "object", "required": ["member", "task"], "properties": [
            "member": ["type": "string", "description": "The member's name, exactly as team lists it."],
            "task": ["type": "string", "description": "A self-contained job: what to do, with which files, and what counts as done."],
            "files": ["type": "array", "items": ["type": "string"], "description": "Paths relative to the project folder the member should look at."],
            "may_change_files": ["type": "boolean", "description": "True only if the member should edit or create files. Default false (read-only)."],
        ]]
    }

    /// The same tools as an MCP server lists them.
    public static var mcpTools: [JSONValue] {
        [["name": "team", "description": .string(teamDescription), "inputSchema": inputSchema(for: "team")],
         ["name": "delegate", "description": .string(delegateDescription), "inputSchema": inputSchema(for: "delegate")]]
    }

    /// The driver's brief. Short on purpose: a local model's reading speed and a paid model's context both matter.
    static func brief(goal: String, driver: String) -> String {
        """
        You are \(driver), the driver of a small team in Black Team. The other members are local models and agents: they cost nothing and keep data on this computer. Your tokens are paid, so spend them on planning, hard decisions and review.
        Rules of this room:
        - Call team once to see the members and their speeds. Hand them real jobs with delegate: reading and searching files, summarising, first drafts, tests, repetitive edits.
        - Make every job stand alone: exact files, what to produce, and when it is done. Size it to the member; a local model should get a job of a few minutes.
        - Check each result before you build on it. Do not redo work a member has done; if it is wrong, delegate a sharper job.
        - Keep planning, design decisions and the final answer for yourself. When the goal is done, reply with a short report.

        Goal:
        \(goal)
        """
    }
}

// MARK: Reading what is saved

enum DriveStore {
    static func delegation(_ v: JSONValue) -> Delegation? {
        guard let id = RoomStore.clean(v["id"], max: 36), History.validID(id), let member = RoomStore.clean(v["memberId"], max: 36),
              let name = RoomStore.clean(v["memberName"], max: RoomLimits.name, allowEmpty: true),
              let task = RoomStore.clean(v["taskId"], max: 36), let status = v["status"]?.string.flatMap({ DelegationStatus(rawValue: $0) }) else { return nil }
        func count(_ key: String) -> Int? { v[key]?.double.flatMap { $0 >= 0 && $0 < 1e12 && $0.rounded() == $0 ? Int($0) : nil } }
        return Delegation(id: id, memberId: member, memberName: name, taskId: task, title: RoomStore.clean(v["title"], max: RoomLimits.title, allowEmpty: true) ?? "",
                          write: v["write"]?.bool == true, status: status, started: RoomStore.clean(v["started"], max: 40, allowEmpty: true) ?? "",
                          finished: RoomStore.clean(v["finished"], max: 40), changed: count("changed"),
                          result: RoomStore.clean(v["result"], max: 1200, multiline: true, allowEmpty: true) ?? "",
                          error: RoomStore.clean(v["error"], max: RoomLimits.note, multiline: true, allowEmpty: true) ?? "", paid: v["paid"]?.bool == true,
                          promptTokens: count("promptTokens"), completionTokens: count("completionTokens"), seconds: count("seconds") ?? 0)
    }

    static func ledger(_ v: JSONValue) -> RunLedger? {
        guard let list = v["lines"]?.array else { return nil }
        var lines: [LedgerLine] = []
        for entry in list.prefix(RoomLimits.members + 1) {
            guard let name = RoomStore.clean(entry["name"], max: RoomLimits.name, allowEmpty: true), let paid = entry["paid"]?.bool else { continue }
            func count(_ key: String) -> Int? { entry[key]?.double.flatMap { $0 >= 0 && $0 < 1e12 && $0.rounded() == $0 ? Int($0) : nil } }
            lines.append(LedgerLine(name: name, role: RoomStore.clean(entry["role"], max: RoomLimits.role, allowEmpty: true) ?? "", paid: paid,
                                    prompt: count("prompt"), completion: count("completion"), seconds: count("seconds") ?? 0, runs: count("runs") ?? 0))
        }
        return RunLedger(lines: lines)
    }
}

// MARK: Tokens, from what the engines and tools report

extension ThreadRef {
    /// Adds tokens a LOCAL model read and wrote to the conversation's running total (`localUsage`), when the server reported them.
    func addLocalUsage(prompt: Int, completion: Int) {
        guard prompt > 0 || completion > 0 else { return }
        var thread = value.object ?? [:]
        let before = CloudUsage(json: thread["localUsage"])
        thread["localUsage"] = CloudUsage(prompt: before.prompt + prompt, completion: before.completion + completion).json
        value = .object(thread)
    }
}

/// Usage figures a subscription agent prints at the end of a turn (Claude Code's `result` line, Codex's `turn.completed`).
enum AgentUsage {
    static func parse(_ line: String, service: AgentService) -> CloudUsage? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{"), text.contains("usage"), let json = try? JSONValue.parse(text), let usage = json["usage"], usage.object != nil else { return nil }
        switch (service, json["type"]?.string) {
        case (.claudeCode, "result"):
            let input = usage["input_tokens"]?.int ?? 0, made = usage["cache_creation_input_tokens"]?.int ?? 0, read = usage["cache_read_input_tokens"]?.int ?? 0
            return CloudUsage(prompt: input + made + read, completion: usage["output_tokens"]?.int ?? 0, cached: read)
        case (.codex, "turn.completed"):
            return CloudUsage(prompt: usage["input_tokens"]?.int ?? 0, completion: usage["output_tokens"]?.int ?? 0, cached: usage["cached_input_tokens"]?.int ?? 0)
        default: return nil
        }
    }
}
