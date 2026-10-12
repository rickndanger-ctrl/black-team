import Foundation
import CryptoKit

/// A switch a caller flips to stop a running tool, like a JavaScript AbortSignal.
public final class CancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var nextID = 0

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let pending = Array(handlers.values)
        handlers = [:]
        lock.unlock()
        for handler in pending { handler() }
    }

    /// Calls `handler` when the signal is cancelled (not if it already was). Returns a function that stops listening.
    public func observe(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock()
        if cancelled { lock.unlock(); return {} }
        let id = nextID
        nextID += 1
        handlers[id] = handler
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.handlers[id] = nil; self.lock.unlock()
        }
    }
}

/// A regular expression written for JavaScript, tested the way `RegExp.test` is.
public struct JSPattern: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = false) {
        // ICU's `$` also matches before a final newline; `\z` is JavaScript's `$`.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
    public func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil
    }
}

/// A failure shown to the model. `missing` marks a file that does not exist, which gets the standard hint.
struct ToolFailure: Error {
    let message: String
    var missing = false
}
func fail(_ message: String) -> ToolFailure { ToolFailure(message: message) }
func posixFailure(_ code: Int32) -> ToolFailure {
    let names: [Int32: String] = [ENOENT: "ENOENT", EISDIR: "EISDIR", ENOTDIR: "ENOTDIR", EACCES: "EACCES", EEXIST: "EEXIST", EPERM: "EPERM", ENOTEMPTY: "ENOTEMPTY"]
    return ToolFailure(message: "\(names[code] ?? "errno \(code)"): \(String(cString: strerror(code)))", missing: code == ENOENT)
}
func isMissing(_ error: Error) -> Bool {
    if let failure = error as? ToolFailure { return failure.missing }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
    if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) { return true }
    if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain, under.code == Int(ENOENT) { return true }
    return false
}

struct FileStat {
    var isFile: Bool
    var isDirectory: Bool
    var size: Int64
    var mode: Int
    var mtimeMs: Double
}

private func fileInfo() -> stat { stat() }
private func followedStat(_ path: String, _ info: inout stat) -> Int32 { stat(path, &info) }
private func plainStat(_ path: String, _ info: inout stat) -> Int32 { lstat(path, &info) }

/// Path helpers with Node's `path` semantics (paths are absolute and use "/").
enum PathUtil {
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }
    static func resolve(_ base: String, _ input: String) -> String {
        input.hasPrefix("/") ? normalize(input) : normalize(base + "/" + input)
    }
    static func join(_ a: String, _ b: String) -> String { normalize(a + "/" + b) }
    static func dirname(_ path: String) -> String {
        let parts = normalize(path).split(separator: "/")
        return "/" + parts.dropLast().joined(separator: "/")
    }
    static func basename(_ path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? ""
    }
    static func relative(_ from: String, _ to: String) -> String {
        let a = normalize(from).split(separator: "/"), b = normalize(to).split(separator: "/")
        var common = 0
        while common < a.count && common < b.count && a[common] == b[common] { common += 1 }
        let ups = Array(repeating: "..", count: a.count - common)
        return (ups + b[common...].map(String.init)).joined(separator: "/")
    }
    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func stat(_ path: String, follow: Bool = true) -> FileStat? {
        var info = fileInfo()
        let status = follow ? followedStat(path, &info) : plainStat(path, &info)
        guard status == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        let mtime = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        return FileStat(isFile: kind == S_IFREG, isDirectory: kind == S_IFDIR, size: Int64(info.st_size), mode: Int(info.st_mode & 0o777), mtimeMs: mtime)
    }
    static func statThrowing(_ path: String) throws -> FileStat {
        guard let info = stat(path) else { throw posixFailure(errno) }
        return info
    }
    static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    static func readData(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw posixFailure(errno) }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw posixFailure(errno) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    static func readText(_ path: String) throws -> String { String(decoding: try readData(path), as: UTF8.self) }

    /// Writes with the given mode (the umask still applies, as in Node).
    static func writeData(_ path: String, _ data: Data, mode: Int, truncate: Bool = true) throws {
        let fd = open(path, O_WRONLY | O_CREAT | (truncate ? O_TRUNC : 0), mode_t(mode))
        guard fd >= 0 else { throw posixFailure(errno) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { if errno == EINTR { continue }; throw posixFailure(errno) }
                offset += written
            }
        }
    }
    static func splitLines(_ text: String) -> [String] {
        text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// JavaScript strings count UTF-16 units; slices here never cut a surrogate pair in two.
enum JSString {
    static func prefix(_ text: String, _ count: Int) -> String {
        let units = Array(text.utf16)
        if count >= units.count { return text }
        var end = max(0, count)
        if end > 0 && UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[0..<end], as: UTF16.self)
    }
    static func length(_ text: String) -> Int { text.utf16.count }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
func randomHex(_ bytes: Int) -> String { (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

func currentEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }

/// Looks a program up on PATH (no `which`). A name with a slash is used as it is.
func lookUpProgram(_ name: String, path: String? = nil) -> String? {
    func usable(_ file: String) -> Bool {
        guard let info = PathUtil.stat(file), info.isFile else { return false }
        return access(file, X_OK) == 0
    }
    if name.contains("/") { return usable(name) ? name : nil }
    let search = path ?? getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
    for folder in search.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = "\(folder)/\(name)"
        if usable(candidate) { return candidate }
    }
    return nil
}

/// Runs one program in its own process group, collects its output and can kill the whole group.
final class ExecJob: @unchecked Sendable {
    struct Outcome {
        var code: Int32?
        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        var combined: [UInt8] = []
        var timedOut = false
        var overflow = false
        var spawnError: Int32?
    }

    private let executable: String, arguments: [String], cwd: String?, env: [String: String]
    private let seconds: Double, combinedCap: Int, streamCap: Int
    private let signal: CancelSignal?
    private let lock = NSLock()
    private var outcome = Outcome()
    private var finished = false, exited = false, stopRequested = false
    private var exitCode: Int32?
    private var openReaders = 2
    private var pid: pid_t = 0
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timer: DispatchWorkItem?
    private var stopListening: (@Sendable () -> Void)?

    init(executable: String, arguments: [String], cwd: String?, env: [String: String], seconds: Double, combinedCap: Int = 2 * 1024 * 1024, streamCap: Int = Int.max, signal: CancelSignal? = nil) {
        self.executable = executable; self.arguments = arguments; self.cwd = cwd; self.env = env
        self.seconds = seconds; self.combinedCap = combinedCap; self.streamCap = streamCap; self.signal = signal
    }

    func run() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (next: CheckedContinuation<Outcome, Never>) in start(next) }
        } onCancel: { [self] in stop() }
    }

    private func start(_ next: CheckedContinuation<Outcome, Never>) {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { outcome.spawnError = errno; outcome.code = 127; next.resume(returning: outcome); return }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        // A group of its own, so one signal reaches the command and everything it started.
        // The app may block or ignore signals; the command starts with the defaults, so SIGTERM stops it.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for number in Int32(1)..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults, number) }
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for item in argv { free(item) }; for item in envp { free(item) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(outPipe[1]); close(errPipe[1])
        if status != 0 {
            close(outPipe[0]); close(errPipe[0])
            outcome.spawnError = status
            outcome.code = 127
            let reason = status == ENOENT ? "ENOENT" : String(cString: strerror(status))
            outcome.combined = Array("spawn \(executable) \(reason)".utf8)
            next.resume(returning: outcome)
            return
        }
        lock.lock()
        continuation = next
        pid = child
        let pendingStop = stopRequested
        lock.unlock()
        let work = DispatchWorkItem { [self] in
            lock.lock(); outcome.timedOut = true; lock.unlock()
            stop()
        }
        lock.lock(); timer = work; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        let removal = signal?.observe { [self] in stop() }
        lock.lock(); stopListening = removal; lock.unlock()
        Thread.detachNewThread { [self] in read(outPipe[0], into: 0) }
        Thread.detachNewThread { [self] in read(errPipe[0], into: 1) }
        Thread.detachNewThread { [self] in await_(child) }
        if pendingStop { stop() }
    }

    private func read(_ fd: Int32, into stream: Int) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            lock.lock(); let done = finished; lock.unlock()
            if done { break }
            let ready = poll(&poller, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
            if count == 0 { break }
            append(Array(buffer[0..<count]), stream: stream)
        }
        close(fd)
        lock.lock()
        openReaders -= 1
        let complete = openReaders == 0 && exited
        lock.unlock()
        if complete { finish() }
    }

    private func append(_ chunk: [UInt8], stream: Int) {
        lock.lock()
        if finished { lock.unlock(); return }
        if outcome.combined.count < combinedCap { outcome.combined.append(contentsOf: chunk) }
        let current = stream == 0 ? outcome.stdout.count : outcome.stderr.count
        var exceeded = false
        if current + chunk.count > streamCap {
            exceeded = true
            outcome.overflow = true
            let room = max(0, streamCap - current)
            if stream == 0 { outcome.stdout.append(contentsOf: chunk.prefix(room)) } else { outcome.stderr.append(contentsOf: chunk.prefix(room)) }
        } else if stream == 0 { outcome.stdout.append(contentsOf: chunk) } else { outcome.stderr.append(contentsOf: chunk) }
        lock.unlock()
        if exceeded { stop() }
    }

    private func await_(_ child: pid_t) {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        // Killed by a signal gives no exit code, which reads as 1 below, as in Node.
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        lock.lock()
        exited = true
        exitCode = code
        let complete = openReaders == 0
        lock.unlock()
        if complete { finish() } else {
            // A command that leaves a background process holding the output open never closes; its own exit is enough.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in finish() }
        }
    }

    private func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        timer?.cancel()
        let removal = stopListening
        var result = outcome
        result.code = exitCode ?? 1
        let next = continuation
        continuation = nil
        lock.unlock()
        removal?()
        next?.resume(returning: result)
    }

    func stop() {
        lock.lock()
        if pid == 0 { stopRequested = true; lock.unlock(); return }
        let done = finished
        let group = pid
        lock.unlock()
        if done { return }
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(-group, SIGKILL) }
    }
}

struct CaptureResult {
    var status: Int32?
    var stdout: String
    var stderr: String
    var missing: Bool
    var failed: Bool
}

/// Like Node's execFile: a program run without a shell, output captured, bounded in time and size.
func capture(_ program: String, _ args: [String], cwd: String? = nil, timeout: Double, maxBuffer: Int) async -> CaptureResult {
    guard let executable = lookUpProgram(program) else { return CaptureResult(status: nil, stdout: "", stderr: "", missing: true, failed: true) }
    let job = ExecJob(executable: executable, arguments: args, cwd: cwd, env: currentEnvironment(), seconds: timeout, streamCap: maxBuffer)
    let result = await job.run()
    if result.spawnError == ENOENT { return CaptureResult(status: nil, stdout: "", stderr: "", missing: true, failed: true) }
    let killed = result.timedOut || result.overflow
    let failed = result.spawnError != nil || killed || result.code != 0
    return CaptureResult(status: killed ? nil : result.code, stdout: String(decoding: result.stdout, as: UTF8.self), stderr: String(decoding: result.stderr, as: UTF8.self), missing: false, failed: failed)
}
