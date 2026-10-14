import Foundation
import BlackTeamKit

// black-team hermes tools | skills | plugins | mcp | key: the same choices as Settings → Agents & apps → Hermes, from the terminal.
// Reads the connected Hermes (connect it in the app first); changes only Black Team's own settings, never Hermes's.

/// The app's scripts folder: --scripts, BLACK_TEAM_SCRIPTS, or the `scripts` folder beside the program's folder in the Linux package.
@MainActor private func scriptsFolder() -> String? {
    if let given = option("--scripts") ?? ProcessInfo.processInfo.environment["BLACK_TEAM_SCRIPTS"] { return given }
    let program = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let beside = program.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts").path
    return FileManager.default.fileExists(atPath: beside + "/hermes-abilities.py") ? beside : nil
}

private func tokensText(_ value: JSONValue?) -> String { value?.int.map { "about \($0) tokens" } ?? "cost not measured" }

@MainActor func runHermesCommand(_ backend: Backend) async throws -> Int32 {
    let service = HermesAbilitiesService(dataFolder: backend.dataFolder, integrations: backend.integrations, scripts: scriptsFolder())
    let context = (try? backend.configStore.read().model.context) ?? 0
    let area = arguments.isEmpty ? "" : arguments.removeFirst()
    let action = arguments.first.flatMap { ["list", "on", "off", "add", "remove", "search", "set", "forget", "refresh"].contains($0) ? $0 : nil }
    if action != nil { arguments.removeFirst() }
    let view = await service.overview(context: context, refresh: action == "refresh")
    guard view["connected"]?.bool == true else { fail("Hermes is not connected. Open Settings → Agents & apps and choose Connect Hermes first.") }
    if let problem = view["problem"]?.string { FileHandle.standardError.write(Data(("note: " + problem + "\n").utf8)) }

    /// The names of the things now on, with `names` switched on or off.
    func changed(_ current: [String], _ names: [String]) -> [String] {
        var next = current
        for name in names { if action == "on" { if !next.contains(name) { next.append(name) } } else { next.removeAll { $0 == name } } }
        return next
    }
    func requireNames() -> [String] {
        guard !arguments.isEmpty else { fail("Name what to switch \(action ?? "")."); }
        return arguments
    }

    switch area {
    case "tools":
        if action == "on" || action == "off" {
            let names = requireNames()
            let current = (view["groups"]?.array ?? []).filter { $0["on"]?.bool == true }.compactMap { $0["name"]?.string }
            try await service.save(["toolsets": .array(changed(current, names).map { .string($0) })])
            print("Saved. New Hermes conversations use these tool groups.")
            return 0
        }
        if asJSON { print(view["groups"]!.text(pretty: true)); return 0 }
        for group in view["groups"]?.array ?? [] {
            let state = group["locked"]?.bool == true ? "unavailable" : group["on"]?.bool == true ? "on" : "off"
            print("\(group["name"]?.string ?? "")\t\(state)\t\(group["labelText"]?.string ?? "")\t\(tokensText(group["tokens"]))")
            if let reason = group["reason"]?.string { print("    \(reason)") }
        }
        let total = view["total"]
        print("total: \(tokensText(total?["tokens"])) in every message, counting Black Team's own file-delivery tool; model context \(total?["context"]?.int ?? 0)")
        if let warning = total?["warning"]?.string { print("warning: \(warning)") }
        return 0

    case "skills":
        let skills = view["skills"]
        let all = (skills?["categories"]?.array ?? []).flatMap { $0["skills"]?.array ?? [] }
        if action == "on" || action == "off" {
            // A category name switches all of its skills.
            var ids: [String] = []
            for name in requireNames() {
                let inCategory = all.filter { $0["category"]?.string == name }.compactMap { $0["id"]?.string }
                ids += inCategory.isEmpty ? [name] : inCategory
            }
            let current = all.filter { $0["on"]?.bool == true }.compactMap { $0["id"]?.string }
            try await service.save(["skills": .array(changed(current, ids).map { .string($0) })])
            print("Saved. New Hermes conversations link these skills.")
            return 0
        }
        let query = action == "search" ? arguments.joined(separator: " ").lowercased() : ""
        let shown = all.filter { query.isEmpty || ($0["id"]?.string ?? "").lowercased().contains(query) || ($0["description"]?.string ?? "").lowercased().contains(query) }
        if asJSON { print(JSONValue.array(shown).text(pretty: true)); return 0 }
        for skill in shown { print("\(skill["id"]?.string ?? "")\t\(skill["on"]?.bool == true ? "on" : "off")\t\(skill["description"]?.string ?? "")") }
        if query.isEmpty {
            for skill in skills?["optional"]?.array ?? [] { print("\(skill["id"]?.string ?? "")\toptional, off\t\(skill["description"]?.string ?? "")") }
            print("your own skills: \(skills?["own"]?["count"]?.int ?? 0) in \(skills?["own"]?["folder"]?.string ?? "")")
            print("skill list in every message: \(tokensText(skills?["indexTokens"]))")
        }
        return 0

    case "plugins":
        if action == "set" {
            guard arguments.count >= 1, arguments[0] == "web" else { fail("Usage: black-team hermes plugins set web <provider> (or \"none\")", code: 2) }
            let name = arguments.count > 1 && arguments[1] != "none" ? arguments[1] : ""
            try await service.save(["webSearch": .string(name)])
            print("Saved.")
            return 0
        }
        if action == "on" || action == "off" {
            let current = (view["plugins"]?.array ?? []).filter { $0["on"]?.bool == true }.compactMap { $0["key"]?.string }
            try await service.save(["plugins": .array(changed(current, requireNames()).map { .string($0) })])
            print("Saved.")
            return 0
        }
        if asJSON { print(view["plugins"]!.text(pretty: true)); return 0 }
        for plugin in view["plugins"]?.array ?? [] {
            let state = plugin["locked"]?.bool == true ? "unavailable" : plugin["on"]?.bool == true ? "on" : "off"
            print("\(plugin["key"]?.string ?? "")\t\(state)\t\(plugin["labelText"]?.string ?? "")")
            if let reason = plugin["reason"]?.string { print("    \(reason)") }
        }
        print("web search: \(view["web"]?["selected"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "not chosen")  (black-team hermes plugins set web <provider>)")
        return 0

    case "mcp":
        let current = (view["mcp"]?.array ?? []).map { server -> JSONValue in
            .object(["name": server["name"] ?? "", "command": server["command"] ?? "", "args": server["args"] ?? [], "url": server["url"] ?? "",
                     "envNames": .array((server["env"]?.array ?? []).compactMap { $0["name"] }), "enabled": server["enabled"] ?? true])
        }
        switch action {
        case "add":
            // black-team hermes mcp add <name> (--url <address> | <absolute program> [arguments...]) [--env NAME]...
            var rest = arguments, envNames: [String] = []
            while let at = rest.firstIndex(of: "--env"), at + 1 < rest.count { envNames.append(rest[at + 1]); rest.removeSubrange(at...(at + 1)) }
            guard rest.count >= 2 else { fail("Usage: black-team hermes mcp add <name> <absolute program> [arguments...] [--env NAME]\n   or: black-team hermes mcp add <name> --url http://127.0.0.1:<port>/<path>", code: 2) }
            var server: [String: JSONValue] = ["name": .string(rest[0]), "envNames": .array(envNames.map { .string($0) }), "enabled": true]
            if rest[1] == "--url" { guard rest.count == 3 else { fail("Give one address after --url.", code: 2) }; server["url"] = .string(rest[2]) }
            else { server["command"] = .string(rest[1]); server["args"] = .array(rest.dropFirst(2).map { .string($0) }) }
            try await service.save(["mcp": .array(current + [.object(server)])])
            print("Saved. Values for --env names are set with: black-team hermes key set mcp.\(rest[0]).<NAME>")
            return 0
        case "remove", "on", "off":
            let names = requireNames()
            let next = current.compactMap { server -> JSONValue? in
                guard let name = server["name"]?.string, names.contains(name) else { return server }
                if action == "remove" { return nil }
                var object = server.object ?? [:]
                object["enabled"] = .bool(action == "on")
                return .object(object)
            }
            try await service.save(["mcp": .array(next)])
            print("Saved.")
            return 0
        default:
            if asJSON { print(view["mcp"]!.text(pretty: true)); return 0 }
            for server in view["mcp"]?.array ?? [] {
                let target = (server["url"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? ([server["command"]?.string ?? ""] + (server["args"]?.array ?? []).compactMap { $0.string }).joined(separator: " ")
                print("\(server["name"]?.string ?? "")\t\(server["enabled"]?.bool == true ? "on" : "off")\t\(tokensText(server["tokens"]))\t\(target)")
            }
            return 0
        }

    case "key":
        guard let name = arguments.first else { fail("Usage: black-team hermes key set <NAME> (the value is read from standard input)\n       black-team hermes key forget <NAME>", code: 2) }
        if action == "forget" { try await service.setKey(name: name, value: nil); print("Forgotten."); return 0 }
        guard action == "set" else { fail("Usage: black-team hermes key set <NAME>", code: 2) }
        // The value comes from standard input, so it is not in the command line or the shell history.
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { fail("Pipe the value in: printf '%s' \"$VALUE\" | black-team hermes key set \(name)") }
        try await service.setKey(name: name, value: line)
        print("Saved. It is never shown again.")
        return 0

    default:
        fail("Usage: black-team hermes tools|skills|plugins|mcp|key (black-team hermes --help)", code: 2)
    }
}
