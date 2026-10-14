import XCTest
@testable import BlackTeamKit

// "Set up your agents": the plan for a computer with nothing, some or all agents, and running it. A fake machine stands in for the
// computer and a fake installer for Hermes, so nothing real is downloaded, run or connected.

/// Stands in for the Hermes installer: puts a minimal Hermes folder where the plan will find it, or fails as told.
final class FakeHermesInstaller: HermesInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let folder: String
    var failure: Error?
    init(folder: String) { self.folder = folder }
    var calls: Int { lock.withLock { count } }

    func install(progress: (@Sendable (HermesInstallEvent) -> Void)?) async throws -> HermesInstall {
        lock.withLock { count += 1 }
        progress?(.checking)
        if let failure { throw failure }
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/venv/bin", withIntermediateDirectories: true)
        for name in ["hermes_bootstrap.py", "cli.py"] { fm.createFile(atPath: folder + "/" + name, contents: Data("# fake\n".utf8)) }
        fm.createFile(atPath: folder + "/venv/bin/python", contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        let found = try XCTUnwrap(inspectHermes(source: folder))
        progress?(.done(found))
        return found
    }
    func cancel() {}
}

/// A computer: which agents are on it, whether it has a terminal and Python, and where a Hermes would be.
final class FakeMachine: @unchecked Sendable {
    let dir: String
    let store: Integrations
    var apps: [FoundApp] = []
    var terminals: [FoundTerminal] = [FoundTerminal(name: "Ghostty", executable: "/usr/bin/true", args: ["-e"])]
    var tooling = HermesTooling(uv: "/usr/bin/uv", python: "/usr/bin/python3")
    let hermesFolder: String
    let installer: FakeHermesInstaller

    init(_ test: XCTestCase) {
        dir = makeTemporaryFolder(test)
        store = Integrations(stateDir: dir + "/state")
        store.hermesSupported = true
        hermesFolder = dir + "/data/hermes/hermes-agent"
        installer = FakeHermesInstaller(folder: hermesFolder)
    }

    /// An agent program that exists and can be run (it is never run: connecting only records where it is).
    func app(_ id: String, _ name: String, preset: Bool = true) -> FoundApp {
        let path = dir + "/bin/" + id
        try? FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        return FoundApp(id: id, name: name, executable: path, preset: preset)
    }

    func context() -> SetupContext {
        let found = DiscoveryResult(terminals: terminals, apps: apps, presets: PRESETS.map { KnownPreset(id: $0.id, name: $0.name, command: $0.command) },
                                    runtime: "", dictation: "", graph: "")
        let installs = inspectHermes(source: hermesFolder).map { [$0] } ?? []
        return SetupContext(found: found, hermesInstalls: installs, settings: (try? store.read()) ?? IntegrationSettings(), hermesSupported: store.hermesSupported,
                            tooling: tooling, modelName: "Qwen", dataFolder: dir + "/data")
    }

    var services: SetupServices {
        SetupServices(store: store, context: { [unowned self] in self.context() }, installer: installer)
    }
    var plan: SetupPlan { buildSetupPlan(context()) }
}

final class SetupPlanTests: XCTestCase {
    private func state(_ plan: SetupPlan, _ id: String) -> SetupStepState? { plan.steps.first { $0.id == id }?.state }

    func testPlanWhenNothingIsFound() throws {
        let m = FakeMachine(self)
        let plan = m.plan
        XCTAssertEqual(plan.steps.map(\.id), ["hermes-install", "hermes-connect", "hermes-tools", "agents-missing"])
        XCTAssertEqual(plan.pending.map(\.id), ["hermes-install", "hermes-connect", "hermes-tools"])
        let install = try XCTUnwrap(plan.steps.first)
        XCTAssertTrue(install.changes.contains { $0.contains("github.com") })
        XCTAssertTrue(install.changes.contains { $0.contains("pypi.org") })
        XCTAssertTrue(install.changes.contains { $0.contains("~/.hermes") && $0.contains("not touched") })
        // Agents that are not installed are shown with their makers' commands as text, and cannot be approved.
        let note = try XCTUnwrap(plan.steps.last)
        XCTAssertEqual(note.commands.map(\.name), ["Claude Code", "Codex", "Pi", "OpenCode", "DeepSeek Harness", "Aider"])
        XCTAssertFalse(note.approvable)
        XCTAssertTrue(note.commands.allSatisfy { !$0.command.isEmpty })
        // The tool switches follow the product principles: coding on, browser and desktop off.
        let tools = try XCTUnwrap(plan.steps.first { $0.id == "hermes-tools" })
        XCTAssertTrue(tools.changes.contains { $0.hasPrefix("Browser tools: off") })
        XCTAssertTrue(tools.changes.contains { $0.hasPrefix("Desktop control: off") })
    }

    func testPlanWhenSomeAreFoundAndOneIsConnected() throws {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code"), m.app("codex", "Codex")]
        try m.store.save(["harnesses": [["id": "codex", "name": "Codex", "executable": .string(m.apps[1].executable), "args": [], "terminal": [], "preset": "codex"]]])
        let plan = m.plan
        XCTAssertEqual(state(plan, "connect:claude"), .willDo)
        XCTAssertEqual(state(plan, "connect:codex"), .done)
        XCTAssertEqual(plan.steps.map(\.id).prefix(2), ["connect:claude", "connect:codex"])   // found agents come first, in the discovery order
        let claude = try XCTUnwrap(plan.steps.first)
        XCTAssertTrue(claude.detail.contains("Qwen"), "the description names the model in use")
        let missing = try XCTUnwrap(plan.steps.last { $0.id == "agents-missing" })
        XCTAssertEqual(missing.commands.map(\.name), ["Pi", "OpenCode", "DeepSeek Harness", "Aider"])
    }

    func testPlanWhenEverythingIsConnected() async throws {
        let m = FakeMachine(self)
        m.apps = PRESETS.map { m.app($0.id, $0.name) }
        _ = try await m.installer.install(progress: nil)
        let entries = m.apps.map { JSONValue.object(["id": .string($0.id), "name": .string($0.name), "executable": .string($0.executable), "args": [], "terminal": [], "preset": .string($0.id)]) }
        try m.store.save(["harnesses": .array(entries)])
        try connectHermes(store: m.store, install: try XCTUnwrap(inspectHermes(source: m.hermesFolder)))
        let plan = m.plan
        XCTAssertTrue(plan.isComplete)
        XCTAssertTrue(plan.pending.isEmpty)
        XCTAssertEqual(plan.steps.filter { $0.state != .done }.count, 0, "no note either when every known agent is installed")
        XCTAssertEqual(m.installer.calls, 1)
    }

    func testAnAgentNeedsATerminal() {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code")]
        m.terminals = []
        let step = m.plan.steps[0]
        XCTAssertEqual(step.state, .needsSomething)
        XCTAssertTrue(step.needs?.contains("terminal") == true)
        XCTAssertFalse(step.approvable)
    }

    func testMissingPythonSaysWhatToInstall() async throws {
        let m = FakeMachine(self)
        m.tooling = HermesTooling()
        let plan = m.plan
        XCTAssertEqual(state(plan, "hermes-install"), .needsSomething)
        XCTAssertEqual(plan.steps.first?.needs, HermesTooling.missingMessage)
        XCTAssertTrue(HermesTooling.missingMessage.contains("Python 3.14"))
        XCTAssertTrue(HermesTooling.missingMessage.contains("uv"))
        XCTAssertEqual(state(plan, "hermes-connect"), .needsSomething)
        XCTAssertTrue(plan.pending.isEmpty, "nothing to approve, so nothing nags")
        // And asking for it anyway runs nothing.
        let results = await applySetup(approved: ["hermes-install", "hermes-connect"], services: m.services)
        XCTAssertEqual(results.map(\.status), ["skipped", "skipped"])
        XCTAssertEqual(results[0].message, HermesTooling.missingMessage)
        XCTAssertEqual(m.installer.calls, 0)
    }

    func testHermesFoundOnThisComputerIsNotInstalledAgain() async throws {
        let m = FakeMachine(self)
        _ = try await m.installer.install(progress: nil)
        let plan = m.plan
        XCTAssertEqual(state(plan, "hermes-install"), .done)
        XCTAssertEqual(state(plan, "hermes-connect"), .willDo)
        XCTAssertEqual(m.installer.calls, 1)
    }

    func testNothingIsLookedAtOrChangedByMakingAPlan() {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code")]
        _ = m.plan
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.store.file), "a plan only reads")
        XCTAssertEqual(m.installer.calls, 0)
    }

    // MARK: Running it

    func testNothingRunsWithoutApproval() async throws {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code")]
        let results = await applySetup(approved: [], services: m.services)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(m.installer.calls, 0)
        XCTAssertTrue(try m.store.read().harnesses.isEmpty)
        // Only the approved step runs.
        let one = await applySetup(approved: ["connect:claude"], services: m.services)
        XCTAssertEqual(one.map(\.status), ["done"])
        XCTAssertEqual(try m.store.read().harnesses.map(\.id), ["claude"])
        XCTAssertEqual(m.installer.calls, 0)
        XCTAssertFalse(try m.store.read().hermes.enabled)
    }

    func testApprovingEverythingConnectsAndInstallsInOrder() async throws {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code"), m.app("codex", "Codex")]
        let events = EventLog()
        let results = await applySetup(approved: m.plan.pending.map(\.id), services: m.services) { events.add($0) }
        XCTAssertEqual(results.map(\.id), ["connect:claude", "connect:codex", "hermes-install", "hermes-connect", "hermes-tools"])
        XCTAssertEqual(results.map(\.status), Array(repeating: "done", count: 5))
        XCTAssertEqual(try m.store.read().harnesses.map(\.id), ["claude", "codex"])
        let settings = try m.store.read()
        XCTAssertTrue(settings.hermes.enabled)
        XCTAssertEqual(settings.hermes.source, m.hermesFolder)
        XCTAssertEqual(settings.hermes.python, m.hermesFolder + "/venv/bin/python")
        XCTAssertTrue(settings.hermes.coding)
        XCTAssertFalse(settings.hermes.browser, "browser stays off")
        XCTAssertFalse(settings.hermes.desktop, "desktop control stays off")
        XCTAssertNotEqual(settings.engine, "hermes", "Black Team Code stays the default engine")
        XCTAssertEqual(events.statuses(for: "hermes-install").prefix(2), ["running", "running"])
        XCTAssertEqual(events.statuses(for: "hermes-install").last, "done")
        XCTAssertTrue(m.plan.isComplete)
    }

    func testRunningItAgainDoesNothingForFinishedSteps() async throws {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code")]
        let ids = m.plan.pending.map(\.id)
        _ = await applySetup(approved: ids, services: m.services)
        let before = try Data(contentsOf: URL(fileURLWithPath: m.store.file))
        let again = await applySetup(approved: ids, services: m.services)
        XCTAssertEqual(again.map(\.status), Array(repeating: "done", count: ids.count))
        XCTAssertTrue(again.allSatisfy { $0.message == "Already done." })
        XCTAssertEqual(m.installer.calls, 1, "Hermes is installed once")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: m.store.file)), before)
    }

    func testAFailedStepDoesNotStopTheOthers() async throws {
        let m = FakeMachine(self)
        // Claude Code's program is gone by the time it is connected, so saving it fails; Codex is fine; Hermes fails to install.
        var claude = m.app("claude", "Claude Code")
        claude.executable = m.dir + "/bin/vanished"
        m.apps = [claude, m.app("codex", "Codex")]
        m.installer.failure = BlackTeamError("The internet connection was lost.")
        let results = await applySetup(approved: m.plan.pending.map(\.id), services: m.services)
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        XCTAssertEqual(byID["connect:claude"]?.status, "failed")
        XCTAssertEqual(byID["connect:codex"]?.status, "done", "the step after a failure still ran")
        XCTAssertEqual(byID["hermes-install"]?.status, "failed")
        XCTAssertEqual(byID["hermes-install"]?.message, "The internet connection was lost.")
        XCTAssertEqual(byID["hermes-connect"]?.status, "skipped", "connecting needs the install")
        XCTAssertEqual(byID["hermes-tools"]?.status, "skipped")
        XCTAssertEqual(try m.store.read().harnesses.map(\.id), ["codex"])
        XCTAssertFalse(try m.store.read().hermes.enabled)
        // Trying again retries only what is left.
        m.installer.failure = nil
        let retry = await applySetup(approved: ["connect:codex", "hermes-install", "hermes-connect", "hermes-tools"], services: m.services)
        XCTAssertEqual(retry.map(\.status), ["done", "done", "done", "done"])
        XCTAssertEqual(retry.first?.message, "Already done.")
    }

    func testStoppingMarksTheRestStopped() async throws {
        let m = FakeMachine(self)
        m.installer.failure = CancellationError()
        let results = await applySetup(approved: m.plan.pending.map(\.id), services: m.services)
        XCTAssertEqual(results.map(\.status), ["stopped", "stopped", "stopped"])
        XCTAssertFalse(try m.store.read().hermes.enabled)
    }

    func testAStepThatIsNotInThePlanIsRefused() async {
        let m = FakeMachine(self)
        let results = await applySetup(approved: ["connect:nonexistent", "rm -rf"], services: m.services)
        XCTAssertEqual(results.map(\.status), ["skipped", "skipped"])
        XCTAssertEqual(m.installer.calls, 0)
    }

    func testHermesTheUserAlreadyConfiguredIsLeftAlone() async throws {
        let m = FakeMachine(self)
        _ = try await m.installer.install(progress: nil)
        var own = try m.store.read().hermes
        own.enabled = true; own.coding = true; own.browser = true; own.source = m.hermesFolder; own.python = m.hermesFolder + "/venv/bin/python"
        try m.store.save(["hermes": .encoded(own), "engine": "black-team"])
        XCTAssertTrue(m.plan.isComplete)
        let results = await applySetup(approved: ["hermes-connect", "hermes-tools"], services: m.services)
        XCTAssertEqual(results.map(\.message), ["Already done.", "Already done."])
        let settings = try m.store.read()
        XCTAssertTrue(settings.hermes.browser, "their own choice of browser tools is kept")
        XCTAssertEqual(settings.engine, "black-team")
    }

    // MARK: Not now

    func testNotNowIsRememberedUntilSomethingNewIsFound() throws {
        let m = FakeMachine(self)
        m.apps = [m.app("claude", "Claude Code")]
        let offers = SetupOfferStore(dataFolder: m.dir + "/data")
        XCTAssertTrue(offers.shouldOffer(m.plan))
        try offers.dismiss(m.plan.pending.map(\.id))
        XCTAssertFalse(offers.shouldOffer(m.plan), "said Not now, so it does not nag")
        XCTAssertFalse(SetupOfferStore(dataFolder: m.dir + "/data").shouldOffer(m.plan), "and it is remembered across launches")
        XCTAssertEqual(mode(offers.file), 0o600)
        m.apps.append(m.app("codex", "Codex"))
        XCTAssertTrue(offers.shouldOffer(m.plan), "a newly found agent is offered")
        // Needing something is not something to approve, so it never asks either.
        let none = FakeMachine(self)
        none.tooling = HermesTooling()
        XCTAssertFalse(SetupOfferStore(dataFolder: none.dir + "/data").shouldOffer(none.plan))
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SetupEvent] = []
    func add(_ event: SetupEvent) { lock.withLock { all.append(event) } }
    func statuses(for id: String) -> [String] { lock.withLock { all.filter { $0.stepID == id }.map(\.status) } }
}
