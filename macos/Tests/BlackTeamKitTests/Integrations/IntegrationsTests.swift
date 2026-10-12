import XCTest
@testable import BlackTeamKit

private struct FakeRuntime: HarnessRuntime {
    var key: String? = "fixture-secret"
    func start() async throws -> String { "http://127.0.0.1:1234/v1" }
    func requestHeaders() -> [String: String] { key.map { ["Authorization": "Bearer " + $0] } ?? [:] }
}

private actor Opened {
    var calls: [(app: String, script: String, text: String, mode: Int)] = []
    func add(_ app: String, _ script: String) {
        calls.append((app, script, (try? String(contentsOfFile: script, encoding: .utf8)) ?? "", mode(script)))
    }
}

final class IntegrationsTests: XCTestCase {
    private func fixture() -> (dir: String, exe: String, store: Integrations, state: String) {
        let dir = makeTemporaryFolder(self)
        let exe = dir + "/runtime"
        FileManager.default.createFile(atPath: exe, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o700])
        let state = dir + "/state"
        return (dir, exe, Integrations(stateDir: state), state)
    }

    private func config(_ dir: String, id: String = "user-model", context: Int = 32768) -> Config {
        Config(model: ModelConfig(source: "server", id: id, name: "My Model", context: context), workspace: dir)
    }

    private func entry(_ exe: String, id: String = "test-cli", args: [String] = [], terminal: [String] = [], preset: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "name": "Test CLI", "executable": .string(exe),
                                           "args": .array(args.map { .string($0) }), "terminal": .array(terminal.map { .string($0) })]
        if let preset { object["preset"] = .string(preset) }
        return .object(object)
    }

    func testSettingsFileShapeAndValidation() throws {
        let f = fixture()
        XCTAssertEqual(try f.store.read(), IntegrationSettings())
        try f.store.save(["harnesses": [entry(f.exe)]])
        let stored = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: f.state + "/integrations.json")))
        XCTAssertEqual(Set(stored.object!.keys), ["hermes", "harnesses", "engine", "dictation"])
        XCTAssertEqual(stored["engine"], "black-team")
        XCTAssertEqual(mode(f.state + "/integrations.json"), 0o600)
        XCTAssertThrowsError(try f.store.save(["harnesses": [entry(f.exe, id: "bad").object.map { var o = $0; o["args"] = "shell string"; return .object(o) }!]]))
        XCTAssertThrowsError(try f.store.save(["other": 1]))
        XCTAssertThrowsError(try f.store.save(["harnesses": [entry(f.exe, preset: "constructor")]])) { XCTAssertTrue("\($0)".contains("Invalid harness") || ($0 as? BlackTeamError)?.message.contains("Invalid harness") == true) }
        XCTAssertThrowsError(try f.store.save(["harnesses": [entry("relative/path")]]))
        XCTAssertThrowsError(try f.store.save(["engine": "hermes"])) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "Hermes is not available on macOS yet.") }
        XCTAssertEqual(try f.store.read().harnesses.map(\.id), ["test-cli"])
    }

    func testLaunchWritesPrivateScriptWithLiteralArguments() async throws {
        let f = fixture()
        try f.store.save(["harnesses": [entry(f.exe, args: ["--model", "{model}", "{workspace}", "$(touch should-not-exist)", "it's"])]])
        let opened = Opened()
        let result = try await launchHarness(id: "test-cli", store: f.store, config: config(f.dir), runtime: FakeRuntime(), stateDir: f.state,
                                             searchPath: ["/usr/bin"], open: { try await opened.add($0, $1) })
        XCTAssertEqual(result, LaunchResult(launched: true, name: "Test CLI"))
        let calls = await opened.calls
        XCTAssertEqual(calls.count, 1)
        let call = calls[0]
        XCTAssertEqual(call.app, "Terminal")
        XCTAssertEqual(call.mode, 0o700)
        XCTAssertEqual(mode(f.state + "/launch"), 0o700)
        XCTAssertTrue(call.script.hasPrefix(f.state + "/launch/") && call.script.hasSuffix(".command"))
        XCTAssertTrue(call.text.hasPrefix("#!/bin/zsh\nrm -f -- \"$0\"\ncd -- '\(f.dir)' || exit 1\nexport BLACK_TEAM_BASE_URL='http://127.0.0.1:1234/v1'\n"))
        XCTAssertTrue(call.text.contains("export OPENAI_API_KEY='fixture-secret'\n"))
        XCTAssertTrue(call.text.contains("export PATH='/usr/bin:/bin:/usr/sbin:/sbin'\n"))
        XCTAssertTrue(call.text.hasSuffix("exec '\(f.exe)' '--model' 'user-model' '\(f.dir)' '$(touch should-not-exist)' 'it'\\''s'\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir + "/should-not-exist"))
        // The next launch deletes the old script.
        _ = try await launchHarness(id: "test-cli", store: f.store, config: config(f.dir), runtime: FakeRuntime(), stateDir: f.state, open: { try await opened.add($0, $1) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.script))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.state + "/launch").count, 1)
    }

    func testMissingHarnessAndNoKey() async throws {
        let f = fixture()
        do { _ = try await launchHarness(id: "missing", store: f.store, config: config(f.dir), runtime: FakeRuntime(), stateDir: f.state, open: { _, _ in }); XCTFail() }
        catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("Configure") == true) }
        XCTAssertEqual(modelEnvironment(config: config(f.dir), runtime: FakeRuntime(key: nil), endpoint: "e")["OPENAI_API_KEY"], "local")
        XCTAssertEqual(modelEnvironment(config: Config(workspace: f.dir), runtime: FakeRuntime(), endpoint: "e")["OPENAI_MODEL"], "black-team-local")
    }

    func testLocalEnvironmentDropsSecretsAndDesktopNames() {
        let env = localEnvironment(["PATH": "/bin", "HOME": "/h", "USER": "u", "LANG": "C", "LC_ALL": "C", "TERM": "x", "TMPDIR": "/t",
                                    "DISPLAY": ":0", "WAYLAND_DISPLAY": "w", "XDG_RUNTIME_DIR": "/r", "DBUS_SESSION_BUS_ADDRESS": "d",
                                    "ANTHROPIC_API_KEY": "secret", "OPENAI_API_KEY": "secret", "SHELL": "/bin/zsh"])
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TERM", "TMPDIR"])
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("a b"), "'a b'")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote("$(x) `y` \"z\"\n"), "'$(x) `y` \"z\"\n'")
    }

    func testKnownHarnessConnectsInOneStepAndLaunchesPointedAtTheModel() async throws {
        let f = fixture()
        let found = DiscoveryResult(terminals: [FoundTerminal(name: "Term", executable: f.dir)], apps: [
            FoundApp(id: "codex", name: "Codex", executable: f.exe, preset: true), FoundApp(id: "pi", name: "Pi", executable: f.exe, preset: true),
        ], presets: [], runtime: "", dictation: "", graph: "")
        // A terminal bundle must be an .app folder.
        let bundle = f.dir + "/Term.app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        var withApp = found; withApp.terminals = [FoundTerminal(name: "Term", executable: bundle)]
        XCTAssertEqual(try connectHarness(id: "codex", store: f.store, found: withApp), ConnectResult(connected: true, name: "Codex"))
        XCTAssertEqual(try connectHarness(id: "codex", store: f.store, found: withApp), ConnectResult(connected: true, name: "Codex"))
        try connectHarness(id: "pi", store: f.store, found: withApp)
        XCTAssertEqual(try f.store.read().harnesses.map { [$0.id, $0.preset ?? "", String($0.terminal.count)] }, [["codex", "codex", "1"], ["pi", "pi", "1"]])
        XCTAssertThrowsError(try connectHarness(id: "aider", store: f.store, found: withApp)) { XCTAssertTrue("\($0)".contains("not found")) }
        XCTAssertThrowsError(try connectHarness(id: "hermes", store: f.store, found: withApp)) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "Hermes is not available on macOS yet.") }
        var none = withApp; none.terminals = []
        XCTAssertThrowsError(try connectHarness(id: "codex", store: Integrations(stateDir: f.dir + "/other"), found: none)) { XCTAssertTrue(($0 as? BlackTeamError)!.message.contains("terminal")) }

        let opened = Opened()
        let cfg = config(f.dir, id: "user \"model\"")
        for id in ["codex", "pi"] {
            _ = try await launchHarness(id: id, store: f.store, config: cfg, runtime: FakeRuntime(), stateDir: f.state, open: { try await opened.add($0, $1) })
        }
        let calls = await opened.calls
        // Each launch deletes the earlier script, so check the text captured at open time.
        XCTAssertEqual(calls[0].app, bundle)
        XCTAssertTrue(calls[0].text.contains("'-c' 'model_providers.black_team.base_url=\"http://127.0.0.1:1234/v1\"'"))
        XCTAssertTrue(calls[0].text.contains("'model=\"user \\\"model\\\"\"'"))
        XCTAssertTrue(calls[0].text.contains("'model_context_window=32768'"))
        XCTAssertTrue(calls[0].text.contains("export OPENAI_API_KEY='fixture-secret'"))
        XCTAssertTrue(calls[1].text.contains("'--provider' 'black-team' '--model' 'user \"model\"'"))
        let profile = f.state + "/harnesses/pi"
        XCTAssertTrue(calls[1].text.contains("export PI_CODING_AGENT_DIR='\(profile)'"))
        let models = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: profile + "/models.json")))
        XCTAssertEqual(models["providers"]?["black-team"]?["baseUrl"], "http://127.0.0.1:1234/v1")
        XCTAssertEqual(models["providers"]?["black-team"]?["models"]?[0]?["contextWindow"], 32768)
        XCTAssertEqual(mode(profile + "/models.json"), 0o600)
        XCTAssertEqual(mode(profile), 0o700)
    }

    func testOpenFailureRemovesScript() async throws {
        let f = fixture()
        try f.store.save(["harnesses": [entry(f.exe)]])
        do {
            _ = try await launchHarness(id: "test-cli", store: f.store, config: config(f.dir), runtime: FakeRuntime(), stateDir: f.state,
                                        open: { _, _ in throw BlackTeamError("The harness could not launch. Check its executable, terminal and workspace.") })
            XCTFail()
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.state + "/launch").count, 0)
    }
}

final class PresetsTests: XCTestCase {
    func testEveryPresetBuildsAndFilesArePrivate() throws {
        let state = makeTemporaryFolder(self)
        let values = PresetValues(endpoint: "http://127.0.0.1:1234/v1", model: "m", key: "k", context: 8192, name: "M")
        for item in PRESETS { _ = try applyPreset(item.id, values, stateDir: state) }
        XCTAssertEqual(PRESETS.map(\.command), ["claude", "codex", "pi", "opencode", "dsh", "aider"])
        let claude = try applyPreset("claude", values, stateDir: state)
        XCTAssertEqual(claude.env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:1234")
        XCTAssertEqual(claude.env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(claude.env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "2048")
        XCTAssertEqual(try applyPreset("aider", values, stateDir: state).args, ["--openai-api-base", "http://127.0.0.1:1234/v1", "--model", "openai/m"])
        let patch = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: state + "/harnesses/dsh/black-team.patch.json")))
        XCTAssertEqual(patch.array!.filter { $0["disabled"] == true }.map { $0["id"]!.string! }, ["llm-deepseek", "llm-deepseek-account", "session-title-llm"])
        let dsh = try applyPreset("dsh", values, stateDir: state)
        XCTAssertEqual(dsh.args, ["--profile", "web", "--patch", state + "/harnesses/dsh/black-team.patch.json", "--port", "0"])
        XCTAssertTrue(dsh.opensLocalPage)
        // A harness that serves a page is not exec'd: its output is shown and the first local address opened once.
        let script = launchScript(workspace: "/tmp/w", environment: ["A": "b"], executable: "/x/dsh", args: dsh.args, opensLocalPage: true)
        XCTAssertFalse(script.contains("\nexec "))
        XCTAssertTrue(script.contains("'/x/dsh' '--profile' 'web'"))
        XCTAssertTrue(script.contains("/usr/bin/open \"$match[1]\""))
        XCTAssertTrue(launchScript(workspace: "/tmp/w", environment: [:], executable: "/x/pi", args: []).contains("\nexec '/x/pi'"))
        let opencode = try JSONValue.parse(try applyPreset("opencode", values, stateDir: state).env["OPENCODE_CONFIG_CONTENT"]!)
        XCTAssertEqual(opencode["model"], "black-team/m")
        XCTAssertThrowsError(try applyPreset("nope", PresetValues(), stateDir: state)) { XCTAssertTrue("\($0)".contains("does not know")) }
    }
}

final class DiscoveryTests: XCTestCase {
    private func executable(_ file: String, mode: Int = 0o700) {
        try! FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data("#!/bin/sh\nexit 99\n".utf8), attributes: [.posixPermissions: mode])
    }

    func testFindsAppsTerminalsAndToolsWithoutRunningThem() throws {
        let home = makeTemporaryFolder(self)
        let bin = home + "/bin"
        for name in ["claude", "dsh", "graphify", "llama-server"] { executable(bin + "/" + name) }
        executable(bin + "/codex", mode: 0o644)
        executable(home + "/.cargo/bin/aider")
        executable(home + "/.nvm/versions/node/v20.1.0/bin/pi")
        let apps = home + "/Applications"
        for name in ["Ghostty.app", "kitty.app"] { try FileManager.default.createDirectory(atPath: apps + "/" + name, withIntermediateDirectories: true) }
        let found = discoverInstalled(home: home, env: ["PATH": bin], applicationFolders: [apps])
        XCTAssertEqual(found.apps.map { [$0.id, $0.name, String($0.preset)] }, [["claude", "Claude Code", "true"], ["pi", "Pi", "true"], ["dsh", "DeepSeek Harness", "true"], ["aider", "Aider", "true"]])
        XCTAssertEqual(found.terminals, [FoundTerminal(name: "Ghostty", executable: apps + "/Ghostty.app"), FoundTerminal(name: "kitty", executable: apps + "/kitty.app")])
        XCTAssertEqual(found.graph, bin + "/graphify")
        XCTAssertEqual(found.runtime, bin + "/llama-server")
        XCTAssertEqual(try String(contentsOfFile: bin + "/claude", encoding: .utf8), "#!/bin/sh\nexit 99\n")
    }

    func testMissingInstallsAndRelativePathEntriesAreIgnored() {
        let home = makeTemporaryFolder(self)
        let found = discoverInstalled(home: home, env: ["PATH": ".:relative"], applicationFolders: [])
        XCTAssertEqual(found.apps, []); XCTAssertEqual(found.terminals, [])
        XCTAssertEqual([found.runtime, found.dictation, found.graph], ["", "", ""])
        XCTAssertEqual(found.presets.map(\.command), ["claude", "codex", "pi", "opencode", "dsh", "aider"])
    }

    func testSearchPathsListUsualPlacesWithoutDuplicates() {
        let paths = harnessSearchPaths(home: "/Users/x", env: ["PATH": "/usr/bin:relative:/opt/homebrew/bin:/usr/bin"])
        XCTAssertEqual(Array(paths.prefix(3)), ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        XCTAssertEqual(paths.count, Set(paths).count)
        for expected in ["/Users/x/.local/bin", "/Users/x/bin", "/Users/x/.npm-global/bin", "/Users/x/.bun/bin", "/Users/x/.cargo/bin",
                         "/Users/x/.claude/local", "/Users/x/.local/share/mise/shims"] { XCTAssertTrue(paths.contains(expected), expected) }
        XCTAssertFalse(paths.contains("relative"))
    }
}
