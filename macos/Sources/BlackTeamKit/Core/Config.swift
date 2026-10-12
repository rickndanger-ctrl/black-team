import Foundation

private let GiB = 1024 * 1024 * 1024
private let modelKeys = ["name", "file", "runtime", "context", "gpuLayers", "threads", "source", "endpoint", "id", "apiKey", "mmproj", "draft"]
private let topKeys = ["schemaVersion", "model", "workspace", "phone"]
private let phoneKeys = ["enabled", "hostname", "owner"]

/// The model settings. `mmproj` and `draft` are optional files beside a model: its vision
/// projector and a draft model for faster replies.
public struct ModelConfig: Codable, Equatable, Sendable {
    public var source = "gguf"
    public var endpoint = "http://127.0.0.1:11434/v1"
    public var id = ""
    public var apiKey = ""
    public var name = "Local model"
    public var file = ""
    public var runtime = ""
    public var context = 4096
    public var gpuLayers = 0
    public var threads = 4
    public var mmproj = ""
    public var draft = ""

    public init(source: String = "gguf", endpoint: String = "http://127.0.0.1:11434/v1", id: String = "", apiKey: String = "",
                name: String = "Local model", file: String = "", runtime: String = "", context: Int = 4096, gpuLayers: Int = 0,
                threads: Int = 4, mmproj: String = "", draft: String = "") {
        self.source = source; self.endpoint = endpoint; self.id = id; self.apiKey = apiKey; self.name = name; self.file = file
        self.runtime = runtime; self.context = context; self.gpuLayers = gpuLayers; self.threads = threads; self.mmproj = mmproj; self.draft = draft
    }
}

public struct PhoneConfig: Codable, Equatable, Sendable {
    public var enabled = false
    public var hostname = ""
    public var owner = ""
    public init(enabled: Bool = false, hostname: String = "", owner: String = "") {
        self.enabled = enabled; self.hostname = hostname; self.owner = owner
    }
}

/// The contents of `config.json`, the same shape as on Linux.
public struct Config: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var model = ModelConfig()
    public var workspace: String
    public var phone = PhoneConfig()
    public init(model: ModelConfig = ModelConfig(), workspace: String = AppPaths.defaultWorkspace(), phone: PhoneConfig = PhoneConfig()) {
        self.model = model; self.workspace = workspace; self.phone = phone
    }
}

private func configJSON(_ config: Config) -> JSONValue {
    let data = (try? JSONEncoder().encode(config)) ?? Data("{}".utf8)
    return (try? JSONValue.parse(data)) ?? .object([:])
}

private func requireObject(_ value: JSONValue?, _ label: String) throws -> [String: JSONValue] {
    guard let object = value?.object else { throw BlackTeamError("\(label) must be an object.") }
    return object
}

private func requireKeys(_ value: JSONValue?, _ allowed: [String], _ label: String) throws {
    for key in try requireObject(value, label).keys where !allowed.contains(key) {
        throw BlackTeamError("Unsupported \(label) setting: \(key).")
    }
}

private func requireText(_ value: JSONValue?, _ label: String, max: Int = 4096) throws {
    guard let text = value?.string, text.utf16.count <= max, !text.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
        throw BlackTeamError("\(label) must be text without control characters (maximum \(max) characters).")
    }
}

private func requireInteger(_ value: JSONValue?, _ label: String, _ low: Int, _ high: Int) throws {
    guard let number = value?.double, number.rounded() == number, number >= Double(low), number <= Double(high) else {
        throw BlackTeamError("\(label) must be a whole number from \(low) to \(high).")
    }
}

private func validateShape(_ config: JSONValue, cloud: CloudRules) throws {
    try requireKeys(config, topKeys, "configuration")
    if config["schemaVersion"]?.double != 1 { throw BlackTeamError("Unsupported configuration version. Install a compatible Black Team version.") }
    try requireKeys(config["model"], modelKeys, "model")
    let model = config["model"]!
    guard let source = model["source"]?.string, ["gguf", "server", "cloud"].contains(source) else {
        throw BlackTeamError("Choose a GGUF file, an existing local server or a cloud model.")
    }
    // A cloud model's address is checked as a cloud address; every other source still only ever talks to this Mac.
    if source == "cloud" { _ = try cloud(model["endpoint"]?.string ?? "") } else { _ = try localEndpoint(model["endpoint"]?.string ?? "") }
    guard let key = model["apiKey"]?.string else { throw BlackTeamError("The server API key must contain only printable characters without spaces.") }
    _ = try serverHeaders(key)
    try requireText(model["id"], "Server model ID", max: 256)
    try requireText(model["name"], "Model name", max: 120)
    if model["name"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BlackTeamError("Enter a model name.") }
    for field in ["file", "runtime", "mmproj", "draft"] {
        try requireText(model[field], "Model \(field)")
        let value = model[field]!.string!
        if !value.isEmpty && !value.hasPrefix("/") { throw BlackTeamError("Model \(field) must be an absolute local path.") }
    }
    try requireInteger(model["context"], "Context size", 512, source == "cloud" ? 2_000_000 : 131072)
    try requireInteger(model["gpuLayers"], "GPU layers", 0, 999)
    try requireInteger(model["threads"], "CPU threads", 1, 1024)
    try requireText(config["workspace"], "Workspace")
    if !config["workspace"]!.string!.hasPrefix("/") { throw BlackTeamError("Workspace must be an absolute local path.") }
    try requireKeys(config["phone"], phoneKeys, "phone")
    let phone = config["phone"]!
    guard phone["enabled"]?.bool != nil else { throw BlackTeamError("Phone enabled must be true or false.") }
    try requireText(phone["hostname"], "Phone hostname", max: 253)
    try requireText(phone["owner"], "Phone owner", max: 120)
    let hostname = phone["hostname"]!.string!
    if !hostname.isEmpty, hostname.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: [.regularExpression, .caseInsensitive]) == nil || hostname.utf16.count > 253 {
        throw BlackTeamError("Phone hostname must be a hostname without a scheme, path, or port.")
    }
}

// MARK: Files

private struct FileHeader { var bytes: [UInt8]; var size: Int; var realPath: String }

private func readHeader(_ filename: String, length: Int, label: String, access mode: Int32 = R_OK) throws -> FileHeader {
    func fail(_ reason: String) -> BlackTeamError { BlackTeamError("\(label) cannot be read: \(reason).") }
    let info = CoreFS.stat(filename)
    if info.error != 0 { throw fail(CoreFS.errnoName(info.error)) }
    if (info.mode & S_IFMT) != S_IFREG { throw fail("not a regular file") }
    if access(filename, mode) != 0 { throw fail(CoreFS.errnoName(errno)) }
    let fd = open(filename, O_RDONLY)
    if fd < 0 { throw fail(CoreFS.errnoName(errno)) }
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: length)
    if pread(fd, &bytes, length, 0) != length { throw fail("file is truncated") }
    guard let resolved = realpath(filename, nil) else { throw fail(CoreFS.errnoName(errno)) }
    defer { free(resolved) }
    return FileHeader(bytes: bytes, size: info.size, realPath: String(cString: resolved))
}

public struct ModelFileInfo: Equatable, Sendable {
    public var bytes: Int
    public var version: Int
    public var realPath: String
}

public struct RuntimeFileInfo: Equatable, Sendable {
    public var bytes: Int
    public var realPath: String
}

public func inspectModel(_ filename: String) throws -> ModelFileInfo {
    if filename.isEmpty || !filename.hasPrefix("/") { throw BlackTeamError("Choose a local GGUF model file first.") }
    let info = try readHeader(filename, length: 24, label: "GGUF model")
    let version = Int(info.bytes[4]) | Int(info.bytes[5]) << 8 | Int(info.bytes[6]) << 16 | Int(info.bytes[7]) << 24
    if String(decoding: info.bytes[0..<4], as: UTF8.self) != "GGUF" || ![2, 3].contains(version) {
        throw BlackTeamError("Choose a GGUF version 2 or 3 model; this file has an invalid or unsupported header.")
    }
    return ModelFileInfo(bytes: info.size, version: version, realPath: info.realPath)
}

/// Mach-O CPU types: the 64-bit flag (0x01000000) plus 7 (x86) or 12 (ARM).
public enum MachOCPU {
    public static let arm64: UInt32 = 0x0100000C
    public static let x86_64: UInt32 = 0x01000007
    #if arch(arm64)
    public static let current: UInt32 = arm64
    #else
    public static let current: UInt32 = x86_64
    #endif
    public static func name(_ type: UInt32) -> String { type == arm64 ? "arm64" : "x86_64" }
}

#if os(Linux)
/// The ELF machine number and the name used in messages for this computer (`process.arch` in the Node app).
public enum ELFMachine {
    #if arch(arm64)
    public static let current: UInt16 = 183
    public static let name = "arm64"
    #else
    public static let current: UInt16 = 62
    public static let name = "x64"
    #endif
}

/// Accepts a 64-bit little-endian ELF executable (or position-independent executable) built for this computer.
/// `cpuType` is only used on the Mac.
public func inspectRuntime(_ filename: String, cpuType: UInt32 = MachOCPU.current) throws -> RuntimeFileInfo {
    if filename.isEmpty || !filename.hasPrefix("/") || (filename as NSString).lastPathComponent != "llama-server" {
        throw BlackTeamError("Choose the llama-server executable from an extracted Linux llama.cpp release.")
    }
    let info = try readHeader(filename, length: 64, label: "llama-server", access: R_OK | X_OK)
    let h = info.bytes
    let type = UInt16(h[16]) | UInt16(h[17]) << 8
    let machine = UInt16(h[18]) | UInt16(h[19]) << 8
    // 0x7f "ELF", 64-bit (2), little-endian (1), ET_EXEC (2) or ET_DYN (3), the right machine.
    guard h[0] == 0x7f, h[1] == 0x45, h[2] == 0x4c, h[3] == 0x46, h[4] == 2, h[5] == 1, type == 2 || type == 3, machine == ELFMachine.current else {
        throw BlackTeamError("llama-server must be a native Linux \(ELFMachine.name) executable. Keep it alongside its release libraries.")
    }
    return RuntimeFileInfo(bytes: info.size, realPath: info.realPath)
}
#else
/// Accepts a thin 64-bit Mach-O executable of this Mac's architecture, or a universal binary containing one.
public func inspectRuntime(_ filename: String, cpuType: UInt32 = MachOCPU.current) throws -> RuntimeFileInfo {
    if filename.isEmpty || !filename.hasPrefix("/") || (filename as NSString).lastPathComponent != "llama-server" {
        throw BlackTeamError("Choose the llama-server executable from an extracted macOS llama.cpp release.")
    }
    let info = try readHeader(filename, length: 64, label: "llama-server", access: R_OK | X_OK)
    let h = info.bytes
    func little(_ at: Int) -> UInt32 { UInt32(h[at]) | UInt32(h[at + 1]) << 8 | UInt32(h[at + 2]) << 16 | UInt32(h[at + 3]) << 24 }
    func big(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]) }
    var matches = false
    if little(0) == 0xfeedfacf {
        // MH_EXECUTE is file type 2.
        matches = little(4) == cpuType && little(12) == 2
    } else if big(h, 0) == 0xcafebabe {
        let count = Int(big(h, 4))
        if (1...16).contains(count) {
            let table = count <= 2 ? h : try readHeader(filename, length: 8 + 20 * count, label: "llama-server", access: R_OK | X_OK).bytes
            matches = (0..<count).contains { big(table, 8 + 20 * $0) == cpuType }
        }
    }
    if !matches {
        throw BlackTeamError("llama-server must be a native macOS \(MachOCPU.name(cpuType)) executable. Keep it alongside its release libraries.")
    }
    return RuntimeFileInfo(bytes: info.size, realPath: info.realPath)
}
#endif

public struct MemoryEstimate: Equatable, Sendable {
    public var modelBytes: Int
    public var headroomBytes: Int
    public var estimatedBytes: Int
    public var exceedsTotal: Bool
    public var exceedsFree: Bool
    public var warning: String?
    public var note: String
}

/// `totalBytes` and `freeBytes` default to this Mac's memory and what it can hand out now.
public func estimateMemory(_ modelBytes: Int, totalBytes: Int? = nil, freeBytes: Int? = nil) -> MemoryEstimate {
    let total = totalBytes ?? Int(ProcessInfo.processInfo.physicalMemory)
    let free = freeBytes ?? SystemInfo.memoryInfo().available
    let headroom = max(2 * GiB, Int((Double(modelBytes) * 0.25).rounded(.up)))
    let estimated = modelBytes + headroom
    return MemoryEstimate(
        modelBytes: modelBytes, headroomBytes: headroom, estimatedBytes: estimated,
        exceedsTotal: estimated > total, exceedsFree: estimated > free,
        warning: estimated > total
            ? "This model plus basic headroom exceeds system RAM. Choose a smaller model or expect memory pressure."
            : estimated > free ? "This model plus basic headroom exceeds currently free RAM. Close other apps or choose a smaller model." : nil,
        note: "Rough RAM estimate only. Context length, model architecture, GPU memory, and other apps affect actual usage; this does not guarantee the model will fit.")
}

public struct ModelValidation: Equatable, Sendable {
    public var server: Bool
    public var model: ModelFileInfo?
    public var runtime: RuntimeFileInfo?
    public var memory: MemoryEstimate?
}

public func validateModelFiles(_ model: ModelConfig, cloud: CloudRules = .standard) throws -> ModelValidation {
    if model.source == "cloud" {
        _ = try cloud(model.endpoint)
        if model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.id.utf16.count > 256 || model.id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) {
            throw BlackTeamError("Choose or type the model id of this cloud service.")
        }
        _ = try cloudHeaders(model.apiKey)
        return ModelValidation(server: true)
    }
    if model.source == "server" {
        _ = try localEndpoint(model.endpoint)
        if model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.id.utf16.count > 256 || model.id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) {
            throw BlackTeamError("Choose a model reported by your local server.")
        }
        _ = try serverHeaders(model.apiKey)
        return ModelValidation(server: true)
    }
    let file = try inspectModel(model.file)
    let runtime = try inspectRuntime(model.runtime)
    return ModelValidation(server: false, model: file, runtime: runtime, memory: estimateMemory(file.bytes))
}

private func validateWorkspace(_ workspace: String, defaultWorkspace: String) throws {
    let info = CoreFS.stat(workspace)
    if info.error == ENOENT && workspace == defaultWorkspace { return } // It can be created later, when a feature uses it.
    if info.error != 0 || (info.mode & S_IFMT) != S_IFDIR || access(workspace, R_OK | W_OK | X_OK) != 0 {
        throw BlackTeamError("Choose an existing, readable and writable workspace directory.")
    }
}

/// Checks the workspace and creates the default one (private) when it does not exist yet.
@discardableResult
public func ensureWorkspace(_ workspace: String, defaultWorkspace: String = AppPaths.defaultWorkspace()) throws -> String {
    try validateWorkspace(workspace, defaultWorkspace: defaultWorkspace)
    if workspace == defaultWorkspace && !CoreFS.exists(workspace) {
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try validateWorkspace(workspace, defaultWorkspace: defaultWorkspace)
    return workspace
}

/// Reads and saves `config.json`. A save merges only approved settings into what is stored.
public final class ConfigStore: @unchecked Sendable {
    public let stateDir: String
    public let filename: String
    private let defaultWorkspace: String
    private let lock = NSLock()
    /// How a cloud model's address is checked. Always `.standard` in the app.
    public let cloud: CloudRules

    public init(stateDir: String, defaultWorkspace: String = AppPaths.defaultWorkspace(), cloud: CloudRules = .standard) throws {
        guard stateDir.hasPrefix("/") else { throw BlackTeamError("State directory must be an absolute path.") }
        self.stateDir = stateDir
        self.filename = stateDir + "/config.json"
        self.defaultWorkspace = defaultWorkspace
        self.cloud = cloud
    }

    private func defaults() -> Config { Config(workspace: defaultWorkspace) }

    private func merged(_ base: Config, _ input: [String: JSONValue]) throws -> (value: JSONValue, config: Config) {
        var next = configJSON(base).object!
        for (key, value) in input where key != "model" && key != "phone" { next[key] = value }
        for section in ["model", "phone"] {
            var combined = next[section]?.object ?? [:]
            for (key, value) in input[section]?.object ?? [:] { combined[key] = value }
            next[section] = .object(combined)
        }
        let value = JSONValue.object(next)
        try validateShape(value, cloud: cloud)
        let config = try JSONDecoder().decode(Config.self, from: Data(value.text().utf8))
        return (value, config)
    }

    private func checkInput(_ input: JSONValue) throws -> [String: JSONValue] {
        let object = try requireObject(input, "configuration")
        try requireKeys(input, topKeys, "configuration")
        if object["model"] != nil { try requireKeys(object["model"], modelKeys, "model") }
        if object["phone"] != nil { try requireKeys(object["phone"], phoneKeys, "phone") }
        return object
    }

    /// The stored configuration, or the defaults when none has been saved. Reading creates nothing.
    public func read() throws -> Config {
        let info = CoreFS.stat(filename)
        if info.error == ENOENT { return defaults() }
        let input: JSONValue
        do {
            if info.error != 0 { throw BlackTeamError(CoreFS.errnoName(info.error)) }
            if (info.mode & S_IFMT) != S_IFREG || info.size > 64 * 1024 { throw BlackTeamError("Configuration is not a valid small JSON file.") }
            guard let data = FileManager.default.contents(atPath: filename) else { throw BlackTeamError("EACCES") }
            input = try JSONValue.parse(data)
        } catch {
            throw BlackTeamError("Cannot read Black Team configuration: \((error as? BlackTeamError)?.message ?? "the file is not valid JSON").")
        }
        return try merged(defaults(), try checkInput(input)).config
    }

    @discardableResult
    public func save(_ config: Config) throws -> Config { try save(configJSON(config)) }

    /// Merges the given settings (`model` and `phone` field by field) over the stored ones and writes the result.
    @discardableResult
    public func save(_ input: JSONValue) throws -> Config {
        lock.lock(); defer { lock.unlock() }
        let object = try checkInput(input)
        let (value, next) = try merged(try read(), object)
        if next.model.source == "gguf" {
            if !next.model.file.isEmpty { _ = try inspectModel(next.model.file) }
            if !next.model.runtime.isEmpty { _ = try inspectRuntime(next.model.runtime) }
            for path in [next.model.mmproj, next.model.draft] where !path.isEmpty { _ = try inspectModel(path) }
        }
        try validateWorkspace(next.workspace, defaultWorkspace: defaultWorkspace)
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if CoreFS.isSymlink(stateDir) { throw BlackTeamError("Black Team state directory must not be a symbolic link.") }
        chmod(stateDir, 0o700)
        let data = Data((value.text(pretty: true) + "\n").utf8)
        try CoreFS.writeAtomic(filename, data, temporary: "\(stateDir)/.config-\(CoreFS.hex(12)).tmp", syncDirectory: true)
        return next
    }
}

public struct HardwareReport: Codable, Equatable, Sendable {
    public var platform: String
    public var arch: String
    public var cpu: CPUInfo
    public var memory: MemoryInfo
    public var disk: DiskInfo?
}

/// cores are physical; threads are what the scheduler sees. memory.free is what the system can hand out now.
public func hardwareReport(stateDir: String = NSHomeDirectory()) async -> HardwareReport {
    var memory = SystemInfo.memoryInfo()
    memory.free = memory.available
    #if os(Linux)
    let platform = "linux", arch = ELFMachine.name   // as os.platform() and os.arch() say in the Linux app
    #else
    let platform = "darwin", arch = SystemInfo.isAppleSilicon ? "arm64" : "x64"
    #endif
    return HardwareReport(platform: platform, arch: arch, cpu: SystemInfo.cpuTopology(),
                          memory: memory, disk: SystemInfo.diskSpace(at: stateDir))
}
