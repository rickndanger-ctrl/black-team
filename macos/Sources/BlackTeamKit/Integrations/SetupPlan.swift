import Foundation

// "Set up your agents": one approval for everything. `buildSetupPlan` looks at this computer (found files only; nothing found is ever
// run) and lists the steps, each marked done, will do, or needs something. `applySetup` runs only the steps the person approved, in
// order, and keeps going when one fails. Nothing here installs, downloads or connects anything on its own: the window and the
// command ask first, and pass the approved step IDs.
//
// Step IDs: `connect:<agent id>`, `hermes-install`, `hermes-connect`, `hermes-tools`, and `agents-missing` (only ever a note).

public enum SetupStepState: String, Codable, Equatable, Sendable {
    case done
    case willDo = "will-do"
    case needsSomething = "needs-something"
}

/// An agent that is not installed, with the command its makers give to install it. Shown as text only; Black Team never runs it.
public struct SetupInstallHint: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
}

public struct SetupStep: Codable, Equatable, Sendable {
    public var id: String
    /// "connect", "install", "tools" or "note" (a note is never run).
    public var kind: String
    public var title: String
    /// One plain sentence.
    public var detail: String
    /// What approving it will download or change.
    public var changes: [String]
    public var state: SetupStepState
    /// What is missing, when the state is `needsSomething`.
    public var needs: String?
    public var commands: [SetupInstallHint]

    public init(id: String, kind: String, title: String, detail: String, changes: [String] = [], state: SetupStepState, needs: String? = nil,
                commands: [SetupInstallHint] = []) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.changes = changes
        self.state = state; self.needs = needs; self.commands = commands
    }

    /// Only a step marked will-do can be approved.
    public var approvable: Bool { state == .willDo && kind != "note" }
}

public struct SetupPlan: Codable, Equatable, Sendable {
    public var steps: [SetupStep]
    public init(steps: [SetupStep]) { self.steps = steps }

    /// The steps approving would run.
    public var pending: [SetupStep] { steps.filter(\.approvable) }
    /// Nothing left to approve.
    public var isComplete: Bool { pending.isEmpty }

    public var json: JSONValue { .encoded(self) }
}

/// What the plan is built from: everything it knows about this computer, read beforehand.
public struct SetupContext: Sendable {
    public var found: DiscoveryResult
    /// Hermes installs found by discovery (the person's own, or the one in Black Team's folder).
    public var hermesInstalls: [HermesInstall]
    public var settings: IntegrationSettings
    /// Hermes is supported on this platform (Linux desktop).
    public var hermesSupported: Bool
    public var tooling: HermesTooling
    /// The model in use, for the descriptions; empty when none is set up yet.
    public var modelName: String
    public var dataFolder: String

    public init(found: DiscoveryResult, hermesInstalls: [HermesInstall], settings: IntegrationSettings, hermesSupported: Bool, tooling: HermesTooling,
                modelName: String = "", dataFolder: String = "") {
        self.found = found; self.hermesInstalls = hermesInstalls; self.settings = settings; self.hermesSupported = hermesSupported
        self.tooling = tooling; self.modelName = modelName; self.dataFolder = dataFolder
    }
}

/// The install command each maker gives for its agent (checked 2026-10-13). Text only.
let agentInstallCommands: [(id: String, command: String)] = [
    ("claude", "curl -fsSL https://claude.ai/install.sh | bash"),
    ("codex", "npm install -g @openai/codex"),
    ("pi", "npm install -g @earendil-works/pi-coding-agent"),
    ("opencode", "curl -fsSL https://opencode.ai/install | bash"),
    ("dsh", "npm install -g @deepseek-ai/dsh"),
    ("aider", "python -m pip install aider-install && aider-install"),
]

private let terminalMissing = "A terminal is needed to open agents. Install one (for example Ghostty, Kitty, Alacritty, GNOME Terminal, Konsole or XTerm), then set up again."

public func buildSetupPlan(_ c: SetupContext) -> SetupPlan {
    var steps: [SetupStep] = []
    let model = c.modelName.isEmpty ? "your local model" : c.modelName
    let connected = c.settings.harnesses

    // 1. Each agent found on this computer that is not connected yet.
    for app in c.found.apps where app.id != "hermes" || c.hermesSupported {
        let done = connected.contains { $0.id == app.id || $0.executable == app.executable }
        var step = SetupStep(
            id: "connect:" + app.id, kind: "connect", title: "Connect " + app.name,
            detail: app.preset ? "Opens \(app.name) in a terminal, already pointed at \(model)." : "Adds a button that opens \(app.name) in a terminal. It keeps its own model settings.",
            changes: ["Adds a launcher for \(app.name) to Black Team's settings.", "Does not change \(app.name)'s own settings or files."],
            state: done ? .done : .willDo)
        if !done && c.found.terminals.isEmpty { step.state = .needsSomething; step.needs = terminalMissing }
        steps.append(step)
    }

    // 2. Hermes Agent: install it if it is nowhere on this computer, connect it, and choose its tool switches.
    if c.hermesSupported {
        let enabled = c.settings.hermes.enabled
        let installed = c.hermesInstalls.first
        let folder = HermesInstaller.sourceFolder(dataFolder: c.dataFolder.isEmpty ? "<Black Team data folder>" : c.dataFolder)
        if let installed {
            steps.append(SetupStep(id: "hermes-install", kind: "install", title: "Hermes Agent is installed",
                                   detail: "Found on this computer: \(installed.source).", state: .done))
        } else if !c.tooling.isAvailable {
            steps.append(SetupStep(id: "hermes-install", kind: "install", title: "Install Hermes Agent",
                                   detail: "Hermes adds browser, desktop and file tools to Code.", state: .needsSomething, needs: HermesTooling.missingMessage))
        } else {
            var changes = ["Downloads Hermes Agent, about 79 MB, from github.com: one fixed, checked version (\(HermesArchive.pinned.commit.prefix(8))).",
                           "Downloads its Python packages from the Python package index (pypi.org).",
                           "Puts them in Black Team's own folder, \(folder). Your own ~/.hermes and any Hermes you installed yourself are not touched."]
            if !c.tooling.uv.isEmpty { changes.append("If this computer has no Python 3.14, the uv tool downloads one from github.com into the same folder.") }
            steps.append(SetupStep(id: "hermes-install", kind: "install", title: "Install Hermes Agent",
                                   detail: "Hermes adds browser, desktop and file tools to Code. It is not installed yet, so Black Team will download it.", changes: changes, state: .willDo))
        }
        let installStep = steps.last!
        let ready = installStep.state == .done || installStep.state == .willDo
        let waiting = "Hermes Agent has to be installed first."
        steps.append(SetupStep(
            id: "hermes-connect", kind: "connect", title: "Connect Hermes",
            detail: "Lets a Code conversation use Hermes and its tools when you choose it, using \(model). Black Team Code stays the default.",
            changes: ["Saves where Hermes is, so Code can start it.", "Hermes uses a private profile for each conversation and never your own."],
            state: enabled ? .done : ready ? .willDo : .needsSomething, needs: enabled || ready ? nil : waiting))
        steps.append(SetupStep(
            id: "hermes-tools", kind: "tools", title: "Choose Hermes's tools",
            detail: "Files, terminal, search and planning on. Browser and desktop control stay off.",
            changes: ["Files, terminal, search and planning: on.",
                      "Browser tools: off. They visit websites; switch them on in Settings → Agents & apps.",
                      "Desktop control: off. It can operate other apps; switch it on in Settings → Agents & apps.",
                      "New Code conversations use Hermes. You can change that in Settings → Agents & apps."],
            state: enabled ? .done : ready ? .willDo : .needsSomething, needs: enabled || ready ? nil : waiting))
    }

    // 3. Agents that are not installed: what their makers say to run, as text only.
    let foundIDs = Set(c.found.apps.map(\.id))
    let missing = agentInstallCommands.compactMap { item -> SetupInstallHint? in
        guard !foundIDs.contains(item.id), let name = c.found.presets.first(where: { $0.id == item.id })?.name else { return nil }
        return SetupInstallHint(name: name, command: item.command)
    }
    if !missing.isEmpty {
        steps.append(SetupStep(id: "agents-missing", kind: "note", title: "Agents that are not installed",
                               detail: "Black Team does not install these. If you want one, run its install command yourself, then set up again.",
                               state: .needsSomething, needs: "Not installed", commands: missing))
    }
    return SetupPlan(steps: steps)
}

// MARK: Running the plan

public struct SetupStepResult: Codable, Equatable, Sendable {
    public var id: String
    /// "done", "failed", "skipped" or "stopped".
    public var status: String
    public var message: String
    public init(id: String, status: String, message: String) { self.id = id; self.status = status; self.message = message }
}

/// What a running step says as it goes.
public struct SetupEvent: Equatable, Sendable {
    public var stepID: String
    /// "running", "done", "failed", "skipped" or "stopped".
    public var status: String
    public var stage: String
    public var fraction: Double?
    public var bytesPerSecond: Double
    public init(stepID: String, status: String, stage: String, fraction: Double? = nil, bytesPerSecond: Double = 0) {
        self.stepID = stepID; self.status = status; self.stage = stage; self.fraction = fraction; self.bytesPerSecond = bytesPerSecond
    }
}

/// What `applySetup` changes and reads. The app builds it from the Backend; tests give fakes.
public struct SetupServices: Sendable {
    public var store: Integrations
    /// What is on this computer right now, asked again for every run so a repeat run sees what the last one did.
    public var context: @Sendable () -> SetupContext
    public var installer: HermesInstalling
    public init(store: Integrations, context: @escaping @Sendable () -> SetupContext, installer: HermesInstalling) {
        self.store = store; self.context = context; self.installer = installer
    }
}

/// "Connect Hermes" as the window does it: the found installation, enabled.
@discardableResult
public func connectHermes(store: Integrations, install: HermesInstall) throws -> IntegrationSettings {
    var hermes = try store.read().hermes
    hermes.source = install.source; hermes.python = install.python; hermes.enabled = true
    return try store.save(JSONValue.object(["hermes": .encoded(hermes)]))
}

/// Runs the approved steps in order. A step that fails does not stop the ones after it (unless they need it); a step already done
/// is left alone, so running the plan again does nothing for what is finished. Cancelling the task stops the running step and
/// reports the rest as stopped. Returns one result per approved step, in plan order.
public func applySetup(approved ids: [String], services: SetupServices, progress: (@Sendable (SetupEvent) -> Void)? = nil) async -> [SetupStepResult] {
    let report: @Sendable (SetupEvent) -> Void = { progress?($0) }
    var context = services.context()
    let plan = buildSetupPlan(context)
    var results: [SetupStepResult] = []
    let approved = Set(ids)
    for id in ids where !plan.steps.contains(where: { $0.id == id }) {
        results.append(SetupStepResult(id: id, status: "skipped", message: "That step is not part of this computer's plan."))
    }
    var hermes: HermesInstall? = context.hermesInstalls.first
    var cancelled = false
    for step in plan.steps where approved.contains(step.id) {
        func finish(_ status: String, _ message: String) {
            results.append(SetupStepResult(id: step.id, status: status, message: message))
            report(SetupEvent(stepID: step.id, status: status, stage: message, fraction: status == "done" ? 1 : nil))
        }
        if cancelled || Task.isCancelled { cancelled = true; finish("stopped", "Stopped before this step."); continue }
        switch step.state {
        case .done: finish("done", "Already done."); continue
        case .needsSomething: finish("skipped", step.needs ?? "Something is missing."); continue
        case .willDo: break
        }
        if step.kind == "note" { finish("skipped", "Nothing to do."); continue }
        report(SetupEvent(stepID: step.id, status: "running", stage: "Starting\u{2026}"))
        do {
            switch step.id {
            case "hermes-install":
                hermes = try await services.installer.install { event in
                    switch event {
                    case .checking: report(SetupEvent(stepID: step.id, status: "running", stage: "Checking this computer\u{2026}"))
                    case .downloading(let p): report(SetupEvent(stepID: step.id, status: "running", stage: "Downloading Hermes Agent", fraction: p.fraction, bytesPerSecond: p.bytesPerSecond))
                    case .verifying: report(SetupEvent(stepID: step.id, status: "running", stage: "Checking the download\u{2026}"))
                    case .unpacking: report(SetupEvent(stepID: step.id, status: "running", stage: "Unpacking Hermes Agent\u{2026}"))
                    case .creatingEnvironment: report(SetupEvent(stepID: step.id, status: "running", stage: "Creating Hermes's Python environment\u{2026}"))
                    case .installingPackages(let n): if n > 1 && n % 10 != 0 { break }; report(SetupEvent(stepID: step.id, status: "running", stage: n == 0 ? "Installing Hermes's Python packages\u{2026}" : "Installing Hermes's Python packages (\(n))\u{2026}"))
                    case .done: break
                    }
                }
                finish("done", "Hermes Agent is installed.")
            case "hermes-connect":
                guard let install = hermes else { finish("skipped", "Hermes Agent is not installed, so it was not connected."); continue }
                try connectHermes(store: services.store, install: install)
                finish("done", "Hermes is connected.")
            case "hermes-tools":
                var settings = try services.store.read()
                guard settings.hermes.enabled else { finish("skipped", "Hermes is not connected, so its tools were not chosen."); continue }
                settings.hermes.coding = true; settings.hermes.browser = false; settings.hermes.desktop = false
                // Black Team Code stays what runs new Code conversations; Hermes is a choice the person makes.
                try services.store.save(JSONValue.object(["hermes": .encoded(settings.hermes)]))
                finish("done", "Hermes's file and terminal tools are on. Browser and desktop control are off.")
            default:
                guard step.id.hasPrefix("connect:") else { finish("skipped", "Unknown step."); continue }
                let result = try connectHarness(id: String(step.id.dropFirst("connect:".count)), store: services.store, found: context.found)
                finish("done", "\(result.name) is connected.")
            }
            context = services.context()
        } catch is CancellationError {
            cancelled = true
            finish("stopped", "Stopped. What was downloaded is kept, so it carries on from there next time.")
        } catch {
            finish("failed", (error as? BlackTeamError)?.message ?? error.localizedDescription)
        }
    }
    return results
}

// MARK: Not now

/// What the person said "Not now" to, kept in `<data>/setup-offer.json`, so the card does not come back for the same things.
/// A step it has not seen before (a newly found agent) is offered again.
public struct SetupOfferStore: Sendable {
    public let file: String
    public init(dataFolder: String) { file = dataFolder + "/setup-offer.json" }

    private struct Stored: Codable { var dismissed: [String] }

    public func dismissed() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return Set(stored.dismissed)
    }

    /// Remembers "Not now" for these steps.
    public func dismiss(_ ids: [String]) throws {
        let all = dismissed().union(ids).sorted()
        try privateDirectory((file as NSString).deletingLastPathComponent)
        try writeJSON(file, Stored(dismissed: all))
    }

    /// True when the plan has a step to approve that "Not now" has not been said to.
    public func shouldOffer(_ plan: SetupPlan) -> Bool {
        let seen = dismissed()
        return plan.pending.contains { !seen.contains($0.id) }
    }
}

/// The plan, and whether to put it in front of the person unasked.
public struct SetupOffer: Codable, Equatable, Sendable {
    public var show: Bool
    /// "model-ready", "found-something-new" or "asked".
    public var reason: String
    public var plan: SetupPlan
    public var json: JSONValue { .encoded(self) }
}
