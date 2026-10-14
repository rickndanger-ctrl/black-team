import Foundation

// What the person can do with a Code run beyond sending and stopping: pause it, let it go on, and set how it spends and checks.
// The engine reads the settings itself at each step (Engine/CodeSettings.swift); this is the way in for the window and the terminal.

extension Backend {
    /// The settings store, and the skills kept beside the conversations. The engine shares both.
    public var codeSettings: CodeSettingsStore { CodeSettingsStore(dataFolder: dataFolder) }
    public var skills: SkillStore { SkillStore(dataFolder: dataFolder, settings: codeSettings) }

    /// Asks the running Code job to pause at its next step boundary; a tool that is running finishes first. False when none is running.
    @discardableResult
    public func pause() -> Bool {
        lock.lock(); let current = job; lock.unlock()
        guard let current, current.kind == "agent", current.state == "running", !current.phase.isEmpty else { return false }
        current.requestPause()
        return true
    }

    /// Lets a paused Code job go on. False when none is running.
    @discardableResult
    public func resume() -> Bool {
        lock.lock(); let current = job; lock.unlock()
        guard let current, current.kind == "agent", current.state == "running" else { return false }
        current.resume()
        return true
    }

    /// Ctrl-\\ in the terminal: pauses a running Code job, or lets a paused one go on. Nil when no Code job is running.
    public func togglePause() -> String? {
        lock.lock(); let current = job; lock.unlock()
        guard let current, current.kind == "agent", current.state == "running", !current.phase.isEmpty else { return nil }
        if current.pauseRequested { current.resume(); return "Continuing." }
        current.requestPause()
        return "Pausing after this step. Press Ctrl-\\ again to continue."
    }

    /// The model in use as the settings know it: the service host and model id a cloud price is kept under.
    public func codeModelKey() -> (cloud: Bool, host: String, model: String, name: String) {
        guard let model = try? configStore.read().model else { return (false, "", "", "") }
        let cloud = model.source == "cloud"
        return (cloud, cloud ? cloudHost(model.endpoint, rules: cloudRules) : "", model.id, model.name)
    }

    /// Everything the window shows in a conversation's Code settings: what is set, what applies, and the price of the model in use.
    public func codeSettingsView(thread id: String?) -> JSONValue {
        let all = codeSettings.global()
        let key = codeModelKey()
        let mine = id.map { codeSettings.thread($0) } ?? CodeThreadSettings()
        let effective = codeSettings.effective(thread: id ?? "", cloud: key.cloud, host: key.host, model: key.model)
        var model: [String: JSONValue] = ["cloud": .bool(key.cloud), "name": .string(key.name)]
        if key.cloud, let price = all.prices[CodeGlobalSettings.priceKey(host: key.host, model: key.model)] { model["price"] = price.json }
        var view: [String: JSONValue] = [
            "model": .object(model),
            "tokenCeiling": .number(Double(effective.tokenCeiling)), "moneyCeiling": .number(effective.moneyCeiling),
            "check": .bool(effective.check), "summarize": .bool(effective.summarize),
            "defaults": ["tokenCeiling": .number(Double(all.tokenCeiling)), "moneyCeiling": .number(all.moneyCeiling)],
            "saveSkillsWithoutAsking": .bool(all.saveSkillsWithoutAsking), "projectSkillsWritable": .bool(all.projectSkillsWritable),
        ]
        view["own"] = ["check": mine.check.map { .bool($0) } ?? .null, "summarize": mine.summarize.map { .bool($0) } ?? .null]
        return .object(view)
    }

    /// Changes Code settings. `thread` limits the choice to that conversation; prices and the skill switches are always global.
    @discardableResult
    public func changeCodeSettings(_ input: [String: JSONValue]) throws -> JSONValue {
        let allowed: Set<String> = ["thread", "tokenCeiling", "moneyCeiling", "check", "summarize", "price", "saveSkillsWithoutAsking", "projectSkillsWritable"]
        guard input.keys.allSatisfy({ allowed.contains($0) }) else { throw BlackTeamError("Unsupported Code setting.") }
        func whole(_ value: JSONValue?, _ label: String) throws -> Int? {
            guard let value, value != .null else { return nil }
            guard let number = value.double, number.rounded() == number, number >= 0, number <= 1e12 else { throw BlackTeamError("\(label) must be a whole number, 0 or more (0 means no limit).") }
            return Int(number)
        }
        func amount(_ value: JSONValue?, _ label: String) throws -> Double? {
            guard let value, value != .null else { return nil }
            guard let number = value.double, number >= 0, number <= 1e9, number.isFinite else { throw BlackTeamError("\(label) must be a number, 0 or more (0 means no limit).") }
            return number
        }
        func flag(_ value: JSONValue?, _ label: String) throws -> Bool? {
            guard let value, value != .null else { return nil }
            guard let on = value.bool else { throw BlackTeamError("\(label) must be on or off.") }
            return on
        }
        let tokens = try whole(input["tokenCeiling"], "The token limit"), money = try amount(input["moneyCeiling"], "The spending limit")
        let check = try flag(input["check"], "Check the work"), summarize = try flag(input["summarize"], "Summarize"),
            noAsk = try flag(input["saveSkillsWithoutAsking"], "Save skills without asking"), projectWrite = try flag(input["projectSkillsWritable"], "Project skills")
        var price: ModelPrice?
        if let given = input["price"], given != .null {
            guard let parsed = ModelPrice(json: given) else { throw BlackTeamError("Give both prices as numbers, 0 or more, per million tokens.") }
            guard codeModelKey().cloud else { throw BlackTeamError("Prices are for cloud models. This model runs on this computer and costs nothing per token.") }
            price = parsed
        }
        let id = input["thread"]?.string
        if let id {
            guard history.get(id) != nil else { throw BlackTeamError("Conversation not found.") }
            try codeSettings.updateThread(id) { mine in
                if let tokens { mine.tokenCeiling = tokens }
                if let money { mine.moneyCeiling = money }
                if let check { mine.check = check }
                if let summarize { mine.summarize = summarize }
            }
        }
        try codeSettings.updateGlobal { all in
            if id == nil {
                if let tokens { all.tokenCeiling = tokens }
                if let money { all.moneyCeiling = money }
                if let check { all.check = check }
                if let summarize { all.summarize = summarize }
            }
            if let noAsk { all.saveSkillsWithoutAsking = noAsk }
            if let projectWrite { all.projectSkillsWritable = projectWrite }
            if let price { let key = codeModelKey(); all.prices[CodeGlobalSettings.priceKey(host: key.host, model: key.model)] = price }
        }
        changed()
        return codeSettingsView(thread: id)
    }

    // MARK: Skills (the Memory page, and the terminal)

    /// Skills as the Memory page lists them, for the workspace of a project when one is given.
    public func skillsView(workspace: String? = nil) -> JSONValue {
        let store = skills
        let all = codeSettings.global()
        return ["skills": .array(store.list(workspace: workspace).map { info in
            ["name": .string(info.name), "description": .string(info.description), "source": .string(info.source), "enabled": .bool(info.enabled),
             "characters": .number(Double(info.characters)), "editable": .bool(info.source == "mine")]
        }), "folder": .string(store.folder), "saveWithoutAsking": .bool(all.saveSkillsWithoutAsking), "projectWritable": .bool(all.projectSkillsWritable)]
    }
}
