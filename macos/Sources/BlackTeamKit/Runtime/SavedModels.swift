import Foundation
import CryptoKit

// The models a person has set up, so switching between them is one choice.
// config.json still holds the one model in use; this list sits beside it in its
// own file, so an older Black Team can read the same configuration after a rollback.

private let limit = 24
private let textKeys = ["name", "file", "runtime", "source", "endpoint", "id", "apiKey", "mmproj", "draft"]
private let numberKeys = ["context", "gpuLayers", "threads"]

private func json(_ model: ModelConfig) -> JSONValue {
    let data = (try? JSONEncoder().encode(model)) ?? Data("{}".utf8)
    return (try? JSONValue.parse(data)) ?? .object([:])
}

/// Two saved entries are the same model when they point at the same file, or the same model on the same server.
public func keyOf(_ model: ModelConfig) -> String {
    let identity: JSONValue = model.source == "server" ? [.string("server"), .string(model.endpoint), .string(model.id)] : [.string("gguf"), .string(model.file)]
    let digest = SHA256.hash(data: Data(identity.text().utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
}

/// A saved entry only when every field has the right type and size; anything else is not a model.
func cleanModel(_ entry: JSONValue?) -> ModelConfig? {
    guard let object = entry?.object, let source = object["source"]?.string, ["gguf", "server"].contains(source) else { return nil }
    var text: [String: String] = [:]
    for key in textKeys {
        let value = object[key] ?? .null
        if case .null = value { text[key] = ""; continue }
        guard let string = value.string, string.utf16.count <= 4096, !string.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        text[key] = string
    }
    var numbers: [String: Int] = [:]
    for key in numberKeys {
        guard let value = object[key]?.double, value.rounded() == value, value >= 0, value <= 9_007_199_254_740_991 else { return nil }
        numbers[key] = Int(value)
    }
    let model = ModelConfig(source: text["source"]!, endpoint: text["endpoint"]!, id: text["id"]!, apiKey: text["apiKey"]!, name: text["name"]!,
                            file: text["file"]!, runtime: text["runtime"]!, context: numbers["context"]!, gpuLayers: numbers["gpuLayers"]!,
                            threads: numbers["threads"]!, mmproj: text["mmproj"]!, draft: text["draft"]!)
    if model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    if model.source == "server" ? (model.endpoint.isEmpty || model.id.isEmpty) : model.file.isEmpty { return nil }
    return model
}

func cleanModel(_ model: ModelConfig) -> ModelConfig? { cleanModel(json(model)) }

/// What the interface may see of a saved model: never the server key. `location` is `where` in JSON.
public struct SavedModelSummary: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var source: String
    public var context: Int
    public var active: Bool
    public var location: String
    enum CodingKeys: String, CodingKey { case key, name, source, context, active, location = "where" }
}

public final class SavedModels: @unchecked Sendable {
    public let stateDir: String
    private let filename: String
    private let lock = NSLock()

    public init(stateDir: String) throws {
        guard stateDir.hasPrefix("/") else { throw BlackTeamError("State directory must be an absolute path.") }
        self.stateDir = stateDir
        self.filename = stateDir + "/saved-models.json"
    }

    // The list is a convenience: a missing or damaged file means an empty list, never a failed start.
    // Beside the models it keeps the keys of found models the user said "not now" to.
    private func load() -> (models: [ModelConfig], ignored: [String]) {
        let info = CoreFS.stat(filename)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= 256 * 1024,
              let data = FileManager.default.contents(atPath: filename), let saved = try? JSONValue.parse(data) else { return ([], []) }
        var seen = Set<String>()
        var models: [ModelConfig] = []
        for entry in saved["models"]?.array ?? [] {
            guard let model = cleanModel(entry), seen.insert(keyOf(model)).inserted else { continue }
            models.append(model)
            if models.count == limit { break }
        }
        let ignored = (saved["ignored"]?.array ?? []).compactMap { $0.string }.filter { isKey($0) }.prefix(100)
        return (models, Array(ignored))
    }

    private func isKey(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{16}$", options: .regularExpression) != nil }

    public func read() -> [ModelConfig] { load().models }
    public func ignored() -> [String] { load().ignored }

    private func write(_ models: [ModelConfig], _ keep: [String]) throws {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body: JSONValue = ["version": 1, "models": .array(models.map(json)), "ignored": .array(keep.map { .string($0) })]
        // Entries can hold a local server key, so the file is private like config.json.
        try CoreFS.writeAtomic(filename, Data((body.text(pretty: true) + "\n").utf8), temporary: "\(stateDir)/.saved-models-\(CoreFS.hex(12)).tmp")
    }

    @discardableResult
    public func remember(_ input: ModelConfig) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let model = cleanModel(input) else { throw BlackTeamError("This model cannot be saved to your list.") }
        let key = keyOf(model)
        let stored = load()
        let others = stored.models.filter { keyOf($0) != key }
        if others.count >= limit { throw BlackTeamError("Your list holds up to \(limit) models. Remove one first.") }
        // A model that joins the list is no longer one the user passed over.
        try write(others + [model], stored.ignored.filter { $0 != key })
        return key
    }

    public func forget(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stored = load()
        let kept = stored.models.filter { keyOf($0) != key }
        if kept.count == stored.models.count { throw BlackTeamError("That model is not in your list.") }
        try write(kept, stored.ignored)
    }

    public func find(_ key: String) -> ModelConfig? { read().first { keyOf($0) == key } }

    /// "Not now" for a found model: the home page stops offering it; Settings still can.
    @discardableResult
    public func ignore(_ key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isKey(key) else { throw BlackTeamError("Choose a found model to pass over.") }
        let stored = load()
        if !stored.ignored.contains(key) { try write(stored.models, Array((stored.ignored + [key]).suffix(100))) }
        return true
    }

    public func list(active: ModelConfig? = nil) -> [SavedModelSummary] {
        let current = active.flatMap(cleanModel).map(keyOf) ?? ""
        return read().map { model in
            var place = (model.file as NSString).lastPathComponent
            if model.source == "server" {
                place = model.endpoint.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"/v1/?$"#, with: "", options: .regularExpression)
            }
            return SavedModelSummary(key: keyOf(model), name: model.name, source: model.source, context: model.context, active: keyOf(model) == current, location: place)
        }
    }
}

public func createSavedModels(_ stateDir: String) throws -> SavedModels { try SavedModels(stateDir: stateDir) }

public struct SwitchResult: Equatable, Sendable { public var switched: Bool; public var name: String }

/// Stops whatever is loaded, then makes the chosen model the one in use. The next message starts it.
public func switchModel(key: String, saved: SavedModels, configStore: ConfigStore, stop: () async throws -> Void, busy: () -> Bool) async throws -> SwitchResult {
    if busy() { throw BlackTeamError("Wait for the current response before switching models.") }
    guard let model = saved.find(key) else { throw BlackTeamError("That model is not in your list.") }
    do { _ = try validateModelFiles(model) }
    catch { throw BlackTeamError("\(model.name) cannot be used right now: \(messageOf(error))") }
    try await stop()
    if busy() { throw BlackTeamError("Wait for the current response before switching models.") }
    try configStore.save(["model": json(model)])
    return SwitchResult(switched: true, name: model.name)
}

public func switchModel(key: String, saved: SavedModels, configStore: ConfigStore, runtime: ModelRuntime, busy: () -> Bool) async throws -> SwitchResult {
    try await switchModel(key: key, saved: saved, configStore: configStore, stop: { try await runtime.stop() }, busy: busy)
}

public struct AddModelsResult: Equatable, Sendable {
    public var added: [String]
    public var skipped: [String]
    public var inUse: String
}

/// Adds models the finder turned up. Each is checked like one set up by hand; the first becomes
/// the model in use when none was set up yet, so a new install is ready after one choice.
/// Threads default to the physical cores: on a CPU, hyper-threads slow a model down rather than help.
public func addModels(items: [JSONValue], saved: SavedModels, configStore: ConfigStore, threads: Int? = nil) throws -> AddModelsResult {
    let threads = threads ?? max(1, min(64, SystemInfo.cpuTopology().cores))
    if items.isEmpty || items.count > limit { throw BlackTeamError("Choose at least one model to add.") }
    let base = try configStore.read().model
    var added: [ModelConfig] = [], skipped: [String] = []
    for item in items {
        var title = "Model"
        if let given = item["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { title = String(given.prefix(120)) }
        do {
            var context = 4096
            if let value = item["context"]?.double, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 { context = Int(max(512, min(131072, value))) }
            let model: ModelConfig
            if item["source"]?.string == "server" {
                model = ModelConfig(source: "server", endpoint: try localEndpoint(item["endpoint"]?.string ?? ""), id: item["id"]?.string ?? "", apiKey: "", name: title,
                                    file: "", runtime: "", context: context, gpuLayers: 0, threads: threads, mmproj: "", draft: "")
            } else {
                model = ModelConfig(source: "gguf", endpoint: base.endpoint, id: "", apiKey: "", name: title, file: item["file"]?.string ?? "",
                                    runtime: item["runtime"]?.string ?? "", context: context, gpuLayers: 0, threads: threads,
                                    mmproj: item["mmproj"]?.string ?? "", draft: item["draft"]?.string ?? "")
            }
            _ = try validateModelFiles(model)
            try saved.remember(model)
            added.append(model)
        } catch { skipped.append("\(title): \(messageOf(error))") }
    }
    if added.isEmpty { throw BlackTeamError("No model could be added. \(skipped.first ?? "")") }
    var ready = false
    if let current = cleanModel(base) { ready = current.source == "server" ? !current.id.isEmpty : !current.runtime.isEmpty }
    if !ready { try configStore.save(["model": json(added[0])]) }
    return AddModelsResult(added: added.map(\.name), skipped: skipped, inUse: ready ? base.name : added[0].name)
}

public func forgetModel(key: String, saved: SavedModels, configStore: ConfigStore) throws {
    let active = cleanModel(try configStore.read().model)
    if let active, keyOf(active) == key { throw BlackTeamError("This model is in use. Switch to another model before removing it.") }
    try saved.forget(key)
}
