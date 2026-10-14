import XCTest
@testable import BlackTeamKit

/// The unit text for both platforms, and installing and removing it in a temporary home with a fake systemctl and launchctl.
final class ServiceUnitTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var active = "inactive", enabled = "disabled", systemctlWorks = true
        var list: [String] { lock.lock(); defer { lock.unlock() }; return all }
        func add(_ text: String) { lock.lock(); all.append(text); lock.unlock() }
        func runner() -> ServiceCommandRunner {
            { [self] program, arguments in
                add(([program] + arguments).joined(separator: " "))
                if program == "systemctl" {
                    if !systemctlWorks { return ServiceCommandResult(status: 127, output: "not found") }
                    if arguments.contains("is-enabled") { return ServiceCommandResult(status: 0, output: enabled) }
                    if arguments.contains("is-active") { return ServiceCommandResult(status: 0, output: active) }
                }
                return ServiceCommandResult(status: 0, output: "")
            }
        }
    }

    func home() throws -> String {
        let folder = (PathUtil.realpath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bt-unit-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: folder + "/data", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        return folder
    }

    func unit(_ program: String = "/opt/black team/bin/black-team") -> ServiceUnit {
        ServiceUnit(program: program, arguments: ["service", "run"], path: "/home/me/.local/bin:/usr/bin", logFile: "/home/me/Library/Logs/Black Team/service.log")
    }

    // MARK: Text

    func testTheSystemdUnitRunsTheServiceAsTheUserWithHardeningThatLeavesToolsAlone() throws {
        let text = try unit().systemdText()
        XCTAssertTrue(text.hasPrefix("# black-team-managed-v1\n"))
        XCTAssertTrue(text.contains("ExecStart=\"/opt/black team/bin/black-team\" \"service\" \"run\"\n"))
        XCTAssertTrue(text.contains("Environment=\"PATH=/home/me/.local/bin:/usr/bin\"\n"))
        XCTAssertTrue(text.contains("Restart=on-failure\n"))
        XCTAssertTrue(text.contains("NoNewPrivileges=yes\n"))
        XCTAssertTrue(text.contains("WantedBy=default.target\n"))
        XCTAssertTrue(text.contains("UMask=0077\n"))
        // Nothing that would stop a Code run from using its tools or the home folder.
        for forbidden in ["User=", "ProtectHome", "ProtectSystem", "PrivateTmp", "MemoryDenyWriteExecute", "PrivateDevices", "SystemCallFilter", "CapabilityBoundingSet"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertFalse(text.contains("/bin/sh"))
    }

    func testSystemdQuotingStopsPathsFromBeingReadAsAnythingButAPath() throws {
        let odd = ServiceUnit(program: "/opt/a\"b$c%d\\e/black-team", arguments: ["service", "run", "--data", "/data/100%"], path: "/usr/bin")
        let text = try odd.systemdText()
        XCTAssertTrue(text.contains("\"/opt/a\\\"b$$c%%d\\\\e/black-team\""))
        XCTAssertTrue(text.contains("\"/data/100%%\""))
        XCTAssertThrowsError(try ServiceUnit(program: "/opt/x\nExecStartPre=/bin/evil", path: "/usr/bin").systemdText())
        XCTAssertThrowsError(try ServiceUnit(program: "/opt/x", path: "/usr/bin\n[Install]").systemdText())
    }

    func testTheLaunchdPlistRunsAtLoginAndRestartsOnlyAfterAFailure() throws {
        let text = try ServiceUnit(program: "/Applications/Black Team.app/Contents/MacOS/black-team", arguments: ["service", "run", "--data", "/Users/me/A&B"],
                                   path: "/usr/bin:/bin", logFile: "/Users/me/Library/Logs/Black Team/service.log").launchdText()
        XCTAssertTrue(text.contains("<key>Label</key>\n    <string>com.blackteam.service</string>"))
        XCTAssertTrue(text.contains("<string>/Applications/Black Team.app/Contents/MacOS/black-team</string>"))
        XCTAssertTrue(text.contains("<string>service</string>\n        <string>run</string>"))
        XCTAssertTrue(text.contains("<string>/Users/me/A&amp;B</string>"))
        XCTAssertTrue(text.contains("<key>RunAtLoad</key>\n    <true/>"))
        XCTAssertTrue(text.contains("<key>SuccessfulExit</key>\n        <false/>"))
        XCTAssertTrue(text.contains("<key>Umask</key>\n    <integer>63</integer>"))
        XCTAssertTrue(text.contains("<key>StandardErrorPath</key>\n    <string>/Users/me/Library/Logs/Black Team/service.log</string>"))
        XCTAssertTrue(text.contains("black-team-managed-v1"))
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"))
        XCTAssertTrue(text.hasSuffix("</dict>\n</plist>\n"))
        // It parses as a property list, with the program and its arguments as separate strings.
        let parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil) as? [String: Any]
        XCTAssertEqual(parsed?["ProgramArguments"] as? [String], ["/Applications/Black Team.app/Contents/MacOS/black-team", "service", "run", "--data", "/Users/me/A&B"])
        XCTAssertEqual((parsed?["EnvironmentVariables"] as? [String: String])?["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(parsed?["RunAtLoad"] as? Bool, true)
    }

    func testAnUpdateKeepsTheUnitPointingAtTheCurrentLink() throws {
        let root = try home() + "/share/black-team"
        try FileManager.default.createDirectory(atPath: root + "/releases/0.1.0/resources/app/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/current", withDestinationPath: "releases/0.1.0")
        XCTAssertEqual(ServiceUnit.stableProgramPath(root + "/releases/0.1.0/resources/app/bin/black-team"), root + "/current/resources/app/bin/black-team")
        // Not a packaged install: left as it is.
        XCTAssertEqual(ServiceUnit.stableProgramPath("/work/macos/.build/debug/black-team"), "/work/macos/.build/debug/black-team")
        let made = try ServiceUnit.forThisProgram(executable: root + "/releases/0.1.0/resources/app/bin/black-team", dataFolder: nil, environment: ["PATH": "/usr/bin:relative/bin"], home: "/home/me")
        XCTAssertEqual(made.program, root + "/current/resources/app/bin/black-team")
        XCTAssertEqual(made.arguments, ["service", "run"])
        XCTAssertTrue(made.path.hasPrefix("/usr/bin:/home/me/.local/bin"))
        XCTAssertFalse(made.path.contains("relative"))
        let custom = try ServiceUnit.forThisProgram(executable: "/x/black-team", dataFolder: "/scratch/data", environment: [:], home: "/home/me")
        XCTAssertEqual(custom.arguments, ["service", "run", "--data", "/scratch/data"])
    }

    // MARK: Installing and removing

    func testInstallWritesOnlyTheUnitAndEnablesItAndUninstallRemovesExactlyThat() async throws {
        let home = try home(), calls = Calls()
        let manager = ServiceManager(platform: .systemd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 1000)
        XCTAssertFalse(manager.isInstalled())
        let path = try await manager.install(unit("/opt/black-team/bin/black-team"))
        XCTAssertEqual(path, home + "/.config/systemd/user/black-team.service")
        XCTAssertTrue(manager.isInstalled())
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), try unit("/opt/black-team/bin/black-team").systemdText())
        // It enabled it for the next login but did not start it.
        XCTAssertTrue(calls.list.contains("systemctl --user enable black-team.service"))
        XCTAssertFalse(calls.list.contains { $0.contains(" start ") || $0.contains("--now") })
        // Nothing but the unit was written under the home folder (and the record in the data folder).
        let written = (FileManager.default.enumerator(atPath: home)?.allObjects as? [String] ?? []).filter { !$0.hasPrefix("data") }.sorted()
        XCTAssertEqual(written, [".config", ".config/systemd", ".config/systemd/user", ".config/systemd/user/black-team.service"])

        let removed = try await manager.uninstall()
        XCTAssertTrue(removed)
        XCTAssertFalse(manager.isInstalled())
        XCTAssertTrue(calls.list.contains("systemctl --user disable --now black-team.service"))
        // The folders the install made are gone again, and nothing is left behind.
        XCTAssertEqual((FileManager.default.enumerator(atPath: home)?.allObjects as? [String] ?? []).sorted(), ["data"])
        // A second uninstall has nothing to do.
        let again = try await manager.uninstall()
        XCTAssertFalse(again)
    }

    func testInstallingAgainChangesNothingAndAFolderThatWasThereBeforeStays() async throws {
        let home = try home(), calls = Calls()
        try FileManager.default.createDirectory(atPath: home + "/.config/systemd/user", withIntermediateDirectories: true)
        try "keep".write(toFile: home + "/.config/systemd/user/other.service", atomically: true, encoding: .utf8)
        let manager = ServiceManager(platform: .systemd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 1000)
        let first = try await manager.install(unit())
        let before = try String(contentsOfFile: first, encoding: .utf8)
        var attributes = try FileManager.default.attributesOfItem(atPath: first)
        let modified = attributes[.modificationDate] as? Date
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await manager.install(unit())
        XCTAssertEqual(try String(contentsOfFile: first, encoding: .utf8), before)
        attributes = try FileManager.default.attributesOfItem(atPath: first)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified, "an identical unit is not rewritten")
        // A changed unit (a new program path after an update) replaces ours.
        _ = try await manager.install(unit("/opt/new/black-team"))
        XCTAssertTrue(try String(contentsOfFile: first, encoding: .utf8).contains("/opt/new/black-team"))
        let removed = try await manager.uninstall()
        XCTAssertTrue(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.config/systemd/user/other.service"), "someone else's unit is not ours to remove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.config/systemd/user"), "a folder that was already there stays")
    }

    func testAFileThatIsNotOursIsNeverReplacedOrRemoved() async throws {
        let home = try home(), calls = Calls()
        let path = home + "/.config/systemd/user/black-team.service"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "[Unit]\nDescription=mine\n".write(toFile: path, atomically: true, encoding: .utf8)
        let manager = ServiceManager(platform: .systemd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 1000)
        XCTAssertFalse(manager.isInstalled())
        do { _ = try await manager.install(unit()); XCTFail("should have refused") }
        catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("will not replace it") == true) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[Unit]\nDescription=mine\n")
        let again = try await manager.uninstall()
        XCTAssertFalse(again)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[Unit]\nDescription=mine\n")
    }

    func testWithoutSystemctlNothingIsWritten() async throws {
        let home = try home(), calls = Calls()
        calls.systemctlWorks = false
        let manager = ServiceManager(platform: .systemd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 1000)
        do { _ = try await manager.install(unit()); XCTFail("should have refused") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("systemctl") == true) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.config"))
        let state = await manager.state()
        XCTAssertFalse(state.supported)
    }

    func testStartStopRestartAndStateUseSystemctlForTheUserOnly() async throws {
        let home = try home(), calls = Calls()
        let manager = ServiceManager(platform: .systemd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 1000)
        do { try await manager.start(); XCTFail("not installed") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("not turned on") == true) }
        _ = try await manager.install(unit())
        try await manager.start(); try await manager.restart(); try await manager.stop()
        XCTAssertTrue(calls.list.contains("systemctl --user start black-team.service"))
        XCTAssertTrue(calls.list.contains("systemctl --user restart black-team.service"))
        XCTAssertTrue(calls.list.contains("systemctl --user stop black-team.service"))
        XCTAssertTrue(calls.list.allSatisfy { !$0.hasPrefix("sudo") && ($0.hasPrefix("systemctl --user") || $0.hasPrefix("journalctl --user")) })
        calls.enabled = "enabled"; calls.active = "active"
        let state = await manager.state()
        XCTAssertEqual(state, ServiceUnitState(supported: true, installed: true, enabled: true, active: true, path: home + "/.config/systemd/user/black-team.service"))
    }

    func testLaunchdInstallWritesTheAgentAndRemovesTheFoldersItMade() async throws {
        let home = try home(), calls = Calls()
        let manager = ServiceManager(platform: .launchd, home: home, dataFolder: home + "/data", runner: calls.runner(), uid: 501)
        var agent = unit("/Applications/Black Team.app/Contents/MacOS/black-team")
        agent.logFile = home + "/Library/Logs/Black Team/service.log"
        let path = try await manager.install(agent)
        XCTAssertEqual(path, home + "/Library/LaunchAgents/com.blackteam.service.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Logs/Black Team"))
        XCTAssertTrue(calls.list.contains("launchctl bootstrap gui/501 \(path)"))
        XCTAssertTrue(calls.list.contains("launchctl enable gui/501/com.blackteam.service"))
        XCTAssertTrue(manager.isInstalled())
        let removed = try await manager.uninstall()
        XCTAssertTrue(removed)
        XCTAssertTrue(calls.list.contains("launchctl bootout gui/501/com.blackteam.service"))
        XCTAssertEqual((FileManager.default.enumerator(atPath: home)?.allObjects as? [String] ?? []).sorted(), ["data"])
    }

    func testTheSetupPlanListsTheBackgroundServiceUntickedAndInstallsOnlyWhenApproved() async throws {
        let found = DiscoveryResult(terminals: [], apps: [], presets: [], runtime: "", dictation: "", graph: "")
        var context = SetupContext(found: found, hermesInstalls: [], settings: IntegrationSettings(), hermesSupported: false, tooling: HermesTooling(),
                                   serviceSupported: true, serviceInstalled: false)
        var plan = buildSetupPlan(context)
        let step = try XCTUnwrap(plan.steps.first { $0.id == "background-service" })
        XCTAssertTrue(step.optIn)
        XCTAssertEqual(step.state, .willDo)
        XCTAssertTrue(step.approvable)
        // It is never offered unasked: the plan counts as complete without it.
        XCTAssertTrue(plan.pending.isEmpty)
        XCTAssertTrue(plan.isComplete)
        context.serviceInstalled = true
        plan = buildSetupPlan(context)
        XCTAssertEqual(plan.steps.first { $0.id == "background-service" }?.state, .done)
        // Not supported here: not listed.
        context.serviceSupported = false
        XCTAssertNil(buildSetupPlan(context).steps.first { $0.id == "background-service" })

        // Approving other steps does not touch it; approving it installs through the installer it was given.
        final class Installer: ServiceInstalling, @unchecked Sendable {
            var installs = 0
            func isInstalled() -> Bool { installs > 0 }
            func install() async throws -> String { installs += 1; return "/unit" }
        }
        let installer = Installer()
        context.serviceSupported = true; context.serviceInstalled = false
        let store = Integrations(stateDir: try home() + "/data")
        let services = SetupServices(store: store, context: { context }, installer: FailingInstaller(), service: installer)
        let none = await applySetup(approved: [], services: services)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(installer.installs, 0)
        let results = await applySetup(approved: ["background-service"], services: services)
        XCTAssertEqual(results.map(\.status), ["done"])
        XCTAssertEqual(installer.installs, 1)
    }

    struct FailingInstaller: HermesInstalling {
        func install(progress: (@Sendable (HermesInstallEvent) -> Void)?) async throws -> HermesInstall { throw BlackTeamError("not used") }
        func cancel() {}
    }
}
