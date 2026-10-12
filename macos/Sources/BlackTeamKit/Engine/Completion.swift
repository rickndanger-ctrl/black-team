import Foundation

/// One tool call the model asked for, assembled from the streamed pieces.
public struct ToolCallPart: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
}

/// llama.cpp reports its own timings; for other servers the engine works them out from the clock.
public struct CompletionTimings: Equatable, Sendable {
    public var promptN: Double
    public var promptPerSecond: Double
    public var predictedN: Double
    public var predictedPerSecond: Double
}

public struct CompletionUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Prompt tokens the service served from its cache, when it says so.
    public var cachedTokens: Int = 0
    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.cachedTokens = cachedTokens
    }
}

public struct Completion: Equatable, Sendable {
    public var text: String
    public var calls: [ToolCallPart]
    public var finish: String
    public var usage: CompletionUsage?
    public var timings: CompletionTimings?
}

/// The model server answered with an error status. `overflow` means the prompt did not fit its window.
public struct ModelRequestError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public let status: Int
    public let overflow: Bool
    /// The service's full error text and the field it named, so a cloud 400 can be learned from.
    public var detail: String = ""
    public var param: String = ""
    public var errorDescription: String? { message }
}

/// Stops a request when the model has been silent for longer than the allowance.
private final class IdleGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let idle: Duration
    private var last = ContinuousClock.now
    private var expired = false
    private var watchdog: Task<Void, Never>?

    init(milliseconds: Int) { idle = .milliseconds(max(0, milliseconds)) }

    var fired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func alive() { lock.lock(); last = ContinuousClock.now; lock.unlock() }

    func start(cancelling work: Task<Completion, Error>) {
        watchdog = Task { [self] in
            while !Task.isCancelled {
                let remaining = timeLeft()
                if remaining <= .zero {
                    expire()
                    work.cancel()
                    return
                }
                try? await Task.sleep(for: remaining)
            }
        }
    }

    private func timeLeft() -> Duration { lock.lock(); defer { lock.unlock() }; return idle - (ContinuousClock.now - last) }
    private func expire() { lock.lock(); expired = true; lock.unlock() }

    func stop() { watchdog?.cancel() }
}

extension Engine {
    /// One streamed completion. Returns the text, any tool calls, and the two measured speeds.
    /// A local model can be silent for minutes while it reads; it is only stuck when the gap
    /// between pieces passes `idleMs`. Stopping (the signal, or cancelling the task) throws `CancellationError`.
    public static func complete(endpoint: String, headers: [String: String] = [:], body: JSONValue, signal: CancelSignal? = nil, idleMs: Int,
                                fetch: @escaping HTTPStreamFetch, onText: @escaping @Sendable (String) throws -> Void = { _ in },
                                now: @escaping @Sendable () -> Date = { Date() }) async throws -> Completion {
        if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
        let sent = now()
        let idle = IdleGuard(milliseconds: idleMs)
        var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.text().utf8)
        // The engine watches for silence itself, so the system's own timeout must be longer.
        request.timeoutInterval = Double(idleMs) / 1000 + 60
        let sendable = request
        idle.alive()
        let work = Task<Completion, Error> {
            try await stream(sendable, fetch: fetch, signal: signal, idle: idle, onText: onText, now: now, sent: sent)
        }
        idle.start(cancelling: work)
        let unobserve = signal?.observe { work.cancel() }
        defer { idle.stop(); unobserve?() }
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            let stopped = signal?.isCancelled == true || Task.isCancelled
            if idle.fired && !stopped { throw BlackTeamError("The model stopped sending data. What it wrote so far is saved.") }
            if stopped { throw CancellationError() }
            throw error
        }
    }

    private static func stream(_ request: URLRequest, fetch: HTTPStreamFetch, signal: CancelSignal?, idle: IdleGuard,
                               onText: @Sendable (String) throws -> Void, now: @Sendable () -> Date, sent: Date) async throws -> Completion {
        let (response, lines) = try await fetch(request)
        idle.alive()
        guard (200..<300).contains(response.statusCode) else {
            var raw = ""
            do { for try await line in lines { raw += line + "\n"; if raw.utf8.count > 1 << 20 { break } } } catch {}
            let found = cloudErrorDetail(raw)
            let detail = (try? JSONValue.parse(raw)) == nil ? "" : found.message
            let lowered = detail.lowercased()
            let overflow = lowered.contains("exceed") || lowered.contains("context length") || lowered.contains("too long") || lowered.contains("maximum context")
            throw ModelRequestError(message: EText.trim("The model returned HTTP \(response.statusCode). \(EText.prefix(detail, 200))"), status: response.statusCode, overflow: overflow,
                                    detail: detail, param: found.param)
        }
        struct Slot { var id = "", name = "", arguments = "" }
        var slots: [Int: Slot] = [:]
        var text = "", textUnits = 0
        var finish: String?, usage: CompletionUsage?, timings: CompletionTimings?, first: Date?
        func number(_ value: JSONValue?) -> Double { value?.double ?? 0 }

        func process(_ raw: String) throws {
            let row = EText.trim(raw)
            if !row.hasPrefix("data:") || row == "data: [DONE]" { return }
            guard let data = try? JSONValue.parse(String(row.dropFirst(5))) else { return }
            if let error = data["error"], error != .null, error != .bool(false) {
                let message = error["message"]?.string ?? ""
                throw BlackTeamError(message.isEmpty ? "The model stream failed." : message)
            }
            if let item = data["usage"], item.object != nil {
                usage = CompletionUsage(promptTokens: Int(number(item["prompt_tokens"])), completionTokens: Int(number(item["completion_tokens"])),
                                        cachedTokens: Int(number(item["prompt_tokens_details"]?["cached_tokens"])))
            }
            if let item = data["timings"], item.object != nil {
                timings = CompletionTimings(promptN: number(item["prompt_n"]), promptPerSecond: number(item["prompt_per_second"]),
                                            predictedN: number(item["predicted_n"]), predictedPerSecond: number(item["predicted_per_second"]))
            }
            guard let choice = data["choices"]?[0], choice.object != nil else { return }
            let delta = choice["delta"]
            let content = delta?["content"]?.string ?? ""
            let toolCalls = delta?["tool_calls"]
            if first == nil, !content.isEmpty || (toolCalls != nil && toolCalls != .null) { first = now() }
            if !content.isEmpty {
                text += content; textUnits += EText.length(content)
                if textUnits > 256 * 1024 { throw BlackTeamError("The reply reached the storage limit.") }
                try onText(text)
            }
            for part in toolCalls?.array ?? [] {
                let index = part["index"]?.int ?? 0
                if index < 0 { continue }
                var slot = slots[index] ?? Slot()
                if let id = part["id"]?.string, !id.isEmpty { slot.id = id }
                if let name = part["function"]?["name"]?.string, !name.isEmpty { slot.name += name }
                if let piece = part["function"]?["arguments"]?.string, !piece.isEmpty { slot.arguments += piece }
                slots[index] = slot
                if EText.length(slot.arguments) > 1024 * 1024 { throw BlackTeamError("A tool call was too large.") }
            }
            if let reason = choice["finish_reason"]?.string, !reason.isEmpty { finish = reason }
        }

        for try await line in lines {
            if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            idle.alive()
            if EText.length(line) > 2 * 1024 * 1024 { throw BlackTeamError("The local model returned an oversized stream frame.") }
            try process(line)
        }
        if signal?.isCancelled == true || Task.isCancelled { throw CancellationError() }
        guard let finished = finish else { throw BlackTeamError("The model stream ended before it finished. Send a message to continue.") }
        // llama.cpp reports its own timings. Other local servers do not, and the clock gives the same
        // two speeds: time to the first token is the read, the rest is the write.
        if timings == nil, let usage, usage.promptTokens != 0, let first {
            let read = max(0.05, first.timeIntervalSince(sent)), write = max(0.05, now().timeIntervalSince(first))
            timings = CompletionTimings(promptN: Double(usage.promptTokens), promptPerSecond: Double(usage.promptTokens) / read,
                                        predictedN: Double(usage.completionTokens), predictedPerSecond: Double(usage.completionTokens) / write)
        }
        return Completion(text: text, calls: slots.keys.sorted().map { ToolCallPart(id: slots[$0]!.id, name: slots[$0]!.name, arguments: slots[$0]!.arguments) },
                          finish: finished, usage: usage, timings: timings)
    }
}
