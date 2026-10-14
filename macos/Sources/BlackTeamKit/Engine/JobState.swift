import Foundation

/// The meter shown beside the mode switch: measured speeds and how full the working budget is.
/// Code fills every field; plain Chat fills only the ones it knows.
public struct JobMeter: Codable, Equatable, Sendable {
    public var read: Int?
    public var write: Int?
    public var used: Int?
    public var budget: Int?
    public var window: Int?
    public var trims: Int?

    public init(read: Int? = nil, write: Int? = nil, used: Int? = nil, budget: Int? = nil, window: Int? = nil, trims: Int? = nil) {
        self.read = read; self.write = write; self.used = used; self.budget = budget; self.window = window; self.trims = trims
    }

    /// The saved shape: only the fields that are set.
    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        for (name, value) in [("read", read), ("write", write), ("used", used), ("budget", budget), ("window", window), ("trims", trims)] {
            if let value { object[name] = .number(Double(value)) }
        }
        return .object(object)
    }
}

/// A risky command waiting for the person's answer.
public struct PendingApproval: Equatable, Sendable {
    public var id: String
    /// SHA-256 of the command, so an answer is bound to exactly that command.
    public var digest: String
    public var command: String
    public var description: String
    /// Milliseconds since 1970; the engine denies the command by itself when this passes.
    public var expires: Int64
}

/// The person's answer to a `PendingApproval`: its id and digest, and "once" or "deny".
public struct ApprovalAnswer: Equatable, Sendable {
    public var id: String
    public var digest: String
    public var choice: String
    public init(id: String, digest: String, choice: String) { self.id = id; self.digest = digest; self.choice = choice }
}

/// Everything the interface shows about a running job, as one value.
public struct JobSnapshot: Equatable, Sendable {
    public var id: String
    public var threadId: String?
    public var kind: String
    public var state: String
    public var progress: String
    public var context: JSONValue?
    public var meter: JobMeter?
    public var approval: PendingApproval?
}

/// A job the interface polls or observes: the `job` object of the JavaScript backend.
/// Safe to read and write from any thread. `kind` is "chat", "agent" or "memory"; `state` is
/// "running", "done", "error" or "interrupted".
public final class JobState: @unchecked Sendable {
    public let id: String
    public let threadId: String?
    public let kind: String

    private let lock = NSLock()
    private var current: JobSnapshot
    private var approver: (@Sendable (ApprovalAnswer) throws -> Void)?
    private var observers: [Int: @Sendable (JobSnapshot) -> Void] = [:]
    private var nextObserver = 0
    private var policy: UnattendedPolicy?

    public init(id: String = UUID().uuidString.lowercased(), threadId: String? = nil, kind: String = "agent", state: String = "running", progress: String = "") {
        self.id = id; self.threadId = threadId; self.kind = kind
        current = JobSnapshot(id: id, threadId: threadId, kind: kind, state: state, progress: progress)
    }

    public var snapshot: JobSnapshot { lock.lock(); defer { lock.unlock() }; return current }

    public var state: String {
        get { snapshot.state }
        set { change { $0.state = newValue } }
    }
    public var progress: String {
        get { snapshot.progress }
        set { change { $0.progress = newValue } }
    }
    /// The context report of the last review (Chat).
    public var context: JSONValue? {
        get { snapshot.context }
        set { change { $0.context = newValue } }
    }
    public var meter: JobMeter? {
        get { snapshot.meter }
        set { change { $0.meter = newValue } }
    }
    /// The command waiting for an answer, if any.
    public var approval: PendingApproval? { snapshot.approval }

    /// Set only for a scheduled run, before it starts: what it may do without asking and how long a question may wait.
    public var unattended: UnattendedPolicy? {
        get { lock.lock(); defer { lock.unlock() }; return policy }
        set { lock.lock(); policy = newValue; lock.unlock() }
    }

    /// Answers the pending approval. Throws "No matching active approval." unless the id and digest
    /// match the one waiting and the choice is "once" or "deny". Callable from any thread.
    public func approve(_ answer: ApprovalAnswer) throws {
        lock.lock(); let handler = approver; lock.unlock()
        guard let handler else { throw BlackTeamError("No matching active approval.") }
        try handler(answer)
    }

    public func approve(id: String, digest: String, choice: String) throws {
        try approve(ApprovalAnswer(id: id, digest: digest, choice: choice))
    }

    /// Calls `handler` with the new snapshot after every change. Returns a function that stops listening.
    /// Handlers run on whichever thread made the change, so hop to the main actor before touching views.
    public func observe(_ handler: @escaping @Sendable (JobSnapshot) -> Void) -> @Sendable () -> Void {
        lock.lock(); let key = nextObserver; nextObserver += 1; observers[key] = handler; lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.observers[key] = nil; self.lock.unlock()
        }
    }

    /// Changes under one lock, then tells the observers.
    public func change(_ update: (inout JobSnapshot) -> Void) {
        lock.lock()
        update(&current)
        let snapshot = current, listeners = Array(observers.values)
        lock.unlock()
        for listener in listeners { listener(snapshot) }
    }

    // Used by the engine: show an approval and become the one who can answer it.
    func present(_ approval: PendingApproval, answer: @escaping @Sendable (ApprovalAnswer) throws -> Void) {
        lock.lock(); approver = answer; lock.unlock()
        change { $0.approval = approval }
    }

    func withdraw() {
        lock.lock(); approver = nil; lock.unlock()
        change { $0.approval = nil }
    }
}

/// The conversation an engine run writes into. The engine updates the last message (the reply)
/// as the turn goes; the interface can read `value` at any time.
public final class ThreadRef: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JSONValue

    public init(_ value: JSONValue) { stored = value }

    public var value: JSONValue {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// Replaces the last message (the reply being written).
    func setLast(_ message: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        guard case .object(var top) = stored, case .array(var messages)? = top["messages"], !messages.isEmpty else { return }
        top["messages"] = nil
        stored = .null
        messages[messages.count - 1] = message
        top["messages"] = .array(messages)
        stored = .object(top)
    }
}
