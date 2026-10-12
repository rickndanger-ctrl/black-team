import XCTest
@testable import BlackTeamKit

// Cloud models: the address rule, the key, the request body, what is learned from a 400, and the saved model.
final class CloudTests: XCTestCase {
    let key = "sk-test-secret-key-1234567890"

    // MARK: Address

    func testAGoodHttpsAddressIsAcceptedAndNormalised() throws {
        let a = try cloudEndpoint("https://api.openai.com/v1")
        XCTAssertEqual(a, CloudEndpoint(base: "https://api.openai.com/v1", host: "api.openai.com"))
        XCTAssertEqual(try cloudEndpoint("HTTPS://API.OpenAI.com/v1/").base, "https://api.openai.com/v1")
        XCTAssertEqual(try cloudEndpoint("https://openrouter.ai/api/v1").base, "https://openrouter.ai/api/v1")
        XCTAssertEqual(try cloudEndpoint("https://generativelanguage.googleapis.com/v1beta/openai/").base, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(try cloudEndpoint("https://gateway.example-corp.com:8443/llm").base, "https://gateway.example-corp.com:8443/llm")
        XCTAssertEqual(try cloudEndpoint("https://api.anthropic.com:443/v1").base, "https://api.anthropic.com/v1")
        XCTAssertEqual(try cloudEndpoint("https://api.openai.com./v1").host, "api.openai.com")
    }

    func testHttpLocalhostPrivateAddressesAndCredentialsAreRefused() {
        let refused = [
            "http://api.openai.com/v1",                 // not https
            "ftp://api.openai.com/v1", "api.openai.com/v1", "", "   ", "https://",
            "https://localhost/v1", "https://LOCALHOST:8443/v1", "https://foo.localhost/v1",
            "https://127.0.0.1/v1", "https://127.0.0.1:8443/v1", "https://[::1]/v1", "https://10.0.0.5/v1", "https://192.168.1.20/v1",
            "https://172.16.0.9/v1", "https://169.254.1.1/v1", "https://8.8.8.8/v1",   // any IP address, public or not
            "https://2130706433/v1", "https://0x7f.0.0.1/v1", "https://127.1/v1", "https://0177.0.0.1/v1",
            "https://printer.local/v1", "https://nas.lan/v1", "https://box.internal/v1", "https://intranet/v1", "https://singlelabel/v1",
            "https://user:pass@api.openai.com/v1", "https://user@api.openai.com/v1",
            "https://api.openai.com/v1?key=abc", "https://api.openai.com/v1#frag", "https://api.openai.com/v1?",
            "https://api.openai.com/../v1", "https://api.openai.com/v1/../x", "https://api.openai.com/v 1",
            "https://-bad.example-corp.com/v1", "https://exa_mple.com/v1", "https://api.openai.com:0/v1", "https://api.openai.com:99999/v1",
            "https://%6c%6f%63%61%6c%68%6f%73%74/v1", "https://api.openai.com\\@evil.com/v1",
        ]
        for value in refused { XCTAssertThrowsError(try cloudEndpoint(value), value) }
        XCTAssertThrowsError(try cloudEndpoint("http://api.openai.com/v1")) { assertMatch(messageOf($0), "must use https") }
    }

    func testLocalAddressesStayLocalAndCloudAddressesAreNotLocal() throws {
        XCTAssertNoThrow(try localEndpoint("http://127.0.0.1:11434/v1"))
        XCTAssertThrowsError(try localEndpoint("https://api.openai.com/v1"))
        XCTAssertThrowsError(try cloudEndpoint("http://127.0.0.1:11434/v1"))
    }

    // MARK: Key

    func testTheKeyIsRedactedFromAnyText() {
        let text = "failed with Bearer \(key) and key \(key) and sk-abcdefghijklmnopqrstuvwxyz and x-api-key: abcdefgh12345678 and AIzaSyA1234567890abcdefghijk"
        let clean = redactSecrets(text, keys: [key])
        XCTAssertFalse(clean.contains(key))
        XCTAssertFalse(clean.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(clean.contains("abcdefgh12345678"))
        XCTAssertFalse(clean.contains("AIzaSyA1234567890"))
        XCTAssertEqual(redactSecrets("plain", keys: [""]), "plain")
        XCTAssertThrowsError(try cloudHeaders("")) { assertMatch(messageOf($0), "API key") }
        XCTAssertThrowsError(try cloudHeaders("has space"))
        XCTAssertEqual(try cloudHeaders("abc123"), ["Authorization": "Bearer abc123"])
    }

    // MARK: Request body

    func testABodyCarriesTheStandardFieldsOnly() {
        let messages: [JSONValue] = [["role": "user", "content": "hi"]]
        let tools: [JSONValue] = [["type": "function", "function": ["name": "read"]]]
        let standard: Set<String> = ["model", "messages", "stream", "stream_options", "max_tokens", "temperature", "tools", "tool_choice", "reasoning_effort"]
        for mode in ["fast", "balanced", "deep", "extended"] {
            let body = CloudRequest.body(model: "m", messages: messages, tools: tools, maxTokens: 2048, mode: mode, caps: CloudCaps())
            XCTAssertTrue(Set(body.object!.keys).isSubset(of: standard), "\(mode): \(body.object!.keys.sorted())")
            for banned in ["chat_template_kwargs", "thinking_budget_tokens", "cache_prompt", "timings_per_token", "top_k", "min_p", "repeat_penalty", "mirostat"] {
                XCTAssertNil(body[banned], banned)
            }
            XCTAssertEqual(body["stream_options"]?["include_usage"], true)
            XCTAssertEqual(body["max_tokens"]?.int, 2048)
            XCTAssertEqual(body["tool_choice"], "auto")
            XCTAssertEqual(body["reasoning_effort"] != nil, mode != "fast", mode)
        }
        let chat = CloudRequest.body(model: "m", messages: messages, tools: nil, maxTokens: 512, mode: "fast", caps: CloudCaps())
        XCTAssertNil(chat["tools"]); XCTAssertNil(chat["tool_choice"])
    }

    func testWhatAModelRefusedIsLeftOutAndTheTokenFieldIsRenamed() {
        let caps = CloudCaps(rejected: ["temperature", "reasoning_effort"], maxTokensField: "max_completion_tokens")
        let body = CloudRequest.body(model: "m", messages: [], tools: nil, maxTokens: 300, mode: "deep", caps: caps)
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["reasoning_effort"]); XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"]?.int, 300)
    }

    // MARK: Learning from a 400

    func testA400NamingAFieldTeachesTheRequestOnce() throws {
        var caps = CloudCaps()
        let temperature = try XCTUnwrap(CloudRequest.learn(status: 400, message: "Unsupported value: 'temperature' does not support 0.7 with this model.", param: "temperature", from: caps))
        XCTAssertEqual(temperature.rejected, ["temperature"]); caps = temperature
        let tokens = try XCTUnwrap(CloudRequest.learn(status: 400, message: "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", param: "max_tokens", from: caps))
        XCTAssertEqual(tokens.maxTokensField, "max_completion_tokens"); XCTAssertEqual(tokens.rejected, ["temperature"]); caps = tokens
        let effort = try XCTUnwrap(CloudRequest.learn(status: 400, message: "Unrecognized request argument supplied: reasoning_effort", param: "", from: caps))
        XCTAssertEqual(effort.rejected, ["temperature", "reasoning_effort"]); caps = effort
        let usage = try XCTUnwrap(CloudRequest.learn(status: 400, message: "stream_options.include_usage is not supported", param: "stream_options.include_usage", from: caps))
        XCTAssertTrue(usage.rejected.contains("stream_options"))
        // Nothing new to learn, a different status, or a message that names no field: no retry.
        XCTAssertNil(CloudRequest.learn(status: 400, message: "temperature again", param: "temperature", from: usage))
        XCTAssertNil(CloudRequest.learn(status: 400, message: "Your prompt is too long", param: "", from: CloudCaps()))
        XCTAssertNil(CloudRequest.learn(status: 500, message: "temperature", param: "temperature", from: CloudCaps()))
        XCTAssertNil(CloudRequest.learn(status: 401, message: "temperature", param: "temperature", from: CloudCaps()))
    }

    func testErrorBodiesInEitherShapeAreRead() {
        XCTAssertEqual(cloudErrorDetail(#"{"error":{"message":"bad","param":"temperature"}}"#).param, "temperature")
        XCTAssertEqual(cloudErrorDetail(#"[{"error":{"code":400,"message":"wrapped in a list","status":"INVALID_ARGUMENT"}}]"#).message, "wrapped in a list")
        XCTAssertEqual(cloudErrorDetail(#"{"error":"just text"}"#).message, "just text")
        XCTAssertEqual(cloudErrorDetail("not json at all").message, "not json at all")
    }

    func testLessonsAreRememberedPerServiceAndModelInAPrivateFile() throws {
        let folder = makeTemporaryFolder(self)
        let store = CloudCapabilities(dataFolder: folder)
        XCTAssertEqual(store.caps(host: "api.example-llm.com", model: "big"), CloudCaps())
        store.record(host: "api.example-llm.com", model: "big", CloudCaps(rejected: ["temperature"], maxTokensField: "max_completion_tokens"))
        XCTAssertEqual(CloudCapabilities(dataFolder: folder).caps(host: "api.example-llm.com", model: "big").rejected, ["temperature"])
        XCTAssertEqual(store.caps(host: "api.example-llm.com", model: "small"), CloudCaps())
        XCTAssertEqual(store.caps(host: "other.example-llm.com", model: "big"), CloudCaps())
        XCTAssertEqual(mode(folder + "/cloud-capabilities.json"), 0o600)
    }

    // MARK: Finding models

    func testOnlyAnthropicIsSentAnthropicStyleHeaders() async throws {
        let list = #"{"data":[{"id":"m"}]}"#
        let seen = CloudHeaderBox()
        let fetch: HTTPFetch = { request in
            seen.add(request.url!.host!, request.allHTTPHeaderFields ?? [:])
            return (Data(list.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await discoverCloudModels(endpoint: "https://openrouter.ai/api/v1", apiKey: "k", fetch: fetch)
        _ = try await discoverCloudModels(endpoint: "https://api.anthropic.com/v1", apiKey: "k", fetch: fetch)
        // Header names are case-insensitive: Linux's URLRequest stores them capitalised.
        func header(_ host: String, _ name: String) -> String? { seen.headers[host]?.first { $0.key.lowercased() == name.lowercased() }?.value }
        XCTAssertNil(header("openrouter.ai", "x-api-key"))
        XCTAssertNil(header("openrouter.ai", "anthropic-version"))
        XCTAssertEqual(header("openrouter.ai", "Authorization"), "Bearer k")
        XCTAssertEqual(header("api.anthropic.com", "x-api-key"), "k")
        XCTAssertEqual(header("api.anthropic.com", "anthropic-version"), "2023-06-01")
    }

    func testFreeModelsThatCanUseToolsAreRecognised() async throws {
        let list = #"{"data":[{"id":"a/free-tools:free","context_length":262144,"pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools","temperature"]},"# +
            #"{"id":"b/free-no-tools:free","pricing":{"prompt":"0","completion":"0"},"supported_parameters":["temperature"]},"# +
            #"{"id":"c/paid","pricing":{"prompt":"0.00000005","completion":"0.0000002"},"supported_parameters":["tools"]},"# +
            #"{"id":"d/unpriced"},{"id":"e/free-unknown","pricing":{"prompt":0,"completion":0}}]}"#
        let found = try await discoverCloudModels(endpoint: "https://openrouter.ai/api/v1", apiKey: "k", fetch: { request in
            (Data(list.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(found.models.map(\.free), [true, true, false, false, true])
        XCTAssertEqual(found.models.map(\.tools), [true, false, true, nil, nil])
        // Offered as free agents: free and not known to lack tools.
        XCTAssertEqual(found.models.filter(\.freeAgent).map(\.id), ["a/free-tools:free", "e/free-unknown"])
    }

    func testFindingModelsSendsTheKeyOnlyToTheCheckedAddress() async throws {
        let seen = ServerRequests()
        let fetch: HTTPFetch = { request in
            seen.add(request)
            let body = #"{"object":"list","data":[{"id":"alpha","context_length":128000},{"id":"beta"},{"id":"alpha"},{"id":"  "}]}"#
            return (Data(body.utf8), response(request.url!))
        }
        let found = try await discoverCloudModels(endpoint: "https://api.example-llm.com/v1", apiKey: key, fetch: fetch)
        XCTAssertEqual(found.models, [CloudModelInfo(id: "alpha", context: 128000), CloudModelInfo(id: "beta", context: nil)])
        XCTAssertEqual(found.host, "api.example-llm.com")
        XCTAssertEqual(seen.list[0].url?.absoluteString, "https://api.example-llm.com/v1/models")
        XCTAssertEqual(seen.list[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        // An address that fails the check never reaches the network, so the key cannot go anywhere it should not.
        for bad in ["http://api.example-llm.com/v1", "https://127.0.0.1/v1", "https://localhost/v1", "https://u:p@api.example-llm.com/v1"] {
            do { _ = try await discoverCloudModels(endpoint: bad, apiKey: key, fetch: fetch); XCTFail(bad) } catch {}
        }
        XCTAssertEqual(seen.count, 1)
    }

    func testFindingModelsExplainsFailuresWithoutTheKey() async {
        func failing(_ status: Int, _ body: String) -> HTTPFetch {
            { request in (Data(body.utf8), response(request.url!, status)) }
        }
        for (status, body) in [(401, #"{"error":{"message":"Incorrect API key provided: sk-test-secret-key-1234567890"}}"#), (403, "{}"), (404, "{}"), (500, #"{"error":{"message":"oops sk-test-secret-key-1234567890"}}"#)] {
            do { _ = try await discoverCloudModels(endpoint: "https://api.example-llm.com/v1", apiKey: key, fetch: failing(status, body)); XCTFail("\(status)") }
            catch { XCTAssertFalse(messageOf(error).contains(key), "\(status): \(messageOf(error))"); XCTAssertFalse(messageOf(error).isEmpty) }
        }
        do { _ = try await discoverCloudModels(endpoint: "https://api.example-llm.com/v1", apiKey: key, fetch: { _ in throw URLError(.cannotConnectToHost) }); XCTFail() }
        catch { assertMatch(messageOf(error), "Cannot reach api.example-llm.com") }
        do { _ = try await discoverCloudModels(endpoint: "https://api.example-llm.com/v1", apiKey: "", fetch: failing(200, "{}")); XCTFail() }
        catch { assertMatch(messageOf(error), "API key") }
    }

    func testAServicePagingItsListIsFollowed() async throws {
        let calls = Counter()
        let fetch: HTTPFetch = { request in
            let page = calls.next()
            let body = page == 0 ? #"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"# : #"{"data":[{"id":"b"}],"has_more":false}"#
            if page == 1 { XCTAssertTrue(request.url!.absoluteString.hasSuffix("/models?after_id=a")) }
            return (Data(body.utf8), response(request.url!))
        }
        let found = try await discoverCloudModels(endpoint: "https://api.example-llm.com/v1", apiKey: key, fetch: fetch)
        XCTAssertEqual(found.models.map(\.id), ["a", "b"])
    }

    // MARK: Usage

    func testUsageIsReadFromTheApiAndAdded() {
        let one = CloudUsage(api: ["prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": ["cached_tokens": 40]])
        XCTAssertEqual(one, CloudUsage(prompt: 100, completion: 20, cached: 40))
        XCTAssertEqual(one + one, CloudUsage(prompt: 200, completion: 40, cached: 80))
        XCTAssertEqual(CloudUsage(api: ["input_tokens": 7, "output_tokens": 3]), CloudUsage(prompt: 7, completion: 3, cached: 0))
        XCTAssertEqual(CloudUsage(json: one.json), one)
        XCTAssertEqual(CloudUsage(api: nil), CloudUsage())
    }

    // MARK: Budgets

    func testACloudModelIsNotRationedByReadingSpeed() {
        let slow = Engine.budgets(5, 200_000, cloud: true), fast = Engine.budgets(900, 200_000, cloud: true)
        XCTAssertEqual(slow, fast)
        XCTAssertEqual(slow.working, 120_000)            // the same 60% ceiling
        XCTAssertGreaterThan(slow.resultChars, Engine.budgets(900, 200_000).resultChars)
        XCTAssertEqual(Engine.budgets(900, 200_000).working, 120_000)
        XCTAssertEqual(Engine.budgets(5, 65536).working, 12000)   // a local model that reads slowly is still rationed
        XCTAssertEqual(Engine.budgets(5, 65536, cloud: true).working, 39_322)
    }

    // MARK: Config and the saved list

    func configStore(_ rules: CloudRules = .standard) throws -> (ConfigStore, String) {
        let folder = makeTemporaryFolder(self) + "/state"
        return (try ConfigStore(stateDir: folder, defaultWorkspace: NSTemporaryDirectory(), cloud: rules), folder)
    }

    func cloudModel(_ endpoint: String = "https://api.example-llm.com/v1", id: String = "big", apiKey: String? = nil) -> ModelConfig {
        ModelConfig(source: "cloud", endpoint: endpoint, id: id, apiKey: apiKey ?? key, name: "Cloud Big", context: 200_000)
    }

    func testAConfigurationCanHoldACloudModelAndStillRefusesRemoteAddressesForLocalSources() throws {
        let (store, _) = try configStore()
        let saved = try store.save(Config(model: cloudModel(), workspace: NSTemporaryDirectory()))
        XCTAssertEqual(saved.model.source, "cloud")
        XCTAssertEqual(try store.read().model.context, 200_000)
        // Local sources never talk to anything but this Mac.
        XCTAssertThrowsError(try store.save(["model": ["source": "server", "endpoint": "https://api.example-llm.com/v1", "id": "x", "apiKey": ""]]))
        XCTAssertThrowsError(try store.save(["model": ["source": "gguf", "endpoint": "https://api.example-llm.com/v1"]]))
        // And a cloud model never talks to this Mac or over plain http.
        for endpoint in ["http://api.example-llm.com/v1", "https://127.0.0.1/v1", "http://127.0.0.1:11434/v1", "https://localhost/v1"] {
            XCTAssertThrowsError(try store.save(["model": ["source": "cloud", "endpoint": .string(endpoint)]]), endpoint)
        }
        XCTAssertThrowsError(try store.save(["model": ["context": 3_000_000]]))
        XCTAssertThrowsError(try validateModelFiles(cloudModel(apiKey: "")))
        XCTAssertThrowsError(try validateModelFiles(cloudModel(id: " ")))
        XCTAssertNoThrow(try validateModelFiles(cloudModel()))
    }

    func testTheSavedListShowsKindAndHostNeverTheKey() throws {
        let folder = makeTemporaryFolder(self) + "/state"
        let saved = try SavedModels(stateDir: folder)
        let cloud = cloudModel()
        try saved.remember(cloud)
        try saved.remember(ModelConfig(source: "server", endpoint: "http://127.0.0.1:5555/v1", id: "local-one", apiKey: "", name: "Local one"))
        let list = saved.list(active: cloud)
        let entry = try XCTUnwrap(list.first { $0.source == "cloud" })
        XCTAssertEqual(entry.kind, "cloud"); XCTAssertEqual(entry.provider, "api.example-llm.com"); XCTAssertEqual(entry.location, "api.example-llm.com"); XCTAssertTrue(entry.active)
        XCTAssertEqual(list.first { $0.source == "server" }?.kind, "local")
        let text = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        XCTAssertFalse(text.contains(key)); XCTAssertFalse(text.contains("apiKey"))
        XCTAssertEqual(mode(folder + "/saved-models.json"), 0o600)
        // Older summaries without kind still decode.
        let decoded = try JSONDecoder().decode(SavedModelSummary.self, from: Data(#"{"key":"k","name":"n","source":"gguf","context":4096,"active":false,"where":"x.gguf"}"#.utf8))
        XCTAssertEqual(decoded.kind, "local")
        // An entry without a key, or with an address that fails the rule, is not a usable model.
        XCTAssertThrowsError(try saved.remember(cloudModel(apiKey: "")))
        XCTAssertThrowsError(try saved.remember(cloudModel("http://api.example-llm.com/v1")))
        // Same service and model: the key is replaced, not duplicated.
        try saved.remember(cloudModel(apiKey: "sk-another-key-9876543210"))
        XCTAssertEqual(saved.read().filter { $0.source == "cloud" }.count, 1)
    }

    func testTheStubRuleOfATestRunAcceptsOnlyWhatItWasGiven() throws {
        let rules = CloudRules { value in
            if let real = try? cloudEndpoint(value) { return real }
            guard value == "http://127.0.0.1:9/v1" else { throw BlackTeamError("no") }
            return CloudEndpoint(base: value, host: "127.0.0.1:9")
        }
        let (store, _) = try configStore(rules)
        XCTAssertNoThrow(try store.save(Config(model: cloudModel("http://127.0.0.1:9/v1"), workspace: NSTemporaryDirectory())))
        XCTAssertThrowsError(try store.save(["model": ["endpoint": "http://127.0.0.1:10/v1"]]))
        // The default rule, which the app always uses, refuses the very same address.
        let (strict, _) = try configStore()
        XCTAssertThrowsError(try strict.save(Config(model: cloudModel("http://127.0.0.1:9/v1"), workspace: NSTemporaryDirectory())))
    }
}

final class CloudHeaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var headers: [String: [String: String]] = [:]
    func add(_ host: String, _ value: [String: String]) { lock.lock(); headers[host] = value; lock.unlock() }
}
