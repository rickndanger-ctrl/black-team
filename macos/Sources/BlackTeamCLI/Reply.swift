import Foundation
import BlackTeamKit

/// A flag that a signal handler can set while the main task reads it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

/// What a finished reply looked like.
struct FinishedReply {
    var threadId: String
    var runId: String
    var state: String
    var text: String
    var error: String?
    var needsSignIn: String?
    var meter: JSONValue?
    var usage: JSONValue?
    var cloudProvider: String?
    var rollbackReady = false
    var rollbackNote: String?
    /// The ids of file changes the reply made (Code), oldest first.
    var changes: [String] = []
}

/// How the person (or the lack of one) takes part while a reply is running.
struct ReplyHooks {
    /// New reply text.
    var text: (String) -> Void = { _ in }
    /// A tool step: name, short argument summary.
    var step: (String, String) -> Void = { _, _ in }
    /// A tool result: short summary, and whether it was an error.
    var result: (String, Bool) -> Void = { _, _ in }
    /// A command waits for an answer: "once" or "deny".
    var approval: (ApprovalSummary) async -> String = { _ in "deny" }
    /// Becomes true when the person wants the reply stopped.
    var stop: () -> Bool = { false }
}

func oneLine(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    let squeezed = flat.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return squeezed.count > limit ? String(squeezed.prefix(limit - 1)) + "\u{2026}" : squeezed
}

/// Follows a reply that has been submitted until it ends, passing on text, steps and approvals as they appear.
@MainActor func followReply(_ backend: Backend, sent: SubmitResult, hooks: ReplyHooks) async -> FinishedReply {
    var printed = "", steps = 0
    var answered = Set<String>()
    var stopped = false
    func show() {
        guard let view = backend.thread(sent.threadId), let reply = view["messages"]?.array?.last else { return }
        let events = reply["events"]?.array ?? []
        while steps < events.count {
            let event = events[steps]; steps += 1
            let name = event["name"]?.string ?? "", output = event["output"]?.string ?? ""
            switch event["type"]?.string {
            case "tool_use": hooks.step(name, oneLine(output, 120))
            case "tool_result": hooks.result(oneLine(output, 120), event["error"]?.bool == true)
            default: break
            }
        }
        let content = reply["content"]?.string ?? ""
        if content.hasPrefix(printed), content.count > printed.count {
            hooks.text(String(content.dropFirst(printed.count)))
            printed = content
        }
    }
    while backend.isBusy {
        if !stopped, hooks.stop() { stopped = true; backend.cancel() }
        if !stopped, let approval = (try? await backend.status())?.job?.approval, !answered.contains(approval.id) {
            answered.insert(approval.id)
            show()
            let choice = await hooks.approval(approval)
            try? backend.approve(id: approval.id, digest: approval.digest, choice: choice)
            if hooks.stop() { stopped = true; backend.cancel() }
        }
        show()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    await backend.waitForIdle()
    show()
    let view = backend.thread(sent.threadId)
    let reply = view?["messages"]?.array?.last
    var finished = FinishedReply(threadId: sent.threadId, runId: sent.id, state: reply?["state"]?.string ?? "error", text: reply?["content"]?.string ?? "",
                                 error: reply?["error"]?.string, needsSignIn: reply?["needsSignIn"]?.string, meter: reply?["meter"], usage: view?["usage"])
    if view?["privacy"]?.string == "cloud" { finished.cloudProvider = view?["provider"]?.string ?? "a cloud service" }
    finished.rollbackReady = reply?["rollback"]?.bool == true
    finished.rollbackNote = reply?["rollbackNote"]?.string
    finished.changes = (reply?["events"]?.array ?? []).compactMap { $0["change"]?["id"]?.string }
    if !finished.text.hasPrefix(printed) || (printed.isEmpty && !finished.text.isEmpty) {
        // The reply was rewritten or never streamed: give the rest.
        hooks.text(printed.isEmpty ? finished.text : "")
    } else if finished.text.count > printed.count {
        hooks.text(String(finished.text.dropFirst(printed.count)))
    }
    return finished
}
