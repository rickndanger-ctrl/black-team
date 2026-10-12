import Foundation

/// The reply one subscription-agent run is writing: its text, its tool steps, and what the tool said about how it ended.
/// The text and the steps are stored on the assistant message in the same shape a Code conversation uses, so the work log
/// shows them as it does for Black Team's own Code.
final class AgentTurn: @unchecked Sendable {
    /// Most tool steps kept on one reply, as the Code engine keeps.
    static let eventLimit = 200
    /// Most characters of one tool step's input or output, as the Code engine keeps.
    static let stepLimit = 4000

    let service: AgentService
    private let lock = NSLock()
    private var text = ""
    private var events: [JSONValue] = []
    private var names: [String: String] = [:]
    private var finalText = ""
    private var failure: String?
    private var stderrTail: [String] = []
    private var sessionId: String?
    private var sessionChanged = false
    private var overflowFlag = false
    private var deniedSteps: [AgentDenial] = []

    init(service: AgentService) { self.service = service }

    /// Reads one line of output. Standard error is kept only as a tail, to explain a failure the tool printed in words.
    func ingest(_ stream: AgentStream, _ line: String) {
        if stream == .stderr {
            let clean = EText.prefix(redactSecrets(line.trimmingCharacters(in: .whitespaces)), 500)
            guard !clean.isEmpty else { return }
            lock.lock(); stderrTail.append(clean); if stderrTail.count > 5 { stderrTail.removeFirst() }; lock.unlock()
            return
        }
        for event in AgentEventParser.parse(line, service: service) { apply(event) }
    }

    private func apply(_ event: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .session(let id):
            if sessionId == nil { sessionId = id; sessionChanged = true }
        case .text(let piece):
            appendText(redactSecrets(piece))
        case .toolUse(let id, let name, let input):
            names[id] = name
            addEvent(["type": "tool_use", "name": .string(EText.prefix(name, 60)),
                      "output": .string(EText.prefix(redactSecrets(input), AgentTurn.stepLimit))])
        case .toolResult(let id, let output, let isError):
            addEvent(["type": "tool_result", "name": .string(EText.prefix(names[id] ?? "tool", 60)),
                      "output": .string(EText.prefix(redactSecrets(output), AgentTurn.stepLimit)), "error": .bool(isError)])
        case .finished(let answer, let isError):
            finalText = redactSecrets(answer)
            if isError { failure = failure ?? (finalText.isEmpty ? "\(service.displayName) reported an error." : finalText) }
        case .failed(let message):
            failure = failure ?? redactSecrets(message)
        case .denied(let denial):
            // The live line has the tool's message and the end-of-run list has the input: one step, both parts.
            if let at = deniedSteps.firstIndex(where: { !$0.id.isEmpty && $0.id == denial.id }) {
                if deniedSteps[at].input == .null { deniedSteps[at].input = denial.input }
                if deniedSteps[at].message.isEmpty { deniedSteps[at].message = denial.message }
            } else {
                deniedSteps.append(denial)
            }
        case .ignored:
            break
        }
    }

    /// Keeps the reply within 256 KiB, as a Chat reply is kept. Past the limit the run is stopped and the reply says so.
    private func appendText(_ piece: String) {
        guard !piece.isEmpty else { return }
        let separator = text.isEmpty ? "" : "\n\n"
        let room = AgentTools.replyLimit - EText.length(text) - EText.length(separator)
        if EText.length(piece) > room {
            if room > 0 { text += separator + EText.prefix(piece, room) }
            overflowFlag = true
            return
        }
        text += separator + piece
    }

    private func addEvent(_ item: JSONValue) {
        events.append(item)
        if events.count > AgentTurn.eventLimit { events.removeFirst(events.count - AgentTurn.eventLimit) }
    }

    /// True once the reply has reached the 256 KiB limit.
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflowFlag }

    /// The tool's session id, reported once: the first time it is seen after it was read.
    func takeSessionChange() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard sessionChanged else { return nil }
        sessionChanged = false
        return sessionId
    }

    /// The fields the reply message carries now: the text (the final answer when no text was written) and the tool steps.
    var fields: (content: String, events: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        return (text.isEmpty ? finalText : text, events)
    }

    /// Steps that needed approval in this round, in the order they came. Cleared by `startRound`.
    var denials: [AgentDenial] { lock.lock(); defer { lock.unlock() }; return deniedSteps }

    /// Starts another round of the same reply (a resume after approvals): the text and steps stay, the denials and the end-of-run text go.
    func startRound() { lock.lock(); deniedSteps = []; finalText = ""; lock.unlock() }

    /// True when the tool said, in words, that the person's login has expired or is missing. Only the tool's own failure text
    /// and its standard error are read, never the text it wrote as a reply.
    var signedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        let markers: [String]
        switch service {
        case .claudeCode: markers = ["oauth session expired", "failed to authenticate: oauth", "not logged in \u{b7} please run /login", "please run /login"]
        case .codex: markers = ["not logged in", "log out and sign in again", "access token could not be refreshed", "codex login"]
        }
        return ([failure].compactMap { $0 } + stderrTail).contains { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }
    }

    /// What the tool reported as the reason it failed, if it said one in words.
    var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return failure }

    /// The last lines the tool printed to standard error, for an error the tool did not put in words.
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return stderrTail.last }
}
