import Foundation

public struct FoundTerminal: Equatable, Sendable {
    public var name: String
    /// The terminal's `.app` bundle. It is opened with `open -a`, never run directly.
    public var executable: String
    public var args: [String]
    public init(name: String, executable: String, args: [String] = []) {
        self.name = name; self.executable = executable; self.args = args
    }
}

public struct FoundApp: Equatable, Sendable {
    public var id: String
    public var name: String
    public var executable: String
    public var preset: Bool
    public init(id: String, name: String, executable: String, preset: Bool) {
        self.id = id; self.name = name; self.executable = executable; self.preset = preset
    }
}

public struct KnownPreset: Equatable, Sendable {
    public var id: String
    public var name: String
    public var command: String
}

public struct DiscoveryResult: Equatable, Sendable {
    public var terminals: [FoundTerminal]
    public var apps: [FoundApp]
    /// Lets the interface recognise a known harness when its file is chosen by hand.
    public var presets: [KnownPreset]
    public var runtime: String
    public var dictation: String
    public var graph: String
}

func isExecutableFile(_ file: String) -> Bool {
    var info = stat()
    return stat(file, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(file, X_OK) == 0
}

func findExecutable(_ name: String, in dirs: [String]) -> String {
    dirs.map { $0 + "/" + name }.first(where: isExecutableFile) ?? ""
}

/// Every folder worth looking in for a command-line tool, in order, without duplicates.
/// A Mac app's own PATH is minimal, so this adds the usual install places after the PATH.
/// Other areas use it to build a fuller PATH for child processes. It only builds a list:
/// folders are not checked, except that the nvm folder is listed to find installed versions.
public func harnessSearchPaths(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    var dirs = (env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin", home + "/.npm-global/bin",
             home + "/.bun/bin", home + "/.cargo/bin", home + "/.claude/local", home + "/.local/share/mise/shims",
             home + "/.volta/bin", home + "/.local/share/fnm/aliases/default/bin",
             home + "/Library/Application Support/fnm/aliases/default/bin", home + "/Library/pnpm"]
    // nvm keeps one folder per installed Node; newest name first, and only a handful.
    let nvm = home + "/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
        dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.prefix(8).map { nvm + "/" + $0 + "/bin" }
    }
    var seen = Set<String>()
    return dirs.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
}

private let terminalSpecs: [(bundle: String, name: String)] = [
    ("Terminal.app", "Terminal"), ("iTerm.app", "iTerm"), ("Ghostty.app", "Ghostty"),
    ("WezTerm.app", "WezTerm"), ("Alacritty.app", "Alacritty"), ("kitty.app", "kitty"),
]

public func discoverInstalled(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment,
                              applicationFolders: [String]? = nil) -> DiscoveryResult {
    // Bounded filesystem checks only: never run a discovered executable or scan a user's files.
    let dirs = harnessSearchPaths(home: home, env: env)
    let folders = applicationFolders ?? ["/System/Applications/Utilities", "/Applications/Utilities", "/Applications", home + "/Applications"]
    var terminals: [FoundTerminal] = []
    for spec in terminalSpecs {
        for folder in folders {
            let bundle = folder + "/" + spec.bundle
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: bundle, isDirectory: &isDirectory), isDirectory.boolValue {
                terminals.append(FoundTerminal(name: spec.name, executable: bundle)); break
            }
        }
    }
    // Harnesses with a preset open already pointed at the model in use. Hermes is not offered on macOS yet.
    let apps = PRESETS.compactMap { item -> FoundApp? in
        let file = findExecutable(item.command, in: dirs)
        return file.isEmpty ? nil : FoundApp(id: item.id, name: item.name, executable: file, preset: true)
    }
    let presets = PRESETS.map { KnownPreset(id: $0.id, name: $0.name, command: $0.command) }
    return DiscoveryResult(terminals: terminals, apps: apps, presets: presets, runtime: findExecutable("llama-server", in: dirs),
                           dictation: findExecutable("voxtype", in: dirs), graph: findExecutable("graphify", in: dirs))
}
