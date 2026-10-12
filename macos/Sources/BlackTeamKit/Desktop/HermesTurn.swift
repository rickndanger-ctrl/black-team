import Foundation

// One running Hermes turn: the process, the events it prints, the approvals it is answered with, and when it counts as done
// (lib/agent.cjs's `new Promise`). The process gets a group of its own, so Stop reaches everything it started. Stderr is not
// kept: it can hold tool credentials or prompt text, as the JavaScript said.

final class HermesTurn: @unchecked Sendable {
    /// The turn is stopped after this long (1850000 ms in lib/agent.cjs); the model can take minutes before its first token.
    static let timeoutSeconds: Double = 1850
    /// After a stop the process gets this long to exit on SIGINT before SIGKILL.
    static let killAfterSeconds: Double = 8
    /// A line of runner output is kept up to this many bytes of unfinished text; more than this stops the turn.
    static let pendingLimit = 2 * 1024 * 1024
    static let contentLimit = 256 * 1024
    static let eventLimit = 100
    static let artifactLimit = 100
    static let startFailure = "Hermes could not start. Check its Python environment and source directory."
    static let stoppedMessage = "Agent stopped. Send another message to continue."
    static let didNotComplete = "Hermes did not complete this turn. Check the compatible Hermes installation and local model tool support."

    private let lock = NSLock()
    private let thread: ThreadRef
    private let job: JobState
    private let save: @Sendable (JSONValue) throws -> Void
    private let artifacts: String
    /// The key to hide from everything shown, when the model was asked with one (lib/agent.cjs redacts only then).
    private let secret: String?

    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var stopped = false
    private var settled = false
    private var stdoutOpen = true
    private var exited = false
    /// The exit status, or nil when a signal ended the process (as `code` was null in Node).
    private var exitStatus: Int32?
    /// The last `result` event: the turn's outcome.
    private var result: JSONValue?
    private var lastSave: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var unobserve: (@Sendable () -> Void)?

    init(thread: ThreadRef, job: JobState, save: @escaping @Sendable (JSONValue) throws -> Void, artifacts: String, secret: String?) {
        self.thread = thread; self.job = job; self.save = save; self.artifacts = artifacts; self.secret = secret
    }

    /// Starts the runner and returns when it has finished, or throws the message the person should see.
    func run(python: String, arguments: [String], workspace: String, environment: [String: String], cancel: CancelSignal) async throws {
        if cancel.isCancelled { throw CancellationError() }
        // A runner that has gone must not end the service with SIGPIPE; the write fails instead.
        signal(SIGPIPE, SIG_IGN)
        let child = try HermesTurn.spawn(python, arguments, workspace: workspace, environment: environment)
        try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = next; pid = child.pid; input = child.input
            lock.unlock()
            let stopper = cancel.observe { [self] in stop() }
            lock.lock(); unobserve = stopper; lock.unlock()
            if cancel.isCancelled { stop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + HermesTurn.timeoutSeconds) { [self] in stop() }
            Thread.detachNewThread { [self] in readOutput(child.output) }
            Thread.detachNewThread { [self] in waitForExit(child.pid) }
        }
    }

    // MARK: Stop

    /// Stops the turn: SIGINT to the whole group, SIGKILL after a while if it has not settled. Clears a waiting approval.
    private func stop() {
        lock.lock()
        if stopped || settled { lock.unlock(); return }
        stopped = true
        let group = pid
        lock.unlock()
        job.progress = "Stopping agent\u{2026}"
        job.change { $0.approval = nil }
        killpg(group, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + HermesTurn.killAfterSeconds) { [self] in
            lock.lock(); let done = settled; lock.unlock()
            if !done { killpg(group, SIGKILL) }
        }
    }

    // MARK: Output

    /// Reads standard output line by line until it ends, handing each complete line to the event handler.
    private func readOutput(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var pending: [UInt8] = []
        while true {
            let count = cRead(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 10) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                handle(line)
            }
            if pending.count > HermesTurn.pendingLimit { stop() }
        }
        close(fd)
        lock.lock(); stdoutOpen = false; let ready = exited; lock.unlock()
        if ready { closed() }
    }

    private func handle(_ line: [UInt8]) {
        // A line that is not JSON is ignored, as the JavaScript's try/catch did.
        guard let value = try? JSONValue.parse(Data(line)), !value.isNull else { return }
        var saveDue = true
        if let object = value.object { saveDue = self.event(object) }
        guard saveDue else { return }
        let now = nowMillis()
        lock.lock(); let due = now - lastSave > 700; lock.unlock()
        if due {
            do { try save(thread.value); lock.lock(); lastSave = now; lock.unlock() } catch { /* A save that fails is tried again at the next event. */ }
        }
    }

    private func waitForExit(_ child: pid_t) {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        // A process killed by a signal has no exit code.
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        lock.lock(); exited = true; exitStatus = code; let ready = !stdoutOpen; lock.unlock()
        if ready { closed() }
    }

    /// Handles one event. Returns false when the event must not trigger a save (as lib/agent.cjs skipped its save after a
    /// companion_artifact whose file was missing).
    private func event(_ e: [String: JSONValue]) -> Bool {
        let type = e["type"]?.string ?? ""
        if type == "system", let session = e["session_id"]?.string {
            thread.value = thread.value.setting("hermesSession", .string(session))
        }
        if type == "text", let text = e["text"]?.string {
            thread.updateLast { last in last["content"] = .string(clip((last["content"]?.string ?? "") + text, HermesTurn.contentLimit)) }
        }
        if type == "camp_status" {
            job.progress = clip(redact(jsText(e["message"])), 500)
        }
        if type == "tool_use" || type == "tool_result" {
            let name = redact(jsTruthy(e["name"]) ? jsText(e["name"]) : "Tool")
            // JSON.stringify(e.output ?? e.input ?? ''): the first of the two that is not missing or null, else ''.
            let shown = [e["output"], e["input"]].compactMap { $0 }.first { !$0.isNull } ?? .string("")
            let output = redact(shown.text())
            let entry: JSONValue = .object(["type": .string(type), "name": .string(name), "output": .string(output)])
            thread.updateLast { last in
                var list = last["events"]?.array ?? []
                list.append(entry)
                if list.count > HermesTurn.eventLimit { list.removeFirst(list.count - HermesTurn.eventLimit) }
                last["events"] = .array(list)
            }
            job.progress = "\(type == "tool_use" ? "Using" : "Finished") \(redact(jsTruthy(e["name"]) ? jsText(e["name"]) : "tool"))"
        }
        if type == "companion_approval", let id = e["id"]?.string, let digest = e["digest"]?.string, let expires = e["expires"]?.double, expires.isFinite {
            let approval = PendingApproval(id: id, digest: digest, command: redact(jsText(e["command"])),
                                           description: redact(jsText(e["description"])), expires: Int64(min(max(expires, -9e15), 9e15)))
            job.present(approval, answer: { [self] answer in try self.approve(answer) })
        }
        if type == "companion_approval_closed", let id = e["id"]?.string, job.approval?.id == id {
            job.change { $0.approval = nil }
        }
        if type == "companion_artifact", let id = e["id"]?.string, isArtifactID(id) {
            var info = stat()
            // The file must be a regular file the runner wrote, not a link; otherwise the event is dropped.
            guard lstat(artifacts + "/" + id, &info) == 0 else { return false }
            let count = thread.value["messages"]?.array?.last?["artifacts"]?.array?.count ?? 0
            if (info.st_mode & S_IFMT) == S_IFREG && count < HermesTurn.artifactLimit {
                let item: JSONValue = .object(["id": .string(id), "name": .string((jsText(e["name"]) as NSString).lastPathComponent),
                                               "size": .number(Double(info.st_size))])
                thread.updateLast { last in last["artifacts"] = .array((last["artifacts"]?.array ?? []) + [item]) }
            }
        }
        if type == "result" {
            lock.lock(); result = .object(e); lock.unlock()
            if let session = e["session_id"]?.string { thread.value = thread.value.setting("hermesSession", .string(session)) }
            if let text = e["text"]?.string {
                thread.updateLast { last in last["content"] = .string(clip(text, HermesTurn.contentLimit)) }
            }
        }
        return true
    }

    /// Answers the approval waiting now, as `job._approve` did: it must be the same id and digest, unexpired, and once or deny.
    private func approve(_ answer: ApprovalAnswer) throws {
        guard let waiting = job.approval, waiting.id == answer.id, waiting.digest == answer.digest,
              waiting.expires >= nowMillis(), ["once", "deny"].contains(answer.choice) else {
            throw BlackTeamError("No matching active approval.")
        }
        lock.lock(); let fd = input; lock.unlock()
        guard fd >= 0 else { throw BlackTeamError("Agent input is closed.") }
        let line = JSONValue.object(["id": .string(answer.id), "digest": .string(answer.digest), "choice": .string(answer.choice)]).text() + "\n"
        guard HermesTurn.writeAll(line, to: fd) else { throw BlackTeamError("Agent input is closed.") }
        job.change { $0.approval = nil }
        job.progress = "Agent continuing\u{2026}"
    }

    private func redact(_ value: String) -> String {
        clip(secret.map { value.replacingOccurrences(of: $0, with: "[redacted]") } ?? value, 8000)
    }

    private func isArtifactID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    // MARK: Ending

    /// Runs once both standard output and the process have ended, as Node's 'close' event: a turn that was stopped, that exited
    /// with a code, or that sent no result (or a result with a failed exit code) fails.
    private func closed() {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let code = exitStatus, wasStopped = stopped, final = result
        let done = continuation, ending = unobserve
        continuation = nil; unobserve = nil
        let fd = input
        input = -1
        lock.unlock()
        ending?()
        if fd >= 0 { close(fd) }
        job.withdraw()
        let failed = wasStopped || (code ?? 0) != 0 || final == nil || jsTruthy(final?["exit_code"])
        if failed {
            done?.resume(throwing: BlackTeamError(wasStopped ? HermesTurn.stoppedMessage : HermesTurn.didNotComplete))
        } else {
            done?.resume()
        }
    }

    // MARK: Process

    private static func writeAll(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 { if errno == EINTR { continue }; return false }
            offset += written
        }
        return true
    }

    /// Starts the runner with its own process group, a pipe for standard input and output, and standard error discarded.
    /// The runner starts with the default signal set, so SIGINT stops it even when the app ignores or blocks signals.
    private static func spawn(_ path: String, _ arguments: [String], workspace: String, environment: [String: String])
        throws -> (pid: pid_t, input: Int32, output: Int32) {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0 else { throw BlackTeamError(startFailure) }
        guard pipe(&fromChild) == 0 else { close(toChild[0]); close(toChild[1]); throw BlackTeamError(startFailure) }
        for fd in toChild + fromChild { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, workspace)
        #if os(Linux)
        var attributes = posix_spawnattr_t()
        #else
        var attributes: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attributes)
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for number in Int32(1)..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults, number) }
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for item in argv { free(item) }; for item in envp { free(item) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(toChild[0]); close(fromChild[1])
        guard status == 0 else {
            close(toChild[1]); close(fromChild[0])
            throw BlackTeamError(startFailure)
        }
        return (child, toChild[1], fromChild[0])
    }
}
