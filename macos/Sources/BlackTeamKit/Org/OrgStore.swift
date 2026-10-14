import Foundation

// Where an organization lives: `<data>/orgs/<project>/`. Private (0700 folders, 0600 files), atomic writes, no secrets: a role names a saved
// model by its key and the API key stays in the saved-models file, exactly as in the roster.
//
//   org.json       the roles, gates, ceilings and settings
//   tickets.json   every ticket with its history and an index of its artifacts
//   usage.json     one line per stage run (who, how many tokens, paid or local, how long)
//   tickets/<id>/  the artifacts, the canonical copy (a copy is also written into the ticket's branch, see OrgRunner)
//   standups/      the daily stand-up reports
//   work/<id>/     the ticket's own git worktree, when the project is a git repository

/// One lock for every organization file, so reading and writing never interleave.
let orgLock = NSRecursiveLock()

enum OrgStore {
    static func folder(_ dataFolder: String, _ projectId: String) -> String { dataFolder + "/orgs/" + projectId }
    static func file(_ dataFolder: String, _ projectId: String, _ name: String) -> String { folder(dataFolder, projectId) + "/" + name }

    private static func plainFile(_ path: String, limit: Int) -> Data? {
        let info = CoreFS.stat(path)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= limit, !CoreFS.isSymlink(path) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    static func load(_ dataFolder: String, _ projectId: String) -> Organization? {
        guard History.validID(projectId), let data = plainFile(file(dataFolder, projectId, "org.json"), limit: 512 * 1024),
              var org = try? JSONDecoder().decode(Organization.self, from: data), org.projectId == projectId else { return nil }
        // Every field is checked again on the way in, so a damaged or hand-edited file cannot hold what the screens would not allow.
        org.roles = Array(org.roles.compactMap(cleanRole).prefix(OrgLimits.roles))
        org.gates = org.gates.filter { OrgStage(rawValue: $0) != nil }
        return org
    }

    static func save(_ org: Organization, _ dataFolder: String) throws {
        guard History.validID(org.projectId) else { throw BlackTeamError("Invalid project.") }
        try privateDirectory(folder(dataFolder, org.projectId))
        try writeJSON(file(dataFolder, org.projectId, "org.json"), org)
    }

    private struct TicketFile: Codable { var version = 1; var tickets: [OrgTicket] }

    static func tickets(_ dataFolder: String, _ projectId: String) -> [OrgTicket] {
        guard History.validID(projectId), let data = plainFile(file(dataFolder, projectId, "tickets.json"), limit: 16 * 1024 * 1024),
              let saved = try? JSONDecoder().decode(TicketFile.self, from: data) else { return [] }
        var seen = Set<String>()
        return saved.tickets.filter { History.validID($0.id) && seen.insert($0.id).inserted }.prefix(OrgLimits.tickets).map { $0 }
    }

    static func saveTickets(_ tickets: [OrgTicket], _ dataFolder: String, _ projectId: String) throws {
        try privateDirectory(folder(dataFolder, projectId))
        try writeJSON(file(dataFolder, projectId, "tickets.json"), TicketFile(tickets: tickets))
    }

    private struct UsageFile: Codable { var version = 1; var entries: [OrgUsageEntry] }

    static func usage(_ dataFolder: String, _ projectId: String) -> [OrgUsageEntry] {
        guard let data = plainFile(file(dataFolder, projectId, "usage.json"), limit: 8 * 1024 * 1024),
              let saved = try? JSONDecoder().decode(UsageFile.self, from: data) else { return [] }
        return saved.entries
    }

    static func saveUsage(_ entries: [OrgUsageEntry], _ dataFolder: String, _ projectId: String) throws {
        try privateDirectory(folder(dataFolder, projectId))
        try writeJSON(file(dataFolder, projectId, "usage.json"), UsageFile(entries: Array(entries.suffix(OrgLimits.usage))))
    }

    // MARK: Artifacts

    static func artifactFolder(_ dataFolder: String, _ projectId: String, _ ticketId: String) -> String { folder(dataFolder, projectId) + "/tickets/" + ticketId }

    /// A name we made ourselves: letters, digits, dash, dot, no slash.
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 60 && !name.hasPrefix(".") && name.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "." }
    }

    static func writeArtifact(_ dataFolder: String, _ projectId: String, _ ticketId: String, name: String, text: String) throws {
        guard safeName(name), History.validID(ticketId) else { throw BlackTeamError("That artifact cannot be saved.") }
        let dir = artifactFolder(dataFolder, projectId, ticketId)
        try privateDirectory(dir)
        try CoreFS.writeAtomic(dir + "/" + name, Data(text.utf8), temporary: dir + "/" + name + "." + CoreFS.hex(6) + ".tmp")
    }

    static func readArtifact(_ dataFolder: String, _ projectId: String, _ ticketId: String, name: String) -> String? {
        guard safeName(name), History.validID(ticketId), History.validID(projectId),
              let data = plainFile(artifactFolder(dataFolder, projectId, ticketId) + "/" + name, limit: 2 * OrgLimits.artifact) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Checking what comes in

    static func clean(_ text: String, max: Int, multiline: Bool = false, allowEmpty: Bool = false) -> String? {
        RoomStore.clean(.string(text), max: max, multiline: multiline, allowEmpty: allowEmpty)
    }

    static func cleanRole(_ role: OrgRole) -> OrgRole? {
        guard History.validID(role.id), let name = clean(role.name, max: OrgLimits.name),
              let charter = clean(role.charter, max: OrgLimits.charter, multiline: true, allowEmpty: true) else { return nil }
        var out = role
        out.name = name; out.charter = charter
        out.skills = Array(role.skills.compactMap { clean($0, max: OrgLimits.skill, multiline: true) }.prefix(OrgLimits.skills))
        if role.modelKey != nil && role.agent != nil { return nil }
        if let agent = role.agent { guard let service = AgentService.forEngine(agent) else { return nil }; out.agent = service.engine; out.work = nil }
        if role.modelKey != nil { out.work = role.work == "chat" ? "chat" : "code" }
        if let p = role.price, !(p.inPerMillion >= 0 && p.inPerMillion < 1_000_000 && p.outPerMillion >= 0 && p.outPerMillion < 1_000_000) { out.price = nil }
        return out
    }
}
