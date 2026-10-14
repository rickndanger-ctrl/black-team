import Foundation

// The control channel's actions: everything main.cjs answered over IPC from `lib/`, with the same input checks, the same wording
// and the same busy rules ("Another setup action is still running."). `setup-help` and `open-data` are answered with the address or
// folder to open (the window's shell opens it); the file choosers (`pick`) stay in Electron.

public final class DesktopControl: @unchecked Sendable {
    /// Every action preload.cjs lets the window ask for.
    public static let actions: Set<String> = [
        "setup-help", "installed-discover", "hermes-inspect", "phone-setup", "phone-off", "integrations-save", "harness-connect", "harness-launch",
        "server-discover", "model-inspect", "status", "setup-save", "models-find", "models-add", "models-ignore", "model-switch", "model-forget",
        "runtime-start", "runtime-stop", "phone-save", "phone-detect", "phone-command", "phone-connect", "phone-disconnect", "open-data",
        // Cloud models and subscription agents (Desktop/DesktopCloud.swift).
        "cloud-discover", "cloud-save", "project-cloud", "agents-status", "agent-signin", "agent-update",
        // Starter model and vision file downloads (Desktop/DesktopVision.swift).
        "vision-install", "vision-cancel", "starter-list", "starter-install", "starter-cancel",
        // Optimizing a model for this computer (App/BackendTune.swift): start, cancel; progress rides on every `status` as `optimize`.
        "optimize-start", "optimize-cancel",
        // "Set up your agents": the plan, one approval, Not now, stop (Desktop/DesktopSetup.swift).
        "setup-plan", "setup-apply", "setup-dismiss", "setup-cancel",
    ]
    /// Actions that change something: one at a time.
    static let changing: Set<String> = [
        "integrations-save", "harness-connect", "harness-launch", "setup-save", "models-add", "models-ignore", "model-switch", "model-forget",
        "runtime-start", "runtime-stop", "phone-save", "phone-setup", "phone-off", "phone-connect", "phone-disconnect",
        "cloud-save", "project-cloud", "agent-signin", "agent-update", "setup-apply", "setup-dismiss",
    ]

    let backend: Backend
    var vision: VisionInstallState { backend.visionInstall }
    var starter: VisionInstallState { backend.starterInstall }
    private let home: String
    private let environment: [String: String]

    public init(_ backend: Backend, home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.backend = backend; self.home = home; self.environment = environment
    }

    private func discovered() -> LinuxDiscovery {
        let saved = (try? backend.integrations.read().hermes) ?? HermesSettings()
        return discoverLinux(home: home, env: environment, saved: saved, extraSources: [HermesInstaller.sourceFolder(dataFolder: backend.dataFolder)])
    }

    /// Answers one request. `data` is the request's input object (an empty one when none was sent). The control channel is the
    /// desktop's alone; a request made on a phone's behalf is refused here whatever the action (nothing reaches this from HTTP).
    public func handle(_ action: String, _ data: JSONValue? = nil, access: DesktopAccess = .desktop) async throws -> JSONValue {
        try access.requireDesktop()
        guard let input = (data ?? [:]).object else { throw BlackTeamError("Invalid desktop request.") }
        guard Self.actions.contains(action) else { throw BlackTeamError("Unsupported desktop action.") }
        func unsupported(_ allowed: [String], _ message: String) throws {
            if input.keys.contains(where: { !allowed.contains($0) }) { throw BlackTeamError(message) }
        }
        switch action {
        case "status":
            return try await backend.desktopStatusJSON()
        case "vision-install":
            try unsupported([], "Unsupported setup setting.")
            return visionStart()
        case "vision-cancel":
            try unsupported([], "Unsupported setup setting.")
            return visionStop()
        case "starter-list":
            try unsupported([], "Unsupported setup setting.")
            return starterList()
        case "starter-install":
            try unsupported(["id"], "Unsupported setup setting.")
            guard let id = input["id"]?.string, !id.isEmpty else { throw BlackTeamError("That starter model is not in the list.") }
            return starterStart(id)
        case "starter-cancel":
            try unsupported([], "Unsupported setup setting.")
            return starterStop()
        case "optimize-start":
            try unsupported(["key"], "Unsupported setup setting.")
            guard let key = input["key"]?.string, !key.isEmpty else { throw BlackTeamError("Choose a model from your list.") }
            let started = try await backend.optimize(key: key)
            return ["started": .bool(started == .started), "result": .string(started.text)]
        case "optimize-cancel":
            try unsupported([], "Unsupported setup setting.")
            backend.cancelOptimize()
            return ["stopped": true]
        case "setup-plan":
            try unsupported(["reason"], "Unsupported setup setting.")
            return try setupPlanJSON(input)
        case "setup-cancel":
            try unsupported([], "Unsupported setup setting.")
            return setupStop()
        case "server-discover":
            try unsupported(["endpoint", "apiKey"], "Unsupported server discovery setting.")
            // A key that is not text is refused as a key, never silently dropped.
            let key: String? = input["apiKey"].map { $0.string ?? "\u{1}" }
            let found = try await backend.discoverServer(endpoint: input["endpoint"]?.string ?? "", apiKey: key)
            return ["endpoint": .string(found.endpoint), "models": .array(found.models.map { .string($0) })]
        case "models-find":
            let report = await backend.findMyModels()
            func flat<T: Encodable>(_ item: T, _ key: String, _ saved: Bool, _ ignored: Bool) -> JSONValue {
                var object = JSONValue.encoded(item).object ?? [:]
                object["key"] = .string(key); object["saved"] = .bool(saved); object["ignored"] = .bool(ignored)
                return .object(object)
            }
            return ["servers": .array(report.servers.map { flat($0.server, $0.key, $0.saved, $0.ignored) }),
                    "files": .array(report.files.map { flat($0.file, $0.key, $0.saved, $0.ignored) }),
                    "runtime": .string(report.runtime), "looked": .encoded(report.looked), "added": .array(report.added.map { .string($0) })]
        case "model-inspect":
            try unsupported(["file"], "Unsupported setup setting.")
            let file = input["file"]?.string ?? ""
            // As main.cjs: the file is checked together with the llama-server found on this computer.
            let checked = try validateModelFiles(ModelConfig(source: "gguf", file: file, runtime: discovered().result.runtime))
            let info = describeFile(file, bytes: checked.model?.bytes ?? 0)
            let beside = companionsFor(file)
            var object: [String: JSONValue] = ["name": .string(info.name), "context": .number(Double(info.context)), "mmproj": .string(beside.mmproj), "draft": .string(beside.draft)]
            if let training = info.trainingContext { object["trainingContext"] = .number(Double(training)) }
            return .object(object)
        case "installed-discover":
            return discovered().json
        case "hermes-inspect":
            guard let found = inspectHermes(source: input["source"]?.string, python: input["python"]?.string ?? "") else { return .null }
            return ["source": .string(found.source), "python": .string(found.python)]
        case "phone-detect":
            return .encoded(await backend.phone().manager.detect())
        case "phone-command":
            return ["command": .string(Phone.command)]
        case "setup-help":
            let links = ["hermes": "https://github.com/NousResearch/hermes-agent#installation", "ollama": "https://ollama.com/download/linux",
                         "lmstudio": "https://lmstudio.ai/download", "tailscale": "https://tailscale.com/download"]
            guard let topic = input["topic"]?.string, let url = links[topic] else { throw BlackTeamError("Unsupported setup help.") }
            return ["url": .string(url)]
        case "cloud-discover", "agents-status":
            return try await cloudRead(action, input, unsupported)
        case "open-data":
            guard CoreFS.exists(backend.dataFolder) else { throw BlackTeamError("Could not open the application data folder.") }
            return ["path": .string(backend.dataFolder)]
        default:
            return try await change(action, input, unsupported)
        }
    }

    // MARK: Changes

    private func change(_ action: String, _ input: [String: JSONValue], _ unsupported: ([String], String) throws -> Void) async throws -> JSONValue {
        let value = JSONValue.object(input)
        func key() throws -> String {
            guard let key = input["key"]?.string else { throw BlackTeamError("Choose a model from your list.") }
            return key
        }
        switch action {
        case "integrations-save":
            return .encoded(try await backend.saveIntegrations(value))
        case "harness-launch":
            let launched = try await backend.launch(harness: input["id"]?.string ?? "")
            return ["launched": .bool(launched.launched), "name": .string(launched.name)]
        case "harness-connect":
            let found = discovered().result, id = input["id"]?.string ?? ""
            let connected = try await backend.exclusive { () async throws -> ConnectResult in
                if backend.isBusy { throw BlackTeamError("Wait for the current task before changing integrations.") }
                return try connectHarness(id: id, store: backend.integrations, found: found)
            }
            return ["connected": .bool(connected.connected), "name": .string(connected.name)]
        case "setup-apply":
            try unsupported(["ids"], "Unsupported setup setting.")
            return try setupStart(input)
        case "setup-dismiss":
            try unsupported([], "Unsupported setup setting.")
            try backend.dismissSetupOffer()
            return ["dismissed": true]
        case "setup-save":
            let saved = try await backend.saveSetup(value)
            var object: [String: JSONValue] = ["saved": .bool(saved.saved)]
            if let warning = saved.warning { object["warning"] = .string(warning) }
            return .object(object)
        case "models-add":
            try unsupported(["items"], "Unsupported setup setting.")
            let result = try await backend.add(models: input["items"]?.array ?? [])
            return ["added": .array(result.added.map { .string($0) }), "skipped": .array(result.skipped.map { .string($0) }), "inUse": .string(result.inUse)]
        case "models-ignore":
            return ["ignored": .bool(try await backend.ignore(key: input["key"]?.string ?? ""))]
        case "model-switch":
            let switched = try await backend.switchTo(key: try key())
            return ["switched": .bool(switched.switched), "name": .string(switched.name)]
        case "model-forget":
            try await backend.forget(key: try key())
            return ["removed": true]
        case "runtime-start":
            return .encoded(try await backend.startModel())
        case "runtime-stop":
            return .encoded(try await backend.stopModel())
        case "phone-save":
            return try await backend.exclusive { try await self.savePhone(input) }
        case "phone-setup":
            return try await backend.exclusive { .encoded(try await self.backend.phone().manager.setup()) }
        case "phone-off":
            return try await backend.exclusive {
                let off = try await self.backend.phone().manager.disable()
                var object: [String: JSONValue] = ["disabled": .bool(off.disabled)]
                if let warning = off.warning { object["warning"] = .string(warning) }
                return .object(object)
            }
        case "phone-connect":
            return try await backend.exclusive { .encoded(try await self.backend.phone().manager.connect()) }
        case "phone-disconnect":
            return try await backend.exclusive { .encoded(try await self.backend.phone().manager.disconnect()) }
        case "cloud-save", "project-cloud", "agent-signin", "agent-update":
            return try await cloudChange(action, input, unsupported)
        default:
            throw BlackTeamError("Unsupported desktop action.")
        }
    }

    /// `phone-save` (main.cjs): the saved computer and account must be the signed-in ones, and a connected route is not moved.
    private func savePhone(_ input: [String: JSONValue]) async throws -> JSONValue {
        guard let enabled = input["enabled"]?.bool else { throw BlackTeamError("Choose whether to enable Companion.") }
        let next = try validatePhone(enabled: enabled, hostname: input["hostname"]?.string ?? "", owner: input["owner"]?.string ?? "")
        let old = try backend.configStore.read().phone
        let manager = backend.phone().manager
        if next.enabled {
            let me = await manager.detect()
            if !me.online || me.hostname != next.hostname || me.owner != next.owner {
                throw BlackTeamError("Detect the signed-in computer and account before saving private phone access.")
            }
        }
        if old.enabled && (next.hostname != old.hostname || next.owner != old.owner) {
            if try await manager.status(fresh: true).connected {
                throw BlackTeamError("Disconnect the current phone route before changing its computer or account.")
            }
        }
        try backend.configStore.savePhone(next)
        return ["saved": true]
    }
}
