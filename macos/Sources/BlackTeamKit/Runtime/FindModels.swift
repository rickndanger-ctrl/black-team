import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc) || canImport(Musl)
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// Finds the models already on this computer, so setting up is choosing, not typing.
// It asks local servers for their model list and looks for GGUF files in the folders
// model tools use. Loopback requests and file names and sizes only: no file is opened
// beyond its 24-byte header, nothing is executed, and nothing leaves the computer.

private let ports: [(Int, String)] = [(1234, "LM Studio"), (1337, "Jan"), (5001, "KoboldCpp"), (8000, "Local server"), (8080, "llama.cpp"), (11434, "Ollama")]
private let serverNames: Set<String> = ["llama-server", "llama-cpp-server", "koboldcpp", "local-ai", "tabbyapi"]
// Relative to home. `~/models`, `~/Downloads`, the Hugging Face and LM Studio folders are the Mac's common places too;
// the app's own `models` folder in its data folder is added by `ggufFiles`.
private let folders = ["models", "Models", ".cache/lm-studio/models", ".lmstudio/models", ".cache/llama.cpp", "llama.cpp/models",
                       ".local/share/nomic.ai/GPT4All", ".cache/huggingface/hub", "Downloads"]
private let minimumBytes = 200 * 1024 * 1024

// Helper files that sit beside a model but are not one: vision projectors, draft heads, later parts of a split file.
private func isHelperFile(_ name: String) -> Bool {
    name.range(of: #"(^|[-_.])(mmproj|mtp|draft)([-_.]|$)|-0000[2-9]-of-\d{5}\.gguf$|-000[1-9]\d-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil
}
private func isGGUF(_ name: String) -> Bool { name.range(of: #"\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil }

private func label(_ value: String) -> String {
    String(((value as NSString).lastPathComponent).replacingOccurrences(of: #"\.gguf$"#, with: "", options: [.regularExpression, .caseInsensitive]).prefix(120))
}

public struct Companions: Equatable, Sendable {
    public var mmproj: String
    public var draft: String
}

/// Files beside a model that belong to it: its vision projector and a draft model for faster replies.
public func companionsFor(_ file: String) -> Companions {
    let directory = (file as NSString).deletingLastPathComponent
    let own = (file as NSString).lastPathComponent
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { isGGUF($0) && $0 != own }
    func pick(_ pattern: String) -> String {
        let found = names.filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        return found.first.map { directory + "/" + $0 } ?? ""
    }
    return Companions(mmproj: pick(#"(^|[-_.])mmproj([-_.]|$)"#), draft: pick(#"(^|[-_.])(mtp|draft)([-_.]|$)"#))
}

public struct FileDescription: Equatable, Sendable {
    public var name: String
    public var trainingContext: Int?
    public var context: Int
}

public struct MemoryFigures: Equatable, Sendable {
    public var total: Int
    public var free: Int
    public init(total: Int, free: Int) { self.total = total; self.free = free }
}

/// What the file says about itself, for a good name and a context that fits.
public func describeFile(_ file: String, bytes: Int, memory: MemoryFigures? = nil) -> FileDescription {
    let meta = try? describeModel(file)
    let quantity = (try? NSRegularExpression(pattern: #"\b(I?Q\d[A-Z0-9_]*|BF16|F16|F32|UD-[A-Z0-9_]+)\b"#))!
    let base = (file as NSString).lastPathComponent
    var quant = ""
    if let match = quantity.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)), let range = Range(match.range, in: base) { quant = String(base[range]) }
    var name = label(file)
    if let meta, !meta.name.isEmpty {
        name = meta.name
        if !meta.sizeLabel.isEmpty && !meta.name.contains(meta.sizeLabel) { name += " " + meta.sizeLabel }
        if !quant.isEmpty && !meta.name.contains(quant) { name += " " + quant }
        name = String(name.prefix(120))
    }
    let total = memory?.total ?? Int(ProcessInfo.processInfo.physicalMemory)
    return FileDescription(name: name, trainingContext: meta?.trainingContext, context: suggestContext(trainingContext: meta?.trainingContext, bytes: bytes, totalMemory: total))
}

public struct RunningServer: Equatable, Sendable {
    public var port: Int
    public var file: String
    public var executable: String
}

/// The path of a process's program, from the system.
public func processExecutablePath(_ pid: Int) -> String? {
    #if os(Linux)
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return nil }
    return target
    #else
    var buffer = [CChar](repeating: 0, count: 4 * 1024)
    guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
    #endif
}

/// Model servers this user is already running, on whatever port they chose. `processes` lists the user's
/// processes with their command lines; `executablePath` gives the program of a process id.
public func runningServers(processes: () -> AnySequence<ProcessEntry> = SystemInfo.runningProcesses,
                           executablePath: (Int) -> String? = processExecutablePath) -> [RunningServer] {
    var found: [RunningServer] = []
    for entry in processes().prefix(20000) {
        let argv = entry.argv.filter { !$0.isEmpty }
        guard let first = argv.first, serverNames.contains((first as NSString).lastPathComponent) else { continue }
        func value(_ names: String...) -> String? {
            for index in 1..<max(1, argv.count) {
                for name in names {
                    if argv[index] == name { return index + 1 < argv.count ? argv[index + 1] : nil }
                    if argv[index].hasPrefix(name + "=") { return String(argv[index].dropFirst(name.count + 1)) }
                }
            }
            return nil
        }
        guard let parsed = Double((value("--port") ?? "8080").trimmingCharacters(in: .whitespaces)), parsed.rounded() == parsed, parsed >= 1, parsed <= 65535 else { continue }
        let executable = executablePath(entry.pid) ?? ""
        let model = value("-m", "--model") ?? ""
        found.append(RunningServer(port: Int(parsed), file: model, executable: (executable as NSString).lastPathComponent == "llama-server" ? executable : ""))
    }
    return found
}

public struct GGUFScan: Equatable, Sendable {
    public struct Item: Equatable, Sendable { public var file: String; public var real: String; public var bytes: Int }
    public var looked: [String]
    public var files: [Item]
}

private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The folders model tools use, bounded: depth 5, 6000 entries, 60 files. `dataFolder` is Black Team's own
/// data folder, whose `models` folder is scanned too.
public func ggufFiles(home: String, extra: [String] = [], dataFolder: String? = nil) -> GGUFScan {
    var candidates = folders.map { home + "/" + $0 }
    candidates.append((dataFolder ?? AppPaths.dataFolder(home: home)) + "/models")
    candidates += extra
    var roots: [String] = []
    var seenRoots = Set<String>()
    // The disk may ignore letter case (models and Models are one folder), so a folder is scanned once.
    for root in candidates where seenRoots.insert(realPath(root) ?? root).inserted { roots.append(root) }
    var files: [GGUFScan.Item] = [], looked: [String] = []
    var budget = 6000
    func walk(_ directory: String, _ depth: Int) {
        guard let handle = opendir(directory) else { return }
        defer { closedir(handle) }
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            budget -= 1
            if budget < 0 || files.count >= 60 { return }
            let full = directory + "/" + name
            var isDirectory = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) { var info = CStat(); isDirectory = lstat(full, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR }
            // A linked folder is never followed.
            if isDirectory { if depth < 5 && !name.hasPrefix(".git") { walk(full, depth + 1) }; continue }
            if !isGGUF(name) || isHelperFile(name) { continue }
            // Hugging Face keeps its files behind links; a linked file is fine.
            if let info = try? inspectModel(full), info.bytes >= minimumBytes { files.append(.init(file: full, real: info.realPath, bytes: info.bytes)) }
        }
    }
    for root in roots {
        var info = CStat()
        if stat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { looked.append(root); walk(root, 0) }
    }
    var seen = Set<String>()
    return GGUFScan(looked: looked, files: files.filter { seen.insert($0.real).inserted })
}

public struct FoundServer: Codable, Equatable, Sendable {
    public var source = "server"
    public var provider: String
    public var endpoint: String
    public var id: String
    public var name: String
    public var context: Int
    public var contextKnown: Bool
}

public struct FoundFile: Codable, Equatable, Sendable {
    public var source = "gguf"
    public var file: String
    public var name: String
    public var bytes: Int
    public var runtime: String
    public var context: Int
    public var trainingContext: Int?
    public var mmproj: String
    public var draft: String
    public var tooBig: Bool
    public var tight: Bool
}

extension FoundServer { public var json: JSONValue { (try? JSONValue.parse(JSONEncoder().encode(self))) ?? .null } }
extension FoundFile { public var json: JSONValue { (try? JSONValue.parse(JSONEncoder().encode(self))) ?? .null } }

public struct FoundModels: Equatable, Sendable {
    public struct Looked: Equatable, Sendable { public var ports: [Int]; public var folders: [String] }
    public var servers: [FoundServer]
    public var files: [FoundFile]
    public var runtime: String
    public var looked: Looked
}

private func contextOf(_ origin: String, _ fetch: @escaping HTTPFetch, timeoutMs: Int) async -> Int {
    // llama.cpp says how much context it loaded; other servers do not, and the caller falls back.
    var built = URLRequest(url: URL(string: origin + "/props")!)
    built.timeoutInterval = Double(timeoutMs) / 1000
    let request = built
    guard let (data, response) = try? await withDeadline(ms: timeoutMs, { try await fetch(request) }), (200..<300).contains(response.statusCode),
          let size = (try? JSONValue.parse(data))?["default_generation_settings"]?["n_ctx"]?.int, size >= 512 else { return 0 }
    return min(size, 131072)
}

private func order(_ a: String, _ b: String) -> Int { a.localizedCompare(b) == .orderedAscending ? -1 : a == b ? 0 : 1 }

public func findModels(home: String = NSHomeDirectory(), fetch: @escaping HTTPFetch = LocalHTTP.fetch,
                       processes: () -> AnySequence<ProcessEntry> = SystemInfo.runningProcesses,
                       executablePath: (Int) -> String? = processExecutablePath,
                       runtime: String = "", folders extraFolders: [String] = [], timeoutMs: Int = 2500,
                       memory: MemoryFigures? = nil, dataFolder: String? = nil) async -> FoundModels {
    let running = runningServers(processes: processes, executablePath: executablePath)
    var allPorts: [Int] = []
    for port in ports.map(\.0) + running.map(\.port) where !allPorts.contains(port) { allPorts.append(port) }
    var servers: [FoundServer] = []
    await withTaskGroup(of: [FoundServer].self) { group in
        for port in allPorts {
            let own = running.first { $0.port == port }
            let provider = own != nil ? "llama.cpp" : ports.first { $0.0 == port }?.1 ?? "Local server"
            group.addTask {
                guard let found = try? await withDeadline(ms: timeoutMs, { try await discoverModels(endpoint: "http://127.0.0.1:\(port)/v1", fetch: fetch) }) else { return [] }
                let context = await contextOf("http://127.0.0.1:\(port)", fetch, timeoutMs: timeoutMs)
                return found.models.prefix(24).map {
                    FoundServer(provider: provider, endpoint: found.endpoint, id: $0, name: label($0), context: context > 0 ? context : 4096, contextKnown: context > 0)
                }
            }
        }
        for await list in group { servers += list }
    }
    var loadedFiles: [String: String] = [:]
    for port in allPorts { if let own = running.first(where: { $0.port == port }) { loadedFiles["http://127.0.0.1:\(port)/v1"] = own.file } }
    servers.sort { $0.endpoint != $1.endpoint ? order($0.endpoint, $1.endpoint) < 0 : order($0.name, $1.name) < 0 }
    // A running llama-server is also a llama.cpp installation that can start other model files.
    let engine = !runtime.isEmpty ? runtime : running.first { !$0.executable.isEmpty }?.executable ?? ""
    let scan = ggufFiles(home: home, extra: extraFolders, dataFolder: dataFolder)
    var loaded = Set<String>()
    for server in servers {
        let file = loadedFiles[server.endpoint] ?? ""
        if !file.isEmpty { loaded.insert(realPath(file) ?? file) }
    }
    let files = scan.files.filter { !loaded.contains($0.real) }.sorted { order($0.file, $1.file) < 0 }.map { item -> FoundFile in
        let estimate = memory.map { estimateMemory(item.bytes, totalBytes: $0.total, freeBytes: $0.free) } ?? estimateMemory(item.bytes)
        let described = describeFile(item.file, bytes: item.bytes, memory: memory)
        let beside = companionsFor(item.file)
        return FoundFile(file: item.file, name: described.name, bytes: item.bytes, runtime: engine, context: described.context, trainingContext: described.trainingContext,
                         mmproj: beside.mmproj, draft: beside.draft, tooBig: estimate.exceedsTotal, tight: !estimate.exceedsTotal && estimate.exceedsFree)
    }
    return FoundModels(servers: servers, files: files, runtime: engine, looked: .init(ports: allPorts.sorted(), folders: scan.looked))
}
