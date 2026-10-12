import Foundation

// Settings for the other agent apps, and opening them in a terminal pointed at the local model.
// Hermes is not part of the first Mac version: its settings are kept so the file shape matches,
// but it cannot be enabled, connected or launched.

private let hermesUnavailable = "Hermes is not available on macOS yet."

public struct HermesSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var python = ""
    public var source = ""
    public var browserExecutable = ""
    public var desktopDriver = ""
    public var coding = true
    public var browser = false
    public var desktop = false
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        browserExecutable = try c.decodeIfPresent(String.self, forKey: .browserExecutable) ?? ""
        desktopDriver = try c.decodeIfPresent(String.self, forKey: .desktopDriver) ?? ""
        coding = try c.decodeIfPresent(Bool.self, forKey: .coding) ?? true
        browser = try c.decodeIfPresent(Bool.self, forKey: .browser) ?? false
        desktop = try c.decodeIfPresent(Bool.self, forKey: .desktop) ?? false
    }
}

public struct HarnessEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var executable: String
    public var args: [String]
    /// On macOS the first item is the terminal app (an `.app` bundle path); empty means Terminal.
    public var terminal: [String]
    public var preset: String?
    public init(id: String, name: String, executable: String, args: [String] = [], terminal: [String] = [], preset: String? = nil) {
        self.id = id; self.name = name; self.executable = executable; self.args = args; self.terminal = terminal; self.preset = preset
    }
}

public struct IntegrationSettings: Codable, Equatable, Sendable {
    public var hermes = HermesSettings()
    public var harnesses: [HarnessEntry] = []
    /// What runs Code conversations. An optional system dictation tool can be toggled from the text bar.
    public var engine = "black-team"
    public var dictation = ""
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hermes = try c.decodeIfPresent(HermesSettings.self, forKey: .hermes) ?? HermesSettings()
        harnesses = try c.decodeIfPresent([HarnessEntry].self, forKey: .harnesses) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "black-team"
        dictation = try c.decodeIfPresent(String.self, forKey: .dictation) ?? ""
    }
}

private func cleanText(_ value: JSONValue?, max: Int = 4096) -> Bool {
    guard let text = value?.string, text.utf16.count <= max else { return false }
    return !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
}

private func requireExecutable(_ value: String) throws {
    guard cleanText(.string(value)), value.hasPrefix("/") else { throw BlackTeamError("Choose an absolute executable path.") }
    if !isExecutableFile(value) {
        throw BlackTeamError("This application could not be opened. Choose an installed executable with permission to run.")
    }
}

/// A terminal is an `.app` bundle on macOS; a plain executable is accepted too.
private func requireTerminal(_ value: String) throws {
    var isDirectory: ObjCBool = false
    if value.hasPrefix("/"), value.hasSuffix(".app"), cleanText(.string(value)),
       FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue { return }
    try requireExecutable(value)
}

public final class Integrations: @unchecked Sendable {
    public let stateDir: String
    public let file: String
    private let lock = NSLock()

    public init(stateDir: String) {
        self.stateDir = stateDir
        self.file = stateDir + "/integrations.json"
    }

    public func read() throws -> IntegrationSettings {
        lock.lock(); defer { lock.unlock() }
        return try readUnlocked()
    }

    private func readUnlocked() throws -> IntegrationSettings {
        guard let data = FileManager.default.contents(atPath: file) else { return IntegrationSettings() }
        do { return try JSONDecoder().decode(IntegrationSettings.self, from: data) }
        catch { throw BlackTeamError("Cannot read Black Team integration settings: the file is not valid.") }
    }

    @discardableResult
    public func save(_ settings: IntegrationSettings) throws -> IntegrationSettings {
        let data = try JSONEncoder().encode(settings)
        return try save(try JSONValue.parse(data))
    }

    /// Merges the given top-level settings over the stored ones, checks them and writes the result.
    @discardableResult
    public func save(_ value: JSONValue) throws -> IntegrationSettings {
        lock.lock(); defer { lock.unlock() }
        guard let input = value.object, input.keys.allSatisfy({ ["hermes", "harnesses", "engine", "dictation"].contains($0) }) else {
            throw BlackTeamError("Unsupported integration setting.")
        }
        var next = try JSONValue.parse(JSONEncoder().encode(try readUnlocked())).object!
        for (key, item) in input { next[key] = item }
        guard let engine = next["engine"]?.string, ["black-team", "hermes"].contains(engine) else {
            throw BlackTeamError("Choose Black Team or Hermes for Code conversations.")
        }
        if !cleanText(next["dictation"]) { throw BlackTeamError("Invalid dictation tool path.") }
        if let tool = next["dictation"]?.string, !tool.isEmpty { try requireExecutable(tool) }
        let hermesKeys = ["enabled", "python", "source", "browserExecutable", "desktopDriver", "coding", "browser", "desktop"]
        guard let h = next["hermes"]?.object, h.keys.allSatisfy(hermesKeys.contains),
              ["enabled", "coding", "browser", "desktop"].allSatisfy({ h[$0]?.bool != nil }),
              cleanText(h["python"]), cleanText(h["source"]) else { throw BlackTeamError("Invalid Hermes settings.") }
        for key in ["browserExecutable", "desktopDriver"] {
            if let item = h[key] {
                if !cleanText(item) { throw BlackTeamError("Invalid tool executable path.") }
                if let path = item.string, !path.isEmpty { try requireExecutable(path) }
            }
        }
        if engine == "hermes" || h["enabled"]?.bool == true { throw BlackTeamError(hermesUnavailable) }
        guard let list = next["harnesses"]?.array, list.count <= 20 else { throw BlackTeamError("Configure up to 20 harnesses.") }
        var ids = Set<String>()
        let invalid = BlackTeamError("Invalid harness. Use unique IDs, a name, argument arrays and executable paths.")
        for item in list {
            guard let entry = item.object, entry.keys.allSatisfy({ ["id", "name", "executable", "args", "terminal", "preset"].contains($0) }),
                  let id = entry["id"]?.string, id.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil, !ids.contains(id),
                  cleanText(entry["name"], max: 100), !(entry["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let args = entry["args"]?.array, args.count <= 64, args.allSatisfy({ cleanText($0) }),
                  let terminal = entry["terminal"]?.array, terminal.count <= 16, terminal.allSatisfy({ cleanText($0) })
            else { throw invalid }
            if let preset = entry["preset"], !(preset.string.map { Self.knownPreset($0) } ?? false) { throw invalid }
            ids.insert(id)
            guard let executable = entry["executable"]?.string else { throw BlackTeamError("Choose an absolute executable path.") }
            try requireExecutable(executable)
            if let first = terminal.first?.string { try requireTerminal(first) }
        }
        let settings = try JSONDecoder().decode(IntegrationSettings.self, from: Data(JSONValue.object(next).text().utf8))
        try privateDirectory(stateDir)
        try writeJSON(file, settings)
        return settings
    }

    private static func knownPreset(_ id: String) -> Bool { PRESETS.contains { $0.id == id } }
}

/// The server a launch talks to. The local-server area adapts its runtime to this.
public protocol HarnessRuntime: Sendable {
    /// Makes sure the model is running and returns its `/v1` address.
    func start() async throws -> String
    func requestHeaders() -> [String: String]
}

/// Only what a harness needs from Black Team's own environment: no provider secrets, and no
/// display-server or desktop-session names, which mean nothing in a Terminal window on a Mac.
public func localEnvironment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    source.filter { $0.key.range(of: "^(PATH|HOME|USER|LANG|LC_[A-Z_]+|TERM|TMPDIR)$", options: .regularExpression) != nil }
}

public func modelEnvironment(config: Config, runtime: HarnessRuntime, endpoint: String) -> [String: String] {
    let model = config.model.source == "server" ? config.model.id : "black-team-local"
    let header = runtime.requestHeaders().first { $0.key.lowercased() == "authorization" }?.value ?? ""
    let key = String(header.dropFirst(7)).isEmpty ? "local" : String(header.dropFirst(7))
    return ["BLACK_TEAM_BASE_URL": endpoint, "BLACK_TEAM_MODEL": model, "BLACK_TEAM_WORKSPACE": config.workspace,
            "OPENAI_BASE_URL": endpoint, "OPENAI_API_KEY": key, "OPENAI_MODEL": model]
}

/// Single-quotes a value for a shell; an embedded single quote becomes '\'' .
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The text of the `.command` script that opens a harness: go to the folder, set exactly the
/// given environment, then replace the shell with the harness and its literal arguments.
///
/// A harness that serves a page instead of drawing in the terminal prints the page's address when it
/// is ready. With `opensLocalPage` the script shows the harness's output as usual and opens the first
/// address on this computer that it prints, once; nothing else is ever opened.
public func launchScript(workspace: String, environment: [String: String], executable: String, args: [String],
                         opensLocalPage: Bool = false) -> String {
    var lines = ["#!/bin/zsh", "rm -f -- \"$0\"", "cd -- \(shellQuote(workspace)) || exit 1"]
    for name in environment.keys.sorted() where name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
        lines.append("export \(name)=\(shellQuote(environment[name]!))")
    }
    let command = ([executable] + args).map(shellQuote).joined(separator: " ")
    if opensLocalPage {
        lines += [
            "opened=",
            command + " 2>&1 | while IFS= read -r line; do",
            "  print -r -- \"$line\"",
            "  if [[ -z $opened && $line =~ '(http://127\\.0\\.0\\.1:[0-9]+)' ]]; then opened=1; /usr/bin/open \"$match[1]\"; fi",
            "done",
        ]
    } else {
        lines.append("exec " + command)
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Opens a script in a terminal app. Tests replace it so no terminal opens.
public typealias TerminalOpener = @Sendable (_ terminalApp: String, _ script: String) async throws -> Void

public let openInTerminal: TerminalOpener = { app, script in
    let failure = BlackTeamError("The harness could not launch. Check its executable, terminal and workspace.")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", app, script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw failure }
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw failure }
}

public struct LaunchResult: Equatable, Sendable {
    public var launched: Bool
    public var name: String
}

public func launchHarness(id: String, store: Integrations, config: Config, runtime: HarnessRuntime, stateDir: String,
                          defaultWorkspace: String = AppPaths.defaultWorkspace(),
                          searchPath: [String]? = nil, open: TerminalOpener = openInTerminal) async throws -> LaunchResult {
    guard let item = try store.read().harnesses.first(where: { $0.id == id }) else {
        throw BlackTeamError("Configure this harness in Settings first.")
    }
    if item.id == "hermes" { throw BlackTeamError(hermesUnavailable) }
    try requireExecutable(item.executable)
    if let first = item.terminal.first { try requireTerminal(first) }
    let workspace = try ensureWorkspace(config.workspace, defaultWorkspace: defaultWorkspace)
    let endpoint = try await runtime.start()
    let base = modelEnvironment(config: config, runtime: runtime, endpoint: endpoint)
    let values = ["endpoint": endpoint, "model": base["BLACK_TEAM_MODEL"]!, "workspace": workspace]
    // A known harness gets the settings that point it at this model; the person's own arguments follow.
    let preset = try item.preset.map {
        try applyPreset($0, PresetValues(endpoint: endpoint, model: values["model"]!, key: base["OPENAI_API_KEY"]!,
                                         context: config.model.context, name: config.model.name), stateDir: stateDir)
    } ?? AppliedPreset(args: [], env: [:])
    var env = localEnvironment().merging(base) { _, new in new }.merging(preset.env) { _, new in new }
    // A Mac app starts with a short PATH; the harness may need node, git or rg from the usual places.
    env["PATH"] = ((searchPath ?? harnessSearchPaths()) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).reduce(into: [String]()) {
        if !$0.contains($1) { $0.append($1) }
    }.joined(separator: ":")
    let substitution = try NSRegularExpression(pattern: "\\{(endpoint|model|workspace)\\}")
    let args = preset.args + item.args.map { arg in
        var out = "", last = arg.startIndex
        let ns = arg as NSString
        for match in substitution.matches(in: arg, range: NSRange(location: 0, length: ns.length)) {
            let range = Range(match.range, in: arg)!
            out += arg[last..<range.lowerBound] + values[ns.substring(with: match.range(at: 1))]!
            last = range.upperBound
        }
        return out + arg[last...]
    }
    let script = try writeLaunchScript(launchScript(workspace: workspace, environment: env, executable: item.executable, args: args,
                                                    opensLocalPage: preset.opensLocalPage), stateDir: stateDir)
    do { try await open(item.terminal.first ?? "Terminal", script) }
    catch { try? FileManager.default.removeItem(atPath: script); throw error }
    return LaunchResult(launched: true, name: item.name)
}

/// Saves the script privately in `<data>/launch/`, first deleting the ones left by earlier launches.
private func writeLaunchScript(_ text: String, stateDir: String) throws -> String {
    let dir = stateDir + "/launch"
    try privateDirectory(dir)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".command") {
        try? FileManager.default.removeItem(atPath: dir + "/" + name)
    }
    let path = dir + "/" + UUID().uuidString.lowercased() + ".command"
    let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o700)
    if fd < 0 { throw BlackTeamError("The harness could not launch. Check its executable, terminal and workspace.") }
    defer { close(fd) }
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR { continue }; throw BlackTeamError("The harness could not launch. Check its executable, terminal and workspace.") }
        offset += n
    }
    fchmod(fd, 0o700)
    return path
}

public struct ConnectResult: Equatable, Sendable {
    public var connected: Bool
    public var name: String
}

/// One step from "found on this computer" to "opens with my model".
@discardableResult
public func connectHarness(id: String, store: Integrations, found: DiscoveryResult, terminal chosen: FoundTerminal? = nil) throws -> ConnectResult {
    if id == "hermes" { throw BlackTeamError(hermesUnavailable) }
    guard let app = found.apps.first(where: { $0.id == id }) else { throw BlackTeamError("That app was not found on this computer.") }
    let current = try store.read()
    if current.harnesses.contains(where: { $0.id == app.id }) { return ConnectResult(connected: true, name: app.name) }
    guard let terminal = chosen ?? found.terminals.first else {
        throw BlackTeamError("\(app.name) runs in a terminal, and none was found. Install a terminal, then connect it again.")
    }
    var next = current.harnesses
    next.append(HarnessEntry(id: app.id, name: app.name, executable: app.executable, args: [],
                             terminal: [terminal.executable] + terminal.args, preset: app.preset ? app.id : nil))
    try store.save(JSONValue.object(["harnesses": try JSONValue.parse(JSONEncoder().encode(next))]))
    return ConnectResult(connected: true, name: app.name)
}
