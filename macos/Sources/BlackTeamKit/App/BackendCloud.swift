import Foundation

// Privacy travels with the work. There is one workspace and any model, local or cloud, can be chosen; what keeps a private
// conversation private is a rule enforced here, not a separate area of the app:
//
//   - every conversation has a level: "local" (nothing in it may be sent off this Mac) or "cloud" (it may go to `provider`);
//   - a local conversation is never silently continued with a cloud model: the Backend refuses and the interface offers a choice;
//   - a project is local only until the person allows cloud models in it;
//   - a conversation that has been sent to a cloud service gets no memory from the vault;
//   - a phone may continue conversations but never starts or converts one to cloud.

/// Who is sending: the Mac's own windows and command line, or a paired phone.
public enum SubmitOrigin: Sendable { case mac, phone }

/// What the interface needs to know before a message is sent, and what to say if it cannot be.
public struct PrivacyCheck: Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Nothing leaves this Mac, or the conversation is already allowed to go where it is going.
        case allowed
        /// A new conversation with a cloud model: say exactly what will leave before the first send.
        case startsCloud
        /// A local conversation, or one that went to another service, with a cloud model selected.
        case needsChoice
        /// The project is local only.
        case projectLocalOnly
        /// A phone may not start a cloud conversation.
        case phoneNeedsMac
    }

    public var outcome: Outcome
    /// The refusal in words, or the notice for `startsCloud`; empty when allowed.
    public var message: String
    public var provider: String
    public var modelName: String
    /// What leaves this Mac (for `startsCloud`).
    public var willLeave: [String]
    /// A saved local model to switch back to.
    public var localModelName: String
    public var localModelKey: String
    /// What the person must confirm to send an existing conversation to the service (for `needsChoice`).
    public var convertWarning: String

    public init(outcome: Outcome = .allowed, message: String = "", provider: String = "", modelName: String = "", willLeave: [String] = [],
                localModelName: String = "", localModelKey: String = "", convertWarning: String = "") {
        self.outcome = outcome; self.message = message; self.provider = provider; self.modelName = modelName; self.willLeave = willLeave
        self.localModelName = localModelName; self.localModelKey = localModelKey; self.convertWarning = convertWarning
    }

    public var refused: Bool { [.needsChoice, .projectLocalOnly, .phoneNeedsMac].contains(outcome) }
    var refusal: String? { refused ? message : nil }

    static func allowed() -> PrivacyCheck { PrivacyCheck() }
}

extension Backend {
    /// What leaves this Mac for a cloud conversation, in the words the pre-send notice uses.
    static func leaves(kind: String) -> [String] {
        kind == "agent"
            ? ["your messages", "the contents of any file the agent reads and the output of any command it runs", "the path of your workspace folder"]
            : ["your messages, and any pictures you attach"]
    }

    func privacyDecision(config: Config, existing: JSONValue?, project: Project?, kind: String, viaPhone: Bool) -> PrivacyCheck {
        guard config.model.source == "cloud" else { return .allowed() }
        let destination = CloudDestination.model(host: cloudHost(config.model.endpoint, rules: cloudRules), name: config.model.name)
        let alternative = savedModels.list(active: config.model).first { !$0.isCloud }
        return cloudDecision(destination: destination, alternative: alternative.map { ($0.name, $0.key) }, existing: existing, project: project,
                             kind: kind, viaPhone: viaPhone)
    }

    /// The one rule for anything that would leave this Mac: a cloud model, or a subscription agent. Only the destination differs.
    func cloudDecision(destination: CloudDestination, alternative: (name: String, key: String)?, existing: JSONValue?, project: Project?,
                       kind: String, viaPhone: Bool) -> PrivacyCheck {
        let provider = destination.provider
        let name = destination.name
        var result = PrivacyCheck.allowed()
        result.provider = provider; result.modelName = name
        result.localModelName = alternative?.name ?? ""; result.localModelKey = alternative?.key ?? ""
        let isAgent = destination.isAgent
        result.willLeave = isAgent ? CloudDestination.agentLeaves : Backend.leaves(kind: kind)
        let choices: String
        if isAgent {
            choices = "Start a new conversation with \(name), or send this conversation to \(provider)."
        } else {
            choices = alternative.map { "Start a new cloud conversation, switch back to \($0.name), or send this conversation to \(provider)." }
                ?? "Start a new cloud conversation, or send this conversation to \(provider)."
        }
        result.convertWarning = "Send this conversation to \(provider)? Everything in it so far will be sent to \(provider) with your next message: all your messages and the replies"
            + (isAgent ? ", and the file contents and command output the agent saw" : (kind == "agent" ? ", and the file contents and command output the agent saw" : ""))
            + ". The conversation stays marked as having left this Mac, even if you later continue it with a local model."
        // A project that is local only never uses a cloud model.
        if let project, !project.cloudAllowed {
            result.outcome = .projectLocalOnly
            result.message = isAgent
                ? "The project \(project.name) is local only, so \(name) (which runs on \(provider)) is not used for conversations in it. "
                    + "To change that, choose \u{201C}Allow cloud models\u{201D} in the project\u{2019}s menu."
                : "The project \(project.name) is local only, so the cloud model \(name) is not used for conversations in it. "
                    + "To change that, choose \u{201C}Allow cloud models\u{201D} in the project\u{2019}s menu, or select a local model."
            return result
        }
        if let existing {
            let level = existing["privacy"]?.string == "cloud" ? "cloud" : "local"
            let sentTo = existing["provider"]?.string ?? ""
            if level == "local" {
                result.outcome = .needsChoice
                result.message = isAgent
                    ? "This conversation is private to this Mac, and \(name) would send it to \(provider). "
                    : "This conversation is private to this Mac, and \(name) is a cloud model that would send it to \(provider). "
                result.message += "Nothing in a private conversation is sent off this Mac without your say-so. " + choices
                return result
            }
            if sentTo != provider {
                result.outcome = .needsChoice
                result.message = "This conversation was sent to \(sentTo.isEmpty ? "another service" : sentTo), and \(name) would send all of it to \(provider) as well. " + choices
                return result
            }
            result.outcome = .allowed
            return result
        }
        // A new conversation with a cloud model. A phone does not start one: that decision is made at the Mac.
        if viaPhone {
            result.outcome = .phoneNeedsMac
            result.message = isAgent
                ? "Starting a conversation with \(name) is a decision made at the Mac. Open Black Team on your Mac to start one, or ask there."
                : "Starting a conversation with a cloud model is a decision made at the Mac. Open Black Team on your Mac to start one, or ask there."
            return result
        }
        result.outcome = .startsCloud
        result.message = isAgent
            ? "This conversation leaves this Mac. It is handed to \(name), which runs on \(provider) under your subscription: \(result.willLeave.joined(separator: ", and ")). "
                + "\(name) uses its own tools and its maker\u{2019}s service, and Black Team\u{2019}s memory is not used."
            : "This conversation leaves this Mac. It is sent to \(provider), which you chose for it: \(result.willLeave.joined(separator: ", and ")). "
                + "Memory is not used in cloud conversations."
        return result
    }

    // MARK: Subscription agents (Claude Code, Codex)

    /// What a subscription agent run would do, whatever model is selected: the agent runs on its maker's cloud.
    public func agentPrivacyCheck(service: AgentService, threadId: String?, project projectId: String?, viaPhone: Bool = false) -> PrivacyCheck {
        let existing = threadId.flatMap { history.get($0) }
        let wanted = existing != nil ? existing?["project"]?.string : projectId
        let project = locked { projects.first { $0.id == wanted } }
        return cloudDecision(destination: .agent(service), alternative: nil, existing: existing, project: project, kind: "chat", viaPhone: viaPhone)
    }

    /// THE GATE. The runner must call this before starting, resuming or messaging a subscription agent, and must not proceed if it
    /// throws. `existing` is the saved conversation (nil for a new one). Returns the level and provider to save on a new conversation.
    func authorizeAgentRun(service: AgentService, existing: JSONValue?, project: Project?, viaPhone: Bool) throws -> (privacy: String, provider: String) {
        let check = cloudDecision(destination: .agent(service), alternative: nil, existing: existing, project: project, kind: "chat", viaPhone: viaPhone)
        if let refusal = check.refusal { throw BlackTeamError(refusal) }
        return ("cloud", service.provider)
    }

    /// What would happen if this message were sent now. The interface asks this to show the pre-send notice and the refusal
    /// choices; `submit` makes the same decision again itself, so asking is never required for safety.
    public func privacyCheck(threadId: String?, project projectId: String?, kind: String = "chat", viaPhone: Bool = false) -> PrivacyCheck {
        guard let config = try? configStore.read() else { return .allowed() }
        let existing = threadId.flatMap { history.get($0) }
        let wanted = existing != nil ? existing?["project"]?.string : projectId
        let project = locked { projects.first { $0.id == wanted } }
        return privacyDecision(config: config, existing: existing, project: project, kind: kind, viaPhone: viaPhone)
    }

    // MARK: Sending a conversation to a service

    /// "Send this conversation to <service>": turns a conversation into a cloud one, after the person has confirmed by naming the
    /// service. The vault's contents are taken out of it first (Core, recalled notes, recall results). Nothing is sent by this call.
    public func convertToCloud(threadId: String, confirmingProvider: String) throws {
        let config = try configStore.read()
        guard config.model.source == "cloud" else { throw BlackTeamError("Select a cloud model first.") }
        try convert(threadId: threadId, provider: cloudHost(config.model.endpoint, rules: cloudRules), confirming: confirmingProvider)
    }

    /// The same conversion for a subscription agent: the confirmation must name the agent's provider (e.g. "anthropic.com").
    /// Works whatever model is selected.
    public func convertToCloud(threadId: String, confirmingProvider: String, agent: AgentService) throws {
        try convert(threadId: threadId, provider: agent.provider, confirming: confirmingProvider)
    }

    private func convert(threadId: String, provider: String, confirming confirmingProvider: String) throws {
        guard confirmingProvider == provider else {
            throw BlackTeamError("Confirm which service this conversation will be sent to (\(provider)) before it is converted.")
        }
        lock.lock()
        if active != nil { lock.unlock(); throw BlackTeamError("Wait for the running response to finish, or stop it, before converting this conversation.") }
        guard var thread = history.get(threadId) else { lock.unlock(); throw BlackTeamError("Conversation not found.") }
        if let project = projects.first(where: { $0.id == thread["project"]?.string }), !project.cloudAllowed {
            lock.unlock()
            throw BlackTeamError("The project \(project.name) is local only, so its conversations cannot be sent to a cloud service. Choose \u{201C}Allow cloud models\u{201D} in the project\u{2019}s menu first.")
        }
        lock.unlock()
        // Memory is not used in cloud conversations, and what it already put into this one does not travel.
        var object = thread.object ?? [:]
        object["core"] = nil
        object["messages"] = .array((object["messages"]?.array ?? []).map { $0.setting("recalled", nil) })
        thread = .object(object)
        if (thread["kind"]?.string ?? "chat") == "agent", let engine { try engine.scrubForCloud(threadId) }
        thread = thread.setting("privacy", "cloud").setting("provider", .string(provider)).setting("updated", .string(EText.iso(now())))
        try history.save(thread)
        changed()
    }

    // MARK: Projects

    /// A project is local only until the person allows cloud models in it. Allowing needs `confirmed: true`, which the interface
    /// asks for once.
    @discardableResult
    public func setProjectCloud(_ id: String, allowed: Bool, confirmed: Bool = false) throws -> ProjectSummary {
        if allowed && !confirmed { throw BlackTeamError("Confirm that conversations in this project may use cloud models.") }
        lock.lock(); defer { lock.unlock() }
        guard let at = projects.firstIndex(where: { $0.id == id }) else { throw BlackTeamError("That project no longer exists.") }
        var next = projects
        next[at].cloud = allowed ? true : nil
        try writeJSON(dataFolder + "/projects.json", next)
        projects = next
        changed()
        return summary(next[at])
    }

    // MARK: Setting up a cloud model

    /// Asks a cloud service which models it offers. The key is the one typed in the form, or the saved one when the address
    /// is still the saved model's own (same host).
    public func discoverCloud(endpoint: String, apiKey: String? = nil) async throws -> DiscoveredCloud {
        let saved = try configStore.read().model
        let target = try cloudRules(endpoint)
        var key = apiKey ?? ""
        if apiKey == nil, saved.source == "cloud", cloudHost(saved.endpoint, rules: cloudRules) == target.host { key = saved.apiKey }
        return try await discoverCloudModels(endpoint: endpoint, apiKey: key, fetch: fetch, rules: cloudRules)
    }

    // MARK: A Chat turn with a cloud model

    func cloudChatTurn(job: JobState, signal: CancelSignal, ref: ThreadRef, config: Config, mode: String) async throws {
        func check() throws { if signal.isCancelled { throw CancellationError() } }
        let target = try cloudRules(config.model.endpoint)
        let thread = ref.value
        job.progress = "Reading conversation context\u{2026}"
        // No Core, no recalled notes: the vault stays on this Mac.
        let prepared = try prepareCloudContext(messages: ChatStream.messagesFor(thread, cloud: true), context: config.model.context, mode: mode)
        try check()
        ref.updateLast { $0["context"] = prepared.report.json }
        job.context = prepared.report.json
        job.progress = "Waiting for \(target.host)\u{2026}"
        let messages = try modelMessages(prepared.messages, threadId: thread["id"]?.string ?? "")
        let (_, lines) = try await CloudRequest.openStream(endpoint: target, model: config.model.id, apiKey: config.model.apiKey, capabilities: capabilities,
                                                           timeout: 30 * 60, stream: stream) { caps in
            CloudRequest.body(model: config.model.id, messages: messages, tools: nil, maxTokens: prepared.maxTokens, mode: mode, caps: caps)
        }
        try await readReply(lines, job: job, signal: signal, ref: ref, prepared: prepared, cloudHost: target.host)
    }
}

// MARK: Destinations

/// A subscription agent: the person's own command-line app, running on its maker's cloud under their subscription.
public enum AgentService: String, Sendable, CaseIterable {
    case claudeCode, codex
    public var provider: String { self == .claudeCode ? "anthropic.com" : "openai.com" }
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
}

/// Where a conversation would go when it leaves this Mac.
enum CloudDestination {
    case model(host: String, name: String)
    case agent(AgentService)

    var provider: String { switch self { case .model(let host, _): return host; case .agent(let service): return service.provider } }
    var name: String { switch self { case .model(_, let name): return name; case .agent(let service): return service.displayName } }
    var isAgent: Bool { if case .agent = self { return true }; return false }

    static let agentLeaves = ["your messages", "the files in this project folder that the agent chooses to read", "the output of commands it runs"]
}

extension Backend {
    /// Cap on what is handed to a subscription agent, in UTF-16 units.
    static let agentTaskLimit = 24_000

    /// What the runner hands to a subscription agent, and the ONLY thing it may hand over: the conversation's user and assistant
    /// text plus the new message. Never `core`, `recalled` notes, image data, recall results or engine memory. Keeps the newest
    /// turns within `agentTaskLimit`; if the new message alone is larger, its end is kept.
    func agentTaskText(thread: JSONValue, newMessage: String) -> String {
        var turns: [String] = []
        for message in thread["messages"]?.array ?? [] {
            let role = message["role"]?.string
            guard role == "user" || role == "assistant", let text = message["content"]?.string, !text.isEmpty else { continue }
            turns.append((role == "user" ? "User:\n" : "Assistant:\n") + text)
        }
        turns.append("User:\n" + newMessage)
        var kept: [String] = []
        var used = 0
        for turn in turns.reversed() {
            let size = turn.utf16.count + (kept.isEmpty ? 0 : 2)
            if used + size > Backend.agentTaskLimit {
                if kept.isEmpty {
                    var tail = Substring(turn)
                    while tail.utf16.count > Backend.agentTaskLimit { tail = tail.dropFirst() }
                    kept.append(String(tail))
                }
                break
            }
            kept.append(turn); used += size
        }
        return kept.reversed().joined(separator: "\n\n")
    }
}
