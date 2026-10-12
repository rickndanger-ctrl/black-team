import XCTest
@testable import BlackTeamKit

// The gate for subscription agents (Claude Code, Codex): the same outcomes as for a cloud model, whatever model is selected.
final class BackendAgentGateTests: XCTestCase {
    let cloudTests = BackendCloudTests.helper()

    func make(_ fixture: BackendFixture) async throws -> Backend { try await cloudTests.make(fixture) }

    func testServicesNameTheirProviders() {
        XCTAssertEqual(AgentService.claudeCode.provider, "anthropic.com"); XCTAssertEqual(AgentService.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentService.codex.provider, "openai.com"); XCTAssertEqual(AgentService.codex.displayName, "Codex")
    }

    func testNewThreadAtTheMacStartsCloudEvenWithALocalModelSelected() async throws {
        let backend = try await make(try BackendFixture(self))
        let check = backend.agentPrivacyCheck(service: .claudeCode, threadId: nil, project: nil)
        XCTAssertEqual(check.outcome, .startsCloud); XCTAssertEqual(check.provider, "anthropic.com")
        XCTAssertEqual(check.willLeave, ["your messages", "the files in this project folder that the agent chooses to read", "the output of commands it runs"])
        for word in ["Claude Code", "its own tools", "maker", "memory is not used"] { XCTAssertTrue(check.message.lowercased().contains(word.lowercased()), word) }
        let granted = try backend.authorizeAgentRun(service: .codex, existing: nil, project: nil, viaPhone: false)
        XCTAssertEqual(granted.privacy, "cloud"); XCTAssertEqual(granted.provider, "openai.com")
    }

    func testNewThreadViaPhoneNeedsTheMac() async throws {
        let backend = try await make(try BackendFixture(self))
        XCTAssertEqual(backend.agentPrivacyCheck(service: .codex, threadId: nil, project: nil, viaPhone: true).outcome, .phoneNeedsMac)
        XCTAssertThrowsError(try backend.authorizeAgentRun(service: .codex, existing: nil, project: nil, viaPhone: true))
    }

    func testLocalOnlyProjectIsRefusedNamingTheAgent() async throws {
        let backend = try await make(try BackendFixture(self))
        let project = try backend.createProject(name: "Secret Work")
        let check = backend.agentPrivacyCheck(service: .codex, threadId: nil, project: project.id)
        XCTAssertEqual(check.outcome, .projectLocalOnly); XCTAssertTrue(check.message.contains("Codex"))
        XCTAssertThrowsError(try backend.authorizeAgentRun(service: .codex, existing: nil, project: Project(id: project.id, name: "Secret Work", workspace: "", created: ""), viaPhone: false)) {
            assertMatch(messageOf($0), "Codex"); assertMatch(messageOf($0), "local only")
        }
        _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true)
        XCTAssertEqual(backend.agentPrivacyCheck(service: .codex, threadId: nil, project: project.id).outcome, .startsCloud)
    }

    func testLocalThreadNeedsChoiceAndConversionNeedsTheRightName() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        let local = try await cloudTests.send(backend)
        XCTAssertEqual(backend.agentPrivacyCheck(service: .claudeCode, threadId: local.threadId, project: nil).outcome, .needsChoice)
        XCTAssertThrowsError(try backend.authorizeAgentRun(service: .claudeCode, existing: backend.history.get(local.threadId), project: nil, viaPhone: false))
        XCTAssertThrowsError(try backend.convertToCloud(threadId: local.threadId, confirmingProvider: "", agent: .claudeCode)) { assertMatch(messageOf($0), "anthropic.com") }
        XCTAssertThrowsError(try backend.convertToCloud(threadId: local.threadId, confirmingProvider: "openai.com", agent: .claudeCode))
        XCTAssertEqual(backend.history.get(local.threadId)?["privacy"], "local")
        XCTAssertNotNil(backend.history.get(local.threadId)?["core"])
        try backend.convertToCloud(threadId: local.threadId, confirmingProvider: "anthropic.com", agent: .claudeCode)
        let converted = try XCTUnwrap(backend.history.get(local.threadId))
        XCTAssertEqual(converted["privacy"], "cloud"); XCTAssertEqual(converted["provider"], JSONValue.string("anthropic.com"))
        XCTAssertNil(converted["core"]); XCTAssertFalse(converted.text().contains("Vault-Secret"))
        // Now the same agent may continue, also via the phone; the other agent may not.
        XCTAssertEqual(backend.agentPrivacyCheck(service: .claudeCode, threadId: local.threadId, project: nil, viaPhone: true).outcome, .allowed)
        _ = try backend.authorizeAgentRun(service: .claudeCode, existing: converted, project: nil, viaPhone: true)
        XCTAssertEqual(backend.agentPrivacyCheck(service: .codex, threadId: local.threadId, project: nil).outcome, .needsChoice)
    }

    func testThreadSentToAnotherProviderNeedsChoice() async throws {
        let fixture = try BackendFixture(self)
        let backend = try await make(fixture)
        try await cloudTests.addCloud(backend)
        let cloud = try await cloudTests.send(backend)
        XCTAssertEqual(backend.history.get(cloud.threadId)?["provider"], .string(cloudTests.host))
        let check = backend.agentPrivacyCheck(service: .codex, threadId: cloud.threadId, project: nil)
        XCTAssertEqual(check.outcome, .needsChoice); assertMatch(check.message, cloudTests.host)
    }

    func testAgentTaskTextHasNoVaultContentAndIsBounded() async throws {
        let backend = try await make(try BackendFixture(self))
        let thread: JSONValue = ["id": "t", "core": .string(cloudTests.vaultCore), "images": ["data:image/png;base64,AAAA"],
            "messages": [["role": "user", "content": "hello", "recalled": .string(cloudTests.vaultNote)],
                         ["role": "assistant", "content": "hi there", "recalled": .string(cloudTests.vaultNote)]]]
        let text = backend.agentTaskText(thread: thread, newMessage: "next question")
        XCTAssertEqual(text, "User:\nhello\n\nAssistant:\nhi there\n\nUser:\nnext question")
        XCTAssertFalse(text.contains("Vault-Secret")); XCTAssertFalse(text.contains("base64"))
        let long = String(repeating: "x", count: 20_000)
        let big: JSONValue = ["messages": [["role": "user", "content": .string("OLDEST" + long)], ["role": "assistant", "content": .string(long)]]]
        let bounded = backend.agentTaskText(thread: big, newMessage: "newest")
        XCTAssertLessThanOrEqual(bounded.utf16.count, 24_000)
        XCTAssertTrue(bounded.hasSuffix("User:\nnewest")); XCTAssertFalse(bounded.contains("OLDEST"))
        XCTAssertLessThanOrEqual(backend.agentTaskText(thread: [:], newMessage: String(repeating: "y", count: 50_000)).utf16.count, 24_000)
    }
}
