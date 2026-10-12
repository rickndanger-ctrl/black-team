import Foundation

// What is installed on this Linux computer, as lib/discovery.cjs finds it: the same folders (the PATH, ~/.local/bin, ~/bin), the same
// order, and Hermes with it. Bounded file checks only: nothing found is ever run.

public struct HermesInstall: Equatable, Sendable {
    public var source: String
    public var python: String
}

public struct LinuxDiscovery: Sendable {
    public var result: DiscoveryResult
    public var hermes: [HermesInstall]

    /// The JSON the window reads (`installed-discover`).
    public var json: JSONValue {
        [
            "hermes": .array(hermes.map { ["source": .string($0.source), "python": .string($0.python)] }),
            "terminals": .array(result.terminals.map { ["name": .string($0.name), "executable": .string($0.executable), "args": .array($0.args.map { .string($0) })] }),
            "apps": .array(result.apps.map { ["id": .string($0.id), "name": .string($0.name), "executable": .string($0.executable), "preset": .bool($0.preset)] }),
            "presets": .array(result.presets.map { ["id": .string($0.id), "name": .string($0.name), "command": .string($0.command)] }),
            "runtime": .string(result.runtime), "dictation": .string(result.dictation), "graph": .string(result.graph),
        ]
    }
}

/// `inspectHermes`: a Hermes folder with its two files and a Python it can run, or nil. A Python symbolic link is not resolved:
/// the virtual environment's path selects its installed packages.
public func inspectHermes(source: String?, python: String = "") -> HermesInstall? {
    guard let source, source.hasPrefix("/"), ["hermes_bootstrap.py", "cli.py"].allSatisfy({ CoreFS.exists(source + "/" + $0) }) else { return nil }
    let candidates = [python] + ["venv", ".venv"].map { source + "/" + $0 + "/bin/python" }
    guard let interpreter = candidates.first(where: { !$0.isEmpty && $0.hasPrefix("/") && isExecutableFile($0) }) else { return nil }
    return HermesInstall(source: source, python: interpreter)
}

public func discoverLinux(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment,
                          saved: HermesSettings = HermesSettings()) -> LinuxDiscovery {
    var seen = Set<String>()
    let dirs = ((env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init) + [home + "/.local/bin", home + "/bin"])
        .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    let hermesBin = findExecutable("hermes", in: dirs)
    var resolved = ""
    if !hermesBin.isEmpty, let real = realpath(hermesBin, nil) { resolved = String(cString: real); free(real) }
    func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    var sources: [String] = []
    for item in [saved.source, home + "/.hermes/hermes-agent", home + "/hermes-agent", home + "/Projects/hermes-agent",
                 home + "/.local/share/hermes/hermes-agent", resolved.isEmpty ? "" : parent(parent(parent(resolved)))] where !item.isEmpty && !sources.contains(item) {
        sources.append(item)
    }
    let hermes = sources.compactMap { inspectHermes(source: $0, python: $0 == saved.source ? saved.python : "") }
    let terminals = discoverLinuxTerminals(home: home, env: env)
    var apps = PRESETS.compactMap { item -> FoundApp? in
        let file = findExecutable(item.command, in: dirs)
        return file.isEmpty ? nil : FoundApp(id: item.id, name: item.name, executable: file, preset: true)
    }
    if !hermesBin.isEmpty { apps.append(FoundApp(id: "hermes", name: "Hermes Terminal", executable: hermesBin, preset: false)) }
    let presets = PRESETS.map { KnownPreset(id: $0.id, name: $0.name, command: $0.command) }
    return LinuxDiscovery(result: DiscoveryResult(terminals: terminals, apps: apps, presets: presets, runtime: findExecutable("llama-server", in: dirs),
                                                  dictation: findExecutable("voxtype", in: dirs), graph: findExecutable("graphify", in: dirs)),
                          hermes: hermes)
}
