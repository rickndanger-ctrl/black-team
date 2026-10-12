import Foundation
import CryptoKit

// A room: the local and cloud agents working on ONE project as a team, with the person as the lead.
// A task board per project. Nothing moves one member's output to another except the lead's hand-off (BackendRoom.swift).

public enum RoomLimits {
    public static let members = 8
    public static let tasks = 200
    public static let notes = 100
    public static let name = 60
    public static let role = 40
    public static let title = 120
    public static let detail = 4000
    public static let result = 4000
    public static let note = 1000
}

public enum RoomStatus: String, Codable, Sendable { case todo, doing, review, done }

public struct RoomMember: Codable, Equatable, Sendable {
    public var id: String
    /// The display name, e.g. "Ornith", "Nemotron (free)", "Claude Code".
    public var name: String
    /// A short free-text label the lead gives, e.g. "reviewer".
    public var role: String
    /// A saved model's key (local or cloud). Exactly one of `modelKey` and `agent` is set.
    public var modelKey: String?
    /// "claude-code" or "codex".
    public var agent: String?
    /// Agents only: ask, edit or auto.
    public var permission: String?
    /// Models only: "chat" or "code".
    public var work: String?

    public var service: AgentService? { AgentService.forEngine(agent) }
}

public struct RoomTask: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: RoomStatus
    public var assignee: String?
    /// The conversation that worked on this task.
    public var threadId: String?
    public var result: String
    /// File changes the run reported, when known.
    public var changed: Int?
    /// The task this one was handed on from.
    public var from: String?
    /// The lead's note when sending back, or the error text of a run that did not finish (then `failed` is true).
    public var note: String
    public var failed: Bool
    /// For a handed-on task: "Result from <member>:" and the result the lead chose to pass on. Part of the message the receiver gets.
    public var inherited: String
    public var created: String
    public var updated: String
}

public struct RoomNote: Codable, Equatable, Sendable {
    public var at: String
    public var text: String
}

/// What is saved for one project.
struct RoomData: Equatable {
    var members: [RoomMember] = []
    var tasks: [RoomTask] = []
    var notes: [RoomNote] = []
    /// The latest team run (BackendTeam.swift); only the latest is kept.
    var team: TeamRun?
}

/// A member as the screens read it: its settings, where it runs, and whether it can be used right now.
public struct RoomMemberView: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var modelKey: String?
    public var agent: String?
    public var permission: String?
    public var work: String?
    /// "local" or "cloud".
    public var kind: String
    /// For cloud members, the service the work goes to; empty for local ones.
    public var provider: String
    public var usable: Bool
    /// Why it cannot be used now (model missing, tool not installed, project is local only); empty when usable.
    public var reason: String
}

public struct RoomState: Codable, Equatable, Sendable {
    public var projectId: String
    public var projectName: String
    public var cloudAllowed: Bool
    /// A job is running somewhere in Black Team (only one runs at a time).
    public var busy: Bool
    public var members: [RoomMemberView]
    public var tasks: [RoomTask]
    public var notes: [RoomNote]
    /// The latest team run, or nil when none was ever started.
    public var team: TeamRun?
}

/// Exactly what the receiving member would be given, and where it would go.
public struct HandOffPreview: Codable, Equatable, Sendable {
    public var taskId: String
    public var receiverId: String
    public var receiverName: String
    public var title: String
    public var detail: String
    public var includesResult: Bool
    /// The whole message, character for character.
    public var text: String
    public var leavesThisMac: Bool
    public var provider: String
    /// SHA-256 of `text` and the receiver id. `roomHandOff` refuses unless it matches.
    public var digest: String
}

// MARK: Storage

enum RoomStore {
    static func path(dataFolder: String, projectId: String) -> String { dataFolder + "/rooms/" + projectId + ".json" }

    static func clipUnits(_ text: String, _ limit: Int) -> String { EText.prefix(text, limit) }

    static func clean(_ value: JSONValue?, max: Int, multiline: Bool = false, allowEmpty: Bool = false) -> String? {
        guard let raw = value?.string else { return nil }
        let bad = raw.unicodeScalars.contains { s in
            (s.value < 0x20 && !(multiline && (s.value == 0x0A || s.value == 0x09 || s.value == 0x0D))) || s.value == 0x7F
        }
        if bad { return nil }
        let text = multiline ? raw : EText.trim(raw)
        if !allowEmpty, EText.trim(text).isEmpty { return nil }
        return EText.length(text) > max ? EText.prefix(text, max) : text
    }

    static func member(_ v: JSONValue) -> RoomMember? {
        guard let id = clean(v["id"], max: 36), History.validID(id),
              let name = clean(v["name"], max: RoomLimits.name) else { return nil }
        let role = clean(v["role"], max: RoomLimits.role, allowEmpty: true) ?? ""
        let key = clean(v["modelKey"], max: 64)
        let agent = v["agent"]?.string
        if (key == nil) == (agent == nil) { return nil }
        if let agent {
            guard let service = AgentService.forEngine(agent) else { return nil }
            let permission = v["permission"]?.string.flatMap { AgentPermission(rawValue: $0) } ?? .edit
            return RoomMember(id: id, name: name, role: role, modelKey: nil, agent: service.engine, permission: permission.rawValue, work: nil)
        }
        let work = v["work"]?.string == "chat" ? "chat" : "code"
        return RoomMember(id: id, name: name, role: role, modelKey: key, agent: nil, permission: nil, work: work)
    }

    static func task(_ v: JSONValue, members: Set<String>) -> RoomTask? {
        guard let id = clean(v["id"], max: 36), History.validID(id),
              let title = clean(v["title"], max: RoomLimits.title),
              let status = v["status"]?.string.flatMap({ RoomStatus(rawValue: $0) }) else { return nil }
        let assignee = clean(v["assignee"], max: 36).flatMap { members.contains($0) ? $0 : nil }
        let thread = clean(v["threadId"], max: 36).flatMap { History.validID($0) ? $0 : nil }
        let from = clean(v["from"], max: 36).flatMap { History.validID($0) ? $0 : nil }
        let changed = v["changed"]?.double.flatMap { $0 >= 0 && $0 < 1_000_000 && $0.rounded() == $0 ? Int($0) : nil }
        return RoomTask(
            id: id, title: title, detail: clean(v["detail"], max: RoomLimits.detail, multiline: true, allowEmpty: true) ?? "",
            status: status, assignee: assignee, threadId: thread,
            result: clean(v["result"], max: RoomLimits.result, multiline: true, allowEmpty: true) ?? "", changed: changed, from: from,
            note: clean(v["note"], max: RoomLimits.note, multiline: true, allowEmpty: true) ?? "", failed: v["failed"]?.bool == true,
            inherited: clean(v["inherited"], max: RoomLimits.result + 200, multiline: true, allowEmpty: true) ?? "",
            created: clean(v["created"], max: 40) ?? "", updated: clean(v["updated"], max: 40) ?? "")
    }

    /// A missing or damaged file is an empty room, never a failure. Every field is checked.
    static func load(dataFolder: String, projectId: String) -> RoomData {
        guard History.validID(projectId) else { return RoomData() }
        let file = path(dataFolder: dataFolder, projectId: projectId)
        let info = CoreFS.stat(file)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= 2 * 1024 * 1024, !CoreFS.isSymlink(file),
              let data = FileManager.default.contents(atPath: file), let root = try? JSONValue.parse(data), root.object != nil else { return RoomData() }
        var out = RoomData()
        var seen = Set<String>()
        for entry in root["members"]?.array ?? [] {
            guard let m = member(entry), seen.insert(m.id).inserted else { continue }
            out.members.append(m)
            if out.members.count == RoomLimits.members { break }
        }
        let ids = Set(out.members.map(\.id))
        var taskIds = Set<String>()
        for entry in root["tasks"]?.array ?? [] {
            guard let t = task(entry, members: ids), taskIds.insert(t.id).inserted else { continue }
            out.tasks.append(t)
            if out.tasks.count == RoomLimits.tasks { break }
        }
        for entry in root["notes"]?.array ?? [] {
            guard let at = clean(entry["at"], max: 40), let text = clean(entry["text"], max: 300) else { continue }
            out.notes.append(RoomNote(at: at, text: text))
            if out.notes.count == RoomLimits.notes { break }
        }
        if let team = root["team"], team.object != nil { out.team = TeamStore.run(team) }
        return out
    }

    static func save(_ data: RoomData, dataFolder: String, projectId: String) throws {
        guard History.validID(projectId) else { throw BlackTeamError("Invalid project.") }
        let dir = dataFolder + "/rooms"
        try privateDirectory(dir)
        struct File: Encodable { var version = 1; var members: [RoomMember]; var tasks: [RoomTask]; var notes: [RoomNote]; var team: TeamRun? }
        try writeJSON(path(dataFolder: dataFolder, projectId: projectId),
                      File(members: data.members, tasks: data.tasks, notes: Array(data.notes.prefix(RoomLimits.notes)), team: data.team))
    }
}

/// The text a member is given for a task. One function builds it for the preview and for the run, so they cannot differ.
func roomMessage(title: String, detail: String, inherited: String, sentBack: String?) -> String {
    var parts = [title]
    if !EText.trim(detail).isEmpty { parts.append(detail) }
    if !inherited.isEmpty { parts.append(inherited) }
    if let sentBack, !EText.trim(sentBack).isEmpty { parts.append("The lead sent this back: " + sentBack) }
    return parts.joined(separator: "\n\n")
}

func roomDigest(text: String, receiver: String) -> String {
    SHA256.hash(data: Data(JSONValue.array([.string(text), .string(receiver)]).text().utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: Team run

public enum TeamLimits {
    public static let tasks = 6
    public static let revisions = 1
    public static let runs = 20
    public static let minutes = 60
    public static let log = 200
    public static let logText = 2000
    public static let goal = 2000
    public static let report = 4000
    public static let message = 400
    /// A member's message stays under about this many UTF-16 units; the oldest results are clipped first.
    public static let memberMessage = 12_000
}

public enum TeamPhase: String, Codable, Sendable {
    case planning, working, reviewing, reporting, done, stopped, failed
    public var finished: Bool { self == .done || self == .stopped || self == .failed }
}

public struct TeamLogEntry: Codable, Equatable, Sendable {
    public var at: String
    public var memberId: String?
    public var memberName: String
    /// plan, work, review, report or system.
    public var kind: String
    public var taskId: String?
    public var text: String

    enum CodingKeys: String, CodingKey { case at, memberId, memberName, kind, taskId, text }
    /// A missing member or task is written as null, so the screens always see every key.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at); try c.encode(memberId, forKey: .memberId); try c.encode(memberName, forKey: .memberName)
        try c.encode(kind, forKey: .kind); try c.encode(taskId, forKey: .taskId); try c.encode(text, forKey: .text)
    }
}

/// One team run: the goal Rick gave, how far it got, and what the team said and did on the way.
public struct TeamRun: Codable, Equatable, Sendable {
    public var id: String
    public var goal: String
    public var leadId: String
    public var reviewerId: String?
    public var phase: TeamPhase
    /// The task being worked on or reviewed, or nil.
    public var current: String?
    /// Member runs used so far (the cap is `TeamLimits.runs`).
    public var runs: Int
    public var started: String
    public var updated: String
    public var report: String
    /// Why the run stopped or failed; empty otherwise.
    public var message: String
    /// The newest `TeamLimits.log` entries, oldest first.
    public var log: [TeamLogEntry]

    enum CodingKeys: String, CodingKey { case id, goal, leadId, reviewerId, phase, current, runs, started, updated, report, message, log }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(goal, forKey: .goal); try c.encode(leadId, forKey: .leadId)
        try c.encode(reviewerId, forKey: .reviewerId); try c.encode(phase, forKey: .phase); try c.encode(current, forKey: .current)
        try c.encode(runs, forKey: .runs); try c.encode(started, forKey: .started); try c.encode(updated, forKey: .updated)
        try c.encode(report, forKey: .report); try c.encode(message, forKey: .message); try c.encode(log, forKey: .log)
    }
}

/// A member as the team run will use it.
public struct TeamMemberPreview: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    /// "local" or "cloud".
    public var kind: String
    /// For cloud members, where the work goes; empty for local ones.
    public var provider: String
    public var usable: Bool
    public var reason: String
    public var lead: Bool
    public var reviewer: Bool
}

/// What a team run would share and where it would go. `roomTeamRun` refuses unless `digest` matches the room as it is then.
public struct TeamPreview: Codable, Equatable, Sendable {
    public var projectId: String
    public var goal: String
    public var leadId: String
    public var reviewerId: String?
    public var members: [TeamMemberPreview]
    /// Any member is cloud.
    public var leavesThisMac: Bool
    /// Whether the memory vault is used (it is not when any member is cloud).
    public var memoryUsed: Bool
    /// The exact text to show before the run.
    public var agreement: String
    public var digest: String
}

enum TeamStore {
    static let kinds: Set<String> = ["plan", "work", "review", "report", "system"]

    /// Text for the log or the board: control characters become spaces, so what is written can always be read back.
    static func text(_ raw: String, _ limit: Int, multiline: Bool = true) -> String {
        var out = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            if s.value == 0x7F || (s.value < 0x20 && !(multiline && (s.value == 0x0A || s.value == 0x09))) { out.append(" ") } else { out.append(s) }
        }
        return EText.prefix(String(out), limit)
    }

    static func run(_ v: JSONValue) -> TeamRun? {
        guard let id = RoomStore.clean(v["id"], max: 36), History.validID(id),
              let goal = RoomStore.clean(v["goal"], max: TeamLimits.goal, multiline: true),
              let lead = RoomStore.clean(v["leadId"], max: 36), History.validID(lead),
              let phase = v["phase"]?.string.flatMap({ TeamPhase(rawValue: $0) }) else { return nil }
        var log: [TeamLogEntry] = []
        for entry in v["log"]?.array ?? [] {
            guard let at = RoomStore.clean(entry["at"], max: 40), let kind = entry["kind"]?.string, kinds.contains(kind),
                  let body = RoomStore.clean(entry["text"], max: TeamLimits.logText, multiline: true, allowEmpty: true) else { continue }
            log.append(TeamLogEntry(at: at, memberId: RoomStore.clean(entry["memberId"], max: 36), memberName: RoomStore.clean(entry["memberName"], max: RoomLimits.name, allowEmpty: true) ?? "",
                                    kind: kind, taskId: RoomStore.clean(entry["taskId"], max: 36), text: body))
        }
        if log.count > TeamLimits.log { log.removeFirst(log.count - TeamLimits.log) }
        let runs = v["runs"]?.int.flatMap { $0 >= 0 && $0 <= 1000 ? $0 : nil } ?? 0
        return TeamRun(id: id, goal: goal, leadId: lead, reviewerId: RoomStore.clean(v["reviewerId"], max: 36), phase: phase,
                       current: RoomStore.clean(v["current"], max: 36), runs: runs, started: RoomStore.clean(v["started"], max: 40) ?? "",
                       updated: RoomStore.clean(v["updated"], max: 40) ?? "",
                       report: RoomStore.clean(v["report"], max: TeamLimits.report, multiline: true, allowEmpty: true) ?? "",
                       message: RoomStore.clean(v["message"], max: TeamLimits.message, multiline: true, allowEmpty: true) ?? "", log: log)
    }
}
