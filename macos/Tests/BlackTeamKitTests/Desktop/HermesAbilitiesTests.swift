import XCTest
@testable import BlackTeamKit

// The tool groups, skills, plugins, web search and MCP servers a person can switch on for Hermes conversations. No Hermes is run:
// the install is a small folder written here in the shape Hermes uses (hand-written fixtures), and the "install's Python" that is asked
// for its tool table is /bin/sh running a script that prints a fixed answer.

/// A fake Hermes install, a data folder, a scripts folder and the service over them.
final class AbilityRig {
    let root: String
    let data: String
    let source: String
    let scripts: String
    let home: String
    let integrations: Integrations
    let service: HermesAbilitiesService

    static let answer: [String: JSONValue] = [
        "version": 1,
        "toolsets": [
            ["name": "terminal", "description": "Terminal/command execution", "tools": ["terminal", "process_manage"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "file", "description": "File tools", "tools": ["read_file", "write_file"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "todo", "description": "Task planning", "tools": ["todo_list"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "skills", "description": "Skill documents", "tools": ["skills_list", "skill_view"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "web", "description": "Web research", "tools": ["web_search", "web_extract"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "browser", "description": "Browser automation", "tools": ["browser_navigate", "terminal"], "includes": [], "posture": false, "requiresEnv": [], "ready": false],
            ["name": "computer_use", "description": "Desktop control", "tools": ["computer_use"], "includes": [], "posture": false, "requiresEnv": [], "ready": false],
            ["name": "vision", "description": "Image analysis", "tools": ["vision_analyze"], "includes": [], "posture": false, "requiresEnv": ["SOME_KEY"], "ready": false],
            ["name": "cronjob", "description": "Scheduled tasks", "tools": ["cronjob_manage"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "hermes-telegram", "description": "Telegram bot toolset", "tools": ["terminal", "web_search"], "includes": [], "posture": false, "requiresEnv": [], "ready": true],
            ["name": "coding", "description": "Coding shortcut", "tools": ["terminal"], "includes": [], "posture": true, "requiresEnv": [], "ready": true],
            ["name": "debugging", "description": "Shortcut of others", "tools": ["terminal"], "includes": ["web", "file"], "posture": false, "requiresEnv": [], "ready": true],
        ],
        "tools": [
            "terminal": ["chars": 4000], "process_manage": ["chars": 2400], "read_file": ["chars": 2000], "write_file": ["chars": 1600], "todo_list": ["chars": 1300],
            "skills_list": ["chars": 2000], "skill_view": ["chars": 2800], "web_search": ["chars": 760], "web_extract": ["chars": 1000], "browser_navigate": ["chars": 4000],
            "computer_use": ["chars": 5800], "vision_analyze": ["chars": 800], "cronjob_manage": ["chars": 7000],
        ],
        "companion": ["companion_files": ["chars": 1200]],
    ]

    init(_ test: XCTestCase, connected: Bool = true) throws {
        root = NSTemporaryDirectory() + "bt-abilities-" + UUID().uuidString.lowercased()
        data = root + "/data"; source = root + "/hermes"; scripts = root + "/app/scripts"; home = root + "/home"
        let manager = FileManager.default
        for folder in [data, source, scripts, home, root + "/app/plugins/companion-tools"] { try manager.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let created = root; test.addTeardownBlock { try? FileManager.default.removeItem(atPath: created) }
        try "".write(toFile: source + "/hermes_bootstrap.py", atomically: true, encoding: .utf8)
        try "".write(toFile: source + "/cli.py", atomically: true, encoding: .utf8)
        try "TOOLSETS = {}\n".write(toFile: source + "/toolsets.py", atomically: true, encoding: .utf8)
        // The "helper" is a shell script; it is run with /bin/sh as the interpreter and prints what the real one would.
        let line = JSONValue.object(AbilityRig.answer).text()
        try "#!/bin/sh\necho 'noise on stdout'\nprintf 'BT_ABILITIES=%s\\n' '\(line)'\n".write(toFile: scripts + "/hermes-abilities.py", atomically: true, encoding: .utf8)
        try "".write(toFile: root + "/app/plugins/companion-tools/__init__.py", atomically: true, encoding: .utf8)
        integrations = Integrations(stateDir: data)
        integrations.hermesSupported = true
        if connected {
            _ = try integrations.save(.object(["hermes": .object(["enabled": true, "python": "/bin/sh", "source": .string(source), "coding": true, "browser": false, "desktop": false])]))
        }
        service = HermesAbilitiesService(dataFolder: data, integrations: integrations, scripts: scripts, home: home)
    }

    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func skill(_ category: String, _ name: String, _ front: String, optional: Bool = false) throws {
        try write(source + (optional ? "/optional-skills/" : "/skills/") + category + "/" + name + "/SKILL.md", "---\n" + front + "\n---\n\n# Body that must never be read\n")
    }

    func plugin(_ path: String, _ yaml: String, base: String? = nil) throws { try write((base ?? source + "/plugins") + "/" + path + "/plugin.yaml", yaml) }

    func settings() throws -> HermesSettings { try integrations.read().hermes }
    func plan() throws -> HermesProfilePlan { HermesProfilePlan.make(settings: try settings(), store: service.store, keys: service.keys, home: home) }

    func overview(context: Int = 32768) async -> JSONValue { await service.overview(context: context) }
}

final class HermesAbilitiesTests: XCTestCase {
    // MARK: Tool groups

    func testGroupsAreReadFromTheInstallWithPlainLabels() async throws {
        let rig = try AbilityRig(self)
        let view = await rig.overview()
        let groups = try XCTUnwrap(view["groups"]?.array)
        func group(_ name: String) -> JSONValue? { groups.first { $0["name"]?.string == name } }
        XCTAssertEqual(group("terminal")?["labelText"]?.string, "Works on \(Place.this)")
        XCTAssertEqual(group("web")?["labelText"]?.string, "Uses the internet")
        XCTAssertEqual(group("browser")?["labelText"]?.string, "Uses the internet")
        XCTAssertEqual(group("vision")?["labelText"]?.string, "Needs an account or key")
        // Software that is not set up yet is still "works on this computer", but Hermes's own word is passed on.
        XCTAssertEqual(group("computer_use")?["labelText"]?.string, "Works on \(Place.this)")
        XCTAssertEqual(group("computer_use")?["ready"]?.bool, false)
        // Platform bundles and the scheduler are the always-running service: shown, off, locked, with the reason.
        for name in ["hermes-telegram", "cronjob"] {
            XCTAssertEqual(group(name)?["labelText"]?.string, "Needs the always-running service")
            XCTAssertEqual(group(name)?["locked"]?.bool, true)
            XCTAssertEqual(group(name)?["on"]?.bool, false)
            XCTAssertTrue(group(name)?["reason"]?.string?.contains("always-running") == true)
        }
        // Hermes's shortcuts of other groups are not groups to switch.
        XCTAssertNil(group("coding")); XCTAssertNil(group("debugging"))
        // A group the install lacks is simply not there.
        XCTAssertNil(group("homeassistant"))
        XCTAssertEqual(group("terminal")?["tokens"]?.int, HermesAbilities.tokens(4000 + 2400))
        XCTAssertEqual(group("terminal")?["description"]?.string, "Terminal/command execution")
    }

    func testTheHelperOutputDecodesAndAnInstallThatCannotAnswerStillListsNothingFalse() async throws {
        let line = JSONValue.object(AbilityRig.answer).text()
        let probe = try JSONDecoder().decode(HermesProbe.self, from: Data(line.utf8))
        XCTAssertEqual(probe.companionCharacters, 1200)
        XCTAssertEqual(probe.toolsets.count, 12)
        let rig = try AbilityRig(self)
        try rig.write(rig.scripts + "/hermes-abilities.py", "#!/bin/sh\nexit 3\n")
        let view = await rig.overview()
        XCTAssertEqual(view["connected"]?.bool, true)
        XCTAssertEqual(view["groups"]?.array?.count, 0)
        XCTAssertNotNil(view["problem"]?.string)
        let off = try AbilityRig(self, connected: false)
        let offView = await off.overview()
        XCTAssertEqual(offView["connected"]?.bool, false)
    }

    func testTheInstallIsAskedOnceAndTheAnswerKeptUntilItChanges() async throws {
        let rig = try AbilityRig(self)
        let counter = rig.root + "/asked.txt"
        let line = JSONValue.object(AbilityRig.answer).text()
        try rig.write(rig.scripts + "/hermes-abilities.py", "#!/bin/sh\necho x >> '\(counter)'\nprintf 'BT_ABILITIES=%s\\n' '\(line)'\n")
        func asked() -> Int { ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }
        _ = await rig.overview()
        let again = await rig.overview()
        XCTAssertEqual(asked(), 1, "the saved answer serves the next read")
        XCTAssertFalse(try XCTUnwrap(again["groups"]?.array).isEmpty)
        // "Read again" asks the install again.
        _ = await rig.service.overview(context: 1000, refresh: true)
        XCTAssertEqual(asked(), 2)
        // A helper that fails leaves the groups out with a sentence, and nothing is saved from it.
        try rig.write(rig.scripts + "/hermes-abilities.py", "#!/bin/sh\nexit 3\n")
        let broken = await rig.service.overview(context: 1000, refresh: true)
        XCTAssertNotNil(broken["problem"]?.string)
    }

    // MARK: Old settings

    func testTheOldSwitchesMigrateToToolGroups() throws {
        var legacy = HermesSettings()
        XCTAssertEqual(HermesAbilitySettings().chosenToolsets(legacy: legacy), ["terminal", "file", "todo"])
        legacy.browser = true; legacy.desktop = true
        XCTAssertEqual(HermesAbilitySettings().chosenToolsets(legacy: legacy), ["terminal", "file", "todo", "browser", "computer_use"])
        legacy.coding = false; legacy.browser = false
        XCTAssertEqual(HermesAbilitySettings().chosenToolsets(legacy: legacy), ["computer_use"])
        // Once a choice is saved it decides, whatever the old switches say.
        var chosen = HermesAbilitySettings(); chosen.toolsets = ["web"]
        XCTAssertEqual(chosen.chosenToolsets(legacy: HermesSettings()), ["web"])
    }

    func testAnUntouchedConnectionPassesExactlyWhatItDidBefore() throws {
        let rig = try AbilityRig(self)
        let plan = try rig.plan()
        XCTAssertEqual(plan.toolsets, ["companion", "terminal", "file", "todo"])
        XCTAssertEqual(plan.enabledPlugins, ["companion-tools"])
        XCTAssertTrue(plan.skillLinks.isEmpty)
        // Browser and desktop control stay opt-in: the old switches are the only way they come on before a choice is saved.
        XCTAssertFalse(plan.toolsets.contains("browser")); XCTAssertFalse(plan.toolsets.contains("computer_use"))
    }

    func testSettingsFromAnOldFileStillDecode() throws {
        let old = try JSONDecoder().decode(HermesSettings.self, from: Data(#"{"enabled":true,"python":"/p","source":"/s","coding":false,"browser":true}"#.utf8))
        XCTAssertTrue(old.browser); XCTAssertFalse(old.coding); XCTAssertFalse(old.desktop)
        let abilities = try JSONDecoder().decode(HermesAbilitySettings.self, from: Data("{}".utf8))
        XCTAssertNil(abilities.toolsets); XCTAssertTrue(abilities.ownSkills)
    }

    // MARK: Cost

    func testCostArithmeticCountsEachToolOnceAndWarnsRelativeToTheContext() async throws {
        XCTAssertEqual(HermesAbilities.tokens(4000), 1000)
        XCTAssertEqual(HermesAbilities.tokens(0), 0)
        let rig = try AbilityRig(self)
        _ = try await rig.service.save(["toolsets": ["terminal", "browser"]])
        let view = await rig.overview(context: 100_000)
        // companion 1200 + terminal 4000 + process_manage 2400 + browser_navigate 4000 (browser also lists terminal: counted once).
        XCTAssertEqual(view["total"]?["tokens"]?.int, HermesAbilities.tokens(1200 + 4000 + 2400 + 4000))
        XCTAssertNil(view["total"]?["warning"])
        let tight = await rig.overview(context: 8192)
        let warning = try XCTUnwrap(tight["total"]?["warning"]?.string)
        XCTAssertTrue(warning.contains("about 2900 tokens"), warning)
        XCTAssertTrue(warning.contains("every message"))
        XCTAssertNil(HermesCatalog.warning(tokens: 100, context: 0))
        XCTAssertNil(HermesCatalog.warning(tokens: 1999, context: 10_000))
        XCTAssertNotNil(HermesCatalog.warning(tokens: 2000, context: 10_000))
    }

    // MARK: Skills

    func skillFixture(_ rig: AbilityRig) throws {
        try rig.skill("devops", "deploy", #"name: deploy"# + "\n" + "description: \"Ship a build, \\\"safely\\\".\"" + "\n" + "platforms: [linux, macos]")
        try rig.skill("devops", "logs", "name: logs\ndescription: Read service logs.")
        try rig.skill("creative", "diagram", "name: diagram\ndescription: >\n  Draw diagrams\n  from code.")
        try rig.skill("creative", "mac-only", "name: mac-only\ndescription: Only on a platform we are not.\nplatforms: [windows]")
        try rig.skill("research", "papers", "name: papers\ndescription: Find papers.", optional: true)
        try rig.write(rig.source + "/skills/devops/DESCRIPTION.md", "---\ndescription: Operations work\n---\n")
    }

    func testSkillsAreListedFromFrontMatterOnlyWithOptionalOnesOff() async throws {
        let rig = try AbilityRig(self)
        try skillFixture(rig)
        let view = await rig.overview()
        let categories = try XCTUnwrap(view["skills"]?["categories"]?.array)
        XCTAssertEqual(categories.compactMap { $0["name"]?.string }, ["creative", "devops"])
        let devops = try XCTUnwrap(categories.first { $0["name"]?.string == "devops" })
        XCTAssertEqual(devops["description"]?.string, "Operations work")
        let deploy = try XCTUnwrap(devops["skills"]?.array?.first { $0["id"]?.string == "devops/deploy" })
        XCTAssertEqual(deploy["description"]?.string, "Ship a build, \"safely\".")
        XCTAssertEqual(deploy["on"]?.bool, false)
        let creative = try XCTUnwrap(categories.first { $0["name"]?.string == "creative" })
        XCTAssertEqual(creative["skills"]?.array?.map { $0["id"]?.string }, ["creative/diagram"], "a skill for another system is not listed")
        XCTAssertEqual(creative["skills"]?[0]?["description"]?.string, "Draw diagrams from code.")
        let optional = try XCTUnwrap(view["skills"]?["optional"]?.array)
        XCTAssertEqual(optional.map { $0["id"]?.string }, ["research/papers"])
        XCTAssertNil(optional[0]["on"], "optional skills have no switch")
        // Optional skills cannot be switched on.
        do { _ = try await rig.service.save(["skills": ["research/papers"]]); XCTFail("accepted") }
        catch { XCTAssertTrue(messageOf(error).contains("Optional skills stay off")) }
    }

    func testChosenSkillsAreLinkedNotCopiedAndTheSkillsGroupComesOn() async throws {
        let rig = try AbilityRig(self)
        try skillFixture(rig)
        _ = try await rig.service.save(["skills": ["devops/deploy", "creative/diagram"], "toolsets": ["terminal"]])
        var plan = try rig.plan()
        XCTAssertEqual(plan.toolsets, ["companion", "terminal", "skills"])
        let profile = rig.root + "/profile"
        try plan.link(into: profile)
        let manager = FileManager.default
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: profile + "/skills/devops/deploy"), rig.source + "/skills/devops/deploy")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: profile + "/skills/devops/DESCRIPTION.md"), rig.source + "/skills/devops/DESCRIPTION.md")
        XCTAssertTrue(CoreFS.exists(profile + "/skills/devops/deploy/SKILL.md"), "the link reaches the install's skill")
        XCTAssertFalse(CoreFS.exists(profile + "/skills/devops/logs"))
        // A skill the agent wrote into the profile itself is never touched; a deselected link goes, and so does its empty category.
        try rig.write(profile + "/skills/devops/agent-made/SKILL.md", "---\nname: agent-made\n---\n")
        _ = try await rig.service.save(["skills": ["devops/logs"]])
        plan = try rig.plan()
        try plan.link(into: profile)
        XCTAssertFalse(CoreFS.exists(profile + "/skills/devops/deploy"))
        XCTAssertFalse(CoreFS.exists(profile + "/skills/creative"))
        XCTAssertTrue(CoreFS.isSymlink(profile + "/skills/devops/logs"))
        XCTAssertTrue(CoreFS.exists(profile + "/skills/devops/agent-made/SKILL.md"))
        // Nothing chosen: no skills group is added.
        _ = try await rig.service.save(["skills": []])
        XCTAssertFalse(try rig.plan().toolsets.contains("skills"))
    }

    func testYourOwnSkillsFolderIsLinkedWhenItHoldsASkill() async throws {
        let rig = try AbilityRig(self)
        let own = HermesAbilities.ownSkillsPath(rig.data)
        XCTAssertTrue(try rig.plan().skillLinks.isEmpty, "an empty folder links nothing")
        try rig.write(own + "/my-notes/SKILL.md", "---\nname: my-notes\ndescription: Mine.\n---\n")
        let plan = try rig.plan()
        XCTAssertEqual(plan.skillLinks["own"], own)
        XCTAssertTrue(plan.toolsets.contains("skills"))
        let view = await rig.overview()
        XCTAssertEqual(view["skills"]?["own"]?["count"]?.int, 1)
        _ = try await rig.service.save(["ownSkills": false])
        XCTAssertNil(try rig.plan().skillLinks["own"])
    }

    func testTheSkillIndexIsCountedAsListingOnly() async throws {
        let rig = try AbilityRig(self)
        try skillFixture(rig)
        let before = await rig.overview(context: 100_000)
        _ = try await rig.service.save(["skills": ["devops/deploy", "devops/logs"], "toolsets": ["terminal"]])
        let after = await rig.overview(context: 100_000)
        _ = before
        let skills = HermesCatalog.skills(source: rig.source).skills.filter { ["devops/deploy", "devops/logs"].contains($0.id) }
        let index = HermesCatalog.indexCharacters(for: skills, categoryDescriptions: ["devops": "Operations work"])
        XCTAssertEqual(after["skills"]?["indexTokens"]?.int, HermesAbilities.tokens(index))
        XCTAssertGreaterThan(index, 1100); XCTAssertLessThan(index, 1500)
        // companion 1200 + terminal group 6400 + the skills group's tools 4800 + the index: never the text of a skill.
        XCTAssertEqual(after["total"]?["tokens"]?.int, HermesAbilities.tokens(1200 + 6400 + 4800 + index))
    }

    // MARK: Plugins and web search

    func pluginFixture(_ rig: AbilityRig) throws {
        try rig.plugin("disk-cleanup", "name: disk-cleanup\nversion: 2.0.0\ndescription: \"Clean up temp files.\"\nprovides_hooks:\n  - pre_tool_call\n")
        try rig.plugin("observability/langfuse", "name: langfuse\ndescription: Optional traces.\nrequires_env:\n  - HERMES_LANGFUSE_PUBLIC_KEY\n  - HERMES_LANGFUSE_SECRET_KEY\n")
        try rig.plugin("memory/mem0", "name: mem0\ndescription: Memory provider.\n")
        try rig.plugin("platforms/telegram", "name: telegram-platform\nkind: platform\ndescription: Telegram.\nrequires_env:\n  - name: TELEGRAM_BOT_TOKEN\n    password: true\n")
        try rig.plugin("web/ddgs", "name: web-ddgs\ndescription: \"DuckDuckGo search, no API key required. Install with `pip install ddgs`.\"\nkind: backend\nprovides_web_providers:\n  - ddgs\n")
        try rig.plugin("web/brave_free", "name: web-brave-free\ndescription: \"Brave Search (free tier). Requires BRAVE_SEARCH_API_KEY.\"\nkind: backend\nprovides_web_providers:\n  - brave-free\n")
        try rig.plugin("web/searxng", "name: web-searxng\ndescription: \"Self-hosted. Requires SEARXNG_URL pointing at your instance.\"\nkind: backend\nprovides_web_providers:\n  - searxng\n")
        try rig.plugin("model-providers/openai", "name: openai\nkind: model-provider\n")
        try rig.plugin("my-tool", "name: my-tool\ndescription: Mine.\nprovides_tools:\n  - my_tool\n", base: rig.home + "/.hermes/plugins")
    }

    func testPluginsAreListedWithLabelsAndMemoryAndPlatformsStayOff() async throws {
        let rig = try AbilityRig(self)
        try pluginFixture(rig)
        let view = await rig.overview()
        let plugins = try XCTUnwrap(view["plugins"]?.array)
        func plugin(_ key: String) -> JSONValue? { plugins.first { $0["key"]?.string == key } }
        XCTAssertEqual(plugin("disk-cleanup")?["labelText"]?.string, "Works on \(Place.this)")
        XCTAssertEqual(plugin("disk-cleanup")?["locked"]?.bool, false)
        XCTAssertEqual(plugin("observability/langfuse")?["labelText"]?.string, "Needs an account or key")
        XCTAssertTrue(plugin("observability/langfuse")?["note"]?.string?.contains("conversations") == true, "a plugin that reports conversations says so")
        XCTAssertEqual(plugin("memory/mem0")?["locked"]?.bool, true)
        XCTAssertTrue(plugin("memory/mem0")?["reason"]?.string?.contains("memory vault") == true)
        XCTAssertEqual(plugin("platforms/telegram")?["labelText"]?.string, "Needs the always-running service")
        XCTAssertEqual(plugin("my-tool")?["yours"]?.bool, true)
        XCTAssertNil(plugin("model-providers/openai"), "model providers are Black Team's job: the local model is pinned")
        XCTAssertNil(plugin("web/ddgs"), "search providers are chosen under web search")
        XCTAssertEqual(plugin("observability/langfuse")?["needs"]?.array?.map { $0["name"]?.string }, ["HERMES_LANGFUSE_PUBLIC_KEY", "HERMES_LANGFUSE_SECRET_KEY"])
        for key in ["memory/mem0", "platforms/telegram"] {
            do { _ = try await rig.service.save(["plugins": .array([.string(key)])]); XCTFail("accepted \(key)") }
            catch { XCTAssertFalse(messageOf(error).isEmpty) }
        }
    }

    func testEnabledPluginsReachTheProfileAndOneYouInstalledIsLinked() async throws {
        let rig = try AbilityRig(self)
        try pluginFixture(rig)
        _ = try await rig.service.save(["plugins": ["disk-cleanup", "my-tool"]])
        let plan = try rig.plan()
        XCTAssertEqual(plan.enabledPlugins, ["companion-tools", "disk-cleanup", "my-tool"])
        XCTAssertEqual(plan.pluginLinks, ["my-tool": rig.home + "/.hermes/plugins/my-tool"])
        XCTAssertTrue(plan.toolsets.contains("my-tool"), "a plugin with tools adds its own group")
        let profile = rig.root + "/profile"
        try FileManager.default.createDirectory(atPath: profile + "/plugins", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile + "/plugins/companion-tools", withDestinationPath: rig.root + "/app/plugins/companion-tools")
        try plan.link(into: profile)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile + "/plugins/my-tool"), rig.home + "/.hermes/plugins/my-tool")
        XCTAssertTrue(CoreFS.isSymlink(profile + "/plugins/companion-tools"), "Black Team's own plugin keeps its link")
        let config = plan.configExtras()
        XCTAssertEqual(config["plugins"]?["enabled"]?.array?.compactMap { $0.string }, plan.enabledPlugins)
    }

    func testWebSearchOffersKeylessFirstAndNeverFallsBackToVendorServices() async throws {
        let rig = try AbilityRig(self)
        try pluginFixture(rig)
        var view = await rig.overview()
        let providers = try XCTUnwrap(view["web"]?["providers"]?.array)
        XCTAssertEqual(providers.compactMap { $0["name"]?.string }, ["ddgs", "brave-free", "searxng"])
        XCTAssertEqual(providers[0]["needsKey"]?.bool, false)
        XCTAssertEqual(providers[0]["missingPackage"]?.string, "ddgs", "the package is named when the install lacks it")
        XCTAssertEqual(providers[1]["needs"]?.array?.map { $0["name"]?.string }, ["BRAVE_SEARCH_API_KEY"])
        XCTAssertEqual(providers[2]["needs"]?.array?.map { $0["name"]?.string }, ["SEARXNG_URL"])
        // With nothing chosen the profile still turns Hermes's free-vendor fallback off.
        XCTAssertEqual(try rig.plan().web["keyless_fallback"], false)
        XCTAssertNil(try rig.plan().web["search_backend"])
        _ = try await rig.service.save(["webSearch": "brave-free"])
        XCTAssertEqual(try rig.plan().web["search_backend"]?.string, "brave-free")
        do { _ = try await rig.service.save(["webSearch": "made-up"]); XCTFail("accepted") } catch { XCTAssertTrue(messageOf(error).contains("made-up")) }
        view = await rig.overview()
        XCTAssertEqual(view["web"]?["selected"]?.string, "brave-free")
    }

    // MARK: Keys

    func testKeysAreOwnerOnlyNeverShownAndReachHermesByEnvironmentOnly() async throws {
        let rig = try AbilityRig(self)
        try pluginFixture(rig)
        _ = try await rig.service.save(["webSearch": "brave-free", "plugins": ["observability/langfuse"]])
        let secret = "sk-very-secret-value-123"
        try await rig.service.setKey(name: "BRAVE_SEARCH_API_KEY", value: secret)
        try await rig.service.setKey(name: "HERMES_LANGFUSE_PUBLIC_KEY", value: "pk-other-secret")
        let mode = try FileManager.default.attributesOfItem(atPath: rig.service.keys.file)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Nothing the window can read holds a value.
        let view = await rig.overview()
        XCTAssertFalse(view.text().contains(secret)); XCTAssertFalse(view.text().contains("pk-other-secret"))
        let brave = try XCTUnwrap(view["web"]?["providers"]?.array?.first { $0["name"]?.string == "brave-free" })
        XCTAssertEqual(brave["needs"]?[0]?["configured"]?.bool, true)
        // The profile's config.yaml has no value; the environment has the ones that belong to what is switched on.
        let plan = try rig.plan()
        XCTAssertFalse(JSONValue.object(plan.configExtras()).text().contains(secret))
        XCTAssertEqual(plan.environment["BRAVE_SEARCH_API_KEY"], secret)
        XCTAssertEqual(plan.environment["HERMES_LANGFUSE_PUBLIC_KEY"], "pk-other-secret")
        // Switch the provider off: its key is no longer passed (it stays saved).
        _ = try await rig.service.save(["webSearch": "", "plugins": []])
        XCTAssertTrue(try rig.plan().environment.isEmpty)
        // Names: only ones something declares, and only well-formed ones.
        for name in ["lowercase", "PATH=x", "NOT_DECLARED_ANYWHERE"] {
            do { try await rig.service.setKey(name: name, value: "v"); XCTFail("accepted \(name)") } catch { XCTAssertFalse(messageOf(error).isEmpty) }
        }
        do { try await rig.service.setKey(name: "BRAVE_SEARCH_API_KEY", value: "two\nlines"); XCTFail("accepted") } catch { XCTAssertFalse(messageOf(error).isEmpty) }
        try await rig.service.setKey(name: "BRAVE_SEARCH_API_KEY", value: nil)
        XCTAssertFalse(rig.service.keys.names().contains("BRAVE_SEARCH_API_KEY"))
    }

    // MARK: MCP servers

    func testMcpEntriesAreCheckedLikeExternalLaunchers() throws {
        func refused(_ server: McpServer, _ fragment: String, line: UInt = #line) {
            XCTAssertThrowsError(try McpRules.validate(server), line: line) { XCTAssertTrue(messageOf($0).contains(fragment), "\(messageOf($0))", line: line) }
        }
        XCTAssertNoThrow(try McpRules.validate(McpServer(name: "ok-server", command: "/bin/sh", args: ["-c", "echo $HOME; ls | wc"], envNames: ["TOKEN"])))
        XCTAssertNoThrow(try McpRules.validate(McpServer(name: "local", url: "http://127.0.0.1:8000/mcp")))
        XCTAssertNoThrow(try McpRules.validate(McpServer(name: "local2", url: "http://localhost:9/mcp")))
        refused(McpServer(name: "rel", command: "bin/tool"), "full path")
        refused(McpServer(name: "rel2", command: "npx"), "full path")
        refused(McpServer(name: "shell", command: "/bin/sh -c 'x'"), "shell")
        refused(McpServer(name: "shell2", command: "/bin/sh; rm"), "shell")
        refused(McpServer(name: "missing", command: "/nonexistent/program"), "could not be found")
        refused(McpServer(name: "interp", command: "/bin/sh", args: ["${HOME}/x"]), "replace")
        refused(McpServer(name: "newline", command: "/bin/sh", args: ["a\nb"]), "one line")
        refused(McpServer(name: "Bad Name", command: "/bin/sh"), "lowercase")
        refused(McpServer(name: "both", command: "/bin/sh", url: "http://127.0.0.1:1/x"), "either")
        refused(McpServer(name: "none"), "either")
        refused(McpServer(name: "far", url: "https://example.com/mcp"), "on \(Place.this)")
        refused(McpServer(name: "far2", url: "http://192.168.1.5:80/mcp"), "on \(Place.this)")
        refused(McpServer(name: "creds", url: "http://user:pw@127.0.0.1:80/mcp"), "address like")
        refused(McpServer(name: "ftp", url: "ftp://127.0.0.1/mcp"), "address like")
        refused(McpServer(name: "args", args: ["x"], url: "http://127.0.0.1:80/mcp"), "no arguments")
        refused(McpServer(name: "envname", command: "/bin/sh", envNames: ["1BAD"]), "environment value")
        XCTAssertThrowsError(try McpRules.validate(McpServer(name: "dup", command: "/bin/sh"), others: [McpServer(name: "dup", command: "/bin/sh")]))
    }

    func testMcpServersGoIntoTheProfileWithValuesOnlyInTheEnvironmentAndTheirCostShowsOnceKnown() async throws {
        let rig = try AbilityRig(self)
        let entry: JSONValue = ["name": "notes", "command": "/bin/sh", "args": ["-c", "exec cat"], "envNames": ["API_TOKEN"], "enabled": true]
        _ = try await rig.service.save(["mcp": [entry]])
        try await rig.service.setKey(name: "mcp.notes.API_TOKEN", value: "mcp-secret-9")
        let plan = try rig.plan()
        let server = try XCTUnwrap(plan.mcpServers["notes"])
        XCTAssertEqual(server["command"]?.string, "/bin/sh")
        XCTAssertEqual(server["args"]?.array?.compactMap { $0.string }, ["-c", "exec cat"])
        XCTAssertEqual(server["env"]?["API_TOKEN"]?.string, "${BT_MCP_NOTES_API_TOKEN}")
        XCTAssertEqual(plan.environment["BT_MCP_NOTES_API_TOKEN"], "mcp-secret-9")
        XCTAssertFalse(JSONValue.object(plan.configExtras()).text().contains("mcp-secret-9"))
        XCTAssertTrue(plan.toolsets.contains("mcp-notes"))
        var view = await rig.overview()
        XCTAssertNil(view["mcp"]?[0]?["tokens"], "not measured before the first conversation")
        XCTAssertEqual(view["mcp"]?[0]?["env"]?[0]?["configured"]?.bool, true)
        XCTAssertFalse(view.text().contains("mcp-secret-9"))
        // The runner reports each tool's size; the server's tools are recognised by Hermes's naming and the total includes them.
        HermesToolReport.record(["tools": ["mcp__notes__read": 1200, "mcp__notes__write": 800, "terminal": 4000]], servers: ["notes"], store: rig.service.store)
        view = await rig.overview()
        XCTAssertEqual(view["mcp"]?[0]?["tokens"]?.int, 500)
        // Switching it off removes it from the profile; removing it forgets its values.
        _ = try await rig.service.save(["mcp": [entry.setting("enabled", false)]])
        XCTAssertTrue(try rig.plan().mcpServers.isEmpty)
        _ = try await rig.service.save(["mcp": []])
        XCTAssertFalse(rig.service.keys.names().contains("mcp.notes.API_TOKEN"))
        do { _ = try await rig.service.save(["mcp": [["name": "x", "command": "relative"]]]); XCTFail("accepted") } catch { XCTAssertTrue(messageOf(error).contains("full path")) }
        do { _ = try await rig.service.save(["unknown": 1]); XCTFail("accepted") } catch { XCTAssertEqual(messageOf(error), "Unsupported Hermes setting.") }
    }

    func testServiceGroupsCannotBeSwitchedOnAndUnknownOnesAreRefused() async throws {
        let rig = try AbilityRig(self)
        for name in ["hermes-telegram", "cronjob"] {
            do { _ = try await rig.service.save(["toolsets": [.string(name)]]); XCTFail("accepted \(name)") } catch { XCTAssertTrue(messageOf(error).contains("always-running")) }
        }
        do { _ = try await rig.service.save(["toolsets": ["nonsense"]]); XCTFail("accepted") } catch { XCTAssertTrue(messageOf(error).contains("no tool group")) }
        do { _ = try await rig.service.save(["toolsets": [5]]); XCTFail("accepted") } catch { XCTAssertEqual(messageOf(error), "Invalid Hermes setting.") }
        let unconnected = try AbilityRig(self, connected: false)
        do { _ = try await unconnected.service.save(["toolsets": ["terminal"]]); XCTFail("accepted") } catch { XCTAssertEqual(messageOf(error), "Connect Hermes first.") }
        _ = try await rig.service.save(["toolsets": ["web", "terminal", "terminal", "companion"]])
        XCTAssertEqual(rig.service.store.read().toolsets, ["web", "terminal"])
    }
}
