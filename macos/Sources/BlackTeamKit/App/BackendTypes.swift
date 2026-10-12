import Foundation

// The values and seams of `Backend`: what the interface reads, and what tests replace.

// MARK: Seams

/// What the backend needs from the model runtime. `ModelRuntime` is the real one; tests use a fake.
public protocol BackendRuntime: AnyObject, Sendable {
    func status() async -> RuntimeStatus
    func modelPid() async -> Int?
    func requestHeaders() async throws -> [String: String]
    func setBusy(_ value: Bool) async throws
    func start() async throws -> String
    func stop(force: Bool) async throws
    func dispose() async throws
}

extension ModelRuntime: BackendRuntime {}

/// The Black Team engine (Code). `Engine` is the real one.
public protocol CodeEngine: AnyObject, Sendable {
    func run(thread: ThreadRef, config: Config, runtime: EngineRuntime, endpoint: String, job: JobState, signal: CancelSignal?,
             save: @escaping @Sendable (JSONValue) throws -> Void, mode: String, workspace: String?) async throws
    func undo(_ id: String?) throws -> UndoResult
}

extension Engine: CodeEngine {}

/// Plans the context of a Chat turn (the llama.cpp tokenizer by default).
public typealias ContextPlanning = @Sendable (_ messages: [JSONValue], _ context: Int, _ mode: String, _ endpoint: String,
                                              _ headers: [String: String], _ signal: CancelSignal?) async throws -> PreparedContext

/// Where the llama.cpp runtime comes from. `RuntimeInstaller` is the real one.
public protocol RuntimeProviding: AnyObject, Sendable {
    func installedRuntime() -> InstalledRuntime?
    func installLatest(progress: (@Sendable (RuntimeInstallEvent) -> Void)?) async throws -> InstalledRuntime
    func cancel()
}

extension RuntimeInstaller: RuntimeProviding {
    public func installLatest(progress: (@Sendable (RuntimeInstallEvent) -> Void)?) async throws -> InstalledRuntime {
        try await install(nil, force: false, progress: progress)
    }
}

// MARK: Runtime as the engine and harnesses see it

/// The headers of a started model, read once before a turn.
///
/// `EngineRuntime.requestHeaders()` is synchronous but `ModelRuntime` is an actor, so the headers are
/// read (asynchronously) right after `start()` and handed to the engine as this value. That is safe
/// because the key is created when the model server starts and does not change while it stays started;
/// a turn that outlives its server fails on its requests anyway, as it would with the JavaScript runtime.
public struct StartedRuntimeHeaders: EngineRuntime, Sendable {
    public var headers: [String: String]
    public init(_ headers: [String: String]) { self.headers = headers }
    public func requestHeaders() -> [String: String] { headers }
}

/// `HarnessRuntime` over a backend runtime: `start()` starts the model and remembers its headers,
/// which are then served synchronously (same reasoning as `StartedRuntimeHeaders`).
public final class HarnessRuntimeAdapter: HarnessRuntime, @unchecked Sendable {
    private let runtime: BackendRuntime
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    public init(_ runtime: BackendRuntime) { self.runtime = runtime }

    public func start() async throws -> String {
        let endpoint = try await runtime.start()
        let read = try await runtime.requestHeaders()
        remember(read)
        return endpoint
    }

    private func remember(_ read: [String: String]) { lock.lock(); headers = read; lock.unlock() }
    public func requestHeaders() -> [String: String] { lock.lock(); defer { lock.unlock() }; return headers }
}

// MARK: Status

public struct RuntimeSummary: Codable, Equatable, Sendable {
    public var state: String
    public var ready: Bool
    public var busy: Bool
    public var name: String
    public var error: String?
    public var features: [String]
}

public struct ApprovalSummary: Codable, Equatable, Sendable {
    public var id: String
    public var digest: String
    public var command: String
    public var description: String
    public var expires: Int64
}

/// The current job, without the callbacks the JavaScript hid from the interface.
public struct JobSummary: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String?
    public var kind: String
    public var state: String
    public var progress: String
    public var context: JSONValue?
    public var meter: JobMeter?
    public var approval: ApprovalSummary?

    public init(_ snapshot: JobSnapshot) {
        id = snapshot.id; threadId = snapshot.threadId; kind = snapshot.kind; state = snapshot.state; progress = snapshot.progress
        context = snapshot.context; meter = snapshot.meter
        approval = snapshot.approval.map { ApprovalSummary(id: $0.id, digest: $0.digest, command: $0.command, description: $0.description, expires: $0.expires) }
    }
}

public struct ProjectSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var workspace: String
    public var exists: Bool
    public var notes: String
}

public struct PerformanceMemory: Codable, Equatable, Sendable {
    public var total: Int
    public var free: Int
    public var used: Int
    public var swapTotal: Int
    public var swapUsed: Int
}

public struct PerformanceSummary: Codable, Equatable, Sendable {
    public var cpu: Int
    public var cores: Int
    public var load: Double
    public var memory: PerformanceMemory
    public var temperature: Int?
    /// Memory held by the model server: the one Black Team started, or the user's own on the configured port.
    public var model: ProcessMemory?
}

/// The model settings the interface may see: everything but the server key.
public struct PublicModelConfig: Codable, Equatable, Sendable {
    public var source: String
    public var endpoint: String
    public var id: String
    public var name: String
    public var file: String
    public var runtime: String
    public var context: Int
    public var gpuLayers: Int
    public var threads: Int
    public var mmproj: String
    public var draft: String
}

public struct PublicConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var model: PublicModelConfig
    public var workspace: String
}

public struct HardwareSummary: Codable, Equatable, Sendable {
    public var platform: String
    public var arch: String
    public var cpu: CPUInfo
    public var memory: MemoryInfo
    public var disk: DiskInfo?
    public var cores: Int
    public var threads: Int
    public var warnings: [String]
}

/// Everything the interface shows, as `status('desktop')` returned it (phone and dictation left out).
public struct BackendStatus: Codable, Equatable, Sendable {
    public var version: String
    public var setupComplete: Bool
    public var runtime: RuntimeSummary
    public var threads: [ThreadSummary]
    public var job: JobSummary?
    public var agentEnabled: Bool
    public var projects: [ProjectSummary]
    public var memory: Bool
    public var codeMap: Bool
    public var performance: PerformanceSummary
    public var config: PublicConfig
    public var models: [SavedModelSummary]
    public var serverKeyConfigured: Bool
    public var integrations: IntegrationSettings?
    public var hardware: HardwareSummary
    /// The llama.cpp runtime Black Team downloaded, if any.
    public var downloadedRuntime: InstalledRuntime?
}

// MARK: Results

public struct SubmitResult: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    public var state: String
}

public struct CancelResult: Codable, Equatable, Sendable { public var stopping: Bool }

public struct SavedFlag: Codable, Equatable, Sendable {
    public var saved: Bool
    public var warning: String?
}

public struct KeeperEntry: Codable, Equatable, Sendable {
    public var text: String
    public var at: Double
}

public struct NoteSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var updated: Double
    public var size: Int
    public var kind: NoteKind
}

public struct KeeperState: Codable, Equatable, Sendable {
    public var usage: MemoryUsage
    public var limits: MemoryLimits
    public var actions: [KeeperEntry]
}

public struct MemoryOverview: Codable, Equatable, Sendable {
    public var notes: [NoteSummary]
    public var graph: MemoryGraph
    public var coreWritten: Bool
    public var keeper: KeeperState
}

public struct ArtifactFile: Equatable, Sendable {
    public var path: String
    public var name: String
    public var size: Int
}

/// A found server or file, marked with its list key and whether it is already saved or was passed over.
public struct MarkedServer: Codable, Equatable, Sendable {
    public var server: FoundServer
    public var key: String
    public var saved: Bool
    public var ignored: Bool
}

public struct MarkedFile: Codable, Equatable, Sendable {
    public var file: FoundFile
    public var key: String
    public var saved: Bool
    public var ignored: Bool
}

public struct FoundModelsReport: Codable, Equatable, Sendable {
    public var servers: [MarkedServer]
    public var files: [MarkedFile]
    public var runtime: String
    public var looked: Looked

    /// Where the finder looked.
    public struct Looked: Codable, Equatable, Sendable { public var ports: [Int]; public var folders: [String] }
}

/// A chosen model file, described: its name, a context that fits, and the files beside it.
public struct ModelInspection: Codable, Equatable, Sendable {
    public var name: String
    public var trainingContext: Int?
    public var context: Int
    public var bytes: Int
    public var mmproj: String
    public var draft: String
}

/// What the interface needs to show a file or folder chooser.
public struct PickerRequest: Equatable, Sendable {
    public var title: String
    public var directory: Bool
    public var extensions: [String]
}

// MARK: Starter models

public struct StarterEntry: Codable, Equatable, Sendable, Identifiable {
    public var model: StarterModel
    public var installed: Bool
    public var recommended: Bool
    /// Whether the model and its headroom fit this Mac's memory.
    public var fits: Bool
    public var id: String { model.id }
}

public struct StarterCatalogue: Codable, Equatable, Sendable {
    public var models: [StarterEntry]
    public var recommendedID: String
    public var memoryBytes: Int64
    public var runtime: InstalledRuntime?
}

/// Progress of `setUpStarter`: a line of text, how far the current download is, and its speed.
public struct SetupProgress: Codable, Equatable, Sendable {
    public var stage: String
    public var fraction: Double?
    public var bytesPerSecond: Double
    public init(stage: String, fraction: Double? = nil, bytesPerSecond: Double = 0) {
        self.stage = stage; self.fraction = fraction; self.bytesPerSecond = bytesPerSecond
    }
}

public struct StarterSetupResult: Codable, Equatable, Sendable {
    public var modelName: String
    public var file: String
    public var runtime: String
    public var runtimeTag: String
    public var warning: String?
}

// MARK: Change notification

/// Tells observers that something changed. Bursts are merged: observers see at most one change
/// per interval, and a slow observer never builds up a queue.
final class ChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [Int: AsyncStream<Void>.Continuation] = [:]
    private var next = 0
    private var scheduled = false
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.05) { self.interval = interval }

    func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock(); let key = next; next += 1; observers[key] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.observers[key] = nil; self.lock.unlock()
            }
        }
    }

    func notify() {
        lock.lock()
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock(); scheduled = false; let all = Array(observers.values); lock.unlock()
        for continuation in all { continuation.yield() }
    }

    func finish() {
        lock.lock(); let all = Array(observers.values); observers = [:]; lock.unlock()
        for continuation in all { continuation.finish() }
    }
}

// MARK: Small helpers shared by the Backend files

extension JSONValue {
    func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        var copy = object ?? [:]
        copy[key] = value
        return .object(copy)
    }

    static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONValue.parse(JSONEncoder().encode(value))) ?? .null
    }
}

extension ThreadRef {
    /// Changes the last message (the reply being written).
    func updateLast(_ change: (inout [String: JSONValue]) -> Void) {
        var thread = value.object ?? [:]
        var messages = thread["messages"]?.array ?? []
        guard !messages.isEmpty else { return }
        var last = messages[messages.count - 1].object ?? [:]
        change(&last)
        messages[messages.count - 1] = .object(last)
        thread["messages"] = .array(messages)
        value = .object(thread)
    }
}

struct Project: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var workspace: String
    var created: String
}
