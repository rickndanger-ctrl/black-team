import Foundation

// Context review: pick which saved turns fit the model's window. With llama.cpp the count is exact,
// asked of the server's own chat template and tokenizer; other servers get a byte estimate.

/// What was measured or estimated, shown beside the reply.
public struct ContextReport: Codable, Equatable, Sendable {
    public var measuredInputTokens: Int
    public var context: Int
    public var maxTokens: Int
    public var omittedMessages: Int
    public var method: String
    public var inputBudget: Int
    public var safetyMargin: Int
    public var decision: String
    /// Tokens set aside for the images in the prompt, counted in `measuredInputTokens`; nil when there are none.
    public var imageReserveTokens: Int? = nil

    public var json: JSONValue {
        var value: JSONValue = ["measuredInputTokens": .number(Double(measuredInputTokens)), "context": .number(Double(context)), "maxTokens": .number(Double(maxTokens)),
         "omittedMessages": .number(Double(omittedMessages)), "method": .string(method), "inputBudget": .number(Double(inputBudget)),
         "safetyMargin": .number(Double(safetyMargin)), "decision": .string(decision)]
        if let imageReserveTokens, imageReserveTokens > 0 { value = value.setting("imageReserveTokens", .number(Double(imageReserveTokens))) }
        return value
    }
}

/// What a picture costs the model's context. llama.cpp turns an image into a number of tokens that depends on its size and the
/// model's projector, and `/apply-template` and `/tokenize` only take text, so each image gets this fixed allowance on top of its
/// message's text. Measured on llama.cpp with Qwen3.5 projectors: 1 token per 32x32 pixels, so 171 tokens for 400x400, 1,202 for 1280x960 and 1,602 for the largest picture Black Team sends (1280x1280); 1700 covers that.
public enum ImageCost {
    public static let tokensPerImage = 1700
    static func count(in message: JSONValue) -> Int { message["images"]?.array?.count ?? 0 }
    /// The allowance for every image in these messages, or nil when there are none.
    static func reserve(_ messages: [JSONValue]) -> Int? {
        let total = messages.reduce(0) { $0 + count(in: $1) } * tokensPerImage
        return total > 0 ? total : nil
    }
}

public struct PreparedContext: Equatable, Sendable {
    public var messages: [JSONValue]
    public var maxTokens: Int
    public var report: ContextReport
}

enum ContextPlanner {
    static let outputBudgets: [String: Int] = ["fast": 512, "balanced": 1024, "deep": 2048, "extended": 4096]
    static let safetyMargin = 128
    static let maxHistoryTurns = 64

    struct Parts {
        var system: [JSONValue]
        var turns: [[JSONValue]]
        var latest: [JSONValue]
        var originalLength: Int
    }

    static func message(_ role: String, _ content: String, images: JSONValue? = nil) -> JSONValue {
        var value: JSONValue = ["role": .string(role), "content": .string(content)]
        // An image stays with the message it was sent in, so dropping an old turn drops its pictures too and none is left alone.
        if let images, images.array?.isEmpty == false { value = value.setting("images", images) }
        return value
    }

    /// The messages as a text-only server template can take them: the same, without the image references.
    static func textOnly(_ messages: [JSONValue]) -> [JSONValue] {
        messages.map { message in
            var object = message.object ?? [:]
            object["images"] = nil
            return .object(object)
        }
    }

    static func conversationParts(_ messages: [JSONValue]) throws -> Parts {
        if messages.isEmpty || messages.count > 10000 {
            throw BlackTeamError("Context review needs a conversation with a latest user message (maximum 10,000 messages).")
        }
        var clean: [(role: String, content: String, images: JSONValue?)] = []
        for item in messages {
            guard let role = item["role"]?.string, ["system", "user", "assistant"].contains(role), let content = item["content"]?.string else {
                throw BlackTeamError("Context review supports plain text system, user, and assistant messages.")
            }
            clean.append((role, content, item["images"]))
        }
        var index = 0
        var system: [JSONValue] = []
        while index < clean.count, clean[index].role == "system" { system.append(message("system", clean[index].content)); index += 1 }
        var turns: [[JSONValue]] = []
        while index < clean.count {
            let item = clean[index]
            if item.role == "system" { throw BlackTeamError("System instructions must precede the conversation for context review.") }
            if item.role == "user" { turns.append([message("user", item.content, images: item.images)]) }
            else {
                if turns.isEmpty { throw BlackTeamError("Conversation history has an assistant response without a user turn.") }
                turns[turns.count - 1].append(message("assistant", item.content))
            }
            index += 1
        }
        if turns.isEmpty || clean[clean.count - 1].role != "user" {
            throw BlackTeamError("Context review requires the latest message to be the user request.")
        }
        let latest = turns.removeLast()
        if turns.contains(where: { $0.count < 2 }) {
            throw BlackTeamError("Remove unfinished earlier turns before context review. The latest user request is kept intact.")
        }
        return Parts(system: system, turns: turns, latest: latest, originalLength: clean.count)
    }

    static func localRoot(_ endpoint: String) throws -> String {
        guard let parts = URLComponents(string: endpoint), let scheme = parts.scheme else {
            throw BlackTeamError("Context review requires the local model endpoint.")
        }
        guard scheme.lowercased() == "http", parts.host == "127.0.0.1", let port = parts.port, port != 80,
              ["/v1", "/v1/"].contains(parts.path), parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw BlackTeamError("Context review only connects to the owned model on 127.0.0.1.")
        }
        return "http://127.0.0.1:\(port)"
    }

    static func stopped(_ signal: CancelSignal?) -> Bool { signal?.isCancelled == true || Task.isCancelled }
}

/// Runs `operation` so that either a stop signal or cancellation of the calling task cancels it.
func cancellable<T: Sendable>(_ signal: CancelSignal?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let work = Task { try await operation() }
    let unobserve = signal?.observe { work.cancel() }
    defer { unobserve?() }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
}

/// Exact token counting through the llama.cpp server's `/props`, `/apply-template` and `/tokenize`.
/// `messages` is the whole saved conversation as `{role, content}` objects, newest request last.
public func prepareContext(messages: [JSONValue], context: Int, mode: String = "balanced", endpoint: String, headers: [String: String],
                           fetch: @escaping HTTPFetch = LocalHTTP.fetch, signal: CancelSignal? = nil) async throws -> PreparedContext {
    let root = try ContextPlanner.localRoot(endpoint)
    if context < 256 { throw BlackTeamError("Context size must be a whole number of at least 256 tokens.") }
    guard let outputBudget = ContextPlanner.outputBudgets[mode] else { throw BlackTeamError("Choose fast, balanced, deep, or extended response mode.") }
    guard let authorization = headers["Authorization"], authorization.hasPrefix("Bearer ") else {
        throw BlackTeamError("Context review requires the private local model authentication.")
    }
    let parts = try ContextPlanner.conversationParts(messages)

    func request(_ route: String, _ body: JSONValue? = nil) async throws -> JSONValue {
        if ContextPlanner.stopped(signal) { throw CancellationError() }
        var urlRequest = URLRequest(url: URL(string: root + route)!)
        urlRequest.httpMethod = body == nil ? "GET" : "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { urlRequest.httpBody = Data(body.text().utf8) }
        let reply: (Data, HTTPURLResponse)
        let outgoing = urlRequest
        do { reply = try await cancellable(signal) { try await fetch(outgoing) } } catch {
            if ContextPlanner.stopped(signal) { throw CancellationError() }
            throw BlackTeamError("Local context review could not reach \(route). Check that the model is running.")
        }
        guard (200..<300).contains(reply.1.statusCode) else {
            throw BlackTeamError("Local context review requires working llama.cpp \(route) support (HTTP \(reply.1.statusCode)). Choose a current llama.cpp release.")
        }
        guard let value = try? JSONValue.parse(reply.0) else {
            if ContextPlanner.stopped(signal) { throw CancellationError() }
            throw BlackTeamError("Local context review received an invalid response from \(route). Choose a current llama.cpp release.")
        }
        return value
    }

    let props = try await request("/props")
    guard let actualContext = props["default_generation_settings"]?["n_ctx"]?.int, actualContext >= 256 else {
        throw BlackTeamError("The local runtime did not report a usable context size. Choose a current llama.cpp release.")
    }
    let effectiveContext = min(context, actualContext)
    let maxTokens = max(64, min(outputBudget, effectiveContext / 4))
    let inputBudget = effectiveContext - maxTokens - ContextPlanner.safetyMargin
    // This bounded suffix keeps review inexpensive even when the saved transcript is long.
    // It never edits the caller's complete, locally stored conversation.
    let recent = Array(parts.turns.suffix(ContextPlanner.maxHistoryTurns))
    var measurements: [Int: (messages: [JSONValue], tokens: Int)] = [:]
    func measure(_ omitted: Int) async throws -> (messages: [JSONValue], tokens: Int) {
        if let known = measurements[omitted] { return known }
        let selected = parts.system + recent.dropFirst(omitted).flatMap { $0 } + parts.latest
        let rendered = try await request("/apply-template", ["messages": .array(ContextPlanner.textOnly(selected))])
        guard let prompt = rendered["prompt"]?.string else {
            throw BlackTeamError("The local runtime did not return a chat template. No estimated token count was substituted.")
        }
        let tokenized = try await request("/tokenize", ["content": .string(prompt), "add_special": true, "parse_special": true])
        guard let tokens = tokenized["tokens"]?.array, tokens.allSatisfy({ ($0.int ?? -1) >= 0 }) else {
            throw BlackTeamError("The local runtime did not return valid token IDs. No estimated token count was substituted.")
        }
        let measured = (selected, tokens.count + selected.reduce(0) { $0 + ImageCost.count(in: $1) } * ImageCost.tokensPerImage)
        measurements[omitted] = measured
        return measured
    }

    var result = try await measure(0)
    if result.tokens > inputBudget {
        // First establish that the instructions and newest request fit without changing either one.
        // Older turns are the only content eligible for removal.
        var low = 0, high = recent.count
        result = try await measure(high)
        if result.tokens > inputBudget {
            throw BlackTeamError("Your latest request and system instructions use \(result.tokens) tokens, exceeding the \(inputBudget)-token input budget. Shorten the request or increase the model context in Settings.")
        }
        while high - low > 1 {
            let middle = (low + high) / 2
            let candidate = try await measure(middle)
            if candidate.tokens <= inputBudget { high = middle; result = candidate } else { low = middle }
        }
    }
    return PreparedContext(messages: result.messages, maxTokens: maxTokens, report: ContextReport(
        measuredInputTokens: result.tokens, context: effectiveContext, maxTokens: maxTokens,
        omittedMessages: parts.originalLength - result.messages.count, method: "local-tokenizer", inputBudget: inputBudget,
        safetyMargin: ContextPlanner.safetyMargin, decision: parts.originalLength == result.messages.count ? "keep" : "select_recent",
        imageReserveTokens: ImageCost.reserve(result.messages)))
}

/// Generic compatible servers do not share llama.cpp's tokenizer API. This estimate is labelled as one
/// in the interface; it is never presented as a measured model token count.
public func prepareServerContext(messages: [JSONValue], context: Int, mode: String = "balanced", endpoint: String) throws -> PreparedContext {
    _ = try localEndpoint(endpoint)
    if context < 512 || context > 131072 { throw BlackTeamError("Choose a context size from 512 to 131072.") }
    guard let outputBudget = ContextPlanner.outputBudgets[mode] else { throw BlackTeamError("Choose a supported response mode.") }
    let parts = try ContextPlanner.conversationParts(messages)
    let maxTokens = max(64, min(outputBudget, context / 4))
    let inputBudget = context - maxTokens - ContextPlanner.safetyMargin
    var recent = Array(parts.turns.suffix(ContextPlanner.maxHistoryTurns))
    func estimate(_ selected: [JSONValue]) -> Int {
        128 + selected.reduce(0) { $0 + ($1["content"]?.string ?? "").utf8.count + 32 + ImageCost.count(in: $1) * ImageCost.tokensPerImage }
    }
    func select() -> [JSONValue] { parts.system + recent.flatMap { $0 } + parts.latest }
    var selected = select()
    while estimate(selected) > inputBudget && !recent.isEmpty {
        recent.removeFirst()
        selected = select()
    }
    let tokens = estimate(selected)
    if tokens > inputBudget {
        throw BlackTeamError("Your latest request and system instructions exceed the estimated input budget. Shorten the request or increase context in both Black Team and your model server.")
    }
    return PreparedContext(messages: selected, maxTokens: maxTokens, report: ContextReport(
        measuredInputTokens: tokens, context: context, maxTokens: maxTokens, omittedMessages: parts.originalLength - selected.count,
        method: "estimated-bytes", inputBudget: inputBudget, safetyMargin: ContextPlanner.safetyMargin,
        decision: parts.originalLength == selected.count ? "keep" : "select_recent",
        imageReserveTokens: ImageCost.reserve(selected)))
}
