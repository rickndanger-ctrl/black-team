import Foundation

// The choices a person makes about how Code spends and checks: the ceilings, the review switch, the summary switch, the prices of
// cloud models and what skills may do. Kept in the data folder as plain JSON (`code-settings.json`), with a small file per
// conversation (`code/<conversation id>.json`) for the choices made for that conversation alone.

/// Choices that apply to every Code conversation unless a conversation overrides them.
public struct CodeGlobalSettings: Equatable, Sendable {
    /// Most tokens (read plus written) one conversation may use. 0 means no limit.
    public var tokenCeiling = CodeGlobalSettings.defaultTokenCeiling
    /// Most money one cloud conversation may spend, at the prices set below. 0 means no limit.
    public var moneyCeiling = 0.0
    /// Nil leaves the default: on for cloud models, off for models on this computer.
    public var check: Bool?
    public var summarize: Bool?
    /// A skill the model writes is saved without asking (off unless the person turns it on).
    public var saveSkillsWithoutAsking = false
    /// The model may save skills into the project's own `skills/` folder.
    public var projectSkillsWritable = false
    /// Skills the person turned off, by name.
    public var skillsOff: [String] = []
    /// Prices per million tokens, by `service/model`. Nothing is built in.
    public var prices: [String: ModelPrice] = [:]

    public static let defaultTokenCeiling = 2_000_000
    public init() {}

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "tokenCeiling": .number(Double(tokenCeiling)), "moneyCeiling": .number(moneyCeiling),
            "saveSkillsWithoutAsking": .bool(saveSkillsWithoutAsking), "projectSkillsWritable": .bool(projectSkillsWritable),
            "skillsOff": .array(skillsOff.map { .string($0) }),
            "prices": .object(prices.mapValues { $0.json }),
        ]
        if let check { object["check"] = .bool(check) }
        if let summarize { object["summarize"] = .bool(summarize) }
        return .object(object)
    }

    init(json: JSONValue?) {
        if let ceiling = json?["tokenCeiling"]?.int, ceiling >= 0 { tokenCeiling = ceiling }
        if let money = json?["moneyCeiling"]?.double, money >= 0, money.isFinite { moneyCeiling = money }
        check = json?["check"]?.bool; summarize = json?["summarize"]?.bool
        saveSkillsWithoutAsking = json?["saveSkillsWithoutAsking"]?.bool == true
        projectSkillsWritable = json?["projectSkillsWritable"]?.bool == true
        skillsOff = (json?["skillsOff"]?.array ?? []).compactMap(\.string)
        for (key, value) in json?["prices"]?.object ?? [:] { if let price = ModelPrice(json: value) { prices[key] = price } }
    }

    /// The key a cloud model's price is kept under.
    public static func priceKey(host: String, model: String) -> String { "\(host)/\(model)" }
}

/// Choices made for one conversation. Nil means "as usual".
public struct CodeThreadSettings: Equatable, Sendable {
    public var tokenCeiling: Int?
    public var moneyCeiling: Double?
    public var check: Bool?
    public var summarize: Bool?
    public init() {}

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let tokenCeiling { object["tokenCeiling"] = .number(Double(tokenCeiling)) }
        if let moneyCeiling { object["moneyCeiling"] = .number(moneyCeiling) }
        if let check { object["check"] = .bool(check) }
        if let summarize { object["summarize"] = .bool(summarize) }
        return .object(object)
    }

    init(json: JSONValue?) {
        if let ceiling = json?["tokenCeiling"]?.int, ceiling >= 0 { tokenCeiling = ceiling }
        if let money = json?["moneyCeiling"]?.double, money >= 0, money.isFinite { moneyCeiling = money }
        check = json?["check"]?.bool; summarize = json?["summarize"]?.bool
    }
}

/// What applies to a conversation now.
public struct CodeEffective: Equatable, Sendable {
    public var tokenCeiling: Int
    public var moneyCeiling: Double
    public var check: Bool
    public var summarize: Bool
    public var price: ModelPrice?
}

public final class CodeSettingsStore: @unchecked Sendable {
    public let dataFolder: String
    private let lock = NSLock()
    public init(dataFolder: String) { self.dataFolder = dataFolder }

    private var globalFile: String { dataFolder + "/code-settings.json" }
    private func threadFile(_ id: String) -> String { dataFolder + "/code/" + id + ".json" }

    private func read(_ path: String) -> JSONValue? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONValue.parse(data)
    }

    public func global() -> CodeGlobalSettings { lock.lock(); defer { lock.unlock() }; return CodeGlobalSettings(json: read(globalFile)) }

    public func saveGlobal(_ settings: CodeGlobalSettings) throws {
        lock.lock(); defer { lock.unlock() }
        try privateDirectory(dataFolder)
        try writeJSON(globalFile, settings.json)
    }

    /// Changes the global choices under one lock, so two changes at once are both kept.
    @discardableResult
    public func updateGlobal(_ change: (inout CodeGlobalSettings) throws -> Void) throws -> CodeGlobalSettings {
        lock.lock(); defer { lock.unlock() }
        var settings = CodeGlobalSettings(json: read(globalFile))
        try change(&settings)
        try privateDirectory(dataFolder)
        try writeJSON(globalFile, settings.json)
        return settings
    }

    public func thread(_ id: String) -> CodeThreadSettings {
        guard Self.valid(id) else { return CodeThreadSettings() }
        lock.lock(); defer { lock.unlock() }
        return CodeThreadSettings(json: read(threadFile(id)))
    }

    @discardableResult
    public func updateThread(_ id: String, _ change: (inout CodeThreadSettings) throws -> Void) throws -> CodeThreadSettings {
        guard Self.valid(id) else { throw BlackTeamError("This conversation has no valid id.") }
        lock.lock(); defer { lock.unlock() }
        var settings = CodeThreadSettings(json: read(threadFile(id)))
        try change(&settings)
        try privateDirectory(dataFolder + "/code")
        try writeJSON(threadFile(id), settings.json)
        return settings
    }

    static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 80 && !id.contains("/") && !id.contains("..") }

    /// The choices that apply now. A cloud model checks its work and summarizes what it trims unless told not to; a model on this
    /// computer does neither unless told to, because each costs minutes of reading.
    public func effective(thread id: String, cloud: Bool, host: String, model: String) -> CodeEffective {
        let all = global(), mine = thread(id)
        return CodeEffective(tokenCeiling: mine.tokenCeiling ?? all.tokenCeiling, moneyCeiling: cloud ? (mine.moneyCeiling ?? all.moneyCeiling) : 0,
                             check: mine.check ?? all.check ?? cloud, summarize: mine.summarize ?? all.summarize ?? cloud,
                             price: cloud ? all.prices[CodeGlobalSettings.priceKey(host: host, model: model)] : nil)
    }
}
