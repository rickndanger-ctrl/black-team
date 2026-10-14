import Foundation

// What a Black Team conversation can do through a connected Hermes: the tool groups, skills, plugins and MCP servers the person has
// switched on, where those choices are kept, and the checks they pass. The catalogue of what an install offers is in
// HermesCatalog.swift; how a choice becomes a Hermes profile is in HermesProfile.swift; the screens' actions are in
// HermesAbilitiesControl.swift. Nothing here starts Hermes.

/// The plain label shown beside every tool group, plugin and provider.
public enum AbilityLabel: String, Codable, Sendable, CaseIterable {
    case computer, key, internet, service

    public var text: String {
        switch self {
        case .computer: return "Works on \(Place.this)"
        case .key: return "Needs an account or key"
        case .internet: return "Uses the internet"
        case .service: return "Needs the always-running service"
        }
    }
}

/// One MCP tool server the person added for Hermes conversations. Environment values are not here: only their names are, and the
/// values are in the key file.
public struct McpServer: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    public var url: String
    public var envNames: [String]
    public var enabled: Bool

    public init(name: String, command: String = "", args: [String] = [], url: String = "", envNames: [String] = [], enabled: Bool = true) {
        self.name = name; self.command = command; self.args = args; self.url = url; self.envNames = envNames; self.enabled = enabled
    }

    /// The environment variable that carries one of this server's values to Hermes (the profile refers to it as `${...}`).
    public func variable(_ envName: String) -> String { "BT_MCP_" + name.uppercased().replacingOccurrences(of: "-", with: "_") + "_" + envName }

    /// The key-file name that holds one of this server's values.
    public func keyName(_ envName: String) -> String { "mcp." + name + "." + envName }
}

/// The choices a person made about what Hermes may do in a Black Team conversation (`hermes-abilities.json`, in the data folder).
public struct HermesAbilitySettings: Codable, Equatable, Sendable {
    /// The tool groups switched on, not counting the companion tools, which are always on. Nil until a choice is saved: until then the
    /// old three switches (`HermesSettings.coding`, `.browser`, `.desktop`) decide.
    public var toolsets: [String]?
    /// Skills switched on, as `category/name`.
    public var skills: [String] = []
    /// Whether the "your own skills" folder is linked in.
    public var ownSkills = true
    /// Plugins switched on, as Hermes names them (`disk-cleanup`, `observability/langfuse`) or the folder of one the person installed.
    public var plugins: [String] = []
    /// The web search provider Hermes uses (`ddgs`, `searxng`, ...), or empty.
    public var webSearch = ""
    public var mcp: [McpServer] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolsets = try c.decodeIfPresent([String].self, forKey: .toolsets)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        ownSkills = try c.decodeIfPresent(Bool.self, forKey: .ownSkills) ?? true
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? []
        webSearch = try c.decodeIfPresent(String.self, forKey: .webSearch) ?? ""
        mcp = try c.decodeIfPresent([McpServer].self, forKey: .mcp) ?? []
    }

    /// The groups to pass on (after the companion tools): the saved choice, or the old switches' meaning.
    public func chosenToolsets(legacy: HermesSettings) -> [String] {
        if let toolsets { return toolsets }
        var list: [String] = []
        if legacy.coding { list += HermesAbilities.codingGroups }
        if legacy.browser { list.append("browser") }
        if legacy.desktop { list.append("computer_use") }
        return list
    }
}

public enum HermesAbilities {
    /// What the old "coding" switch meant.
    public static let codingGroups = ["terminal", "file", "todo"]
    /// The tools Black Team's own plugin adds; always on.
    public static let companion = "companion"
    /// A group list longer than this share of the model's context earns a warning: local models read slowly.
    public static let warnShare = 0.20

    static let settingsFile = "hermes-abilities.json"
    static let keysFile = "hermes-keys.json"
    static let probeFile = "hermes-probe.json"
    static let costsFile = "hermes-mcp-costs.json"
    static let ownSkillsFolder = "hermes-skills"

    /// "About N tokens" from a count of characters of tool descriptions.
    public static func tokens(_ characters: Int) -> Int { (characters + 2) / 4 }

    public static func ownSkillsPath(_ dataFolder: String) -> String { dataFolder + "/" + ownSkillsFolder }
}

// MARK: Where the choices are kept

public final class HermesAbilityStore: @unchecked Sendable {
    public let dataFolder: String
    private let lock = NSLock()

    public init(dataFolder: String) { self.dataFolder = dataFolder }

    var file: String { dataFolder + "/" + HermesAbilities.settingsFile }

    public func read() -> HermesAbilitySettings {
        lock.lock(); defer { lock.unlock() }
        return readUnlocked()
    }

    private func readUnlocked() -> HermesAbilitySettings {
        guard let data = FileManager.default.contents(atPath: file), let settings = try? JSONDecoder().decode(HermesAbilitySettings.self, from: data) else {
            return HermesAbilitySettings()
        }
        return settings
    }

    public func write(_ settings: HermesAbilitySettings) throws {
        lock.lock(); defer { lock.unlock() }
        try privateDirectory(dataFolder)
        try writeJSON(file, settings)
    }

    /// Reading cost of each MCP server, measured the last time Hermes connected to it (name -> characters of tool descriptions).
    public func mcpCosts() -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: dataFolder + "/" + HermesAbilities.costsFile),
              let costs = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return costs
    }

    func recordMcpCosts(_ costs: [String: Int]) throws {
        lock.lock(); defer { lock.unlock() }
        try privateDirectory(dataFolder)
        var all = mcpCosts()
        for (name, characters) in costs { all[name] = characters }
        try writeJSON(dataFolder + "/" + HermesAbilities.costsFile, all)
    }
}

// MARK: Keys

/// Keys and other values Hermes reads from its environment (a search provider's key, an MCP server's token). One owner-only file in
/// the data folder. A value goes to the Hermes process by environment only; nothing here is ever shown again, written into a profile
/// or sent to the window or a phone, which are told only which names have a value.
public final class HermesKeyStore: @unchecked Sendable {
    let file: String
    private let dataFolder: String
    private let lock = NSLock()

    public init(dataFolder: String) {
        self.dataFolder = dataFolder
        self.file = dataFolder + "/" + HermesAbilities.keysFile
    }

    private func readUnlocked() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: file), let all = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return all
    }

    /// The names that have a value (never the values).
    public func names() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(readUnlocked().filter { !$0.value.isEmpty }.keys)
    }

    func values() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return readUnlocked()
    }

    /// A name is an environment variable (`BRAVE_SEARCH_API_KEY`) or an MCP value (`mcp.<server>.<NAME>`).
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^([A-Z][A-Z0-9_]{2,63}|mcp\\.[a-z0-9][a-z0-9_-]{0,39}\\.[A-Za-z_][A-Za-z0-9_]{0,63})$", options: .regularExpression) != nil
    }

    public func set(_ name: String, _ value: String) throws {
        guard Self.isValidName(name) else { throw BlackTeamError("That is not a name Hermes can read.") }
        guard !value.isEmpty, value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw BlackTeamError("Enter the value on one line, up to 4096 characters.")
        }
        lock.lock(); defer { lock.unlock() }
        var all = readUnlocked()
        all[name] = value
        try privateDirectory(dataFolder)
        try writeJSON(file, all)
    }

    public func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readUnlocked()
        guard all.removeValue(forKey: name) != nil else { return }
        try writeJSON(file, all)
    }

    /// Forgets every value of a server that was removed.
    func removeServer(_ server: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readUnlocked()
        let before = all.count
        all = all.filter { !$0.key.hasPrefix("mcp." + server + ".") }
        if all.count != before { try writeJSON(file, all) }
    }
}

// MARK: MCP servers

public enum McpRules {
    static let maxServers = 12
    static let maxArguments = 32

    /// Checks one server as the screen or the command line gives it. The rules are those of the app's external launchers: an absolute
    /// executable, literal arguments one per field, no shell, no typed JSON. A server reached by address must be on this computer.
    public static func validate(_ server: McpServer, others: [McpServer] = []) throws {
        guard server.name.range(of: "^[a-z0-9][a-z0-9_-]{0,39}$", options: .regularExpression) != nil else {
            throw BlackTeamError("Name the server with lowercase letters, digits, - or _ (up to 40 characters).")
        }
        if others.contains(where: { $0.name == server.name }) { throw BlackTeamError("There is already an MCP server called \(server.name).") }
        let hasCommand = !server.command.isEmpty, hasURL = !server.url.isEmpty
        guard hasCommand != hasURL else { throw BlackTeamError("Give either a program to run or an address on \(Place.this), not both.") }
        if hasCommand {
            try validateCommand(server.command)
            guard server.args.count <= maxArguments else { throw BlackTeamError("Use up to \(maxArguments) arguments.") }
            for argument in server.args { try validateArgument(argument) }
        } else {
            try validateURL(server.url)
            if !server.args.isEmpty { throw BlackTeamError("A server reached by address takes no arguments.") }
        }
        for name in server.envNames {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                throw BlackTeamError("\(name) is not a name an environment value can have.")
            }
        }
        if Set(server.envNames).count != server.envNames.count { throw BlackTeamError("Each environment value needs its own name.") }
    }

    static func validateCommand(_ command: String) throws {
        guard command.hasPrefix("/") else { throw BlackTeamError("Choose the program by its full path, starting with /.") }
        if command.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) || command.contains(where: { "$`;|&<>(){}*?!\"'\\".contains($0) }) {
            throw BlackTeamError("Give only the program's path here. Put each option in its own argument field; nothing is run through a shell.")
        }
        guard isExecutableFile(command) else { throw BlackTeamError("That program could not be found or is not allowed to run. Choose an installed executable.") }
    }

    static func validateArgument(_ argument: String) throws {
        guard argument.utf8.count <= 1024, !argument.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw BlackTeamError("An argument must be one line of up to 1024 characters.")
        }
        // Hermes expands ${...} inside its settings, which would make an argument something other than what was typed.
        if argument.contains("${") { throw BlackTeamError("Hermes would replace \"${\" in an argument with an environment value. Remove it, or use the environment value fields.") }
    }

    static func validateURL(_ text: String) throws {
        guard text.utf8.count <= 512, let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BlackTeamError("Use an address like http://127.0.0.1:8000/mcp.")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw BlackTeamError("Only a server on \(Place.this) can be added here. An address elsewhere would send your conversation off \(Place.this).")
        }
    }
}
