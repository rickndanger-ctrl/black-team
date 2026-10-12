import Foundation

/// What to start: the tool's program, its arguments, its folder and its environment.
public struct AgentCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workspace: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workspace: String, environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.workspace = workspace; self.environment = environment
    }
}

public enum AgentStream: Sendable { case stdout, stderr }

/// How a run ended. `status` is nil when the tool was killed by a signal.
public struct AgentExit: Equatable, Sendable {
    public var status: Int32?
    public var timedOut = false
    public var cancelled = false
    public var spawnError: String?

    public init(status: Int32?, timedOut: Bool = false, cancelled: Bool = false, spawnError: String? = nil) {
        self.status = status; self.timedOut = timedOut; self.cancelled = cancelled; self.spawnError = spawnError
    }
}

/// Finds and starts a subscription agent's command. The app uses `ProcessAgentLauncher`; tests feed recorded lines instead.
public protocol AgentLauncher: Sendable {
    /// The tool's program on this Mac, or nil when it is not installed.
    func executable(for service: AgentService) -> String?

    /// Runs the command until it exits, `timeout` passes, or `signal` is cancelled. `onLine` is called for each line, in order per stream,
    /// from a background thread.
    func run(_ command: AgentCommand, timeout: TimeInterval, signal: CancelSignal,
             onLine: @escaping @Sendable (AgentStream, String) -> Void) async -> AgentExit
}

/// The real launcher. It uses posix_spawn (Foundation's Process cannot put the child in a group of its own) so the tool and
/// everything it starts share one process group, and Stop or the time limit signals the whole group.
public struct ProcessAgentLauncher: AgentLauncher {
    /// Lines longer than this are cut, so a tool that never ends a line cannot fill the memory.
    static let lineLimit = 1024 * 1024
    /// How long a stopped run gets to exit after SIGTERM before SIGKILL.
    static let graceSeconds: Double = 3

    public init() {}

    public func executable(for service: AgentService) -> String? { AgentTools.locate(service.program) }

    public func run(_ command: AgentCommand, timeout: TimeInterval, signal: CancelSignal,
                    onLine: @escaping @Sendable (AgentStream, String) -> Void) async -> AgentExit {
        let run = AgentProcessRun(command: command, timeout: timeout, signal: signal, onLine: onLine)
        return await run.start()
    }
}

/// One spawned tool: its pipes, its group, and the timers that stop it.
private final class AgentProcessRun: @unchecked Sendable {
    private let command: AgentCommand
    private let timeout: TimeInterval
    private let signal: CancelSignal
    private let onLine: @Sendable (AgentStream, String) -> Void
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var signalSent = false      // SIGTERM has gone to the group
    private var timedOut = false
    private var hasExited = false
    private var exitStatus: Int32?
    private var readersOpen = 2
    private var continuation: CheckedContinuation<AgentExit, Never>?

    init(command: AgentCommand, timeout: TimeInterval, signal: CancelSignal, onLine: @escaping @Sendable (AgentStream, String) -> Void) {
        self.command = command; self.timeout = timeout; self.signal = signal; self.onLine = onLine
    }

    func start() async -> AgentExit {
        await withCheckedContinuation { (next: CheckedContinuation<AgentExit, Never>) in
            lock.lock(); continuation = next; lock.unlock()
            spawn()
        }
    }

    private func spawnFailed(_ message: String) {
        lock.lock(); let next = continuation; continuation = nil; lock.unlock()
        next?.resume(returning: AgentExit(status: 127, spawnError: message))
    }

    private func spawn() {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return spawnFailed("The tool could not start (pipe).") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return spawnFailed("The tool could not start (pipe).")
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, command.workspace)
        #if os(Linux)
        var attributes = posix_spawnattr_t()
        #else
        var attributes: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attributes)
        // The tool starts with the default signal set, so SIGTERM stops it even when the app ignores or blocks signals.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for number in Int32(1)..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults, number) }
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv: [UnsafeMutablePointer<CChar>?] = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for item in argv { free(item) }; for item in envp { free(item) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, command.executable, &actions, &attributes, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(outPipe[1]); close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            spawnFailed("The tool could not start (\(String(cString: strerror(status)))). Check that it is installed.")
            return
        }
        lock.lock()
        pid = child
        lock.unlock()
        // Stop when the person asks, and when the time limit passes.
        _ = signal.observe { [self] in stop(byTimeLimit: false) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in stop(byTimeLimit: true) }
        Thread.detachNewThread { [self] in readLines(outPipe[0], .stdout) }
        Thread.detachNewThread { [self] in readLines(errPipe[0], .stderr) }
        Thread.detachNewThread { [self] in waitForExit(child) }
        // A Stop that came before the tool started is delivered now.
        if signal.isCancelled { stop(byTimeLimit: false) }
    }

    /// Signals the whole group: SIGTERM, then SIGKILL if it is still there after the grace period.
    private func stop(byTimeLimit: Bool) {
        lock.lock()
        if byTimeLimit { timedOut = true }
        if hasExited { lock.unlock(); return }
        // Before the tool has started, spawn checks the cancel signal again and stops it then.
        if pid == 0 { lock.unlock(); return }
        if signalSent { lock.unlock(); return }
        signalSent = true
        let group = pid
        lock.unlock()
        killpg(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessAgentLauncher.graceSeconds) { [self] in
            lock.lock(); let gone = hasExited; lock.unlock()
            if !gone { killpg(group, SIGKILL) }
        }
    }

    private func readLines(_ fd: Int32, _ stream: AgentStream) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var pending: [UInt8] = []
        while true {
            let count = cRead(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { break }
            for byte in buffer[0..<count] {
                if byte == 10 { emit(&pending, stream); continue }
                pending.append(byte)
                if pending.count >= ProcessAgentLauncher.lineLimit { emit(&pending, stream) }
            }
        }
        if !pending.isEmpty { emit(&pending, stream) }
        close(fd)
        lock.lock()
        readersOpen -= 1
        let complete = readersOpen == 0 && hasExited
        lock.unlock()
        if complete { finish() }
    }

    private func emit(_ pending: inout [UInt8], _ stream: AgentStream) {
        var bytes = pending
        pending.removeAll(keepingCapacity: true)
        if bytes.last == 13 { bytes.removeLast() }
        onLine(stream, String(decoding: bytes, as: UTF8.self))
    }

    private func waitForExit(_ child: pid_t) {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        // Killed by a signal gives no exit code.
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        lock.lock()
        hasExited = true
        exitStatus = code
        let complete = readersOpen == 0
        lock.unlock()
        if complete { finish() } else {
            // A child of the tool can keep a pipe open after the tool exits. Do not wait for it forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in finish() }
        }
    }

    private func finish() {
        lock.lock()
        guard let next = continuation else { lock.unlock(); return }
        continuation = nil
        let result = AgentExit(status: exitStatus, timedOut: timedOut, cancelled: signal.isCancelled && !timedOut)
        lock.unlock()
        next.resume(returning: result)
    }
}
