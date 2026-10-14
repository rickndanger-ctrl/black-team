import Foundation

// The actions behind Settings → Agents & apps → Hermes (tool groups, skills, plugins, web search, MCP servers) and the same things
// on the command line. Reading never starts an agent; the install's own Python is asked once for its tool table, and only after the
// person has connected Hermes.

public final class HermesAbilitiesService: @unchecked Sendable {
    public let dataFolder: String
    let integrations: Integrations
    let scripts: String?
    let home: String
    public let store: HermesAbilityStore
    public let keys: HermesKeyStore

    public init(dataFolder: String, integrations: Integrations, scripts: String?, home: String = NSHomeDirectory()) {
        self.dataFolder = dataFolder; self.integrations = integrations; self.scripts = scripts; self.home = home
        store = HermesAbilityStore(dataFolder: dataFolder)
        keys = HermesKeyStore(dataFolder: dataFolder)
    }

    /// The connected install, or nil.
    func install() -> HermesSettings? {
        guard let settings = try? integrations.read().hermes, settings.enabled, settings.source.hasPrefix("/") else { return nil }
        return settings
    }

    /// The install's answer: the saved one when it is still current, a fresh one when `refresh` or nothing is saved.
    func probe(_ settings: HermesSettings, refresh: Bool) async -> (probe: HermesProbe?, problem: String?) {
        if !refresh, let saved = HermesProbeRunner.cached(dataFolder: dataFolder, source: settings.source, python: settings.python, scripts: scripts) { return (saved, nil) }
        guard let scripts else { return (nil, "This copy of Black Team cannot read your Hermes.") }
        do { return (try await HermesProbeRunner.run(dataFolder: dataFolder, source: settings.source, python: settings.python, scripts: scripts), nil) }
        catch { return (nil, (error as? BlackTeamError)?.message ?? "Your Hermes could not be read.") }
    }

    // MARK: What the screens show

    /// Everything the Hermes screens show. No key or key value is in it, only which names have one.
    public func overview(context: Int, refresh: Bool = false) async -> JSONValue {
        guard let settings = install() else { return ["connected": false] }
        let (found, problem) = await probe(settings, refresh: refresh)
        let chosen = store.read()
        let plan = HermesProfilePlan.make(settings: settings, store: store, keys: keys, home: home)
        let plugins = HermesCatalog.plugins(source: settings.source, home: home)
        let skillList = HermesCatalog.skills(source: settings.source)
        let stored = keys.names()
        let costs = store.mcpCosts()
        let on = Set(chosen.chosenToolsets(legacy: settings))

        var groups: [JSONValue] = []
        if let found {
            for group in HermesCatalog.groups(found) {
                var item: [String: JSONValue] = ["name": .string(group.name), "description": .string(group.description), "label": .string(group.label.rawValue),
                                                 "labelText": .string(group.label.text), "on": .bool(on.contains(group.name)), "locked": .bool(group.lockedReason != nil)]
                if let reason = group.lockedReason { item["reason"] = .string(reason) }
                if let tokens = group.tokens { item["tokens"] = .number(Double(tokens)) }
                if let ready = group.ready { item["ready"] = .bool(ready) }
                groups.append(.object(item))
            }
        }

        // Skills.
        let wanted = Set(chosen.skills)
        let own = HermesAbilities.ownSkillsPath(dataFolder)
        let ownCount = HermesCatalog.ownSkillCount(own)
        let chosenSkills = skillList.skills.filter { wanted.contains($0.id) }
        func skillJSON(_ skill: HermesSkill, on: Bool?) -> JSONValue {
            var item: [String: JSONValue] = ["id": .string(skill.id), "name": .string(skill.name), "category": .string(skill.category), "description": .string(skill.description)]
            if let on { item["on"] = .bool(on) }
            return .object(item)
        }
        let categories = Dictionary(grouping: skillList.skills, by: { $0.category }).keys.sorted().map { category -> JSONValue in
            let members = skillList.skills.filter { $0.category == category }
            return ["name": .string(category), "description": .string(skillList.categoryDescriptions[category] ?? ""),
                    "skills": .array(members.map { skillJSON($0, on: wanted.contains($0.id)) })]
        }
        let skillsIndex = HermesCatalog.indexCharacters(for: chosenSkills, categoryDescriptions: skillList.categoryDescriptions) + (chosen.ownSkills ? ownCount * 200 : 0)

        // Plugins.
        let pluginRows = plugins.filter { $0.kind != .provider }.map { plugin -> JSONValue in
            var item: [String: JSONValue] = ["key": .string(plugin.key), "name": .string(plugin.name), "description": .string(plugin.description),
                                             "label": .string(plugin.label.rawValue), "labelText": .string(plugin.label.text), "yours": .bool(plugin.yours),
                                             "on": .bool(chosen.plugins.contains(plugin.key)), "locked": .bool(plugin.lockedReason != nil),
                                             "needs": .array(plugin.env.map { ["name": .string($0), "configured": .bool(stored.contains($0))] })]
            if let reason = plugin.lockedReason { item["reason"] = .string(reason) }
            if let note = plugin.note { item["note"] = .string(note) }
            return .object(item)
        }
        let providers = HermesCatalog.webProviders(from: plugins, source: settings.source).map { provider -> JSONValue in
            var item: [String: JSONValue] = ["name": .string(provider.name), "description": .string(String(provider.description.prefix(200))), "label": .string(provider.label.rawValue),
                                             "labelText": .string(provider.label.text), "needsKey": .bool(!provider.env.isEmpty),
                                             "needs": .array(provider.env.map { ["name": .string($0), "configured": .bool(stored.contains($0))] })]
            if let package = provider.missingPackage { item["missingPackage"] = .string(package) }
            return .object(item)
        }

        let mcp = chosen.mcp.map { server -> JSONValue in
            var item: [String: JSONValue] = ["name": .string(server.name), "command": .string(server.command), "args": .array(server.args.map { .string($0) }),
                                             "url": .string(server.url), "enabled": .bool(server.enabled),
                                             "env": .array(server.envNames.map { ["name": .string($0), "configured": .bool(stored.contains(server.keyName($0)))] })]
            if let characters = costs[server.name] { item["tokens"] = .number(Double(HermesAbilities.tokens(characters))) }
            return .object(item)
        }

        // The running total: tool descriptions, the skill index, plugin tools and MCP servers measured on a past connect.
        var total: [String: JSONValue] = ["context": .number(Double(context))]
        if let found {
            var tools = Set<String>()
            for set in found.toolsets where plan.toolsets.contains(set.name) { tools.formUnion(set.tools) }
            for plugin in plugins where chosen.plugins.contains(plugin.key) { tools.formUnion(plugin.tools) }
            var characters = found.companionCharacters + tools.reduce(0) { $0 + (found.tools[$1]?.chars ?? 0) }
            characters += chosen.mcp.filter { $0.enabled }.reduce(0) { $0 + (costs[$1.name] ?? 0) }
            if !plan.skillLinks.isEmpty { characters += skillsIndex }
            let tokens = HermesAbilities.tokens(characters)
            total["tokens"] = .number(Double(tokens))
            if let warning = HermesCatalog.warning(tokens: tokens, context: context) { total["warning"] = .string(warning) }
        }

        var result: [String: JSONValue] = [
            "connected": true, "source": .string(settings.source), "groups": .array(groups), "total": .object(total),
            "companionTokens": .number(Double(HermesAbilities.tokens(found?.companionCharacters ?? 0))),
            "skills": ["linked": .bool(!plan.skillLinks.isEmpty), "categories": .array(categories),
                       "optional": .array(skillList.optional.map { skillJSON($0, on: nil) }),
                       "own": ["on": .bool(chosen.ownSkills), "count": .number(Double(ownCount)), "folder": .string(own)],
                       "indexTokens": .number(Double(HermesAbilities.tokens(skillsIndex)))],
            "plugins": .array(pluginRows),
            "providers": .array(plugins.filter { $0.kind == .provider && $0.category != "web" }.map { ["key": .string($0.key), "name": .string($0.name), "label": .string($0.label.text)] }),
            "web": ["selected": .string(chosen.webSearch), "providers": .array(providers)],
            "mcp": .array(mcp),
        ]
        if let problem { result["problem"] = .string(problem) }
        return .object(result)
    }

    // MARK: Changes

    /// Saves some of the choices (each key given replaces that part). Checked against what the connected install offers.
    @discardableResult
    public func save(_ input: [String: JSONValue], refreshOnMissing: Bool = true) async throws -> JSONValue {
        guard input.keys.allSatisfy({ ["toolsets", "skills", "ownSkills", "plugins", "webSearch", "mcp"].contains($0) }) else { throw BlackTeamError("Unsupported Hermes setting.") }
        guard let settings = install() else { throw BlackTeamError("Connect Hermes first.") }
        var next = store.read()
        let (found, _) = await probe(settings, refresh: false)

        func strings(_ key: String, max: Int) throws -> [String]? {
            guard let value = input[key] else { return nil }
            guard let list = value.array, list.count <= max, list.allSatisfy({ $0.string != nil }) else { throw BlackTeamError("Invalid Hermes setting.") }
            var seen = Set<String>()
            return list.compactMap { $0.string }.filter { seen.insert($0).inserted }
        }
        if let names = try strings("toolsets", max: 200) {
            let groups = found.map { HermesCatalog.groups($0) }
            for name in names where name != HermesAbilities.companion {
                guard name.range(of: "^[a-z][a-z0-9_-]{0,40}$", options: .regularExpression) != nil else { throw BlackTeamError("Unknown tool group.") }
                if let groups {
                    guard let group = groups.first(where: { $0.name == name }) else { throw BlackTeamError("Your Hermes has no tool group called \(name).") }
                    if let reason = group.lockedReason { throw BlackTeamError("\(name): \(reason)") }
                } else if name.hasPrefix("hermes-") || HermesCatalog.serviceGroups.contains(name) { throw BlackTeamError("\(name): \(HermesCatalog.serviceReason)") }
            }
            next.toolsets = names.filter { $0 != HermesAbilities.companion }
        }
        if let ids = try strings("skills", max: 1000) {
            let known = Set(HermesCatalog.skills(source: settings.source).skills.map { $0.id })
            if let missing = ids.first(where: { !known.contains($0) }) { throw BlackTeamError("Your Hermes has no skill \(missing). Optional skills stay off.") }
            next.skills = ids
        }
        if let own = input["ownSkills"] {
            guard let flag = own.bool else { throw BlackTeamError("Invalid Hermes setting.") }
            next.ownSkills = flag
        }
        if let keysList = try strings("plugins", max: 200) {
            let all = HermesCatalog.plugins(source: settings.source, home: home)
            for key in keysList {
                guard let plugin = all.first(where: { $0.key == key }), plugin.kind == .general else { throw BlackTeamError("Your Hermes has no plugin \(key) that can be switched on here.") }
                if let reason = plugin.lockedReason { throw BlackTeamError("\(plugin.name): \(reason)") }
            }
            next.plugins = keysList
        }
        if let provider = input["webSearch"] {
            guard let name = provider.string else { throw BlackTeamError("Invalid Hermes setting.") }
            let known = HermesCatalog.webProviders(from: HermesCatalog.plugins(source: settings.source, home: home), source: settings.source).map { $0.name }
            guard name.isEmpty || known.contains(name) else { throw BlackTeamError("Your Hermes has no web search provider called \(name).") }
            next.webSearch = name
        }
        if let value = input["mcp"] {
            guard let list = value.array, list.count <= McpRules.maxServers else { throw BlackTeamError("Add up to \(McpRules.maxServers) MCP servers.") }
            var servers: [McpServer] = []
            for item in list {
                guard let object = item.object, object.keys.allSatisfy({ ["name", "command", "args", "url", "envNames", "enabled"].contains($0) }),
                      let name = object["name"]?.string else { throw BlackTeamError("Invalid MCP server.") }
                let server = McpServer(name: name, command: object["command"]?.string ?? "", args: (object["args"]?.array ?? []).compactMap { $0.string },
                                       url: object["url"]?.string ?? "", envNames: (object["envNames"]?.array ?? []).compactMap { $0.string },
                                       enabled: object["enabled"]?.bool ?? true)
                if (object["args"]?.array ?? []).count != server.args.count || (object["envNames"]?.array ?? []).count != server.envNames.count { throw BlackTeamError("Invalid MCP server.") }
                try McpRules.validate(server, others: servers)
                servers.append(server)
            }
            for old in next.mcp where !servers.contains(where: { $0.name == old.name }) { try keys.removeServer(old.name) }
            next.mcp = servers
        }
        try store.write(next)
        return ["saved": true]
    }

    /// Stores or forgets one key. Only a name something the person switched on declares, or one of an MCP server, is accepted.
    public func setKey(name: String, value: String?) async throws {
        guard let settings = install() else { throw BlackTeamError("Connect Hermes first.") }
        guard HermesKeyStore.isValidName(name) else { throw BlackTeamError("That is not a name Hermes can read.") }
        let chosen = store.read()
        var allowed = Set<String>()
        for server in chosen.mcp { for env in server.envNames { allowed.insert(server.keyName(env)) } }
        let plugins = HermesCatalog.plugins(source: settings.source, home: home)
        for plugin in plugins where plugin.lockedReason == nil { allowed.formUnion(plugin.env) }
        guard allowed.contains(name) else { throw BlackTeamError("Nothing in your Hermes asks for \(name).") }
        if let value { try keys.set(name, value) } else { try keys.remove(name) }
    }
}

extension Backend {
    /// The app's scripts folder, set only by the Linux desktop service.
    var desktopScripts: String? { locked { desktopOptions?.scripts } }
}
