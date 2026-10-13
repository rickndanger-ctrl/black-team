import XCTest
@testable import BlackTeamKit

// Privacy travels with the work: every rule of the cloud design, over the Backend, with the network replaced.
final class BackendCloudTests: XCTestCase {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."
    let vaultNote = "the umbrella is kept in Vault-Secret-Beta"

    let usageStream = "data: {\"choices\":[{\"delta\":{\"content\":\"Cloud \"}}]}\n\n"
        + "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n\n"
        + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        + "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12480,\"completion_tokens\":1930,\"prompt_tokens_details\":{\"cached_tokens\":2000}}}\n\ndata: [DONE]\n\n"

    /// A backend with a vault that has a Core note and a note a message can recall, the local model in use, and the cloud model saved.
    func make(_ fixture: BackendFixture, seedVault: Bool = true) async throws -> Backend {
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        if seedVault {
            try vault.write("Core", "# Core\n\n\(vaultCore)\n")
            try vault.remember("Umbrella", vaultNote)
        }
        fixture.memory = vault
        fixture.reply = { _ in sse(self.usageStream) }
        let backend = try fixture.make()
        return backend
    }

    func addCloud(_ backend: Backend, endpoint: String? = nil, id: String = "big-model", key: String? = nil, name: String = "Cloud Big", context: Int = 100_000) async throws {
        _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": .string(endpoint ?? "https://\(host)/v1"), "id": .string(id), "apiKey": .string(key ?? secret),
                                                   "name": .string(name), "context": .number(Double(context))]])
    }

    func localKey(_ backend: Backend) throws -> String { try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key }

    @discardableResult
    func send(_ backend: Backend, _ text: String = "where is my umbrella", kind: String = "chat", thread: String? = nil, project: String? = nil, from origin: SubmitOrigin = .mac) async throws -> SubmitResult {
        let result = try backend.submit(message: text, kind: kind, requestId: newID(), threadId: thread, project: project, from: origin)
        await backend.waitForIdle()
        return result
    }

    func filesHolding(_ text: String, in folder: String) -> [String] {
        var holders: [String] = []
        for name in (FileManager.default.subpaths(atPath: folder) ?? []) {
            var isDirectory: ObjCBool = false
            let path = folder + "/" + name
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, let data = FileManager.default.contents(atPath: path) else { continue }
            if data.range(of: Data(text.utf8)) != nil { holders.append(name) }
        }
        return holders
    }

    func everything(_ backend: Backend, _ thread: String) -> String {
        backend.history.get(thread)?.text() ?? ""
    }

    // MARK: Rule 1 and 10: a cloud model is a model, with a kind

    func testACloudModelIsSavedWithItsKindAndHostAndTheKeyIsNeverInStatus() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        let before = try await backend.status()
        XCTAssertFalse(before.cloud.selected)
        XCTAssertEqual(before.models.map(\.kind), ["local"])
        try await addCloud(backend)
        let status = try await backend.status()
        XCTAssertTrue(status.setupComplete)
        XCTAssertEqual(status.config.model.kind, "cloud")
        XCTAssertEqual(status.config.model.provider, host)
        XCTAssertEqual(status.runtime.kind, "cloud"); XCTAssertEqual(status.runtime.provider, host); XCTAssertTrue(status.runtime.ready)
        XCTAssertEqual(status.cloud, CloudStatus(selected: true, provider: host, modelName: "Cloud Big", localModelName: "Fixture model", localModelKey: try localKey(backend)))
        XCTAssertEqual(status.models.filter(\.isCloud).map(\.provider), [host])
        XCTAssertEqual(status.models.first(where: \.isCloud)?.active, true)
        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(status.serverKeyConfigured)
        // The key is on disk only in the two private files.
        XCTAssertEqual(mode(fixture.stateDir + "/config.json"), 0o600); XCTAssertEqual(mode(fixture.stateDir + "/saved-models.json"), 0o600)
        // Choosing models in the list works both ways, and the local one is untouched.
        _ = try await backend.switchTo(key: try localKey(backend))
        let back = try await backend.status()
        XCTAssertEqual(back.config.model.kind, "local"); XCTAssertFalse(back.cloud.selected); XCTAssertEqual(back.runtime.kind, "local")
        XCTAssertEqual(back.cloud.localModelName, "Fixture model")
    }

    func testCloudAddressesAreCheckedWhenSaving() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        for endpoint in ["http://api.cloud-test.com/v1", "https://127.0.0.1/v1", "https://localhost/v1", "https://user:pw@api.cloud-test.com/v1", "https://10.0.0.1/v1"] {
            do { try await addCloud(backend, endpoint: endpoint); XCTFail(endpoint) } catch {}
        }
        do { try await addCloud(backend, key: ""); XCTFail("no key") } catch { assertMatch(messageOf(error), "API key") }
        XCTAssertEqual(try backend.configStore.read().model.source, "gguf")
        // A local server still refuses a remote address.
        do { _ = try await backend.saveSetup(["model": ["source": "server", "endpoint": .string("https://\(host)/v1"), "id": "x"]]); XCTFail() } catch {}
    }

    func testFindingModelsUsesTheTypedKeyAndTheSavedKeyOnlyForTheSameHost() async throws {
        let fixture = try BackendFixture(self)
        let seen = ServerRequests()
        fixture.fetch = { request in
            seen.add(request)
            return (Data(#"{"data":[{"id":"big-model"}]}"#.utf8), response(request.url!))
        }
        let backend = try await make(fixture)
        try await addCloud(backend)
        _ = try await backend.discoverCloud(endpoint: "https://\(host)/v1")
        XCTAssertEqual(seen.list[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        _ = try await backend.discoverCloud(endpoint: "https://other.cloud-test.com/v1", apiKey: "typed-key-abcdef")
        XCTAssertEqual(seen.list[1].value(forHTTPHeaderField: "Authorization"), "Bearer typed-key-abcdef")
        // Another host without a typed key: the saved key is not used there.
        do { _ = try await backend.discoverCloud(endpoint: "https://other.cloud-test.com/v1"); XCTFail() } catch { assertMatch(messageOf(error), "API key") }
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(seen.list.compactMap { $0.value(forHTTPHeaderField: "Authorization") }.first { $0.contains(secret) && ($0 != "Bearer \(secret)") })
    }

    // MARK: Rule 9: the key

    func testTheKeyIsClearedWhenTheHostChangesAndNeverCrossesFromALocalServer() async throws {
        let fixture = try BackendFixture(self, server: true)
        let backend = try await make(fixture)
        // The local server's key does not become the cloud key.
        do { _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": .string("https://\(host)/v1"), "id": "big", "name": "Cloud Big"]]); XCTFail() }
        catch { assertMatch(messageOf(error), "API key") }
        XCTAssertEqual(try backend.configStore.read().model.apiKey, "private-server-credential")
        try await addCloud(backend)
        XCTAssertEqual(try backend.configStore.read().model.apiKey, secret)
        // Another host with no new key: refused, and nothing changed.
        do { _ = try await backend.saveSetup(["model": ["endpoint": .string("https://other.cloud-test.com/v1")]]); XCTFail() } catch { assertMatch(messageOf(error), "API key") }
        XCTAssertEqual(try backend.configStore.read().model.endpoint, "https://\(host)/v1")
        XCTAssertEqual(try backend.configStore.read().model.apiKey, secret)
        // The same host (a different path) keeps the key.
        _ = try await backend.saveSetup(["model": ["endpoint": .string("https://\(host)/v2")]])
        XCTAssertEqual(try backend.configStore.read().model.apiKey, secret)
        // A new host with a new key uses the new key only.
        _ = try await backend.saveSetup(["model": ["endpoint": .string("https://other.cloud-test.com/v1"), "apiKey": "second-key-abcdef123456"]])
        XCTAssertEqual(try backend.configStore.read().model.apiKey, "second-key-abcdef123456")
        // And a cloud key does not become a local server key.
        _ = try await backend.saveSetup(["model": ["source": "server", "endpoint": "http://127.0.0.1:5555/v1", "id": "x", "name": "Local"]])
        XCTAssertEqual(try backend.configStore.read().model.apiKey, "")
    }

    func testTheKeyIsInNoFileButTheTwoPrivateOnesAndNoMessage() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let first = try await send(backend)
        // A service that echoes the key in its error: the key is not shown or saved.
        fixture.reply = { _ in (httpResponse(400), lines(["{\"error\":{\"message\":\"bad request near \(self.secret) here\"}}"])) }
        let failed = try await send(backend, "second", thread: first.threadId)
        let reply = lastMessage(backend, failed.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        assertMatch(reply["error"]?.string ?? "", "HTTP 400")
        XCTAssertFalse((reply["error"]?.string ?? "").contains(secret))
        let phone = try await BackendPhone(backend).phoneStatus().text()
        XCTAssertFalse(phone.contains(secret)); XCTAssertFalse(phone.contains("https://")); XCTAssertTrue(phone.contains(host))
        XCTAssertFalse((BackendPhone(backend).thread(first.threadId)?.text() ?? "").contains(secret))
        XCTAssertEqual(Set(filesHolding(secret, in: fixture.stateDir)), ["config.json", "saved-models.json"])
    }

    // MARK: Rule 2: every conversation has a level

    func testANewCloudConversationSaysWhatLeavesBeforeTheFirstSendAndRecordsItsLevel() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        XCTAssertEqual(backend.privacyCheck(threadId: nil, project: nil).outcome, .allowed)
        try await addCloud(backend)
        let chat = backend.privacyCheck(threadId: nil, project: nil, kind: "chat")
        XCTAssertEqual(chat.outcome, .startsCloud)
        XCTAssertEqual(chat.provider, host)
        assertMatch(chat.message, "leaves \(Place.this)"); assertMatch(chat.message, "your messages"); assertMatch(chat.message, "Memory is not used in cloud conversations")
        let code = backend.privacyCheck(threadId: nil, project: nil, kind: "agent")
        assertMatch(code.message, "the contents of any file the agent reads and the output of any command it runs")
        let sent = try await send(backend)
        let thread = try XCTUnwrap(backend.thread(sent.threadId))
        XCTAssertEqual(thread["privacy"], "cloud"); XCTAssertEqual(thread["provider"], .string(host))
        XCTAssertEqual(backend.threads().first { $0.id == sent.threadId }?.privacy, "cloud")
        XCTAssertEqual(backend.threads().first { $0.id == sent.threadId }?.provider, host)
        XCTAssertEqual(backend.history.get(sent.threadId)?["privacy"], "cloud")
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "done")
        // A local conversation says so too.
        _ = try await backend.switchTo(key: try localKey(backend))
        let local = try await send(backend, "hello")
        XCTAssertEqual(backend.thread(local.threadId)?["privacy"], "local")
        XCTAssertNil(backend.thread(local.threadId)?["provider"])
    }

    // MARK: Rule 3: local never silently becomes cloud

    func testAMessageInALocalConversationIsRefusedWithACloudModelSelectedAndConversionNeedsTheServiceNamed() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        let local = try await send(backend, "where is my umbrella")
        XCTAssertNotNil(backend.history.get(local.threadId)?["core"])
        XCTAssertNotNil(backend.history.get(local.threadId)?["messages"]?[0]?["recalled"])
        try await addCloud(backend)
        let before = fixture.requests.count
        XCTAssertThrowsError(try backend.submit(message: "and now?", requestId: newID(), threadId: local.threadId)) {
            let text = messageOf($0)
            assertMatch(text, "private to \(Place.this)"); assertMatch(text, "Cloud Big"); assertMatch(text, "Start a new cloud conversation")
            assertMatch(text, "switch back to Fixture model"); assertMatch(text, "send this conversation to \(host)")
        }
        XCTAssertEqual(fixture.requests.count, before)
        XCTAssertEqual(backend.history.get(local.threadId)?["messages"]?.array?.count, 2)
        let check = backend.privacyCheck(threadId: local.threadId, project: nil)
        XCTAssertEqual(check.outcome, .needsChoice)
        XCTAssertEqual(check.localModelName, "Fixture model"); XCTAssertEqual(check.provider, host)
        assertMatch(check.convertWarning, "Everything in it so far will be sent to \(host)")
        // Conversion needs the service named; nothing is sent by it.
        XCTAssertThrowsError(try backend.convertToCloud(threadId: local.threadId, confirmingProvider: "")) { assertMatch(messageOf($0), "Confirm which service") }
        XCTAssertThrowsError(try backend.convertToCloud(threadId: local.threadId, confirmingProvider: "other.cloud-test.com"))
        XCTAssertEqual(backend.history.get(local.threadId)?["privacy"], "local")
        try backend.convertToCloud(threadId: local.threadId, confirmingProvider: host)
        let converted = try XCTUnwrap(backend.history.get(local.threadId))
        XCTAssertEqual(converted["privacy"], "cloud"); XCTAssertEqual(converted["provider"], .string(host))
        // The vault's contents that had been put into it are gone: Core, and the recalled lines.
        XCTAssertNil(converted["core"])
        XCTAssertFalse(converted.text().contains("Vault-Secret"))
        XCTAssertEqual(fixture.requests.count, before)
        // Now it may continue, and what is sent has no vault in it.
        try await send(backend, "and now?", thread: local.threadId)
        let body = fixture.requests.body(fixture.requests.count - 1).text()
        XCTAssertFalse(body.contains("Vault-Secret")); XCTAssertTrue(body.contains("big-model"))
        XCTAssertEqual(fixture.runtime.starts, 1)
    }

    func testACloudConversationContinuedWithALocalModelStaysCloudAndGetsNoMemory() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let cloud = try await send(backend, "where is my umbrella")
        _ = try await backend.switchTo(key: try localKey(backend))
        XCTAssertEqual(backend.privacyCheck(threadId: cloud.threadId, project: nil).outcome, .allowed)
        fixture.reply = { _ in sse(answerStream) }
        try await send(backend, "still about the umbrella", thread: cloud.threadId)
        XCTAssertEqual(fixture.runtime.starts, 1)
        XCTAssertEqual(backend.thread(cloud.threadId)?["privacy"], "cloud")
        let local = fixture.requests.body(fixture.requests.count - 1)
        XCTAssertFalse(local.text().contains("Vault-Secret"))
        XCTAssertNil(backend.history.get(cloud.threadId)?["core"])
    }

    func testAConversationSentToOneServiceIsRefusedForAnotherUntilConverted() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let first = try await send(backend)
        try await addCloud(backend, endpoint: "https://second.cloud-test.com/v1", key: "second-key-abcdef123456", name: "Second")
        XCTAssertThrowsError(try backend.submit(message: "again", requestId: newID(), threadId: first.threadId)) {
            assertMatch(messageOf($0), "was sent to \(host)"); assertMatch(messageOf($0), "second.cloud-test.com")
        }
        try backend.convertToCloud(threadId: first.threadId, confirmingProvider: "second.cloud-test.com")
        try await send(backend, "again", thread: first.threadId)
        XCTAssertEqual(backend.thread(first.threadId)?["provider"], "second.cloud-test.com")
        XCTAssertEqual(lastMessage(backend, first.threadId)["state"]?.string, "done")
    }

    // MARK: Rule 4: projects

    func testAProjectIsLocalOnlyUntilCloudModelsAreAllowedAndTheChoiceIsKept() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        let project = try backend.createProject(name: "Secret Work")
        XCTAssertFalse(project.cloudAllowed)
        let local = try await send(backend, "inside", project: project.id)
        try await addCloud(backend)
        XCTAssertEqual(backend.privacyCheck(threadId: nil, project: project.id).outcome, .projectLocalOnly)
        XCTAssertThrowsError(try backend.submit(message: "no", requestId: newID(), project: project.id)) {
            assertMatch(messageOf($0), "local only"); assertMatch(messageOf($0), "Allow cloud models")
        }
        XCTAssertThrowsError(try backend.submit(message: "no", requestId: newID(), threadId: local.threadId))
        XCTAssertThrowsError(try backend.convertToCloud(threadId: local.threadId, confirmingProvider: host)) { assertMatch(messageOf($0), "local only") }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertThrowsError(try backend.setProjectCloud(project.id, allowed: true)) { assertMatch(messageOf($0), "Confirm") }
        XCTAssertFalse(try XCTUnwrap(backend.projectList().first).cloudAllowed)
        // Allowed on purpose, once.
        XCTAssertTrue(try backend.setProjectCloud(project.id, allowed: true, confirmed: true).cloudAllowed)
        XCTAssertTrue(String(decoding: try Data(contentsOf: URL(fileURLWithPath: fixture.stateDir + "/projects.json")), as: UTF8.self).contains("\"cloud\":true"))
        let inside = try await send(backend, "now allowed", project: project.id)
        XCTAssertEqual(backend.thread(inside.threadId)?["privacy"], "cloud")
        await backend.shutdown()
        XCTAssertTrue(try fixture.make().projectList().first?.cloudAllowed == true)
        XCTAssertTrue(try fixture.make().setProjectCloud(project.id, allowed: false).cloudAllowed == false)
        XCTAssertThrowsError(try backend.setProjectCloud("00000000-0000-0000-0000-000000000000", allowed: false))
    }

    // MARK: Rule 5: memory stays local

    func testNoVaultContentIsInAnyCloudChatRequest() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        XCTAssertTrue(backend.memory.core().contains("Vault-Secret-Alpha"))
        try await addCloud(backend)
        let sent = try await send(backend, "where is my umbrella")
        XCTAssertEqual(fixture.requests.count, 1)
        let body = fixture.requests.body(0)
        XCTAssertFalse(body.text().contains("Vault-Secret"))
        XCTAssertFalse(body.text().contains("From your memory"))
        XCTAssertEqual(body["messages"]?[0]?["content"]?.string, ChatStream.CLOUD_SYSTEM)
        XCTAssertNil(backend.history.get(sent.threadId)?["core"])
        XCTAssertNil(backend.history.get(sent.threadId)?["messages"]?[0]?["recalled"])
        XCTAssertEqual(fixture.runtime.starts, 0)
        XCTAssertEqual(fixture.runtime.busy, [])
        // The request went to the cloud host with the key, and nowhere else.
        XCTAssertEqual(fixture.requests.list[0].url?.absoluteString, "https://\(host)/v1/chat/completions")
        XCTAssertEqual(fixture.requests.list[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
    }

    func testCodeWithACloudModelHasNoMemoryToolsNoCoreAndWritesNoJournal() async throws {
        let fixture = try BackendFixture(self)
        let seen = Seen()
        let script = fakeModel([Step(text: "Done locally."), Step(text: "Done in the cloud.")], seen: seen)
        fixture.reply = script
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        try vault.write("Core", "# Core\n\n\(vaultCore)\n")
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, vault: vault, fetch: { try await script($0) }, home: fixture.files.dir, useRtk: false)
        fixture.memory = vault
        try fixture.rewriteConfig { $0.model.context = 65536 }
        let backend = try fixture.make()
        // A local Code turn does get memory: the tools, the Core note, and a journal entry.
        let notesBefore = vault.notes().count
        let localRun = try await send(backend, "Tidy up", kind: "agent")
        XCTAssertEqual(lastMessage(backend, localRun.threadId)["state"]?.string, "done", lastMessage(backend, localRun.threadId)["error"]?.string ?? "")
        guard seen.count == 1 else { return XCTFail("expected one request, saw \(seen.count)") }
        let localTools = seen[0]["tools"]?.array?.compactMap { $0["function"]?["name"]?.string } ?? []
        XCTAssertTrue(localTools.contains("remember") && localTools.contains("recall"))
        XCTAssertTrue(seen[0].text().contains("Vault-Secret-Alpha"))
        let notesAfterLocal = vault.notes().count
        XCTAssertGreaterThan(notesAfterLocal, notesBefore)
        // A cloud Code turn gets none of it.
        try await addCloud(backend)
        let cloud = try await send(backend, "Tidy up in the cloud", kind: "agent")
        XCTAssertEqual(lastMessage(backend, cloud.threadId)["state"]?.string, "done", lastMessage(backend, cloud.threadId)["error"]?.string ?? "")
        guard seen.count == 2 else { return XCTFail("expected two requests, saw \(seen.count)") }
        let body = seen[1]
        let tools = body["tools"]?.array?.compactMap { $0["function"]?["name"]?.string } ?? []
        XCTAssertFalse(tools.isEmpty)
        XCTAssertFalse(tools.contains("remember")); XCTAssertFalse(tools.contains("recall"))
        XCTAssertFalse(body.text().contains("Vault-Secret")); XCTAssertFalse(body.text().contains("memory that lasts"))
        XCTAssertEqual(vault.notes().count, notesAfterLocal)          // no journal entry from a cloud turn
        XCTAssertEqual(lastMessage(backend, cloud.threadId)["state"]?.string, "done")
        XCTAssertEqual(lastMessage(backend, cloud.threadId)["content"]?.string, "Done in the cloud.")
        XCTAssertEqual(backend.thread(cloud.threadId)?["privacy"], "cloud")
    }

    func testConvertingALocalCodeConversationTakesRecallResultsOutOfWhatTheEngineWouldSend() async throws {
        let fixture = try BackendFixture(self)
        let seen = Seen()
        let script = fakeModel([
            Step(calls: [("recall", ["query": "umbrella"])]), Step(text: "Found it."), Step(text: "Continuing in the cloud."),
        ], seen: seen)
        fixture.reply = script
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        try vault.write("Core", "# Core\n\n\(vaultCore)\n")
        try vault.remember("Umbrella", vaultNote)
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, vault: vault, fetch: { try await script($0) }, home: fixture.files.dir, useRtk: false)
        fixture.memory = vault
        try fixture.rewriteConfig { $0.model.context = 65536 }
        let backend = try fixture.make()
        let local = try await send(backend, "Find my umbrella note", kind: "agent")
        XCTAssertEqual(lastMessage(backend, local.threadId)["state"]?.string, "done", lastMessage(backend, local.threadId)["error"]?.string ?? "")
        guard seen.count == 2 else { return XCTFail("expected two requests, saw \(seen.count)") }
        XCTAssertTrue(seen[1].text().contains("Vault-Secret-Beta"))     // the recall result reached the local model
        try await addCloud(backend)
        try backend.convertToCloud(threadId: local.threadId, confirmingProvider: host)
        try await send(backend, "Continue", kind: "agent", thread: local.threadId)
        XCTAssertEqual(seen.count, 3)
        let last = seen[seen.count - 1]
        XCTAssertFalse(last.text().contains("Vault-Secret"))
        XCTAssertTrue(last.text().contains("Memory result removed"))
    }

    func testTidyingMemoryNeverSendsNotesToACloudService() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try backend.memory.write("Huge", "# Huge\n\n" + String(repeating: "A long line of text. ", count: 600))
        XCTAssertFalse(backend.memory.usage().oversized.isEmpty)
        try await addCloud(backend)
        let message = await backend.memoryTidy()
        assertMatch(message, "local model")
        XCTAssertEqual(fixture.requests.count, 0); XCTAssertEqual(fixture.runtime.starts, 0)
    }

    // MARK: Rule 6: phone

    func testAPhoneContinuesConversationsButNeverStartsOrConvertsToCloudAndIsRefusedLikeTheMac() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        let phone = BackendPhone(backend)
        let local = try await send(backend, "from the mac")
        try await addCloud(backend)
        // A phone into a local conversation while the Mac has a cloud model selected: the same refusal as the Mac's.
        var macMessage = "", phoneMessage = ""
        do { _ = try backend.submit(message: "x", requestId: newID(), threadId: local.threadId) } catch { macMessage = messageOf(error) }
        do { _ = try phone.submit(message: "x", kind: "chat", mode: "balanced", requestId: newID(), threadId: local.threadId, project: nil) } catch { phoneMessage = messageOf(error) }
        XCTAssertFalse(macMessage.isEmpty); XCTAssertEqual(phoneMessage, macMessage)
        // A phone does not start a cloud conversation.
        XCTAssertThrowsError(try phone.submit(message: "new", kind: "chat", mode: "balanced", requestId: newID(), threadId: nil, project: nil)) {
            assertMatch(messageOf($0), "decision made at \(Place.the)")
        }
        XCTAssertEqual(backend.privacyCheck(threadId: nil, project: nil, viaPhone: true).outcome, .phoneNeedsMac)
        XCTAssertEqual(fixture.requests.count, 1)
        // It may continue a cloud conversation the Mac started. There is no phone route for conversion or model selection.
        let cloud = try await send(backend, "mac cloud")
        let result = try phone.submit(message: "from the phone", kind: "chat", mode: "balanced", requestId: newID(), threadId: cloud.threadId, project: nil)
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, result.threadId)["state"]?.string, "done")
        XCTAssertEqual(backend.thread(cloud.threadId)?["messages"]?.array?.count, 4)
        // And it may continue a local conversation while the Mac has a local model selected.
        _ = try await backend.switchTo(key: try localKey(backend))
        fixture.reply = { _ in sse(answerStream) }
        _ = try phone.submit(message: "local again", kind: "chat", mode: "balanced", requestId: newID(), threadId: local.threadId, project: nil)
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, local.threadId)["state"]?.string, "done")
    }

    // MARK: Rule 7: the request

    func testACloudChatRequestCarriesStandardFieldsOnlyAtEveryPace() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let standard: Set<String> = ["model", "messages", "stream", "stream_options", "max_tokens", "temperature", "reasoning_effort"]
        var thread: String?
        for pace in ["fast", "balanced", "deep", "extended"] {
            let sent = try backend.submit(message: "pace \(pace)", mode: pace, requestId: newID(), threadId: thread)
            await backend.waitForIdle()
            thread = sent.threadId
            let body = fixture.requests.body(fixture.requests.count - 1)
            XCTAssertTrue(Set(body.object!.keys).isSubset(of: standard), "\(pace): \(body.object!.keys.sorted())")
            XCTAssertEqual(body["reasoning_effort"] != nil, pace != "fast", pace)
            for banned in ["chat_template_kwargs", "thinking_budget_tokens", "cache_prompt", "timings_per_token"] { XCTAssertNil(body[banned], banned) }
            XCTAssertEqual(body["stream_options"]?["include_usage"], true)
        }
        XCTAssertEqual(fixture.requests.body(0)["model"], "big-model")
    }

    func testAServiceThatRefusesFieldsTeachesBlackTeamOnceAndItIsRemembered() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let count = Counter()
        let stream = usageStream
        fixture.reply = { request in
            let body = try JSONValue.parse(request.httpBody ?? Data())
            _ = count.next()
            if body["temperature"] != nil {
                return (httpResponse(400), lines(["{\"error\":{\"message\":\"Unsupported value: 'temperature' does not support 0.7 with this model.\",\"param\":\"temperature\"}}"]))
            }
            if body["max_tokens"] != nil {
                return (httpResponse(400), lines(["{\"error\":{\"message\":\"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.\",\"param\":\"max_tokens\"}}"]))
            }
            return sse(stream)
        }
        let first = try await send(backend, "hello")
        XCTAssertEqual(lastMessage(backend, first.threadId)["state"]?.string, "done")
        let bodies = (0..<fixture.requests.count).map { fixture.requests.body($0) }
        XCTAssertEqual(bodies.count, 3)                                 // the question, then one retry for each lesson
        XCTAssertNotNil(bodies[0]["temperature"]); XCTAssertNil(bodies[1]["temperature"]); XCTAssertNotNil(bodies[1]["max_tokens"])
        XCTAssertNil(bodies[2]["temperature"]); XCTAssertNil(bodies[2]["max_tokens"]); XCTAssertEqual(bodies[2]["max_completion_tokens"]?.int, 2048)
        // Remembered for this service and model: the next message is sent right the first time.
        try await send(backend, "again", thread: first.threadId)
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertNil(fixture.requests.body(3)["temperature"]); XCTAssertNil(fixture.requests.body(3)["max_tokens"])
        XCTAssertEqual(CloudCapabilities(dataFolder: fixture.stateDir).caps(host: host, model: "big-model"), CloudCaps(rejected: ["temperature"], maxTokensField: "max_completion_tokens"))
        // A 400 that names no field is shown, not retried forever.
        fixture.reply = { _ in (httpResponse(400), lines(["{\"error\":{\"message\":\"Your account is out of credit\"}}"])) }
        let failed = try await send(backend, "no credit", thread: first.threadId)
        assertMatch(lastMessage(backend, failed.threadId)["error"]?.string ?? "", "out of credit")
    }

    func testEveryStatusTheServiceCanReturnIsExplainedPlainly() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        var thread: String?
        for (status, expected) in [(401, "refused the API key"), (404, "does not know this model"), (429, "limiting requests"), (503, "had a problem")] {
            fixture.reply = { _ in (httpResponse(status), lines(["{\"error\":{\"message\":\"detail \(self.secret)\"}}"])) }
            let sent = try await send(backend, "try \(status)", thread: thread)
            thread = sent.threadId
            let error = lastMessage(backend, sent.threadId)["error"]?.string ?? ""
            assertMatch(error, expected); XCTAssertFalse(error.contains(secret)); assertMatch(error, host)
        }
    }

    // MARK: Rule 8: usage

    func testTokenUsageIsAddedUpPerCloudConversation() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        let first = try await send(backend, "one")
        XCTAssertEqual(CloudUsage(json: backend.thread(first.threadId)?["usage"]), CloudUsage(prompt: 12480, completion: 1930, cached: 2000))
        XCTAssertEqual(CloudUsage(json: lastMessage(backend, first.threadId)["usage"]), CloudUsage(prompt: 12480, completion: 1930, cached: 2000))
        XCTAssertNil(lastMessage(backend, first.threadId)["meter"])
        try await send(backend, "two", thread: first.threadId)
        XCTAssertEqual(CloudUsage(json: backend.thread(first.threadId)?["usage"]), CloudUsage(prompt: 24960, completion: 3860, cached: 4000))
        // A local conversation has no usage line.
        _ = try await backend.switchTo(key: try localKey(backend))
        fixture.reply = { _ in sse(timedStream) }
        let local = try await send(backend, "local")
        XCTAssertNil(backend.thread(local.threadId)?["usage"])
        XCTAssertNotNil(lastMessage(backend, local.threadId)["meter"])
    }

    func testCodeRecordsUsageAndBudgetsForACloudModelAreNotRationedByReadingSpeed() async throws {
        let fixture = try BackendFixture(self)
        let seen = Seen()
        let script = fakeModel([Step(text: "ok", prompt: 700), Step(text: "ok again", prompt: 900)], seen: seen)
        fixture.reply = script
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, fetch: { try await script($0) }, home: fixture.files.dir, useRtk: false)
        let backend = try fixture.make()
        try await addCloud(backend, context: 200_000)
        let sent = try await send(backend, "go", kind: "agent")
        try await send(backend, "go on", kind: "agent", thread: sent.threadId)
        XCTAssertEqual(CloudUsage(json: backend.thread(sent.threadId)?["usage"]), CloudUsage(prompt: 1600, completion: 40, cached: 0))
        let note = lastMessage(backend, sent.threadId)["events"]?.array?.first?["output"]?.string ?? ""
        assertMatch(note, "working budget 120,000 of 200,000 tokens"); assertMatch(note, "memory is not used")
        // No local calibration was learned from a cloud model.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateDir + "/engine/models.json"))
        // The body is standard only.
        let standard: Set<String> = ["model", "messages", "stream", "stream_options", "max_tokens", "temperature", "reasoning_effort", "tools", "tool_choice"]
        XCTAssertTrue(Set(seen[0].object!.keys).isSubset(of: standard), "\(seen[0].object!.keys.sorted())")
        XCTAssertEqual(seen[0]["tool_choice"], "auto"); XCTAssertEqual(seen[0]["model"], "big-model")
    }

    func testCodeLearnsFrom400AndRemembersIt() async throws {
        let fixture = try BackendFixture(self)
        let seen = Seen()
        let ok = fakeModel([Step(text: "done"), Step(text: "done again")], seen: seen)
        let calls = Counter()
        let script: HTTPStreamFetch = { request in
            let body = try JSONValue.parse(request.httpBody ?? Data())
            if body["temperature"] != nil {
                _ = calls.next()
                return (httpResponse(400), lines(["[{\"error\":{\"code\":400,\"message\":\"temperature must be 1 for this model\",\"status\":\"INVALID_ARGUMENT\"}}]"]))
            }
            return try await ok(request)
        }
        fixture.reply = script
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, fetch: script, home: fixture.files.dir, useRtk: false)
        let backend = try fixture.make()
        try await addCloud(backend)
        let sent = try await send(backend, "go", kind: "agent")
        XCTAssertEqual(lastMessage(backend, sent.threadId)["state"]?.string, "done")
        XCTAssertEqual(calls.next(), 1)
        XCTAssertNil(seen[0]["temperature"])
        try await send(backend, "again", kind: "agent", thread: sent.threadId)
        XCTAssertEqual(calls.next(), 2)                                   // asked once more? no: remembered, so no further refusal
    }

    // MARK: Rule 10: honesty about harnesses and starting

    func testHarnessesAreNotLaunchedAgainstACloudModelAndNothingIsStarted() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await addCloud(backend)
        do { _ = try await backend.launch(harness: "claude"); XCTFail() }
        catch { XCTAssertEqual(messageOf(error), "Agent apps use your local model. Select a local model to launch one.") }
        let summary = try await backend.startModel()
        XCTAssertEqual(summary.kind, "cloud")
        XCTAssertEqual(fixture.runtime.starts, 0)
    }
}
