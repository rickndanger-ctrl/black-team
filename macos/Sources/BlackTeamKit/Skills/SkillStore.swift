import Foundation

// Skills: routines that worked, kept as files so they can be used again. A skill is a folder with a SKILL.md in Hermes's own format
// (YAML front matter with `name` and `description`, then Markdown), so the same folder works in Black Team Code and in Hermes. The
// front matter is read by the reader Hermes support already has (HermesCatalog's Manifest); there is no second parser.
//
// Skills live in `skills/` in Black Team's data folder, plus an optional `skills/` folder inside a project. A skill is text for the
// model to read: nothing in it is ever run except through the normal tools and their approvals.

public struct SkillInfo: Equatable, Sendable {
    public var name: String
    public var description: String
    /// The skill's folder.
    public var folder: String
    /// "mine" (Black Team's own folder) or "project" (the project's `skills/` folder, read-only unless allowed).
    public var source: String
    public var enabled: Bool
    /// Size of the SKILL.md in characters.
    public var characters: Int
}

/// What the model is told about the skills it has, and what that costs it to read.
public struct SkillIndex: Equatable, Sendable {
    public var text: String
    public var count: Int
    public var shown: Int
    public var tokens: Int
}

/// A skill ready to be saved, after every rule has been checked.
public struct SkillDraft: Equatable, Sendable {
    public var name: String
    public var description: String
    public var body: String
    public var source: String
    /// A skill with this name exists already and would be replaced.
    public var replaces: Bool
    var folder: String
}

public final class SkillStore: @unchecked Sendable {
    public static let maxBody = 20_000
    public static let maxDescription = 200
    /// The index in the system prompt holds at most this many skills and characters; the rest are found with `skill`.
    public static let indexEntries = 30
    public static let indexCharacters = 2400
    static let namePattern = "^[a-z0-9][a-z0-9-]{0,62}$"

    public let dataFolder: String
    let settings: CodeSettingsStore

    public init(dataFolder: String, settings: CodeSettingsStore? = nil) {
        self.dataFolder = dataFolder
        self.settings = settings ?? CodeSettingsStore(dataFolder: dataFolder)
    }

    /// Black Team's own skills folder, the one Hermes can be linked to.
    public var folder: String { dataFolder + "/skills" }

    public static func validName(_ name: String) -> Bool { name.range(of: namePattern, options: .regularExpression) != nil }

    // MARK: Reading

    /// Every skill found: Black Team's own first, then the project's. A name found twice is listed once, from Black Team's folder.
    public func list(workspace: String? = nil) -> [SkillInfo] {
        let off = Set(settings.global().skillsOff)
        var found = scan(folder, source: "mine", off: off)
        if let workspace, !workspace.isEmpty {
            let taken = Set(found.map(\.name))
            found += scan(workspace + "/skills", source: "project", off: off).filter { !taken.contains($0.name) }
        }
        return found
    }

    private func scan(_ root: String, source: String, off: Set<String>) -> [SkillInfo] {
        let manager = FileManager.default
        var found: [SkillInfo] = []
        for entry in ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted() where !entry.hasPrefix(".") {
            // `name/SKILL.md`, or `category/name/SKILL.md` as Hermes lays its own out.
            var candidates = [root + "/" + entry]
            if !manager.fileExists(atPath: root + "/" + entry + "/SKILL.md") {
                candidates = ((try? manager.contentsOfDirectory(atPath: root + "/" + entry)) ?? []).sorted().filter { !$0.hasPrefix(".") }.map { root + "/" + entry + "/" + $0 }
            }
            for folder in candidates {
                let key = (folder as NSString).lastPathComponent
                guard SkillStore.validName(key), let text = Self.readSkill(folder + "/SKILL.md"), let matter = Manifest.frontMatter(text) else { continue }
                let description = (matter.scalars["description"] ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(SkillInfo(name: key, description: EText.prefix(description, SkillStore.maxDescription), folder: folder, source: source,
                                       enabled: !off.contains(key), characters: text.count))
            }
        }
        return found
    }

    private static func readSkill(_ file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 120_000)
        return String(data: data, encoding: .utf8)
    }

    /// The short list put in the model's instructions: a line per enabled skill, capped in length. Nil when there is none.
    public func index(workspace: String? = nil) -> SkillIndex? {
        let usable = list(workspace: workspace).filter(\.enabled)
        guard !usable.isEmpty else { return nil }
        var lines: [String] = [], used = 0
        for skill in usable.prefix(SkillStore.indexEntries) {
            let line = "- \(skill.name): \(EText.prefix(skill.description.isEmpty ? "(no description)" : skill.description, 120))"
            if used + line.count + 1 > SkillStore.indexCharacters { break }
            lines.append(line); used += line.count + 1
        }
        let hidden = usable.count - lines.count
        let head = "You have saved skills: routines that worked before. When one fits the task, load it with the skill tool before you start, and follow it using your normal tools."
        var text = head + "\n" + lines.joined(separator: "\n")
        if hidden > 0 { text += "\n(\(hidden) more. Load one by name with the skill tool if the task needs it.)" }
        return SkillIndex(text: text, count: usable.count, shown: lines.count, tokens: Int((Double(text.count) / Engine.CHARS_PER_TOKEN).rounded(.up)))
    }

    /// The text of one skill, without its front matter. Nil when there is none by that name, or it is turned off.
    public func body(_ name: String, workspace: String? = nil) -> String? {
        guard let skill = list(workspace: workspace).first(where: { $0.name == name && $0.enabled }), let text = Self.readSkill(skill.folder + "/SKILL.md") else { return nil }
        return Self.withoutFrontMatter(text)
    }

    static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole file of one of Black Team's own skills, for the Memory page.
    public func text(_ name: String, workspace: String? = nil) throws -> String {
        guard let skill = list(workspace: workspace).first(where: { $0.name == name }), let text = Self.readSkill(skill.folder + "/SKILL.md") else { throw BlackTeamError("That skill was not found.") }
        return text
    }

    // MARK: Saving

    /// Checks a skill the model wants to save. Throws a plain sentence the model can act on.
    public func draft(name rawName: String, description rawDescription: String, body rawBody: String, project: Bool, workspace: String?) throws -> SkillDraft {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SkillStore.validName(name) else { throw BlackTeamError("The name must be lowercase letters, digits and hyphens, such as fix-lint-errors (up to 63 characters).") }
        let description = rawDescription.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw BlackTeamError("Give a one-line description saying when to use the skill.") }
        guard description.count <= SkillStore.maxDescription else { throw BlackTeamError("The description is too long (\(description.count) characters; the most is \(SkillStore.maxDescription)).") }
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw BlackTeamError("Give the steps of the skill in Markdown.") }
        guard body.count <= SkillStore.maxBody else { throw BlackTeamError("The skill is too long (\(EText.grouped(body.count)) characters; the most is \(EText.grouped(SkillStore.maxBody))). Keep it to the steps that matter.") }
        guard !body.hasPrefix("---") else { throw BlackTeamError("Start the steps with text, not with ---.") }
        if body.range(of: #"(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*\S{8,}"#, options: .regularExpression) != nil {
            throw BlackTeamError("The skill looks like it contains a secret. Skills are plain files; leave keys and passwords out.")
        }
        var root = folder, source = "mine"
        if project {
            guard let workspace, !workspace.isEmpty else { throw BlackTeamError("There is no project folder to save into.") }
            guard settings.global().projectSkillsWritable else { throw BlackTeamError("Skills cannot be saved into the project folder unless the person allows it in Settings. Save it to Black Team's own skills instead.") }
            root = workspace + "/skills"; source = "project"
        }
        let target = root + "/" + name
        return SkillDraft(name: name, description: description, body: body, source: source, replaces: FileManager.default.fileExists(atPath: target + "/SKILL.md"), folder: target)
    }

    /// The text of the SKILL.md: Hermes's format.
    static func file(_ draft: SkillDraft) -> String { file(name: draft.name, description: draft.description, body: draft.body) }
    static func file(name: String, description: String, body: String) -> String {
        let quoted = description.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "---\nname: \(name)\ndescription: \"\(quoted)\"\n---\n\n\(body)\n"
    }

    public func save(_ draft: SkillDraft) throws {
        try FileManager.default.createDirectory(atPath: draft.folder, withIntermediateDirectories: true)
        let target = draft.folder + "/SKILL.md", temporary = target + "." + randomHex(4) + ".tmp"
        try Data(SkillStore.file(draft).utf8).write(to: URL(fileURLWithPath: temporary))
        if rename(temporary, target) != 0 { unlink(temporary); throw BlackTeamError("The skill could not be saved.") }
    }

    /// The person's own edit of one of Black Team's skills: the whole file, which must keep its front matter.
    public func write(_ name: String, text: String) throws {
        guard SkillStore.validName(name) else { throw BlackTeamError("That skill was not found.") }
        guard text.count <= SkillStore.maxBody + 2000 else { throw BlackTeamError("The skill is too long.") }
        guard let matter = Manifest.frontMatter(text), matter.scalars["name"] != nil, matter.scalars["description"] != nil else {
            throw BlackTeamError("Keep the lines between --- at the top: a name and a description.")
        }
        let folderPath = folder + "/" + name
        guard FileManager.default.fileExists(atPath: folderPath + "/SKILL.md") else { throw BlackTeamError("That skill was not found.") }
        try Data(text.utf8).write(to: URL(fileURLWithPath: folderPath + "/SKILL.md"))
    }

    /// Removes one of Black Team's skills. The folder goes to `skills/.trash` and is not read from there.
    public func remove(_ name: String) throws {
        guard SkillStore.validName(name), FileManager.default.fileExists(atPath: folder + "/" + name + "/SKILL.md") else { throw BlackTeamError("That skill was not found.") }
        let trash = folder + "/.trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        try FileManager.default.moveItem(atPath: folder + "/" + name, toPath: trash + "/\(name)-\(stamp)")
        try settings.updateGlobal { $0.skillsOff.removeAll { $0 == name } }
    }

    public func setEnabled(_ name: String, _ on: Bool, workspace: String? = nil) throws {
        guard list(workspace: workspace).contains(where: { $0.name == name }) else { throw BlackTeamError("That skill was not found.") }
        try settings.updateGlobal { settings in
            settings.skillsOff.removeAll { $0 == name }
            if !on { settings.skillsOff.append(name) }
        }
    }

    /// How many skills the folder holds, by the count Hermes support uses, for the Hermes screen.
    public var count: Int { HermesCatalog.ownSkillCount(folder) }
}

// MARK: The tools

public enum SkillTools {
    public static let names = ["skill", "save_skill"]

    public static var schemas: [JSONValue] {
        [
            ["type": "function", "function": [
                "name": "skill",
                "description": "Load the steps of one saved skill by name. The skills you have are listed in your instructions. Follow the steps with your normal tools.",
                "parameters": ["type": "object", "properties": ["name": ["type": "string", "minLength": 1, "maxLength": 63]], "required": ["name"]],
            ]],
            ["type": "function", "function": [
                "name": "save_skill",
                "description": "Save a routine that just worked as a skill for later conversations: a short name, one line saying when to use it, and the steps in Markdown. Save only what you ran and saw work. Never include keys or passwords.",
                "parameters": ["type": "object", "properties": [
                    "name": ["type": "string", "minLength": 1, "maxLength": 63, "pattern": .string(SkillStore.namePattern), "description": "lowercase letters, digits and hyphens, such as fix-lint-errors"],
                    "description": ["type": "string", "minLength": 1, "maxLength": .number(Double(SkillStore.maxDescription)), "description": "one line: when to use this skill"],
                    "body": ["type": "string", "minLength": 1, "maxLength": .number(Double(SkillStore.maxBody)), "description": "the steps, in Markdown"],
                    "where": ["type": "string", "enum": ["mine", "project"], "description": "mine (default) or project"],
                ], "required": ["name", "description", "body"]],
            ]],
        ]
    }
}
