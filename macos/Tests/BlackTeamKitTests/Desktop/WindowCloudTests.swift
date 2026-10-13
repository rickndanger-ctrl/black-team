import XCTest
@testable import BlackTeamKit

// Cloud models through the desktop window's surface: the control channel's actions and the HTTP routes, with the network stubbed.
// Each privacy refusal below also holds for a paired phone, tested at the end.
final class WindowCloudTests: XCTestCase {
    // MARK: Setting up

    func testDiscoveringAServiceListsModelsAndWhichAreFree() async throws {
        let r = try await WindowRig(self)
        let found = try await r.result("cloud-discover", ["endpoint": r.address, "apiKey": .string(r.secret)])
        XCTAssertEqual(found["host"]?.string, r.host)
        XCTAssertEqual(found["endpoint"]?.string, "https://\(r.host)/v1")
        let models = try XCTUnwrap(found["models"]?.array)
        XCTAssertEqual(models.map { $0["id"]?.string }, ["vendor/paid-model", "vendor/free-agent:free", "vendor/free-chat:free"])
        XCTAssertEqual(models.map { $0["free"]?.bool }, [false, true, true])
        XCTAssertEqual(models.map { $0["freeAgent"]?.bool }, [false, true, false], "free and not known to lack tool calling")
        XCTAssertEqual(models[1]["context"]?.int, 131072)
        // The key went in the Authorization header to that host and nowhere else.
        let sent = r.discovery.list
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].url?.absoluteString, "https://\(r.host)/v1/models")
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(r.secret)")
        XCTAssertNil(sent[0].value(forHTTPHeaderField: "x-api-key"), "Anthropic's headers go to anthropic.com hosts only")
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    func testDiscoveringRefusesBadAddressesAndWrongKeysWithoutShowingTheKey() async throws {
        let r = try await WindowRig(self)
        await r.expectRefusal("cloud-discover", ["endpoint": .string("http://\(r.host)/v1"), "apiKey": "abcdef"], prefix: "A cloud service must use https.")
        await r.expectRefusal("cloud-discover", ["endpoint": "https://127.0.0.1/v1", "apiKey": "abcdef"], contains: "not an IP address")
        await r.expectRefusal("cloud-discover", ["endpoint": "https://localhost/v1", "apiKey": "abcdef"], contains: "needs a real host name")
        await r.expectRefusal("cloud-discover", ["endpoint": r.address], exact: "Enter the API key for this service.")
        await r.expectRefusal("cloud-discover", ["endpoint": r.address, "apiKey": 5], exact: "The server API key must contain only printable characters without spaces.")
        await r.expectRefusal("cloud-discover", ["endpoint": r.address, "extra": 1], exact: "Unsupported cloud setting.")
        let wrong = await r.refused("cloud-discover", ["endpoint": r.address, "apiKey": "sk-wrong-key-1234567890"])
        XCTAssertEqual(wrong, "\(r.host) refused the API key. Check the key and try again.")
        XCTAssertFalse(r.wire.all.contains("sk-wrong-key-1234567890"))
        // Anthropic's own headers go to anthropic.com and only there.
        _ = await r.ask("cloud-discover", ["endpoint": "https://api.anthropic.com/v1", "apiKey": "sk-ant-test-key-1234567890"])
        let anthropic = try XCTUnwrap(r.discovery.list.last { $0.url?.host == "api.anthropic.com" })
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key-1234567890")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertTrue(r.discovery.list.filter { $0.url?.host != "api.anthropic.com" }.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == nil })
    }

    func testSavingACloudModelAndWhereTheKeyLives() async throws {
        let r = try await WindowRig(self)
        let before = try await r.result("status")
        XCTAssertEqual(before["cloud"]?["selected"]?.bool, false)
        XCTAssertEqual(before["agents"]?.array?.map { $0["engine"]?.string }, ["claude-code", "codex"])
        XCTAssertEqual(before["agents"]?.array?.map { $0["installed"]?.bool }, [true, true])
        let saved = try await r.result("cloud-save", ["endpoint": r.address, "id": "big-model", "apiKey": .string(r.secret), "name": "Cloud Big", "context": 100_000])
        XCTAssertEqual(saved["saved"]?.bool, true)
        XCTAssertEqual(saved["cloud"], ["selected": true, "provider": .string(r.host), "modelName": "Cloud Big", "localModelName": "Fixture model", "localModelKey": .string(r.localKey)])
        // The window sees "Cloud · host" and a saved-model list with a kind and a provider; never the key.
        let status = try await r.result("status")
        XCTAssertEqual(status["config"]?["model"]?["kind"]?.string, "cloud")
        XCTAssertEqual(status["config"]?["model"]?["provider"]?.string, r.host)
        XCTAssertEqual(status["runtime"]?["kind"]?.string, "cloud")
        XCTAssertEqual(status["serverKeyConfigured"]?.bool, true)
        let models = try XCTUnwrap(status["models"]?.array)
        XCTAssertEqual(models.map { $0["kind"]?.string }, ["local", "cloud"])
        XCTAssertEqual(models.map { $0["provider"]?.string }, ["", r.host])
        XCTAssertEqual(models.map { $0["active"]?.bool }, [false, true])
        XCTAssertNil(models[0]["keyConfigured"]); XCTAssertEqual(models[1]["keyConfigured"]?.bool, true)
        XCTAssertFalse(status.text().contains(r.secret))
        let over = await r.desktop("GET", "/api/status")
        XCTAssertEqual(over.status, 200); XCTAssertEqual(over["access"]?.string, "desktop")
        XCTAssertFalse(over.text.contains(r.secret))

        // On disk the key is in two files of the private data folder, both 0600, and the folder is 0700.
        XCTAssertEqual(r.filesHolding(r.secret), ["config.json", "saved-models.json"])
        XCTAssertEqual(mode(r.fixture.stateDir + "/config.json"), 0o600)
        XCTAssertEqual(mode(r.fixture.stateDir + "/saved-models.json"), 0o600)
        XCTAssertEqual(mode(r.fixture.stateDir), 0o700)

        // Saving again without a key keeps it for the same host; a different host clears it, so a key goes only where it was entered for.
        _ = try await r.result("cloud-save", ["endpoint": r.address, "id": "big-model", "name": "Renamed"])
        XCTAssertEqual(try r.backend.configStore.read().model.apiKey, r.secret)
        await r.expectRefusal("cloud-save", ["endpoint": "https://other.cloud-test.com/v1", "id": "big-model", "name": "Elsewhere"], exact: "Enter the API key for this service.")
        XCTAssertEqual(try r.backend.configStore.read().model.endpoint, "https://\(r.host)/v1")
        // The address rules hold for saving too.
        await r.expectRefusal("cloud-save", ["endpoint": .string("http://\(r.host)/v1"), "id": "x", "apiKey": "abcdef"], prefix: "A cloud service must use https.")
        await r.expectRefusal("cloud-save", ["endpoint": "https://10.0.0.5/v1", "id": "x", "apiKey": "abcdef"], contains: "not an IP address")
        await r.expectRefusal("cloud-save", ["endpoint": r.address, "id": "", "apiKey": "abcdef"], exact: "Choose or type the model id of this cloud service.")
        await r.expectRefusal("cloud-save", ["endpoint": r.address, "id": "x", "apiKey": "abcdef", "source": "gguf"], exact: "Unsupported cloud setting.")
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    func testRemovingAKeyTakesItOutOfBothFiles() async throws {
        let r = try await WindowRig(self)
        try await r.addCloud()
        XCTAssertEqual(r.filesHolding(r.secret), ["config.json", "saved-models.json"])
        // The model in use cannot be removed; switch to the local model first.
        await r.expectRefusal("model-forget", ["key": .string(r.cloudKey)], exact: "This model is in use. Switch to another model before removing it.")
        try await r.useLocal()
        XCTAssertEqual(r.filesHolding(r.secret), ["saved-models.json"], "the key left config.json when the local model took its place")
        let removed = try await r.result("model-forget", ["key": .string(r.cloudKey)])
        XCTAssertEqual(removed["removed"]?.bool, true)
        XCTAssertEqual(r.filesHolding(r.secret), [])
        let status = try await r.result("status")
        XCTAssertEqual(status["models"]?.array?.map { $0["kind"]?.string }, ["local"])
        XCTAssertEqual(status["serverKeyConfigured"]?.bool, false, "no key is held for the model in use any more")
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    // MARK: Conversations that would leave

    func testANewCloudConversationNamesWhatLeavesThenRunsAndKeepsTheVaultOut() async throws {
        let r = try await WindowRig(self)
        try await r.addCloud()
        let check = await r.desktop("GET", "/api/privacy?kind=chat")
        XCTAssertEqual(check.status, 200)
        XCTAssertEqual(check["outcome"]?.string, "startsCloud"); XCTAssertEqual(check["refused"]?.bool, false)
        XCTAssertEqual(check["provider"]?.string, r.host); XCTAssertEqual(check["modelName"]?.string, "Cloud Big")
        XCTAssertEqual(check["willLeave"]?.array?.compactMap { $0.string }, ["your messages, and any pictures you attach"])
        XCTAssertEqual(check["message"]?.string, "This conversation leaves \(Place.this). It is sent to \(r.host), which you chose for it: your messages, and any pictures you attach. Memory is not used in cloud conversations.")

        let sent = await r.chat()
        XCTAssertEqual(sent.status, 202, sent.text)
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        let view = await r.desktop("GET", "/api/thread/\(threadId)")
        XCTAssertEqual(view.status, 200)
        XCTAssertEqual(view["privacy"]?.string, "cloud"); XCTAssertEqual(view["provider"]?.string, r.host)
        XCTAssertEqual(view["usage"]?["prompt"]?.int, 12480); XCTAssertEqual(view["usage"]?["completion"]?.int, 1930)
        XCTAssertEqual(view["messages"]?.array?.last?["content"]?.string, "Cloud answer")
        // Only the cloud host got the request, with the key, and nothing from the vault went with it.
        let cloud = r.requests.list.filter { $0.url?.host == r.host }
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud[0].url?.absoluteString, "https://\(r.host)/v1/chat/completions")
        XCTAssertEqual(cloud[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(r.secret)")
        XCTAssertEqual(r.requests.count, 1, "no local server was asked")
        XCTAssertFalse(r.requestText.contains("Vault-Secret"))
        XCTAssertEqual(r.thread(threadId)["core"], nil)
        // Nothing was written to the vault from it.
        XCTAssertFalse(r.filesHolding("Cloud answer").contains { $0.hasPrefix("vault/") })
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    func testALocalConversationIsNeverSentToTheCloudWithoutAConfirmationThatNamesTheService() async throws {
        let r = try await WindowRig(self)
        // A private conversation with the local model, which has used the vault.
        let first = await r.chat("my private plans")
        XCTAssertEqual(first.status, 202)
        let threadId = try XCTUnwrap(first["threadId"]?.string)
        XCTAssertEqual(r.thread(threadId)["privacy"]?.string, "local")
        // Now a cloud model is selected.
        try await r.addCloud()
        let check = await r.desktop("GET", "/api/privacy?threadId=\(threadId)&kind=chat")
        XCTAssertEqual(check["outcome"]?.string, "needsChoice"); XCTAssertEqual(check["refused"]?.bool, true)
        XCTAssertEqual(check["message"]?.string, "This conversation is private to \(Place.this), and Cloud Big is a cloud model that would send it to \(r.host). "
            + "Nothing in a private conversation is sent off \(Place.this) without your say-so. "
            + "Start a new cloud conversation, switch back to Fixture model, or send this conversation to \(r.host).")
        XCTAssertEqual(check["localModelName"]?.string, "Fixture model"); XCTAssertEqual(check["localModelKey"]?.string, r.localKey)
        XCTAssertEqual(check["convertWarning"]?.string, "Send this conversation to \(r.host)? Everything in it so far will be sent to \(r.host) with your next message: all your messages and the replies. "
            + "The conversation stays marked as having left \(Place.this), even if you later continue it with a local model.")
        // The send itself is refused with the same words, and nothing leaves.
        let refused = await r.chat("and now?", ["threadId": .string(threadId)], wait: false)
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(refused.error, check["message"]?.string)
        XCTAssertEqual(r.requests.list.filter { $0.url?.host == r.host }.count, 0)
        // Converting needs the service's name; a wrong one changes nothing.
        let wrong = await r.desktop("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": "openai.com"])
        XCTAssertEqual(wrong.status, 400)
        XCTAssertEqual(wrong.error, "Confirm which service this conversation will be sent to (\(r.host)) before it is converted.")
        XCTAssertEqual(r.thread(threadId)["privacy"]?.string, "local")
        let converted = await r.desktop("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": .string(r.host)])
        XCTAssertEqual(converted.status, 200, converted.text)
        XCTAssertEqual(converted["converted"]?.bool, true)
        XCTAssertEqual(converted["thread"]?["privacy"]?.string, "cloud"); XCTAssertEqual(converted["thread"]?["provider"]?.string, r.host)
        XCTAssertEqual(r.thread(threadId)["core"], nil, "the vault's Core is taken out of a converted conversation")
        let after = await r.desktop("GET", "/api/privacy?threadId=\(threadId)&kind=chat")
        XCTAssertEqual(after["outcome"]?.string, "allowed")
        let sent = await r.chat("and now?", ["threadId": .string(threadId)])
        XCTAssertEqual(sent.status, 202, sent.text)
        XCTAssertFalse(r.requestText.split(separator: "\n").filter { $0.contains("api.cloud-test.com") }.joined().contains("Vault-Secret"))
        // A cloud conversation continued with a local model stays marked cloud and runs locally.
        try await r.useLocal()
        let local = await r.chat("one more", ["threadId": .string(threadId)])
        XCTAssertEqual(local.status, 202)
        XCTAssertEqual(r.thread(threadId)["privacy"]?.string, "cloud")
    }

    func testAProjectIsLocalOnlyUntilCloudIsAllowedInIt() async throws {
        let r = try await WindowRig(self)
        try await r.addCloud()
        let project = try await r.project("Secrets")
        let status = try await r.result("status")
        XCTAssertEqual(status["projects"]?.array?.first?["cloudAllowed"]?.bool, false)
        let check = await r.desktop("GET", "/api/privacy?project=\(project.id)&kind=chat")
        XCTAssertEqual(check["outcome"]?.string, "projectLocalOnly")
        XCTAssertEqual(check["message"]?.string, "The project Secrets is local only, so the cloud model Cloud Big is not used for conversations in it. "
            + "To change that, choose \u{201C}Allow cloud models\u{201D} in the project\u{2019}s menu, or select a local model.")
        let refused = await r.chat("hi", ["project": .string(project.id)], wait: false)
        XCTAssertEqual(refused.status, 400); XCTAssertEqual(refused.error, check["message"]?.string)
        // Allowing needs the person's confirmation, once.
        await r.expectRefusal("project-cloud", ["id": .string(project.id), "allowed": true], exact: "Confirm that conversations in this project may use cloud models.")
        await r.expectRefusal("project-cloud", ["id": .string(newID()), "allowed": true, "confirmed": true], exact: "That project no longer exists.")
        let allowed = try await r.result("project-cloud", ["id": .string(project.id), "allowed": true, "confirmed": true])
        XCTAssertEqual(allowed["cloudAllowed"]?.bool, true)
        let sent = await r.chat("hi", ["project": .string(project.id)])
        XCTAssertEqual(sent.status, 202, sent.text)
        let back = try await r.result("project-cloud", ["id": .string(project.id), "allowed": false])
        XCTAssertEqual(back["cloudAllowed"]?.bool, false)
    }

    // MARK: A phone

    func testAPhoneCannotSetUpCloudModelsOrKeys() async throws {
        let r = try await WindowRig(self)
        let form: JSONValue = ["endpoint": r.address, "id": "big-model", "apiKey": .string(r.secret), "name": "Cloud Big"]
        for action in ["cloud-save", "cloud-discover", "model-switch", "model-forget", "setup-save"] {
            do { _ = try await r.control.handle(action, form, access: .phone); XCTFail("\(action) must be refused for a phone") }
            catch { XCTAssertEqual(messageOf(error), DesktopRefusal.desktopOnly, action) }
        }
        XCTAssertEqual(r.discovery.count, 0, "nothing was asked of any service")
        XCTAssertEqual(r.filesHolding(r.secret), [])
        XCTAssertEqual(try r.backend.configStore.read().model.source, "gguf")
        XCTAssertEqual(r.backend.savedModels.list().filter(\.isCloud).count, 0)
        // And no HTTP route exists for any of it.
        for path in ["/api/cloud-save", "/api/cloud-discover", "/api/cloud", "/api/setup", "/api/model", "/api/models"] {
            let answer = await r.phone("POST", path, form)
            XCTAssertEqual(answer.status, 404, path)
        }
        XCTAssertEqual(r.filesHolding(r.secret), [])
        // The desktop is allowed.
        try await r.addCloud()
        XCTAssertEqual(r.backend.savedModels.list().filter(\.isCloud).count, 1)
    }

    func testAPhoneCannotStartOrConvertACloudConversation() async throws {
        let r = try await WindowRig(self)
        // A private conversation started at the desktop with the local model.
        let local = await r.chat("my private plans")
        let threadId = try XCTUnwrap(local["threadId"]?.string)
        try await r.addCloud()
        let before = r.backend.threads().count

        // Start: a phone with a cloud model selected is refused with the gate's words, and no conversation is made.
        let start = await r.chat("hello from the phone", phone: true, wait: false)
        XCTAssertEqual(start.status, 400)
        XCTAssertEqual(start.error, "Starting a conversation with a cloud model is a decision made at \(Place.the). Open Black Team on \(Place.your) to start one, or ask there.")
        XCTAssertEqual(r.backend.threads().count, before)
        let phoneCheck = await r.phone("GET", "/api/privacy?kind=chat")
        XCTAssertEqual(phoneCheck["outcome"]?.string, "phoneNeedsMac"); XCTAssertEqual(phoneCheck["refused"]?.bool, true)
        // The desktop, in the same state, is allowed.
        let desktopStart = await r.chat("hello from the desktop")
        XCTAssertEqual(desktopStart.status, 202, desktopStart.text)

        // Convert: refused, and the conversation stays private.
        let convert = await r.phone("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": .string(r.host)])
        XCTAssertEqual(convert.status, 403); XCTAssertEqual(convert.error, DesktopRefusal.desktopOnly)
        XCTAssertEqual(r.thread(threadId)["privacy"]?.string, "local")
        // Continuing a private conversation with the cloud model selected is refused for a phone as for the desktop.
        let carry = await r.chat("more", ["threadId": .string(threadId)], phone: true, wait: false)
        XCTAssertEqual(carry.status, 400); XCTAssertTrue(carry.error.hasPrefix("This conversation is private to \(Place.this)"))
        XCTAssertEqual(r.requests.list.filter { $0.url?.host == r.host }.count, 1, "only the desktop's own send reached the service")
        // The desktop converts.
        let converted = await r.desktop("POST", "/api/privacy/convert", ["threadId": .string(threadId), "provider": .string(r.host)])
        XCTAssertEqual(converted.status, 200)
        XCTAssertFalse(r.wire.all.contains(r.secret))
    }

    func testAPhoneCannotAllowCloudInAProject() async throws {
        let r = try await WindowRig(self)
        let project = try await r.project("Secrets")
        do { _ = try await r.control.handle("project-cloud", ["id": .string(project.id), "allowed": true, "confirmed": true], access: .phone); XCTFail("a phone allowed cloud") }
        catch { XCTAssertEqual(messageOf(error), DesktopRefusal.desktopOnly) }
        let answer = await r.phone("POST", "/api/project-cloud", ["id": .string(project.id), "allowed": true, "confirmed": true])
        XCTAssertEqual(answer.status, 404)
        XCTAssertFalse(try XCTUnwrap(r.backend.projectList().first).cloudAllowed)
        // The desktop is allowed.
        _ = try await r.result("project-cloud", ["id": .string(project.id), "allowed": true, "confirmed": true])
        XCTAssertTrue(try XCTUnwrap(r.backend.projectList().first).cloudAllowed)
    }

    func testAPhonesStatusHasNoCloudDetailsAndNoKeys() async throws {
        let r = try await WindowRig(self)
        try await r.addCloud()
        let phone = await r.phone("GET", "/api/status")
        XCTAssertEqual(phone.status, 200); XCTAssertEqual(phone["access"]?.string, "phone")
        for key in ["models", "agents", "cloud", "serverKeyConfigured", "integrations"] { XCTAssertNil(phone[key], key) }
        XCTAssertFalse(phone.text.contains(r.secret))
    }
}
