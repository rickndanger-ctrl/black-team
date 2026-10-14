import Foundation

// The roster: Black Team agents made once and added to any project's room in one step. An entry names a saved model (local or cloud) or a
// subscription agent (Claude Code, Codex), a role, and how it works. It holds no secrets: a model is named by its saved key, and the API
// key stays in the saved-models file where it always was. The roster is one private file in the data folder.

public enum RosterLimits {
    public static let entries = 40
}

public struct RosterEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    /// A saved model's key. Exactly one of `modelKey` and `agent` is set.
    public var modelKey: String?
    /// "claude-code" or "codex".
    public var agent: String?
    /// Agents only: ask, edit or auto.
    public var permission: String?
    /// Models only: "chat" or "code".
    public var work: String?
}

/// A roster entry as the screens read it: whether it is a local or paid agent and whether it can be used now.
public struct RosterEntryView: Codable, Equatable, Sendable {
    public var entry: RosterEntry
    /// "local" or "cloud".
    public var kind: String
    public var provider: String
    public var usable: Bool
    public var reason: String
}

enum RosterStore {
    static func path(_ dataFolder: String) -> String { dataFolder + "/roster.json" }

    static func entry(_ v: JSONValue) -> RosterEntry? {
        guard let id = RoomStore.clean(v["id"], max: 36), History.validID(id), let name = RoomStore.clean(v["name"], max: RoomLimits.name) else { return nil }
        let role = RoomStore.clean(v["role"], max: RoomLimits.role, allowEmpty: true) ?? ""
        let key = RoomStore.clean(v["modelKey"], max: 64)
        let agent = v["agent"]?.string
        if (key == nil) == (agent == nil) { return nil }
        if let agent {
            guard let service = AgentService.forEngine(agent) else { return nil }
            let permission = v["permission"]?.string.flatMap { AgentPermission(rawValue: $0) } ?? .edit
            return RosterEntry(id: id, name: name, role: role, modelKey: nil, agent: service.engine, permission: permission.rawValue, work: nil)
        }
        return RosterEntry(id: id, name: name, role: role, modelKey: key, agent: nil, permission: nil, work: v["work"]?.string == "chat" ? "chat" : "code")
    }

    /// A missing or damaged file is an empty roster, never a failure.
    static func load(_ dataFolder: String) -> [RosterEntry] {
        let file = path(dataFolder)
        let info = CoreFS.stat(file)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= 512 * 1024, !CoreFS.isSymlink(file),
              let data = FileManager.default.contents(atPath: file), let root = try? JSONValue.parse(data) else { return [] }
        var seen = Set<String>(), out: [RosterEntry] = []
        for item in root["agents"]?.array ?? [] {
            guard let entry = entry(item), seen.insert(entry.id).inserted else { continue }
            out.append(entry)
            if out.count == RosterLimits.entries { break }
        }
        return out
    }

    static func save(_ entries: [RosterEntry], _ dataFolder: String) throws {
        struct File: Encodable { var version = 1; var agents: [RosterEntry] }
        try writeJSON(path(dataFolder), File(agents: entries))
    }
}

let rosterLock = NSLock()

extension Backend {
    func rosterView(_ entry: RosterEntry) -> RosterEntryView {
        var view = RosterEntryView(entry: entry, kind: "local", provider: "", usable: true, reason: "")
        if let key = entry.modelKey {
            guard let model = savedModels.find(key) else { view.usable = false; view.reason = "This model is no longer in your list."; return view }
            if model.source == "cloud" { view.kind = "cloud"; view.provider = cloudHost(model.endpoint, rules: cloudRules) }
            do { _ = try validateModelFiles(model, cloud: cloudRules) }
            catch { view.usable = false; view.reason = "\(model.name) cannot be used right now: \(messageOf(error))" }
        } else if let service = AgentService.forEngine(entry.agent) {
            view.kind = "cloud"; view.provider = service.provider
            if !agentInstalled(service) { view.usable = false; view.reason = "\(service.displayName) is not installed on \(Place.this)." }
        }
        return view
    }

    /// The saved agents, newest last.
    public func roster() -> [RosterEntryView] {
        rosterLock.lock(); defer { rosterLock.unlock() }
        return RosterStore.load(dataFolder).map(rosterView)
    }

    private func rosterEdit(_ body: (inout [RosterEntry]) throws -> Void) throws -> [RosterEntryView] {
        rosterLock.lock(); defer { rosterLock.unlock() }
        var entries = RosterStore.load(dataFolder)
        try body(&entries)
        try RosterStore.save(entries, dataFolder)
        changed()
        return entries.map(rosterView)
    }

    private func rosterCheck(name: String, role: String) throws -> (String, String) {
        let name = EText.trim(name), role = EText.trim(role)
        if name.isEmpty || EText.length(name) > RoomLimits.name || RoomStore.clean(.string(name), max: RoomLimits.name) == nil {
            throw BlackTeamError("Give the agent a name of up to \(RoomLimits.name) characters.")
        }
        if EText.length(role) > RoomLimits.role || RoomStore.clean(.string(role), max: RoomLimits.role, allowEmpty: true) == nil {
            throw BlackTeamError("A role is up to \(RoomLimits.role) characters.")
        }
        return (name, role)
    }

    /// Makes a Black Team agent: a saved model or a subscription agent with a name, a role and how it works.
    @discardableResult
    public func rosterCreate(name: String, role: String = "", modelKey: String? = nil, agent: String? = nil, permission: String? = nil,
                             work: String? = nil) throws -> [RosterEntryView] {
        let (name, role) = try rosterCheck(name: name, role: role)
        if (modelKey == nil) == (agent == nil) { throw BlackTeamError("Choose a model or an agent for this one, not both.") }
        var entry = RosterEntry(id: UUID().uuidString.lowercased(), name: name, role: role, modelKey: nil, agent: nil, permission: nil, work: nil)
        if let agent {
            guard let service = AgentService.forEngine(agent) else { throw BlackTeamError("The agent is claude-code or codex.") }
            if let permission, AgentPermission(rawValue: permission) == nil { throw BlackTeamError("Permission is ask, edit or auto.") }
            entry.agent = service.engine; entry.permission = permission ?? "edit"
        } else if let modelKey {
            guard savedModels.find(modelKey) != nil else { throw BlackTeamError("That model is not in your list.") }
            if let work, !["chat", "code"].contains(work) { throw BlackTeamError("Work is chat or code.") }
            entry.modelKey = modelKey; entry.work = work ?? "code"
        }
        return try rosterEdit { entries in
            if entries.count >= RosterLimits.entries { throw BlackTeamError("The roster holds up to \(RosterLimits.entries) agents. Remove one first.") }
            entries.append(entry)
        }
    }

    @discardableResult
    public func rosterRemove(id: String) throws -> [RosterEntryView] {
        try rosterEdit { entries in
            guard let at = entries.firstIndex(where: { $0.id == id }) else { throw BlackTeamError("That agent is not in the roster.") }
            entries.remove(at: at)
        }
    }

    /// Adds a roster agent to a project's room in one step. The room gets its own copy; later changes to either do not touch the other.
    @discardableResult
    public func roomAddFromRoster(projectId: String, rosterId: String) throws -> RoomState {
        rosterLock.lock()
        let entry = RosterStore.load(dataFolder).first { $0.id == rosterId }
        rosterLock.unlock()
        guard let entry else { throw BlackTeamError("That agent is not in the roster.") }
        return try roomAddMember(projectId: projectId, name: entry.name, role: entry.role, modelKey: entry.modelKey, agent: entry.agent,
                                 permission: entry.permission, work: entry.work)
    }

    /// Saves a room member to the roster, so it can be added to other projects.
    @discardableResult
    public func roomSaveToRoster(projectId: String, memberId: String) throws -> [RosterEntryView] {
        _ = try roomProject(projectId)
        roomLock.lock()
        let member = roomLoad(projectId).members.first { $0.id == memberId }
        roomLock.unlock()
        guard let member else { throw BlackTeamError("That member is not in this room.") }
        return try rosterCreate(name: member.name, role: member.role, modelKey: member.modelKey, agent: member.agent, permission: member.permission, work: member.work)
    }
}
