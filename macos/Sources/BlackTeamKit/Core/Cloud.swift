import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cloud models: a service other than this Mac, reached over HTTPS with the person's own API key.
// Everything here is about keeping that door narrow: a strict address check, the key sent only to
// the host it was entered for, redaction of the key from every message, and a request body that
// carries only standard OpenAI fields.

// MARK: Address

/// A cloud address that passed the check: where requests go, and the host that holds the key.
public struct CloudEndpoint: Equatable, Sendable {
    public let base: String
    public let host: String
    public init(base: String, host: String) { self.base = base; self.host = host }
}

/// How cloud addresses are checked. The app always uses `standard`. The seam exists so a test (and the
/// command-line tool's stand-in server run, which lives in `BlackTeamCLI` only) can accept a stub; nothing in
/// this library reads an environment variable or loosens the rule by itself.
public struct CloudRules: Sendable {
    public let check: @Sendable (String) throws -> CloudEndpoint
    public init(check: @escaping @Sendable (String) throws -> CloudEndpoint) { self.check = check }
    public static let standard = CloudRules(check: cloudEndpoint)
    public func callAsFunction(_ value: String) throws -> CloudEndpoint { try check(value) }
}

private let cloudAddressHelp = "Use the service\u{2019}s secure address: https, a real host name, and no password, query or fragment (for example https://api.openai.com/v1)."

/// Host names that mean "this computer or this network", whatever the DNS says.
private let privateSuffixes = [".localhost", ".local", ".localdomain", ".internal", ".lan", ".home", ".home.arpa", ".intranet", ".corp", ".private", ".test", ".invalid", ".example"]

/// Accepts only an `https` address with a real, public-style host name. Not `localhost`, not an IP address in any
/// spelling, no credentials, query or fragment. Local servers go through `localEndpoint` and stay local.
public func cloudEndpoint(_ value: String) throws -> CloudEndpoint {
    let bad = BlackTeamError(cloudAddressHelp)
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf16.count <= 512, !text.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }),
          !text.contains("?"), !text.contains("#"), !text.contains("@"), !text.contains("\\"),
          let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          let rawHost = parts.host?.lowercased(), !rawHost.isEmpty else {
        if text.lowercased().hasPrefix("http://") { throw BlackTeamError("A cloud service must use https. \(cloudAddressHelp)") }
        throw bad
    }
    var host = rawHost
    while host.hasSuffix(".") { host.removeLast() }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let labelPattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
    // At least two labels, each a plain label, and a last label with a letter in it: that refuses every spelling of an IP address.
    guard host.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ $0.range(of: labelPattern, options: .regularExpression) != nil }),
          labels.last!.utf8.count >= 2, labels.last!.contains(where: { $0 >= "a" && $0 <= "z" }) else {
        throw BlackTeamError("A cloud service needs a real host name, not an IP address or a name on this network. \(cloudAddressHelp)")
    }
    if host == "localhost" || privateSuffixes.contains(where: { host.hasSuffix($0) }) {
        throw BlackTeamError("That address is on this computer or this network. Local models are added as a local server instead; a cloud service needs a public host name.")
    }
    let path = parts.percentEncodedPath
    let segments = path.split(separator: "/", omittingEmptySubsequences: true)
    guard path.range(of: #"^(/[A-Za-z0-9._~-]+)*/?$"#, options: .regularExpression) != nil, !segments.contains(".."), !segments.contains("."), path.utf8.count <= 200 else { throw bad }
    var port = ""
    if let given = parts.port {
        guard (1...65535).contains(given) else { throw bad }
        if given != 443 { port = ":\(given)" }
    }
    return CloudEndpoint(base: "https://\(host)\(port)\(segments.isEmpty ? "" : "/" + segments.joined(separator: "/"))", host: host)
}

/// The host name of a saved cloud address, or "" when it is not one.
public func cloudHost(_ endpoint: String, rules: CloudRules = .standard) -> String {
    (try? rules(endpoint))?.host ?? ""
}

// MARK: Key

/// The Authorization header for a cloud key; a key is required.
public func cloudHeaders(_ apiKey: String) throws -> [String: String] {
    if apiKey.isEmpty { throw BlackTeamError("Enter the API key for this service.") }
    return try serverHeaders(apiKey)
}

/// Removes the key, and anything shaped like a bearer token or a provider key, from text that may be shown or saved.
public func redactSecrets(_ text: String, keys: [String] = []) -> String {
    var out = text
    for key in keys where key.utf8.count >= 6 { out = out.replacingOccurrences(of: key, with: "[redacted]", options: .literal) }
    for pattern in [#"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#, #"\bsk-[A-Za-z0-9_-]{16,}"#, #"\bAIza[0-9A-Za-z_-]{20,}"#, #"\b(?:x-api-key|api[-_ ]?key)\s*[:=]\s*[A-Za-z0-9._~+/=-]{8,}"#] {
        out = out.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return out
}

// MARK: Models offered by a service

public struct CloudModelInfo: Equatable, Sendable {
    public var id: String
    /// The context size the service reports, when it does.
    public var context: Int?
    /// The service lists a price of zero for both reading and writing (OpenRouter's free models do).
    public var free = false
    /// The service says the model can call tools; nil when it does not say.
    public var tools: Bool?

    public init(id: String, context: Int? = nil, free: Bool = false, tools: Bool? = nil) {
        self.id = id; self.context = context; self.free = free; self.tools = tools
    }

    /// Worth offering as a free agent: costs nothing and is not known to lack tool calling.
    public var freeAgent: Bool { free && tools != false }
}

public struct DiscoveredCloud: Equatable, Sendable {
    public let endpoint: String
    public let host: String
    public let models: [CloudModelInfo]
}

/// Asks a cloud service which models it offers (`GET <base>/models`). The key goes only to the checked address.
public func discoverCloudModels(endpoint: String, apiKey: String, fetch: HTTPFetch = LocalHTTP.fetch, rules: CloudRules = .standard) async throws -> DiscoveredCloud {
    let target = try rules(endpoint)
    var headers = try cloudHeaders(apiKey)
    // Anthropic's own models route wants the key under its own header name. Only Anthropic gets these:
    // a relay such as OpenRouter takes them as a request for its Anthropic-style list, whose model names
    // ("anthropic/…[1m]") are not the ids its chat route accepts.
    if target.host == "anthropic.com" || target.host.hasSuffix(".anthropic.com") {
        headers["x-api-key"] = apiKey
        headers["anthropic-version"] = "2023-06-01"
    }
    var models: [CloudModelInfo] = []
    var after: String?
    for _ in 0..<5 {
        var link = target.base + "/models"
        if let after, let escaped = after.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { link += "?after_id=" + escaped }
        var request = URLRequest(url: URL(string: link)!)
        request.timeoutInterval = 20
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let result: (Data, HTTPURLResponse)
        do { result = try await fetch(request) } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw BlackTeamError("Cannot reach \(target.host). Check your connection and the address.")
        }
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            let detail = redactSecrets(cloudErrorDetail(String(decoding: data.prefix(65536), as: UTF8.self)).message, keys: [apiKey])
            switch response.statusCode {
            case 401, 403: throw BlackTeamError("\(target.host) refused the API key. Check the key and try again.")
            case 404: throw BlackTeamError("\(target.host) does not list models at this address. You can type a model id instead.")
            default: throw BlackTeamError("\(target.host) could not list its models (HTTP \(response.statusCode)). You can type a model id instead." + (detail.isEmpty ? "" : " \(String(detail.prefix(160)))"))
            }
        }
        guard let value = try? JSONValue.parse(data), let items = value["data"]?.array ?? value["models"]?.array else {
            throw BlackTeamError("\(target.host) returned a model list Black Team cannot read. You can type a model id instead.")
        }
        for item in items {
            guard let id = item["id"]?.string ?? item["name"]?.string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 256,
                  !id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }), !models.contains(where: { $0.id == id }) else { continue }
            var context: Int?
            for field in ["context_length", "context_window", "max_input_tokens", "input_token_limit"] {
                if let number = item[field]?.int, number >= 512 { context = number; break }
            }
            // A price of zero for both directions, written as a number or as text ("0", "0.0").
            func zero(_ value: JSONValue?) -> Bool {
                if let number = value?.double { return number == 0 }
                if let text = value?.string, let number = Double(text) { return number == 0 }
                return false
            }
            let free = zero(item["pricing"]?["prompt"]) && zero(item["pricing"]?["completion"])
            let tools = item["supported_parameters"]?.array.map { $0.contains(.string("tools")) }
            models.append(CloudModelInfo(id: id, context: context, free: free, tools: tools))
            if models.count >= 1000 { break }
        }
        // Services that page their list say so; follow a few pages.
        if value["has_more"]?.bool == true, let last = value["last_id"]?.string, models.count < 1000 { after = last } else { break }
    }
    if models.isEmpty { throw BlackTeamError("\(target.host) reported no models. You can type a model id instead.") }
    return DiscoveredCloud(endpoint: target.base, host: target.host, models: models)
}

// MARK: What each model turned out to accept ("capabilities learned")

/// What one cloud model rejected, learned from its own 400 answers.
public struct CloudCaps: Codable, Equatable, Sendable {
    /// Optional fields the service refused, left out from then on.
    public var rejected: [String] = []
    /// `max_tokens`, or `max_completion_tokens` for services that require the newer name.
    public var maxTokensField = "max_tokens"
    public init(rejected: [String] = [], maxTokensField: String = "max_tokens") { self.rejected = rejected; self.maxTokensField = maxTokensField }
}

/// The record of those lessons, per service and model, in the private data folder. Not provider names in code:
/// the first refusal teaches Black Team, and it is remembered.
public final class CloudCapabilities: @unchecked Sendable {
    private static let lock = NSLock()
    private let filename: String
    private let folder: String

    public init(dataFolder: String) {
        folder = dataFolder
        filename = dataFolder + "/cloud-capabilities.json"
    }

    private func key(_ host: String, _ model: String) -> String { host + "|" + model }

    private func load() -> [String: CloudCaps] {
        guard CoreFS.stat(filename).error == 0, let data = FileManager.default.contents(atPath: filename),
              let saved = try? JSONDecoder().decode([String: CloudCaps].self, from: data) else { return [:] }
        return saved
    }

    public func caps(host: String, model: String) -> CloudCaps {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return load()[key(host, model)] ?? CloudCaps()
    }

    public func record(host: String, model: String, _ caps: CloudCaps) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var all = load()
        all[key(host, model)] = caps
        if all.count > 400 { all = Dictionary(uniqueKeysWithValues: Array(all).suffix(400)) }
        try? privateDirectory(folder)
        try? writeJSON(filename, all)
    }
}

/// The error text and the offending field name from a service's error body (`{"error":{"message","param"}}`, or the
/// same inside a list, as some services answer).
public func cloudErrorDetail(_ raw: String) -> (message: String, param: String) {
    guard var value = try? JSONValue.parse(raw) else { return (EText.trim(EText.prefix(raw, 400)), "") }
    if let first = value.array?.first { value = first }
    let error = value["error"] ?? value
    if let text = error.string { return (text, "") }
    return (error["message"]?.string ?? "", error["param"]?.string ?? "")
}

// MARK: The request

public enum CloudRequest {
    /// Only these optional fields are ever left out after a refusal.
    static let optional = ["temperature", "reasoning_effort", "stream_options", "tool_choice"]

    /// `reasoning_effort` for a pace; nil for Fast (not sent at all).
    public static func effort(_ mode: String) -> String? {
        switch mode {
        case "balanced": return "medium"
        case "deep", "extended": return "high"
        default: return nil
        }
    }

    /// A request in the standard shape and nothing else: no llama.cpp fields (`chat_template_kwargs`, `thinking_budget_tokens`,
    /// `cache_prompt`, sampler extras, `timings_per_token`), shaped by what this model is known to refuse.
    public static func body(model: String, messages: [JSONValue], tools: [JSONValue]? = nil, maxTokens: Int, mode: String, caps: CloudCaps) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model), "messages": .array(messages), "stream": true, "stream_options": ["include_usage": true],
            "temperature": 0.7,
        ]
        body[caps.maxTokensField] = .number(Double(maxTokens))
        if let tools, !tools.isEmpty { body["tools"] = .array(tools); body["tool_choice"] = "auto" }
        if let effort = effort(mode) { body["reasoning_effort"] = .string(effort) }
        for name in caps.rejected { body[name] = nil }
        return .object(body)
    }

    /// What a 400 teaches, or nil when it names nothing new. Looks at the service's own `param` first, then at the text.
    public static func learn(status: Int, message: String, param: String, from caps: CloudCaps) -> CloudCaps? {
        guard status == 400 || status == 422 else { return nil }
        var next = caps
        let text = message.lowercased()
        func names(_ field: String) -> Bool {
            let p = param.lowercased()
            if p == field || p.hasPrefix(field + ".") { return true }
            return text.range(of: "(?<![a-z_])" + field + "(?![a-z_])", options: .regularExpression) != nil
        }
        let other = caps.maxTokensField == "max_tokens" ? "max_completion_tokens" : "max_tokens"
        if names(caps.maxTokensField) { next.maxTokensField = other }
        // "stream_options.include_usage" and "include_usage" both mean the stream options.
        for field in optional where !next.rejected.contains(field) {
            if names(field) || (field == "stream_options" && names("include_usage")) { next.rejected.append(field) }
        }
        return next == caps ? nil : next
    }

    /// The person-facing text of a refusal. The key is redacted.
    public static func failure(status: Int, raw: String, host: String, keys: [String]) -> BlackTeamError {
        let detail = redactSecrets(cloudErrorDetail(raw).message, keys: keys)
        let tail = detail.isEmpty ? "" : " " + String(detail.prefix(300))
        switch status {
        case 401, 403: return BlackTeamError("\(host) refused the API key (HTTP \(status)). Check the key for this service in Available configurations.")
        case 404: return BlackTeamError("\(host) does not know this model (HTTP 404). Check the model id.\(tail)")
        case 429: return BlackTeamError("\(host) is limiting requests (HTTP 429). Wait a moment and try again.\(tail)")
        case 500...599: return BlackTeamError("\(host) had a problem (HTTP \(status)). Try again shortly.\(tail)")
        default: return BlackTeamError("\(host) rejected the request (HTTP \(status)).\(tail)")
        }
    }

    /// Opens a streamed reply from a cloud service, reacting once per refused field to a 400 and remembering the lesson.
    /// `make` builds the body for what is known so far.
    public static func openStream(endpoint: CloudEndpoint, model: String, apiKey: String, capabilities: CloudCapabilities, timeout: TimeInterval,
                                  stream: HTTPStreamFetch, make: (CloudCaps) -> JSONValue) async throws -> (HTTPURLResponse, HTTPLines) {
        for attempt in 0..<5 {
            let caps = capabilities.caps(host: endpoint.host, model: model)
            var request = URLRequest(url: URL(string: endpoint.base + "/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in try cloudHeaders(apiKey) { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = Data(make(caps).text().utf8)
            let response: HTTPURLResponse, lines: HTTPLines
            do { (response, lines) = try await stream(request) } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let known = error as? BlackTeamError { throw known }
                throw BlackTeamError("Cannot reach \(endpoint.host). Check your connection.")
            }
            if (200..<300).contains(response.statusCode) { return (response, lines) }
            var raw = ""
            do { for try await line in lines { raw += line + "\n"; if raw.utf8.count > 65536 { break } } } catch {}
            let detail = cloudErrorDetail(raw)
            if attempt < 4, let next = learn(status: response.statusCode, message: detail.message, param: detail.param, from: caps) {
                capabilities.record(host: endpoint.host, model: model, next)
                continue
            }
            throw failure(status: response.statusCode, raw: raw, host: endpoint.host, keys: [apiKey])
        }
        throw BlackTeamError("\(endpoint.host) kept rejecting the request.")
    }
}

// MARK: Usage

/// Tokens a cloud conversation has used so far, from the service's own `usage` figures. No prices: they change.
public struct CloudUsage: Equatable, Sendable {
    public var prompt = 0
    public var completion = 0
    public var cached = 0
    public init(prompt: Int = 0, completion: Int = 0, cached: Int = 0) { self.prompt = prompt; self.completion = completion; self.cached = cached }

    public init(json: JSONValue?) {
        prompt = json?["prompt"]?.int ?? 0; completion = json?["completion"]?.int ?? 0; cached = json?["cached"]?.int ?? 0
    }

    /// From an API `usage` object.
    public init(api usage: JSONValue?) {
        prompt = usage?["prompt_tokens"]?.int ?? usage?["input_tokens"]?.int ?? 0
        completion = usage?["completion_tokens"]?.int ?? usage?["output_tokens"]?.int ?? 0
        cached = usage?["prompt_tokens_details"]?["cached_tokens"]?.int ?? usage?["cached_tokens"]?.int ?? 0
    }

    public var json: JSONValue { ["prompt": .number(Double(prompt)), "completion": .number(Double(completion)), "cached": .number(Double(cached))] }
    public static func + (a: CloudUsage, b: CloudUsage) -> CloudUsage { CloudUsage(prompt: a.prompt + b.prompt, completion: a.completion + b.completion, cached: a.cached + b.cached) }
}

extension ThreadRef {
    /// Adds one request's tokens to the conversation's running total (`usage` on the thread).
    func addUsage(_ more: CloudUsage) {
        var thread = value.object ?? [:]
        thread["usage"] = (CloudUsage(json: thread["usage"]) + more).json
        value = .object(thread)
    }
}
