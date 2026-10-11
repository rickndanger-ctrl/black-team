import Foundation

// Only a live job for the visible conversation may animate the assistant emblem.
// A saved `writing` message alone is not proof that the model is still running.

public struct ActivityMessage: Equatable {
    public var id: String?
    public var role: String
    public var state: String?
    public init(id: String? = nil, role: String, state: String? = nil) { self.id = id; self.role = role; self.state = state }
}

public struct ActivityThread: Equatable {
    public var id: String
    public var messages: [ActivityMessage]
    public init(id: String, messages: [ActivityMessage]) { self.id = id; self.messages = messages }
}

public struct ActivityJob: Equatable {
    public var threadId: String?
    public var state: String
    public var kind: String
    public var hasApproval: Bool
    public var progress: String
    public init(threadId: String?, state: String, kind: String, hasApproval: Bool = false, progress: String = "") {
        self.threadId = threadId; self.state = state; self.kind = kind; self.hasApproval = hasApproval; self.progress = progress
    }
}

public struct ResponseActivity: Equatable {
    public enum Phase: String, Equatable {
        case offline, approval, stopping, responding, thinking, working, preparing, processing
    }
    public var phase: Phase
    public var label: String
    public var glowing: Bool
    public var messageId: String?

    public init(phase: Phase, label: String, glowing: Bool, messageId: String?) {
        self.phase = phase; self.label = label; self.glowing = glowing; self.messageId = messageId
    }

    private static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the assistant is doing right now, or nil when nothing is live for this conversation.
    public static func current(thread: ActivityThread?, threadId: String?, job: ActivityJob?, connection: String) -> ResponseActivity? {
        guard let threadId, !threadId.isEmpty, let job, job.threadId == threadId, job.state == "running",
              ["chat", "agent"].contains(job.kind) else { return nil }

        let current = thread?.id == threadId ? thread : nil
        let last = current?.messages.last
        if last?.role == "assistant" && last?.state != "writing" { return nil }
        let messageId = last?.role == "assistant" ? last?.id : nil
        func result(_ phase: Phase, _ label: String, _ glowing: Bool = false) -> ResponseActivity {
            ResponseActivity(phase: phase, label: label, glowing: glowing, messageId: messageId)
        }

        if connection != "online" { return result(.offline, "Reconnecting") }
        if job.hasApproval { return result(.approval, "Awaiting your approval") }
        let progress = job.progress
        if has(progress, "stopping|cancel") { return result(.stopping, "Stopping") }
        if has(progress, "writing a reply") { return result(.responding, "Responding", true) }
        if has(progress, "thinking") { return result(.thinking, "Thinking", true) }
        if has(progress, "using |finished |working|tools and workspace") { return result(.working, "Working", true) }
        if messageId == nil || has(progress, "preparing|loading|starting|reading") { return result(.preparing, "Preparing", true) }
        return result(.processing, "Processing", true)
    }
}
