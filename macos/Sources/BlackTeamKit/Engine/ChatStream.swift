import Foundation

/// The two pure helpers of plain Chat that the rest of the chat backend builds on:
/// the messages sent for a thread, and the reader for a streamed reply.
public enum ChatStream {
    public static let SYSTEM = "You are Black Team, a helpful private AI assistant running on the user\u{2019}s computer. This conversation has no tools: do not claim to read files, browse, run commands, or complete external actions. Ask for needed information and be clear about uncertainty."

    /// What was recalled for a message stays attached to it, so earlier turns are sent the same way
    /// every time and the model server's prompt cache keeps working.
    static func withMemory(_ message: JSONValue) -> String {
        let content = message["content"]?.string ?? ""
        guard let recalled = message["recalled"]?.array, !recalled.isEmpty else { return content }
        let lines = recalled.map { "- \($0["title"]?.string ?? "undefined"): \($0["text"]?.string ?? "undefined")" }
        return "\(content)\n\n[From your memory. Use it only if it is relevant.]\n\(lines.joined(separator: "\n"))"
    }

    /// The system message, every finished earlier pair, then the newest request.
    public static func messagesFor(_ thread: JSONValue) -> [JSONValue] {
        let core = thread["core"]?.string ?? ""
        let system = core.isEmpty ? SYSTEM : "\(SYSTEM)\n\nWhat you know about the user:\n\(core)"
        var result: [JSONValue] = [["role": "system", "content": .string(system)]]
        let messages = thread["messages"]?.array ?? []
        var index = 0
        while index < messages.count - 2 {
            let user = messages[index], assistant = messages[index + 1]
            if user["role"]?.string == "user", assistant["role"]?.string == "assistant", assistant["state"]?.string == "done",
               let reply = assistant["content"]?.string, !reply.isEmpty {
                result.append(["role": "user", "content": .string(withMemory(user))])
                result.append(["role": "assistant", "content": .string(reply)])
                index += 1
            }
            index += 1
        }
        if messages.count >= 2 { result.append(["role": "user", "content": .string(withMemory(messages[messages.count - 2]))]) }
        return result
    }

    public struct Result: Equatable, Sendable {
        public var finishReason: String?
        public var timings: JSONValue?
        public var usage: JSONValue?
    }

    /// Reads a server-sent-events reply. `onDelta` gets each choice's `delta` object.
    public static func readStream(_ lines: HTTPLines, onDelta: (JSONValue) throws -> Void, signal: CancelSignal? = nil) async throws -> Result {
        var finished = false
        var result = Result()
        func process(_ raw: String) throws {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.hasPrefix("data:") else { return }
            let data = EText.trim(String(line.dropFirst(5)))
            if data.isEmpty { return }
            if data == "[DONE]" { finished = true; return }
            guard let item = try? JSONValue.parse(data) else { throw BlackTeamError("The local model returned an invalid stream.") }
            if let error = item["error"], error != .null, error != .bool(false) {
                throw BlackTeamError("The local model could not complete the response. Check the model and context settings.")
            }
            if let timings = item["timings"], timings.object != nil { result.timings = timings }
            if let usage = item["usage"], usage.object != nil { result.usage = usage }
            let choice = item["choices"]?[0]
            if let delta = choice?["delta"], delta != .null { try onDelta(delta) }
            if let reason = choice?["finish_reason"]?.string, !reason.isEmpty { finished = true; result.finishReason = reason }
        }
        for try await line in lines {
            if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            if EText.length(line) > 1024 * 1024 { throw BlackTeamError("The local model returned an oversized stream frame.") }
            try process(line)
        }
        if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
        if !finished { throw BlackTeamError("Connection to the local model ended before the response finished.") }
        return result
    }
}
