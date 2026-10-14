import Foundation

// How the person's choices become a conversation's private Hermes profile: the tool groups passed to the runner, the settings added
// to the profile's config.yaml, the skills and plugins linked into it, and the environment (keys) the Hermes process is started
// with. Reads files only; the runner (HermesRunner.swift) applies the result.

struct HermesProfilePlan {
    var toolsets: [String]
    /// `plugins.enabled`
    var enabledPlugins: [String]
    /// Plugins the person installed under their own Hermes, linked into the profile's plugins folder: name -> folder.
    var pluginLinks: [String: String]
    /// Relative path inside the profile's `skills` folder -> what it links to.
    var skillLinks: [String: String]
    var mcpServers: [String: JSONValue]
    var web: [String: JSONValue]
    /// Environment for the Hermes process only. Never written to a file in the profile.
    var environment: [String: String]

    static func make(settings: HermesSettings, store: HermesAbilityStore, keys: HermesKeyStore, home: String = NSHomeDirectory()) -> HermesProfilePlan {
        let chosen = store.read()
        let source = settings.source
        let all = HermesCatalog.plugins(source: source, home: home)
        var toolsets = [HermesAbilities.companion] + chosen.chosenToolsets(legacy: settings).filter { $0 != HermesAbilities.companion }

        // Skills: each chosen skill is linked, not copied, under the category it has in the install.
        var skillLinks: [String: String] = [:]
        let list = HermesCatalog.skills(source: source)
        let wanted = Set(chosen.skills)
        for skill in list.skills where wanted.contains(skill.id) {
            skillLinks[skill.id] = skill.path
            let description = source + "/skills/" + skill.category + "/DESCRIPTION.md"
            if CoreFS.exists(description) { skillLinks[skill.category + "/DESCRIPTION.md"] = description }
        }
        let own = HermesAbilities.ownSkillsPath(store.dataFolder)
        if chosen.ownSkills, HermesCatalog.ownSkillCount(own) > 0 { skillLinks["own"] = own }
        if !skillLinks.isEmpty, !toolsets.contains("skills") { toolsets.append("skills") }

        // Plugins: Hermes's own are named in `plugins.enabled`; one the person installed is also linked in.
        var enabled = [HermesAbilities.companion + "-tools"]
        var links: [String: String] = [:]
        var environment: [String: String] = [:]
        let stored = keys.values()
        func pass(_ names: [String]) { for name in names { if let value = stored[name], !value.isEmpty { environment[name] = value } } }
        for plugin in all where chosen.plugins.contains(plugin.key) && plugin.kind == .general && plugin.lockedReason == nil {
            enabled.append(plugin.key)
            if plugin.yours {
                links[plugin.key] = plugin.path
                if plugin.name != plugin.key { enabled.append(plugin.name) }
            }
            // A plugin's tools join the list under the plugin's own group name, when it has tools.
            if !plugin.tools.isEmpty { toolsets.append((plugin.key as NSString).lastPathComponent) }
            pass(plugin.env)
        }

        // Web search: the chosen provider only. Hermes would otherwise fall back to free vendor services without being asked.
        var web: [String: JSONValue] = ["keyless_fallback": false]
        if !chosen.webSearch.isEmpty {
            web["search_backend"] = .string(chosen.webSearch)
            for provider in HermesCatalog.webProviders(from: all, source: source) where provider.name == chosen.webSearch { pass(provider.env) }
        }

        var servers: [String: JSONValue] = [:]
        for server in chosen.mcp where server.enabled {
            var entry: [String: JSONValue] = [:]
            if !server.command.isEmpty {
                entry["command"] = .string(server.command)
                entry["args"] = .array(server.args.map { .string($0) })
            } else {
                entry["url"] = .string(server.url)
            }
            if !server.envNames.isEmpty {
                var values: [String: JSONValue] = [:]
                for name in server.envNames {
                    values[name] = .string("${" + server.variable(name) + "}")
                    if let value = stored[server.keyName(name)], !value.isEmpty { environment[server.variable(name)] = value }
                }
                entry["env"] = .object(values)
            }
            servers[server.name] = .object(entry)
            toolsets.append("mcp-" + server.name)
        }
        var seen = Set<String>()
        return HermesProfilePlan(toolsets: toolsets.filter { seen.insert($0).inserted }, enabledPlugins: enabled, pluginLinks: links, skillLinks: skillLinks,
                                 mcpServers: servers, web: web, environment: environment)
    }

    /// The settings this plan adds to the profile's config.yaml.
    func configExtras() -> [String: JSONValue] {
        var extras: [String: JSONValue] = ["plugins": ["enabled": .array(enabledPlugins.map { .string($0) })], "web": .object(web)]
        if !mcpServers.isEmpty { extras["mcp_servers"] = .object(mcpServers) }
        return extras
    }

    /// Makes the profile's `skills` and `plugins` folders hold exactly the links this plan names. Only links Black Team made are
    /// ever removed; a skill the agent wrote there itself is left alone.
    func link(into profile: String) throws {
        let manager = FileManager.default
        let skills = profile + "/skills"
        try privateDirectory(skills)
        func reconcile(_ root: String, wanted: [String: String]) throws {
            for case let item as String in manager.enumerator(atPath: root)?.allObjects ?? [] where item.split(separator: "/").count <= 2 {
                let path = root + "/" + item
                guard CoreFS.isSymlink(path) else { continue }
                let target = try? manager.destinationOfSymbolicLink(atPath: path)
                if wanted[item] == nil || wanted[item] != target { try manager.removeItem(atPath: path) }
            }
            for (relative, target) in wanted {
                let path = root + "/" + relative
                if CoreFS.exists(path) || CoreFS.isSymlink(path) { continue }
                let parent = (path as NSString).deletingLastPathComponent
                if parent != root { try privateDirectory(parent) }
                try manager.createSymbolicLink(atPath: path, withDestinationPath: target)
            }
            // Category folders left empty by a removed link.
            for entry in (try? manager.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + entry
                var isDirectory: ObjCBool = false
                if !CoreFS.isSymlink(path), manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                   (try? manager.contentsOfDirectory(atPath: path))?.isEmpty == true { try? manager.removeItem(atPath: path) }
            }
        }
        try reconcile(skills, wanted: skillLinks)
        let plugins = profile + "/plugins"
        try privateDirectory(plugins)
        var pluginWanted = pluginLinks.mapValues { $0 }
        // Black Team's own plugin keeps its link, made by the runner.
        if let own = try? manager.destinationOfSymbolicLink(atPath: plugins + "/companion-tools") { pluginWanted["companion-tools"] = own }
        try reconcile(plugins, wanted: pluginWanted)
    }
}

/// What the runner says about the tools of a turn: the characters of each tool description Hermes sent to the model. Used to show
/// the reading cost of each MCP server once it has connected once.
enum HermesToolReport {
    static func record(_ report: JSONValue, servers: [String], store: HermesAbilityStore) {
        guard let tools = report["tools"]?.object, !servers.isEmpty else { return }
        var costs: [String: Int] = [:]
        for server in servers {
            let prefix = "mcp__" + server.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression) + "__"
            let sizes = tools.filter { $0.key.hasPrefix(prefix) }.compactMap { $0.value.int }
            costs[server] = sizes.reduce(0, +)
        }
        try? store.recordMcpCosts(costs)
    }
}
