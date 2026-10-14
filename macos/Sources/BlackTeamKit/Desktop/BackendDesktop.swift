import Foundation

// What the desktop window reads from the engine beyond the phone's view: the full status of `backend.status('desktop')`
// (lib/server.cjs) and the dictation button.

extension Backend {
    /// Makes this Backend the Linux desktop service: Hermes settings are stored and checked as the Linux app did.
    public func configureDesktop(_ options: DesktopOptions = DesktopOptions()) {
        locked { desktopOptions = options }
        integrations.hermesSupported = true
    }

    /// The dictation tool: the saved choice wins; otherwise the one found on this computer (Voxtype).
    func dictationTool() -> String {
        let saved = (try? integrations.read().dictation) ?? ""
        return saved.isEmpty ? discovery.get().dictation : saved
    }

    /// Starts or stops the system dictation tool. The words are typed by the tool itself, into the focused text bar.
    func dictate() throws {
        let tool = dictationTool()
        if tool.isEmpty { throw BlackTeamError("No system dictation tool is set up on this computer.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = (tool as NSString).lastPathComponent == "voxtype" ? ["record", "toggle"] : []
        process.environment = localEnvironment()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { /* The button does nothing more than ask; a tool that will not start is not an error to show. */ }
    }

    /// `status('desktop')`: the shape the web app reads, from the engine's own status.
    func desktopStatusJSON() async throws -> JSONValue {
        // Read first: a download that finishes while the status is being gathered must not be reported as done beside a status
        // from before it finished.
        let visionInstallBefore = visionInstall.json, starterInstallBefore = starterInstall.json, modelInstallBefore = modelInstall.json
        let status = try await self.status()
        var json = JSONValue.encoded(status).object ?? [:]
        let config = try configStore.read()
        var shown = json["config"]?.object ?? [:]
        shown["phone"] = .encoded(config.phone)
        json["config"] = .object(shown)
        // JavaScript wrote null where there is no value; the web app tells null from missing in a few places.
        var performance = json["performance"]?.object ?? [:]
        for key in ["temperature", "model"] where performance[key] == nil { performance[key] = .null }
        json["performance"] = .object(performance)
        json["access"] = "desktop"
        // Cloud models: a saved cloud model always holds its key (an entry without one is not kept), but the key itself is never sent.
        json["models"] = .array((json["models"]?.array ?? []).map { $0["kind"]?.string == "cloud" ? $0.setting("keyConfigured", .bool(true)) : $0 })
        // Optimizing: how the one in progress stands, and what each model's last result says (stale, if this computer or the program changed).
        json["models"] = .array((json["models"]?.array ?? []).map { item in
            item.setting("tuning", item["key"]?.string.flatMap { savedModels.find($0) }.map { tuningInfo(for: $0) } ?? .null)
        })
        json["optimize"] = optimizeStatus()
        // Subscription agents found on this computer. Whether one is signed in is learned only when it runs (a reply says `needsSignIn`).
        json["visionInstall"] = visionInstallBefore
        json["starterInstall"] = starterInstallBefore
        json["setupRun"] = setupRun.json
        json["modelInstall"] = modelInstallBefore
        json["agents"] = .array(AgentService.allCases.map { DesktopControl.agentJSON($0, installed: agentInstalled($0)) })
        if json["job"] == nil { json["job"] = .null }   // the web app reads `job`, which is null when nothing runs
        // As lib/server.cjs: Hermes is offered when this service has the runner's scripts and Hermes is enabled in its settings.
        let scripts = locked { desktopOptions?.scripts }
        json["hermesEnabled"] = .bool(scripts != nil && (try? integrations.read().hermes.enabled) == true)
        json["dictation"] = .bool(!dictationTool().isEmpty)
        // The background service: the inbox count (the badge), and whether the model was unloaded to free memory (Service/ServiceHooks.swift).
        if let hooks = locked({ service }) { json["service"] = hooks.statusJSON() }
        let service = phone()
        let phoneStatus = try await service.manager.status()
        var url = phoneStatus.url
        if !url.isEmpty {
            let keys = try service.keys ?? PhoneKeys(folder: dataFolder)
            url += "#pair=" + keys.secret("pair", hostname: config.phone.hostname, owner: config.phone.owner)
        }
        json["phone"] = ["enabled": .bool(phoneStatus.enabled), "connected": .bool(phoneStatus.connected), "url": .string(url), "command": .string(phoneStatus.command)]
        return .object(json)
    }
}
