import Foundation

// What a connected Hermes install offers, read from the install itself: its tool groups (asked of its own Python once, in a scratch
// home, by scripts/hermes-abilities.py), and its skills and plugins (read as files). Nothing is hard-coded about which groups exist:
// a group the install lacks is not shown. The few names below only decide a group's plain label.

// MARK: Manifests

/// The part of a `plugin.yaml` or a `SKILL.md` front matter that is read: top-level text values and lists. Hermes's files are plain
/// YAML of this shape; anything nested is skipped.
struct Manifest {
    var scalars: [String: String] = [:]
    var lists: [String: [String]] = [:]

    init(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        func indented(_ line: String) -> Bool { line.first == " " || line.first == "\t" }
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.isEmpty, !indented(line), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":"), line[line.startIndex..<colon].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var children: [String] = []
            while index < lines.count, lines[index].isEmpty || indented(lines[index]) || lines[index].hasPrefix("- ") {
                children.append(lines[index]); index += 1
            }
            let body = children.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if value.isEmpty {
                let items = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
                if !items.isEmpty {
                    lists[key] = items.map { item in
                        if item.hasPrefix("name:") { return Manifest.unquote(String(item.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                        return Manifest.unquote(item.trimmingCharacters(in: .whitespaces))
                    }
                }
            } else if value.range(of: "^[>|][+-]?$", options: .regularExpression) != nil {
                let pieces = body.map { $0.trimmingCharacters(in: .whitespaces) }
                scalars[key] = value.hasPrefix(">") ? pieces.joined(separator: " ") : pieces.joined(separator: "\n")
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                lists[key] = value.dropFirst().dropLast().split(separator: ",").map { Manifest.unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            } else {
                scalars[key] = Manifest.unquote(value)
            }
        }
    }

    static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { return unescape(String(text.dropFirst().dropLast())) }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") { return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return text
    }

    /// The escapes of a double-quoted YAML string: \" \\ \n \t and \uXXXX.
    private static func unescape(_ text: String) -> String {
        var out = "", pending = false
        var units = Array(text.unicodeScalars)[...]
        while let scalar = units.popFirst() {
            if !pending { if scalar == "\\" { pending = true } else { out.unicodeScalars.append(scalar) }; continue }
            pending = false
            switch scalar {
            case "n": out += "\n"
            case "t": out += "\t"
            case "u":
                let hex = String(String.UnicodeScalarView(units.prefix(4)))
                if hex.count == 4, let code = UInt32(hex, radix: 16), let value = Unicode.Scalar(code) { out.unicodeScalars.append(value); units = units.dropFirst(4) }
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The front matter of a SKILL.md: the text between the first two `---` lines.
    static func frontMatter(_ text: String) -> Manifest? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return Manifest(lines[1..<end].joined(separator: "\n"))
    }
}

// MARK: What the install's own Python reported

public struct HermesProbe: Codable, Equatable, Sendable {
    public struct Toolset: Codable, Equatable, Sendable {
        public var name: String
        public var description: String
        public var tools: [String]
        public var includes: [String]
        public var posture: Bool
        public var role: String?
        public var requiresEnv: [String]
        public var ready: Bool?
        public init(name: String, description: String = "", tools: [String] = [], includes: [String] = [], posture: Bool = false, role: String? = nil,
                    requiresEnv: [String] = [], ready: Bool? = nil) {
            self.name = name; self.description = description; self.tools = tools; self.includes = includes; self.posture = posture
            self.role = role; self.requiresEnv = requiresEnv; self.ready = ready
        }
    }
    public struct Tool: Codable, Equatable, Sendable {
        public var chars: Int
        public var toolset: String?
        public init(chars: Int, toolset: String? = nil) { self.chars = chars; self.toolset = toolset }
    }
    public struct Chars: Codable, Equatable, Sendable { public var chars: Int }

    public var version = 1
    public var toolsets: [Toolset] = []
    public var tools: [String: Tool] = [:]
    public var companion: [String: Chars] = [:]
    public var costError: String?
    public init() {}

    /// Characters of tool descriptions Black Team's own companion tools add to every message.
    public var companionCharacters: Int { companion.values.reduce(0) { $0 + $1.chars } }
}

/// Runs scripts/hermes-abilities.py with the install's Python, once, and keeps the answer until the install changes.
public enum HermesProbeRunner {
    static let seconds = 60.0

    struct Cached: Codable { var source: String; var python: String; var stamp: String; var probe: HermesProbe }

    /// Which version of the install and of the helper the answer is for.
    static func stamp(source: String, scripts: String) -> String {
        func mark(_ path: String) -> String {
            var info = stat()
            return stat(path, &info) == 0 ? "\(info.st_size):\(info.st_mtim.tv_sec)" : "-"
        }
        let root = URL(fileURLWithPath: scripts).deletingLastPathComponent().path
        return [mark(source + "/toolsets.py"), mark(source + "/install-stamp.json"), mark(scripts + "/hermes-abilities.py"), mark(root + "/plugins/companion-tools/__init__.py")].joined(separator: "|")
    }

    public static func cached(dataFolder: String, source: String, python: String, scripts: String?) -> HermesProbe? {
        guard let scripts, let data = FileManager.default.contents(atPath: dataFolder + "/" + HermesAbilities.probeFile),
              let saved = try? JSONDecoder().decode(Cached.self, from: data), saved.source == source, saved.python == python,
              saved.stamp == stamp(source: source, scripts: scripts) else { return nil }
        return saved.probe
    }

    /// Asks the install. Throws a sentence for the person when it cannot answer; the screen then lists the groups without their cost.
    public static func run(dataFolder: String, source: String, python: String, scripts: String) async throws -> HermesProbe {
        let helper = scripts + "/hermes-abilities.py"
        guard CoreFS.exists(helper) else { throw BlackTeamError("This copy of Black Team has no Hermes reader, so what your Hermes can do is not shown.") }
        guard CoreFS.exists(source + "/toolsets.py") else { throw BlackTeamError("This Hermes has no tool list Black Team can read.") }
        try privateDirectory(dataFolder)
        // A scratch home, so reading Hermes's tool table leaves nothing in any real Hermes profile.
        let scratch = dataFolder + "/hermes-probe-" + CoreFS.hex(8)
        try privateDirectory(scratch)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        var env = localEnvironment()
        env["HOME"] = scratch
        env["HERMES_HOME"] = scratch
        env["BLACK_TEAM_HERMES_SOURCE"] = source
        env["BLACK_TEAM_COMPANION_PLUGIN"] = URL(fileURLWithPath: scripts).deletingLastPathComponent().appendingPathComponent("plugins/companion-tools").standardized.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let job = ExecJob(executable: python, arguments: [helper], cwd: scratch, env: env, seconds: seconds, streamCap: 8 * 1024 * 1024)
        let outcome = await job.run()
        let output = String(decoding: outcome.stdout, as: UTF8.self)
        guard !outcome.timedOut, outcome.code == 0, let line = output.components(separatedBy: "\n").last(where: { $0.hasPrefix("BT_ABILITIES=") }),
              let probe = try? JSONDecoder().decode(HermesProbe.self, from: Data(line.dropFirst("BT_ABILITIES=".count).utf8)) else {
            throw BlackTeamError(outcome.timedOut ? "Reading your Hermes took too long." : "Your Hermes could not tell Black Team what it can do. Its tool groups are listed without their cost.")
        }
        let saved = Cached(source: source, python: python, stamp: stamp(source: source, scripts: scripts), probe: probe)
        try writeJSON(dataFolder + "/" + HermesAbilities.probeFile, saved)
        return probe
    }
}

// MARK: Tool groups

public struct HermesToolGroup: Equatable, Sendable {
    public var name: String
    public var description: String
    public var label: AbilityLabel
    public var tools: [String]
    /// Characters of tool descriptions in a message when this group is on, if the install said.
    public var characters: Int?
    /// Whether Hermes itself says the group is set up on this computer (nil when it could not say).
    public var ready: Bool?
    /// Why it cannot be switched on, if it cannot.
    public var lockedReason: String?
    public var tokens: Int? { characters.map(HermesAbilities.tokens) }
}

public enum HermesCatalog {
    static let serviceReason = "Needs the always-running Hermes service, which Black Team does not provide yet."

    /// Groups that only make sense inside the always-running service (messaging, scheduled jobs, the task board), besides every
    /// `hermes-*` platform bundle.
    static let serviceGroups: Set<String> = ["cronjob", "kanban", "discord", "discord_admin", "feishu_doc", "feishu_drive", "yuanbao"]
    /// Groups whose use sends something over the internet.
    static let internetGroups: Set<String> = ["web", "search", "browser", "tts", "x_search"]
    /// Groups that run on this computer even though Hermes may report them not set up (they need software, not an account).
    static let computerGroups: Set<String> = ["computer_use"]
    /// Groups Hermes defines for its own surfaces or as shortcuts of other groups.
    static let hiddenGroups: Set<String> = ["desktop_ui", "project", "setup", "context_engine", "bot_room", "coding", "debugging", "safe"]
    static let preferred = ["terminal", "file", "todo", "skills", "web", "search", "browser", "computer_use", "code_execution", "delegation", "session_search",
                            "memory", "clarify", "vision", "image_gen", "tts"]

    public static func label(for set: HermesProbe.Toolset) -> AbilityLabel {
        if set.name.hasPrefix("hermes-") || serviceGroups.contains(set.name) { return .service }
        if internetGroups.contains(set.name) { return .internet }
        if computerGroups.contains(set.name) { return .computer }
        if !set.requiresEnv.isEmpty || set.ready == false { return .key }
        return .computer
    }

    /// The groups to show: every group the install defines, but not its shortcuts and surface-only entries.
    public static func groups(_ probe: HermesProbe) -> [HermesToolGroup] {
        let shown = probe.toolsets.filter { set in
            if hiddenGroups.contains(set.name) || set.posture || set.role != nil { return false }
            if set.name.hasPrefix("hermes-") { return true }
            return !set.tools.isEmpty && set.includes.isEmpty
        }
        let list: [HermesToolGroup] = shown.map { set in
            let label = label(for: set)
            let sizes = set.tools.compactMap { probe.tools[$0]?.chars }
            return HermesToolGroup(name: set.name, description: String(set.description.prefix(240)), label: label, tools: set.tools,
                                   characters: sizes.isEmpty ? nil : sizes.reduce(0, +), ready: set.ready,
                                   lockedReason: label == .service ? serviceReason : nil)
        }
        return list.sorted { a, b in
            let ra = (a.label == .service ? 1000 : 0) + (preferred.firstIndex(of: a.name) ?? 100)
            let rb = (b.label == .service ? 1000 : 0) + (preferred.firstIndex(of: b.name) ?? 100)
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    /// Characters of tool descriptions every message carries with these groups on, each tool counted once however many groups hold it.
    public static func characters(of names: [String], groups: [HermesToolGroup], probe: HermesProbe, extra: Int = 0) -> Int {
        var tools = Set<String>()
        for group in groups where names.contains(group.name) { tools.formUnion(group.tools) }
        return probe.companionCharacters + tools.reduce(0) { $0 + (probe.tools[$1]?.chars ?? 0) } + extra
    }

    /// The warning for a total reading cost, or nil when it is modest for the model's context.
    public static func warning(tokens: Int, context: Int) -> String? {
        guard context > 0 else { return nil }
        let share = Double(tokens) / Double(context)
        guard share >= HermesAbilities.warnShare else { return nil }
        let percent = Int((share * 100).rounded())
        return "These tools add about \(tokens) tokens to every message, about \(percent)% of this model's \(context)-token memory. A local model reads that each time, so replies will start more slowly. Turn off what you do not need."
    }
}

// MARK: Skills

public struct HermesSkill: Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var description: String
    public var path: String
}

public struct HermesSkillList: Equatable, Sendable {
    public var skills: [HermesSkill] = []
    public var optional: [HermesSkill] = []
    /// A category's own DESCRIPTION.md, which Hermes shows in its skill index.
    public var categoryDescriptions: [String: String] = [:]
}

extension HermesCatalog {
    static var thisSystem: String {
        #if os(Linux)
        return "linux"
        #else
        return "macos"
        #endif
    }

    /// Reads `<source>/skills` and `<source>/optional-skills`: `category/name/SKILL.md` front matter only, never a skill's body.
    public static func skills(source: String) -> HermesSkillList {
        var list = HermesSkillList()
        let manager = FileManager.default
        func scan(_ root: String) -> [HermesSkill] {
            var found: [HermesSkill] = []
            for category in ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted() where !category.hasPrefix(".") {
                let folder = root + "/" + category
                for name in ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !name.hasPrefix(".") {
                    let file = folder + "/" + name + "/SKILL.md"
                    guard let handle = FileHandle(forReadingAtPath: file) else { continue }
                    let head = handle.readData(ofLength: 16 * 1024)
                    try? handle.close()
                    guard let matter = Manifest.frontMatter(String(decoding: head, as: UTF8.self)) else { continue }
                    if let platforms = matter.lists["platforms"], !platforms.isEmpty, !platforms.contains(thisSystem) { continue }
                    let description = (matter.scalars["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    found.append(HermesSkill(id: category + "/" + name, name: matter.scalars["name"] ?? name, category: category,
                                             description: String(description.prefix(200)), path: folder + "/" + name))
                }
            }
            return found
        }
        list.skills = scan(source + "/skills")
        list.optional = scan(source + "/optional-skills")
        for category in Set(list.skills.map { $0.category }) {
            if let text = try? String(contentsOfFile: source + "/skills/" + category + "/DESCRIPTION.md", encoding: .utf8),
               let matter = Manifest.frontMatter(text), let description = matter.scalars["description"] { list.categoryDescriptions[category] = description }
        }
        return list
    }

    /// Skills in the folder the person keeps themselves: any `SKILL.md` up to three levels down.
    public static func ownSkillCount(_ folder: String) -> Int {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return 0 }
        var count = 0
        while let item = walker.nextObject() as? String {
            if item.split(separator: "/").count > 4 { walker.skipDescendants(); continue }
            if (item as NSString).lastPathComponent == "SKILL.md" { count += 1 }
            if count >= 500 { break }
        }
        return count
    }

    /// About how many characters Hermes's skill index adds to the system prompt for these skills (its fixed instructions, a line per
    /// category and a line per skill). Only the index is in the prompt; a skill's text is read when the model asks for it.
    public static func indexCharacters(for skills: [HermesSkill], categoryDescriptions: [String: String]) -> Int {
        guard !skills.isEmpty else { return 0 }
        var total = 1100
        for category in Set(skills.map { $0.category }) { total += category.count + (categoryDescriptions[category]?.count ?? 0) + 6 }
        for skill in skills { total += skill.name.count + skill.description.count + 8 }
        return total
    }
}

// MARK: Plugins

public struct HermesPlugin: Equatable, Sendable {
    public enum Kind: String, Sendable { case general, memory, provider, platform }
    /// What `plugins.enabled` names: the folder path under `plugins/` for Hermes's own, the folder name for one the person installed.
    public var key: String
    public var name: String
    public var description: String
    public var kind: Kind
    public var category: String
    public var yours: Bool
    public var label: AbilityLabel
    public var tools: [String]
    /// The environment names it reads, from its manifest.
    public var env: [String]
    public var providers: [String]
    public var path: String
    public var lockedReason: String?
    /// A sentence when using it sends something off this computer.
    public var note: String?
}

extension HermesCatalog {
    static let memoryReason = "Black Team has its own memory vault. A Hermes memory plugin would keep a second copy of what you say, so these stay off."
    static let providerCategories: Set<String> = ["web", "image_gen", "video_gen", "browser"]
    static let hiddenCategories: Set<String> = ["model-providers", "dashboard_auth", "cron_providers", "context_engine"]

    static func environmentNames(_ matter: Manifest) -> [String] {
        var names: [String] = []
        for key in ["requires_env", "optional_env"] { names += matter.lists[key] ?? [] }
        // Hermes's web providers name their key only in their description ("Requires BRAVE_SEARCH_API_KEY").
        let text = matter.scalars["description"] ?? ""
        if let regex = try? NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*_(?:API_KEY|KEY|TOKEN|SECRET|URL)\\b") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) { if let r = Range(match.range, in: text) { names.append(String(text[r])) } }
        }
        var seen = Set<String>()
        return names.filter { KeyName.valid($0) && seen.insert($0).inserted }
    }

    /// Hermes's own plugins under `<source>/plugins`, and (read-only) the ones the person installed under `<home>/.hermes/plugins`.
    public static func plugins(source: String, home: String) -> [HermesPlugin] {
        var list: [HermesPlugin] = []
        let manager = FileManager.default
        func read(_ folder: String, key: String, category: String, yours: Bool) -> HermesPlugin? {
            guard let text = try? String(contentsOfFile: folder + "/plugin.yaml", encoding: .utf8) else { return nil }
            let matter = Manifest(text)
            let name = matter.scalars["name"] ?? (folder as NSString).lastPathComponent
            let description = String((matter.scalars["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            let env = environmentNames(matter)
            var kind = HermesPlugin.Kind.general
            if category == "memory" { kind = .memory }
            else if category == "platforms" || matter.scalars["kind"] == "platform" { kind = .platform }
            else if providerCategories.contains(category) || matter.scalars["kind"] == "backend" { kind = .provider }
            var label = AbilityLabel.computer
            let lowered = description.lowercased()
            if !(matter.lists["requires_env"] ?? []).isEmpty || ["oauth", "sign in", "account", "api key", "requires "].contains(where: { lowered.contains($0) }) { label = .key }
            else if ["web api", "cloud", "online", "http", "google", "microsoft", "trace"].contains(where: { lowered.contains($0) }) { label = .internet }
            if kind == .platform { label = .service }
            var reason: String?
            if kind == .memory { reason = memoryReason }
            if kind == .platform { reason = serviceReason }
            var note: String?
            if label == .key || label == .internet || category == "observability" {
                note = category == "observability" ? "Sends a record of your conversations, including tool use, to the service it reports to." : "May send data off \(Place.this) when it is used."
            }
            return HermesPlugin(key: key, name: name, description: description, kind: kind, category: category, yours: yours, label: label,
                                tools: matter.lists["provides_tools"] ?? [], env: env, providers: matter.lists["provides_web_providers"] ?? [],
                                path: folder, lockedReason: reason, note: note)
        }
        let root = source + "/plugins"
        for entry in ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted() where !entry.hasPrefix(".") && !entry.hasPrefix("_") {
            if hiddenCategories.contains(entry) { continue }
            let folder = root + "/" + entry
            if CoreFS.exists(folder + "/plugin.yaml") {
                if let plugin = read(folder, key: entry, category: "", yours: false) { list.append(plugin) }
            } else {
                for child in ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !child.hasPrefix(".") && !child.hasPrefix("_") {
                    if let plugin = read(folder + "/" + child, key: entry + "/" + child, category: entry, yours: false) { list.append(plugin) }
                }
            }
        }
        let mine = home + "/.hermes/plugins"
        for entry in ((try? manager.contentsOfDirectory(atPath: mine)) ?? []).sorted() where !entry.hasPrefix(".") {
            if let plugin = read(mine + "/" + entry, key: entry, category: "", yours: true) { list.append(plugin) }
        }
        return list
    }

    // MARK: Web search

    public struct WebProvider: Equatable, Sendable {
        public var name: String
        public var plugin: String
        public var description: String
        public var env: [String]
        public var label: AbilityLabel
        /// A Python package the provider needs and the install does not have, if known.
        public var missingPackage: String?
    }

    /// The web search providers, those that need no key first.
    public static func webProviders(from plugins: [HermesPlugin], source: String) -> [WebProvider] {
        var list: [WebProvider] = []
        for plugin in plugins where plugin.category == "web" {
            for provider in plugin.providers {
                var missing: String?
                if let regex = try? NSRegularExpression(pattern: "pip install ([A-Za-z0-9_.-]+)"),
                   let match = regex.firstMatch(in: plugin.description, range: NSRange(plugin.description.startIndex..., in: plugin.description)),
                   let range = Range(match.range(at: 1), in: plugin.description) {
                    let package = String(plugin.description[range])
                    let found = ["venv", ".venv"].contains { venv in
                        ((try? FileManager.default.contentsOfDirectory(atPath: source + "/" + venv + "/lib")) ?? []).contains { python in
                            CoreFS.exists(source + "/" + venv + "/lib/" + python + "/site-packages/" + package)
                        }
                    }
                    if !found { missing = package }
                }
                list.append(WebProvider(name: provider, plugin: plugin.key, description: plugin.description, env: plugin.env,
                                        label: plugin.env.isEmpty ? .internet : .key, missingPackage: missing))
            }
        }
        return list.sorted { a, b in
            let ka = a.env.isEmpty ? 0 : 1, kb = b.env.isEmpty ? 0 : 1
            return ka != kb ? ka < kb : a.name < b.name
        }
    }
}

enum KeyName {
    static func valid(_ name: String) -> Bool { name.range(of: "^[A-Z][A-Z0-9_]{2,63}$", options: .regularExpression) != nil }
}
