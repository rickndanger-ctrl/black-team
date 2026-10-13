import Foundation

/// What the person is told when a subscription-agent conversation is sent through another path.
func agentConversationRefusal(_ agent: AgentService) -> String {
    "This conversation uses \(agent.displayName). Continue it with \(agent.displayName), or start a new conversation."
}

/// Writes one run's reply into the conversation as the tool's output arrives, saving about every 0.75 seconds as Chat does.
/// Lines from the tool's standard output arrive one at a time on one thread, and the lock keeps that order.
private final class AgentRunWriter: @unchecked Sendable {
    private let lock = NSLock()
    let turn: AgentTurn
    private let ref: ThreadRef
    private let job: JobState
    private let stopTool: CancelSignal
    private let save: @Sendable (JSONValue) -> Void
    private var lastSave = Date.distantPast

    init(turn: AgentTurn, ref: ThreadRef, job: JobState, stopTool: CancelSignal, save: @escaping @Sendable (JSONValue) -> Void) {
        self.turn = turn; self.ref = ref; self.job = job; self.stopTool = stopTool; self.save = save
    }

    func line(_ stream: AgentStream, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        turn.ingest(stream, text)
        if stream == .stderr { return }
        if let session = turn.takeSessionChange() { ref.value = ref.value.setting("agentSession", .string(session)) }
        let fields = turn.fields
        ref.updateLast { $0["content"] = .string(fields.content); $0["events"] = .array(fields.events) }
        if case .object(let last)? = fields.events.last, last["type"]?.string == "tool_use" {
            job.progress = "Using \(last["name"]?.string ?? "a tool")\u{2026}"
        } else {
            job.progress = "Writing a reply\u{2026}"
        }
        // Past the reply limit the tool is stopped; the run ends with the storage-limit message.
        if turn.overflowed { stopTool.cancel() }
        if Date().timeIntervalSince(lastSave) > 0.75 { lastSave = Date(); save(ref.value) }
    }
}

extension Backend {
    /// Whether the tool is on this Mac (for the model menu, which offers only the tools it finds).
    public func agentInstalled(_ service: AgentService) -> Bool { agentLauncher.executable(for: service) != nil }

    /// Hands one message to Claude Code or Codex, running in the conversation's folder under the person's own subscription login.
    /// Returns at once; the run goes on in the background, as `submit` does. The gate (`authorizeAgentRun`) is checked first,
    /// every time, and only the agent's task text (or the new message, when resuming the tool's own session) is handed over.
    @discardableResult
    public func submitAgentTask(service: AgentService, message rawMessage: String, requestId: String, threadId givenThread: String? = nil,
                                project givenProject: String? = nil, workspace workspaceOverride: String? = nil,
                                permission: AgentPermission? = nil, from origin: SubmitOrigin = .mac) throws -> SubmitResult {
        if locked({ closing }) { throw BlackTeamError("Black Team is closing.") }
        let message = EText.trim(rawMessage)
        if message.isEmpty || EText.length(message) > 16000 { throw BlackTeamError("Enter a message of up to 16,000 characters.") }
        if !History.validID(requestId) { throw BlackTeamError("A valid request ID is required.") }
        let threadId = givenThread.flatMap { $0.isEmpty ? nil : $0 }
        if let threadId, !History.validID(threadId) { throw BlackTeamError("Invalid conversation ID.") }
        if let givenProject, !History.validID(givenProject) { throw BlackTeamError("Invalid project.") }
        let parts: [JSONValue] = [threadId.map { .string($0) } ?? .null, .string(message), .string(service.engine),
                                  givenProject.map { .string($0) } ?? .null, workspaceOverride.map { .string($0) } ?? .null]
            + (permission.map { [JSONValue.string($0.rawValue)] } ?? [])
        let hash = SHA256.hash(data: Data(JSONValue.array(parts).text().utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = history.request(requestId) {
            if saved["hash"]?.string != hash { throw BlackTeamError("Request ID was already used for another message.") }
            return SubmitResult(id: saved["id"]?.string ?? requestId, threadId: saved["threadId"]?.string ?? "", state: saved["state"]?.string ?? "")
        }

        lock.lock(); defer { lock.unlock() }
        if active != nil { throw BlackTeamError("A response is already running. Wait or stop it before sending another.") }
        let config = try configStore.read()
        let existing = threadId.flatMap { history.get($0) }
        if threadId != nil && existing == nil { throw BlackTeamError("Conversation not found.") }
        if let existing {
            if let other = AgentService.forEngine(existing["engine"]?.string), other != service {
                throw BlackTeamError(agentConversationRefusal(other))
            }
            guard (existing["kind"]?.string ?? "chat") == "agent", existing["engine"]?.string == service.engine else {
                throw BlackTeamError("Start a new conversation to use \(service.displayName) here.")
            }
        }
        let wanted = existing != nil ? existing?["project"]?.string : givenProject
        let project = projects.first { $0.id == wanted }
        if existing == nil, givenProject != nil, project == nil { throw BlackTeamError("That project no longer exists.") }
        // THE GATE. Nothing is started, resumed or saved unless it allows this run.
        let grant = try authorizeAgentRun(service: service, existing: existing, project: project, viaPhone: origin == .phone)
        guard agentLauncher.executable(for: service) != nil else {
            throw BlackTeamError("\(service.displayName) is not installed on \(Place.this). Install it, then sign in with your subscription.")
        }
        // The version check runs in the background, never delaying the run; its answer is kept for the model menu.
        Task.detached { [self] in _ = await self.agentUpdateStatus(service: service) }
        let workspace = try workspaceOverride.map { try ensureWorkspace($0) } ?? project?.workspace ?? config.workspace
        // A new session is told the conversation so far (only its text, through agentTaskText); a resumed one gets the new message.
        let session = existing?["agentSession"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let task = session == nil ? agentTaskText(thread: existing ?? [:], newMessage: message) : message

        var thread = existing ?? history.create(message)
        thread = thread.setting("kind", .string("agent")).setting("engine", .string(service.engine))
        // The level is the conversation's and can change between messages; a message without one keeps the saved level.
        let level = permission ?? AgentPermission.of(thread: existing)
        if let permission { thread = thread.setting("agentPermission", .string(permission.rawValue)) }
        if existing == nil {
            thread = thread.setting("privacy", .string(grant.privacy)).setting("provider", .string(grant.provider))
            if let project { thread = thread.setting("project", .string(project.id)) }
        }
        var messages = thread["messages"]?.array ?? []
        if messages.count >= 1000 || (try? JSONEncoder().encode(thread).count) ?? 0 > 5 * 1024 * 1024 {
            throw BlackTeamError("This conversation is full. Start a new conversation.")
        }
        let userMessage: JSONValue = ["id": .string(UUID().uuidString.lowercased()), "role": "user", "content": .string(message), "state": "done"]
        // The reply records its run (the request ID), the folder it ran in, and what it did, for the work log and for rollback.
        let assistant: JSONValue = ["id": .string(UUID().uuidString.lowercased()), "role": "assistant", "content": "", "state": "writing",
                                    "model": .string(service.displayName), "run": .string(requestId), "workspace": .string(workspace), "events": []]
        messages.append(userMessage)
        messages.append(assistant)
        let request: JSONValue = ["id": .string(requestId), "hash": .string(hash), "state": "running"]
        var requests = thread["requests"]?.array ?? []
        requests.append(request)
        thread = thread.setting("messages", .array(messages)).setting("requests", .array(requests)).setting("updated", .string(EText.iso(now())))
        try history.save(thread)
        history.remember(&thread, request)

        let current = JobState(id: requestId, threadId: thread["id"]?.string, kind: "agent", state: "running",
                               progress: "Starting \(service.displayName)\u{2026}")
        _ = current.observe { [hub] _ in hub.notify() }
        let signal = CancelSignal()
        let ref = ThreadRef(thread)
        job = current; abort = signal; liveThread = ref
        active = Task { [self] in
            await runAgentJob(job: current, signal: signal, ref: ref, request: request, service: service, task: task, session: session,
                              workspace: workspace, permission: level)
        }
        hub.notify()
        return SubmitResult(id: requestId, threadId: thread["id"]?.string ?? "", state: "running")
    }

    /// Runs one agent turn: the snapshot first, then the tool, writing its reply as it goes, then the terminal state.
    private func runAgentJob(job: JobState, signal: CancelSignal, ref: ThreadRef, request: JSONValue, service: AgentService, task: String,
                             session: String?, workspace: String, permission: AgentPermission) async {
        let runId = request["id"]?.string ?? ""
        let threadId = ref.value["id"]?.string ?? ""
        // Before anything changes, a copy of the folder. A folder that cannot be copied still runs; its message says so.
        var rollbackNote: String?
        var rollbackReady = false
        job.progress = "Saving a copy of the project for rollback\u{2026}"
        do {
            switch try snapshots.take(threadId: threadId, runId: runId, workspace: workspace) {
            case .saved: rollbackReady = true
            case .skipped(let why): rollbackNote = why
            }
        } catch {
            rollbackNote = "This task was not saved for rollback: \(messageOf(error))"
        }
        ref.updateLast { message in
            if rollbackReady { message["rollback"] = .bool(true) }
            if let rollbackNote { message["rollbackNote"] = .string(rollbackNote) }
        }

        let turn = AgentTurn(service: service)
        // The tool's own stop: the person's Stop, or the reply reaching its limit.
        let stopTool = CancelSignal()
        // `observe` does not call back for a signal that is already cancelled, so a Stop pressed before this point is passed on here.
        // Without this the tool's own stop signal was never cancelled and the run (and anything waiting for it) never ended.
        _ = signal.observe { stopTool.cancel() }
        if signal.isCancelled { stopTool.cancel() }
        let writer = AgentRunWriter(turn: turn, ref: ref, job: job, stopTool: stopTool) { [weak self] thread in try? self?.persist(thread) }
        // Ask for Claude Code runs the tool again after each round of answers; every other level runs it once.
        var exit = AgentExit(status: nil)
        var notDone: [(reason: String, label: String)] = []
        var allowed: [String] = [], resumes = 0
        var currentTask = task, currentSession = session
        var leftover: [AgentDenial] = []
        while true {
            // Stop came before the tool launched: it is never started.
            if signal.isCancelled { exit = AgentExit(status: nil, cancelled: true); break }
            turn.startRound()
            let arguments = AgentTools.arguments(service: service, task: currentTask, session: currentSession, workspace: workspace,
                                                 permission: permission, allowedTools: allowed)
            let command = AgentCommand(executable: agentLauncher.executable(for: service) ?? service.program, arguments: arguments,
                                       workspace: workspace, environment: AgentTools.environment())
            exit = await agentLauncher.run(command, timeout: AgentTools.timeout, signal: stopTool) { stream, text in
                writer.line(stream, text)
            }
            leftover = turn.denials
            let finished = !signal.isCancelled && !exit.timedOut && !turn.overflowed && turn.failureMessage == nil && exit.spawnError == nil
                && exit.status == 0 && !turn.signedOut
            guard service == .claudeCode, permission == .ask, finished, !leftover.isEmpty else { break }
            if resumes >= AgentAsk.maxRounds { break }
            var rules: [String] = []
            for denial in leftover where !signal.isCancelled {
                switch AgentAsk.decide(denial, workspace: workspace) {
                case .refuse(let reason, let label):
                    notDone.append((reason, label))
                case .ask(let rule, let text, let label):
                    let why = denial.message.isEmpty ? "\(denial.tool) needs your approval." : denial.message
                    if await AgentAsk.ask(job: job, stop: signal, command: text, description: why, now: now) { rules.append(rule) }
                    else { notDone.append((AgentAsk.declined, label)) }
                }
            }
            if rules.isEmpty || signal.isCancelled { leftover = []; break }
            resumes += 1
            allowed = rules
            currentTask = AgentAsk.approvedMessage
            currentSession = ref.value["agentSession"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? currentSession
            leftover = []
            job.progress = "Continuing with what you approved\u{2026}"
        }

        // How the run ended, in the words the person sees.
        let fields = turn.fields
        var content = fields.content
        var state = "done"
        var failure: String?
        var needsSignIn = false
        var needsUpdate: String?
        if signal.isCancelled {
            state = "interrupted"; failure = "Response stopped."
        } else if exit.timedOut {
            state = "error"; failure = "The task stopped after 30 minutes."
        } else if turn.signedOut {
            state = "error"; needsSignIn = true
            failure = "\(service.displayName) is signed out. Sign in again, then send your message once more."
        } else if let sentence = turn.updateSentence {
            state = "error"; needsUpdate = service.engine
            failure = "\(service.displayName) needs updating before it can run this. Update it, then send your message once more.\n\(sentence)"
        } else if turn.overflowed {
            state = "error"; failure = "Response reached the storage limit. Ask for a shorter answer."
        } else if let reason = turn.failureMessage {
            state = "error"; failure = reason
        } else if let spawn = exit.spawnError {
            state = "error"; failure = spawn
        } else if let status = exit.status, status != 0 {
            state = "error"; failure = turn.lastError ?? "\(service.displayName) stopped with exit code \(status)."
        } else if exit.status == nil {
            state = "error"; failure = "\(service.displayName) was stopped by the system."
        }
        // What was not done, in plain words at the end of the reply.
        var closing: [String] = []
        if failure == nil, service == .claudeCode {
            if permission == .ask {
                // Steps still waiting when the rounds ran out were never asked about.
                notDone += leftover.map { ("needs approval", AgentAsk.label($0)) }
                closing = AgentAsk.closingLines(notDone)
            } else if !leftover.isEmpty {
                closing = [AgentAsk.notAllowedLine(leftover, permission: permission)]
            }
        } else if failure == nil, service == .codex, permission == .ask, Self.codexTriedToAct(fields.events) {
            closing = [AgentAsk.codexReadOnlyLine]
        }
        if !closing.isEmpty { content += (content.isEmpty ? "" : "\n\n") + closing.joined(separator: "\n") }
        if failure == nil, content.isEmpty { content = "Done." }

        var thread = ref.value
        var messages = thread["messages"]?.array ?? []
        if !messages.isEmpty {
            var last = messages[messages.count - 1].object ?? [:]
            last["state"] = .string(state)
            last["content"] = .string(content)
            last["events"] = .array(fields.events)
            if needsSignIn { last["needsSignIn"] = .string(service.engine) }
            if let needsUpdate { last["needsUpdate"] = .string(needsUpdate) }
            if let failure { last["error"] = .string(redactSecrets(failure, keys: [])) }
            messages[messages.count - 1] = .object(last)
        }
        thread = thread.setting("messages", .array(messages)).setting("updated", .string(EText.iso(now())))
        history.remember(&thread, request.setting("state", .string(state)))
        var finalState = state, finalText = failure ?? "Agent task complete"
        do { try history.save(thread) } catch { finalState = "error"; finalText = "Could not save this conversation. Check available disk space." }
        ref.value = thread
        job.state = finalState
        job.progress = finalText
        locked { abort = nil; active = nil; liveThread = nil; lastActivity = now() }
        changed()
    }

    /// True when a read-only Codex run tried to change something (a file change, or a step that failed), so it could not act.
    private static func codexTriedToAct(_ events: [JSONValue]) -> Bool {
        events.contains { $0["type"]?.string == "tool_use" && $0["name"]?.string == "file change" || $0["error"]?.bool == true }
    }

    /// The command that signs the person in again: the tool's own `auth login` (Claude Code) or `login` (Codex), by its full path.
    public func agentSignInCommand(service: AgentService) -> (executable: String, arguments: [String]) {
        (agentLauncher.executable(for: service) ?? service.program, service == .claudeCode ? ["auth", "login"] : ["login"])
    }

    /// Opens the sign-in command in the person's own Terminal, so the sign-in happens there and Black Team sees none of it.
    public func openAgentSignIn(service: AgentService) async throws {
        guard agentLauncher.executable(for: service) != nil else {
            throw BlackTeamError("\(service.displayName) is not installed on \(Place.this). Install it, then sign in with your subscription.")
        }
        let command = agentSignInCommand(service: service)
        let text = launchScript(workspace: home, environment: AgentTools.environment(), executable: command.executable, args: command.arguments)
        let script = try writeLaunchScript(text, stateDir: dataFolder)
        do { try await terminal("Terminal", script) }
        catch { try? FileManager.default.removeItem(atPath: script); throw BlackTeamError("Terminal could not be opened to sign in to \(service.displayName).") }
    }

    /// The command that updates the tool: its own `update`, by its full path (Claude Code `claude update`, Codex `codex update`).
    public func agentUpdateCommand(service: AgentService) -> (executable: String, arguments: [String]) {
        (agentLauncher.executable(for: service) ?? service.program, ["update"])
    }

    /// Opens the update command in the person's own Terminal. Black Team starts it and captures nothing from it.
    public func openAgentUpdate(service: AgentService) async throws {
        guard agentLauncher.executable(for: service) != nil else {
            throw BlackTeamError("\(service.displayName) is not installed on \(Place.this). Install it, then sign in with your subscription.")
        }
        let command = agentUpdateCommand(service: service)
        let text = launchScript(workspace: home, environment: AgentTools.environment(), executable: command.executable, args: command.arguments)
        let script = try writeLaunchScript(text, stateDir: dataFolder)
        do { try await terminal("Terminal", script) }
        catch { try? FileManager.default.removeItem(atPath: script); throw BlackTeamError("Terminal could not be opened to update \(service.displayName).") }
    }

    /// The installed and latest versions of a subscription agent. Checked only for a tool that is installed; the latest version
    /// is kept for 12 hours. Nothing is updated.
    public func agentUpdateStatus(service: AgentService) async -> AgentUpdateStatus {
        guard let executable = agentLauncher.executable(for: service) else { return AgentUpdateStatus(installed: nil, latest: nil) }
        guard let installed = await AgentVersions.installedVersion(service: service, executable: executable) else {
            return AgentUpdateStatus(installed: nil, latest: nil)
        }
        let latest = await AgentVersionStores.store(dataFolder: dataFolder).latest(service: service, now: now(), fetch: fetch)
        return AgentUpdateStatus(installed: installed, latest: latest)
    }

    /// Puts the files a subscription-agent task changed back as they were before it ran. Refused while any task is running,
    /// and only for a task whose snapshot was saved.
    @discardableResult
    public func rollBack(threadId: String, runId: String) throws -> AgentSnapshots.Restored {
        guard History.validID(threadId), History.validID(runId) else { throw BlackTeamError("Not found.") }
        lock.lock()
        let running = active != nil
        lock.unlock()
        if running { throw BlackTeamError("Wait for the running task to finish, or stop it, before rolling back.") }
        guard var thread = history.get(threadId) else { throw BlackTeamError("Conversation not found.") }
        var messages = thread["messages"]?.array ?? []
        guard let at = messages.firstIndex(where: { $0["run"]?.string == runId }) else { throw BlackTeamError("There is no saved state for this task.") }
        let message = messages[at]
        guard message["rollback"]?.bool == true else { throw BlackTeamError("There is no saved state for this task.") }
        guard message["rolledBack"]?.bool != true else { throw BlackTeamError("This task has already been rolled back.") }
        guard let workspace = message["workspace"]?.string, workspace.hasPrefix("/") else { throw BlackTeamError("There is no saved state for this task.") }
        let restored = try snapshots.restore(threadId: threadId, runId: runId, workspace: workspace)
        messages[at] = message.setting("rolledBack", .bool(true))
        thread = thread.setting("messages", .array(messages)).setting("updated", .string(EText.iso(now())))
        try history.save(thread)
        changed()
        return restored
    }
}
