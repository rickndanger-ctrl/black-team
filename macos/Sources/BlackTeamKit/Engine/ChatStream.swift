import Foundation

/// The two pure helpers of plain Chat that the rest of the chat backend builds on:
/// the messages sent for a thread, and the reader for a streamed reply.
public enum ChatStream {
    /// Worded so that a very small model still answers: told flatly that it "has no tools", the 0.8B starter model, with thinking on,
    /// reasoned its way to refusing sums and translations. Measured on it: 20 of 20 simple questions right with this wording.
    public static let SYSTEM = "You are Black Team, a helpful assistant running privately on the user\u{2019}s own computer. Answer the user\u{2019}s questions directly and do what they ask. You cannot open files, browse the web or run commands in this conversation, so never say that you did. If you are unsure, say so."

    /// The same instructions for a conversation with a cloud service: it must not claim to be local or to know the vault.
    public static let CLOUD_SYSTEM = "You are Black Team, a helpful AI assistant. This conversation has no tools: do not claim to read files, browse, run commands, or complete external actions. Ask for needed information and be clear about uncertainty."

    /// What was recalled for a message stays attached to it, so earlier turns are sent the same way
    /// every time and the model server's prompt cache keeps working.
    static func withMemory(_ message: JSONValue) -> String {
        let content = message["content"]?.string ?? ""
        guard let recalled = message["recalled"]?.array, !recalled.isEmpty else { return content }
        let lines = recalled.map { "- \($0["title"]?.string ?? "undefined"): \($0["text"]?.string ?? "undefined")" }
        return "\(content)\n\n[From your memory. Use it only if it is relevant.]\n\(lines.joined(separator: "\n"))"
    }

    /// A user message as it is sent: its text with memory, and the references of its images (the bytes are added when the request is made).
    static func userMessage(_ message: JSONValue, memory: Bool = true) -> JSONValue {
        var value: JSONValue = ["role": "user", "content": .string(memory ? withMemory(message) : (message["content"]?.string ?? ""))]
        let refs = (message["images"]?.array ?? []).compactMap { ImageRef($0) }
        if !refs.isEmpty { value = value.setting("images", .array(refs.map(\.json))) }
        return value
    }

    /// The system message, every finished earlier pair, then the newest request.
    /// For a cloud conversation (`cloud: true`) the vault has no part in it: no Core, and no recalled notes.
    public static func messagesFor(_ thread: JSONValue, cloud: Bool = false) -> [JSONValue] {
        let core = cloud ? "" : thread["core"]?.string ?? ""
        let base = cloud ? CLOUD_SYSTEM : SYSTEM
        let system = core.isEmpty ? base : "\(base)\n\nWhat you know about the user:\n\(core)"
        var result: [JSONValue] = [["role": "system", "content": .string(system)]]
        let messages = thread["messages"]?.array ?? []
        var index = 0
        while index < messages.count - 2 {
            let user = messages[index], assistant = messages[index + 1]
            if user["role"]?.string == "user", assistant["role"]?.string == "assistant", assistant["state"]?.string == "done",
               let reply = assistant["content"]?.string, !reply.isEmpty {
                result.append(userMessage(user, memory: !cloud))
                result.append(["role": "assistant", "content": .string(reply)])
                index += 1
            }
            index += 1
        }
        if messages.count >= 2 { result.append(userMessage(messages[messages.count - 2], memory: !cloud)) }
        return result
    }

    public struct Result: Equatable, Sendable {
        public var finishReason: String?
        public var timings: JSONValue?
        public var usage: JSONValue?
    }

    /// Reads a server-sent-events reply. `onDelta` gets each choice's `delta` object.
    public static func readStream(_ lines: HTTPLines, onDelta: (JSONValue) throws -> Void, signal: CancelSignal? = nil, subject: String = "local model") async throws -> Result {
        var finished = false
        var result = Result()
        func process(_ raw: String) throws {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.hasPrefix("data:") else { return }
            let data = EText.trim(String(line.dropFirst(5)))
            if data.isEmpty { return }
            if data == "[DONE]" { finished = true; return }
            guard let item = try? JSONValue.parse(data) else { throw BlackTeamError("The \(subject) returned an invalid stream.") }
            if let error = item["error"], error != .null, error != .bool(false) {
                throw BlackTeamError("The \(subject) could not complete the response. Check the model and context settings.")
            }
            if let timings = item["timings"], timings.object != nil { result.timings = timings }
            if let usage = item["usage"], usage.object != nil { result.usage = usage }
            let choice = item["choices"]?[0]
            if let delta = choice?["delta"], delta != .null { try onDelta(delta) }
            if let reason = choice?["finish_reason"]?.string, !reason.isEmpty { finished = true; result.finishReason = reason }
        }
        for try await line in lines {
            if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            if EText.length(line) > 1024 * 1024 { throw BlackTeamError("The \(subject) returned an oversized stream frame.") }
            try process(line)
        }
        if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
        if !finished { throw BlackTeamError("Connection to the \(subject) ended before the response finished.") }
        return result
    }
}
