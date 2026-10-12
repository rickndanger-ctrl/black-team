import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Starts and stops Black Team's own llama-server, or connects to a model server that is
// already running. Everything that touches the system (the process, the network, the
// port, the help text) is passed in with a real default, so tests use a fake process.

public enum RuntimeState: String, Codable, Equatable, Sendable { case off, starting, ready, error }

public struct RuntimeStatus: Codable, Equatable, Sendable {
    public var state: RuntimeState
    public var ready: Bool
    public var busy: Bool
    public var error: String?
    public var name: String
    public var port: Int?
    public var features: [String]
}

// MARK: Process seam

/// What the runtime needs from a child process: its id and a way to send it a signal.
public protocol ModelProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    func send(signal: Int32)
}

public struct ProcessExit: Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?
    public init(code: Int32? = nil, signal: Int32? = nil) { self.code = code; self.signal = signal }
}

public struct ProcessLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
}

/// Throw this from a spawner when the process cannot start; `code` is the errno name (such as ENOENT).
public struct SpawnError: Error, Sendable {
    public var code: String
    public init(code: String) { self.code = code }
}

/// Starts a process with no input or output. `onExit` must be called once, when the process has ended.
public typealias ProcessSpawner = @Sendable (ProcessLaunch, @escaping @Sendable (ProcessExit) -> Void) throws -> ModelProcess

/// The environment a model process gets: hardware and locale settings, without credentials or
/// llama.cpp options that could enable public listeners, remote models, RPC, or tools. The Linux
/// list also kept library paths and CUDA/HIP/XDG names; the official macOS llama.cpp build finds its
/// dylibs beside the executable through rpath, so no DYLD_* variable is passed on.
public func runtimeEnvironment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    source.filter { key, _ in
        key.range(of: #"^(?:PATH|HOME|LANG|LC_[A-Z_]+|TMPDIR)$"#, options: .regularExpression) != nil
    }
}

/// A free loopback port: bound, read and released again.
public func reserveLoopbackPort() async throws -> Int {
    #if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    if fd < 0 { throw BlackTeamError("Could not reserve a local model port.") }
    defer { close(fd) }
    var address = sockaddr_in()
    #if !os(Linux)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if bound != 0 { throw BlackTeamError("Could not reserve a local model port.") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    if named != 0 { throw BlackTeamError("Could not reserve a local model port.") }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// The text of `llama-server --help` (both streams: builds differ in where they print it), read with an
/// 8 second limit and 4 MiB cap. Blocks, so callers run it off the actor.
public func readHelpText(_ file: String, environment: [String: String] = runtimeEnvironment()) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: file)
    process.arguments = ["--help"]
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { return "" }
    let box = HelpBox()
    let group = DispatchGroup()
    for (index, pipe) in [out, err].enumerated() {
        group.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.set(index, data); group.leave()
        }
    }
    if done.wait(timeout: .now() + 8) == .timedOut {
        process.terminate()
        if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
    }
    _ = group.wait(timeout: .now() + 2)
    let limit = 4 * 1024 * 1024
    return String(decoding: box.joined().prefix(limit), as: UTF8.self)
}

private final class HelpBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts = [Data(), Data()]
    func set(_ index: Int, _ data: Data) { lock.lock(); parts[index] = data; lock.unlock() }
    func joined() -> Data { lock.lock(); defer { lock.unlock() }; return parts[0] + Data("\n".utf8) + parts[1] }
}

// MARK: Real processes

/// Children Black Team started, so they can be stopped when the app quits.
final class ChildRegistry: @unchecked Sendable {
    static let shared = ChildRegistry()
    private let lock = NSLock()
    private var pids = Set<Int32>()
    private var hooked = false

    func add(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
        if !hooked { hooked = true; atexit { ChildRegistry.shared.terminateAll() } }
    }
    func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }

    /// SIGTERM, a short wait, then SIGKILL for whatever is left.
    func terminateAll() {
        lock.lock(); let list = Array(pids); lock.unlock()
        for pid in list { kill(pid, SIGTERM) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while ProcessInfo.processInfo.systemUptime < deadline, list.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
        for pid in list where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

private final class SystemProcess: ModelProcess, @unchecked Sendable {
    let process: Process
    var watcher: Process?
    var pid: Int32 { process.processIdentifier }
    init(_ process: Process) { self.process = process }
    func send(signal: Int32) { if process.isRunning { kill(process.processIdentifier, signal) } }
}

private func spawnErrorCode(_ error: Error) -> String {
    let nsError = error as NSError
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return CoreFS.errnoName(Int32(underlying.code))
    }
    if nsError.domain == NSPOSIXErrorDomain { return CoreFS.errnoName(Int32(nsError.code)) }
    switch nsError.code {
    case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "ENOENT"
    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "EACCES"
    default: return "process error"
    }
}

#if os(Linux)
private final class PlainProcess: ModelProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var gone = false
    var watcherPid: Int32 = 0
    init(pid: Int32) { self.pid = pid }
    func markGone() { lock.lock(); gone = true; lock.unlock() }
    func send(signal: Int32) { lock.lock(); let alive = !gone; lock.unlock(); if alive { kill(pid, signal) } }
}

/// Starts `path` with posix_spawn, standard streams on /dev/null. Returns the process id or the errno.
private func linuxSpawn(_ path: String, _ arguments: [String], environment: [String: String]) -> (pid: Int32, error: Int32) {
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    // The program starts with the default signal set, so SIGTERM stops it even when this process blocks or ignores signals.
    var attributes = posix_spawnattr_t()
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var mask = sigset_t(), defaults = sigset_t()
    sigemptyset(&mask); sigemptyset(&defaults)
    for number in Int32(1)..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults, number) }
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for item in argv { free(item) }; for item in envp { free(item) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, path, &actions, &attributes, &argv, &envp)
    return (child, status)
}

/// Starts a real process (Linux). A small `sh` watcher beside it ends the child within two seconds if Black Team
/// itself dies without a chance to stop it. A thread waits for the child and reports how it ended.
public let systemSpawn: ProcessSpawner = { launch, onExit in
    let started = linuxSpawn(launch.executable, launch.arguments, environment: launch.environment)
    if started.error != 0 { throw SpawnError(code: CoreFS.errnoName(started.error)) }
    let handle = PlainProcess(pid: started.pid)
    ChildRegistry.shared.add(started.pid)
    let watcher = linuxSpawn("/bin/sh", ["-c", #"while kill -0 "$1" 2>/dev/null && kill -0 "$2" 2>/dev/null; do sleep 2; done; kill -0 "$1" 2>/dev/null || kill "$2" 2>/dev/null"#,
                                          "black-team-watch", String(getpid()), String(started.pid)], environment: ["PATH": "/usr/bin:/bin"])
    handle.watcherPid = watcher.error == 0 ? watcher.pid : 0
    let thread = Thread {
        var status: Int32 = 0
        while waitpid(started.pid, &status, 0) < 0 && errno == EINTR {}
        handle.markGone()
        ChildRegistry.shared.remove(started.pid)
        if handle.watcherPid > 0 { kill(handle.watcherPid, SIGTERM); var reaped: Int32 = 0; waitpid(handle.watcherPid, &reaped, 0) }
        let signal = status & 0x7f
        if signal != 0 { onExit(ProcessExit(code: nil, signal: signal)) } else { onExit(ProcessExit(code: (status >> 8) & 0xff, signal: nil)) }
    }
    thread.start()
    return handle
}
#else
/// Starts a real process. A small `sh` watcher beside it ends the child within two seconds if Black Team
/// itself dies without a chance to stop it (a crash or a kill -9), which no normal exit hook could cover.
public let systemSpawn: ProcessSpawner = { launch, onExit in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch.executable)
    process.arguments = launch.arguments
    process.environment = launch.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let handle = SystemProcess(process)
    process.terminationHandler = { finished in
        ChildRegistry.shared.remove(finished.processIdentifier)
        handle.watcher?.terminate()
        if finished.terminationReason == .uncaughtSignal { onExit(ProcessExit(code: nil, signal: finished.terminationStatus)) }
        else { onExit(ProcessExit(code: finished.terminationStatus, signal: nil)) }
    }
    do { try process.run() } catch { throw SpawnError(code: spawnErrorCode(error)) }
    ChildRegistry.shared.add(process.processIdentifier)
    let watcher = Process()
    watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Ends when either process is gone; kills the model only when Black Team is the one that vanished.
    watcher.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null && kill -0 "$2" 2>/dev/null; do sleep 2; done; kill -0 "$1" 2>/dev/null || kill "$2" 2>/dev/null"#,
                         "black-team-watch", String(getpid()), String(process.processIdentifier)]
    watcher.standardInput = FileHandle.nullDevice; watcher.standardOutput = FileHandle.nullDevice; watcher.standardError = FileHandle.nullDevice
    watcher.environment = ["PATH": "/usr/bin:/bin"]
    if (try? watcher.run()) != nil { handle.watcher = watcher }
    return handle
}
#endif

func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGHUP: return "SIGHUP"
    case SIGINT: return "SIGINT"
    case SIGQUIT: return "SIGQUIT"
    case SIGILL: return "SIGILL"
    case SIGABRT: return "SIGABRT"
    case SIGFPE: return "SIGFPE"
    case SIGKILL: return "SIGKILL"
    case SIGBUS: return "SIGBUS"
    case SIGSEGV: return "SIGSEGV"
    case SIGPIPE: return "SIGPIPE"
    case SIGTERM: return "SIGTERM"
    default: return "signal \(signal)"
    }
}

// MARK: Support

private struct FatalStart: Error { let message: String }

func messageOf(_ error: Error) -> String {
    if let known = error as? BlackTeamError { return known.message }
    return error.localizedDescription
}

/// Runs `operation`, giving up with `DeadlineExceeded` after `ms`. The operation is cancelled when it does.
struct DeadlineExceeded: Error {}
func withDeadline<T: Sendable>(ms: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(nanoseconds: UInt64(max(1, ms)) * 1_000_000); throw DeadlineExceeded() }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func removeCredentials(_ directory: String?) {
    guard let directory else { return }
    // The key stays protected by mode 0600 if cleanup fails.
    try? FileManager.default.removeItem(atPath: directory)
}

private final class OwnedLaunch: @unchecked Sendable {
    var process: ModelProcess?
    var exited = false
    var stopped = false
    var error: String?
    let credentialDirectory: String
    var termination: Task<Void, Error>?
    init(credentialDirectory: String) { self.credentialDirectory = credentialDirectory }
}

// MARK: ModelRuntime

public actor ModelRuntime {
    private let configStore: ConfigStore
    private let spawn: ProcessSpawner
    private let fetch: HTTPFetch
    private let reservePort: @Sendable () async throws -> Int
    private let helpProbe: @Sendable (String) -> String
    private let environment: @Sendable () -> [String: String]
    private let appleSilicon: Bool
    private let cores: @Sendable () -> Int
    private let startupTimeoutMs: Int, pollIntervalMs: Int, stopTimeoutMs: Int, killTimeoutMs: Int
    /// Asked before this runtime starts a model process of its own; throwing refuses the start (another Black Team holds the model).
    private let launchGuard: (@Sendable () throws -> Void)?

    private var state = RuntimeState.off
    private var error: String?
    private var name = "Local model"
    private var port: Int?
    private var key: String?
    private var externalEndpoint: String?
    private var busy = false
    private var launch: OwnedLaunch?
    private var features: [String] = []
    private var helpCache: [String: String] = [:] // help text by executable and modification time, read once per build
    private var generation = 0
    private var operationNumber = 0
    private var startTask: (number: Int, task: Task<String, Error>)?
    private var stopTask: (number: Int, task: Task<Void, Error>)?

    public init(configStore: ConfigStore, spawn: @escaping ProcessSpawner = systemSpawn, fetch: @escaping HTTPFetch = LocalHTTP.fetch,
                reservePort: @escaping @Sendable () async throws -> Int = { try await reserveLoopbackPort() },
                help: @escaping @Sendable (String) -> String = { readHelpText($0) },
                environment: @escaping @Sendable () -> [String: String] = { runtimeEnvironment() },
                appleSilicon: Bool = SystemInfo.isAppleSilicon,
                cores: @escaping @Sendable () -> Int = { SystemInfo.cpuTopology().cores },
                startupTimeoutMs: Int = 120_000, pollIntervalMs: Int = 350, stopTimeoutMs: Int = 3000, killTimeoutMs: Int = 1000,
                launchGuard: (@Sendable () throws -> Void)? = nil) {
        self.launchGuard = launchGuard
        self.configStore = configStore; self.spawn = spawn; self.fetch = fetch; self.reservePort = reservePort
        self.helpProbe = help; self.environment = environment; self.appleSilicon = appleSilicon; self.cores = cores
        self.startupTimeoutMs = startupTimeoutMs; self.pollIntervalMs = pollIntervalMs
        self.stopTimeoutMs = stopTimeoutMs; self.killTimeoutMs = killTimeoutMs
    }

    /// Ends every model process Black Team started. Call when the app terminates; also runs at process exit.
    public nonisolated static func terminateOwnedProcesses() { ChildRegistry.shared.terminateAll() }

    public func status() -> RuntimeStatus {
        RuntimeStatus(state: state, ready: state == .ready, busy: busy, error: error, name: name, port: port,
                      features: state == .ready && externalEndpoint == nil ? features : [])
    }

    /// The model process Black Team started, while it runs; a connected server is not ours.
    public func modelPid() -> Int? {
        guard let launch, !launch.exited, let pid = launch.process?.pid, pid > 0 else { return nil }
        return Int(pid)
    }

    public func requestHeaders() throws -> [String: String] {
        if externalEndpoint != nil && state == .ready { return try serverHeaders(key ?? "") }
        guard state == .ready, let key, !key.isEmpty else { throw BlackTeamError("The local model is not ready.") }
        return ["Authorization": "Bearer \(key)"]
    }

    public func setBusy(_ value: Bool) throws {
        if value && state != .ready { throw BlackTeamError("The local model is not ready.") }
        busy = value
    }

    // MARK: Start

    /// Starts the selected model, or connects to the selected server, and returns its `/v1` address.
    /// Calls made while a start is running share it; a start waits for a stop in progress.
    @discardableResult
    public func start() async throws -> String {
        if let stopping = stopTask { try await stopping.task.value; return try await start() }
        if state == .ready { return externalEndpoint ?? "http://127.0.0.1:\(port ?? 0)/v1" }
        if let starting = startTask { return try await starting.task.value }
        generation += 1
        operationNumber += 1
        let current = generation, number = operationNumber
        let task = Task { try await self.startOperation(current, number) }
        startTask = (number, task)
        return try await task.value
    }

    private func startOperation(_ generation: Int, _ number: Int) async throws -> String {
        defer { if startTask?.number == number { startTask = nil } }
        return try await runStart(generation)
    }

    private func assertCurrent(_ generation: Int, _ launch: OwnedLaunch? = nil) throws {
        if generation != self.generation { throw BlackTeamError("Model start cancelled.") }
        if let message = launch?.error { throw BlackTeamError(message) }
        if launch?.exited == true { throw BlackTeamError("The local model process exited before it was ready.") }
    }

    /// What this build of llama-server accepts, so the launch plan adds only flags it knows.
    private func helpFor(_ file: String) async -> String {
        var stamp = file
        if let modified = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]) as? Date { stamp = "\(file):\(modified.timeIntervalSince1970)" }
        if let cached = helpCache[stamp] { return cached }
        let probe = helpProbe
        let text = await Task.detached { probe(file) }.value
        helpCache[stamp] = text
        return text
    }

    private func makeCredentials(_ key: String) throws -> (directory: String, file: String) {
        var template = Array((NSTemporaryDirectory() + "black-team-engine-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw BlackTeamError("Could not prepare the model's private key (\(CoreFS.errnoName(errno))).") }
        let directory = String(cString: template)
        chmod(directory, 0o700)
        let file = directory + "/api-key"
        let fd = open(file, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            let code = errno
            removeCredentials(directory)
            throw BlackTeamError("Could not prepare the model's private key (\(CoreFS.errnoName(code))).")
        }
        let bytes = Array((key + "\n").utf8)
        let written = write(fd, bytes, bytes.count)
        close(fd)
        if written != bytes.count { removeCredentials(directory); throw BlackTeamError("Could not prepare the model's private key (EIO).") }
        return (directory, file)
    }

    private func get(_ url: String, key: String?, timeoutMs: Int) async throws -> (Data, HTTPURLResponse) {
        var built = URLRequest(url: URL(string: url)!)
        built.timeoutInterval = Double(timeoutMs) / 1000
        if let key { built.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let request = built
        let fetch = self.fetch
        return try await withDeadline(ms: timeoutMs) { try await fetch(request) }
    }

    private func runStart(_ generation: Int) async throws -> String {
        var launch: OwnedLaunch?
        var credentialDirectory: String?
        state = .starting
        error = nil
        do {
            if let previous = self.launch, !previous.exited { throw BlackTeamError("The previous model process has not stopped.") }
            let config = try configStore.read()
            // A cloud model runs at its service; the Backend never asks this runtime to start one.
            if config.model.source == "cloud" { throw BlackTeamError("A cloud model runs at its service, so there is nothing to start on this Mac.") }
            _ = try validateModelFiles(config.model, cloud: configStore.cloud)
            name = config.model.name
            if config.model.source == "server" {
                let found = try await discoverModels(endpoint: config.model.endpoint, apiKey: config.model.apiKey, fetch: fetch)
                try assertCurrent(generation)
                if !found.models.contains(config.model.id) { throw BlackTeamError("The selected model is no longer available. Discover models again in Settings.") }
                externalEndpoint = found.endpoint
                key = config.model.apiKey
                state = .ready
                return found.endpoint
            }
            externalEndpoint = nil
            try launchGuard?()
            let chosenPort = try await reservePort()
            try assertCurrent(generation)
            if chosenPort < 1 || chosenPort > 65535 { throw BlackTeamError("Could not reserve a local model port.") }
            port = chosenPort
            let newKey = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            key = newKey
            // Command lines are visible to other users. Put the private engine credential in a
            // restricted file instead of exposing it through the arguments.
            let credentials = try makeCredentials(newKey)
            credentialDirectory = credentials.directory
            let help = await helpFor(config.model.runtime)
            try assertCurrent(generation)
            let plan = planLaunch(model: config.model, port: chosenPort, keyFile: credentials.file, cores: cores(), help: help, appleSilicon: appleSilicon)
            features = plan.features
            let owned = OwnedLaunch(credentialDirectory: credentials.directory)
            launch = owned
            let process: ModelProcess
            do {
                process = try spawn(ProcessLaunch(executable: config.model.runtime, arguments: plan.args, environment: environment())) { [weak self] exit in
                    Task { await self?.finish(owned, exit) }
                }
            } catch {
                let code = (error as? SpawnError)?.code ?? "process error"
                owned.exited = true
                removeCredentials(credentials.directory)
                throw BlackTeamError("Could not start llama-server (\(code)).")
            }
            owned.process = process
            self.launch = owned

            let root = "http://127.0.0.1:\(chosenPort)"
            let deadline = ProcessInfo.processInfo.systemUptime + Double(startupTimeoutMs) / 1000
            while ProcessInfo.processInfo.systemUptime < deadline {
                try assertCurrent(generation, owned)
                do {
                    let remaining = Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)
                    let (healthData, health) = try await get(root + "/health", key: nil, timeoutMs: max(1, min(2000, remaining)))
                    if (200..<300).contains(health.statusCode), try JSONValue.parse(healthData)["status"]?.string == "ok" {
                        let (propsData, props) = try await get(root + "/props", key: newKey, timeoutMs: 2000)
                        if props.statusCode == 401 || props.statusCode == 403 { throw FatalStart(message: "Another process answered on the model port. Please start the model again.") }
                        if !(200..<300).contains(props.statusCode) { throw FatalStart(message: "The runtime could not verify its model. Choose a current llama.cpp release.") }
                        let identity = try JSONValue.parse(propsData)
                        var matching = false
                        if let path = identity["model_path"]?.string, let reported = realPath(path), let expected = realPath(config.model.file) { matching = reported == expected }
                        if !matching { throw FatalStart(message: "The runtime reported a different model. Start was cancelled.") }
                        let (_, bare) = try await get(root + "/props", key: nil, timeoutMs: 2000)
                        // /health is public; /props must enforce our launch-specific key.
                        if ![401, 403].contains(bare.statusCode) { throw FatalStart(message: "The runtime did not enforce private authentication. Choose a current llama.cpp release.") }
                        try assertCurrent(generation, owned)
                        state = .ready
                        return root + "/v1"
                    }
                } catch let fatal as FatalStart {
                    throw BlackTeamError(fatal.message)
                } catch {
                    try assertCurrent(generation, owned)
                }
                await delay(pollIntervalMs)
            }
            throw BlackTeamError("The local model did not become ready in time. Check its size, runtime libraries, and available memory.")
        } catch {
            var failure = error
            if let launch, !launch.exited {
                do { try await terminate(launch) } catch { failure = error }
            }
            if launch == nil || launch?.exited == true { removeCredentials(credentialDirectory) }
            if generation == self.generation {
                state = .error
                self.error = messageOf(failure)
                port = nil
                key = nil
            }
            if failure is CancellationError { throw BlackTeamError("Model start cancelled.") }
            throw failure
        }
    }

    /// Sleeps; returns early when the start is cancelled.
    private func delay(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }

    private func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func finish(_ launch: OwnedLaunch, _ exit: ProcessExit) {
        if launch.exited { return }
        launch.exited = true
        removeCredentials(launch.credentialDirectory)
        let how = exit.signal.map(signalName) ?? "code \(exit.code.map { String($0) } ?? "unknown")"
        launch.error = "The local model process exited (\(how))."
        if self.launch === launch {
            port = nil
            key = nil
            busy = false
            if !launch.stopped { state = .error; error = launch.error }
        }
    }

    // MARK: Stop

    private func waitForExit(_ launch: OwnedLaunch, ms: Int) async {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(ms) / 1000
        while !launch.exited && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func terminate(_ launch: OwnedLaunch) async throws {
        if launch.exited { return }
        if let running = launch.termination { return try await running.value }
        launch.stopped = true
        // A separate task, so a cancelled start can still wait out the process it is ending.
        let task = Task {
            launch.process?.send(signal: SIGTERM)
            await self.waitForExit(launch, ms: self.stopTimeoutMs)
            if !launch.exited {
                launch.process?.send(signal: SIGKILL)
                await self.waitForExit(launch, ms: self.killTimeoutMs)
            }
            if !launch.exited { throw BlackTeamError("The owned model process did not stop. Close Black Team before trying again.") }
        }
        launch.termination = task
        try await task.value
    }

    /// Stops the model, cancelling a start in progress. While a response is being written it refuses unless forced.
    public func stop(force: Bool = false) async throws {
        if busy && !force { throw BlackTeamError("Wait for the response to finish before stopping the model.") }
        if let stopping = stopTask { return try await stopping.task.value }
        generation += 1
        operationNumber += 1
        let number = operationNumber
        let pending = startTask?.task
        pending?.cancel()
        let task = Task { try await self.stopOperation(number, pending) }
        stopTask = (number, task)
        try await task.value
    }

    private func stopOperation(_ number: Int, _ pending: Task<String, Error>?) async throws {
        defer { if stopTask?.number == number { stopTask = nil } }
        do {
            if let launch { try await terminate(launch) }
            if let pending { _ = try? await pending.value }
            state = .off
            error = nil
            busy = false
            port = nil
            key = nil
            launch = nil
            externalEndpoint = nil
        } catch {
            state = .error
            self.error = messageOf(error)
            throw error
        }
    }

    public func dispose() async throws { try await stop(force: true) }
}
