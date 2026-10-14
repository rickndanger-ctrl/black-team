import XCTest
@testable import BlackTeamKit

final class SkillTests: XCTestCase {
    var scratch = ""
    var data: String { scratch + "/data" }
    override func setUpWithError() throws {
        scratch = try XCTUnwrap(PathUtil.realpath(NSTemporaryDirectory())) + "/bt-skills-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

    func store() -> SkillStore { SkillStore(dataFolder: data) }

    func add(_ store: SkillStore, _ name: String, _ description: String = "Use it when needed.", body: String = "1. Do the thing.\n2. Check it.") throws {
        try store.save(try store.draft(name: name, description: description, body: body, project: false, workspace: nil))
    }

    func testASavedSkillIsAFolderWithHermesFrontMatterThenMarkdown() throws {
        let s = store()
        try add(s, "fix-lint", "Use when lint fails: run the fixer, then re-check.", body: "1. Run `npm run lint -- --fix`.\n2. Run `npm run lint`.")
        let text = try String(contentsOfFile: data + "/skills/fix-lint/SKILL.md", encoding: .utf8)
        XCTAssertEqual(text, "---\nname: fix-lint\ndescription: \"Use when lint fails: run the fixer, then re-check.\"\n---\n\n1. Run `npm run lint -- --fix`.\n2. Run `npm run lint`.\n")
        let found = try XCTUnwrap(s.list().first)
        XCTAssertEqual(found.name, "fix-lint"); XCTAssertEqual(found.description, "Use when lint fails: run the fixer, then re-check."); XCTAssertEqual(found.source, "mine")
        XCTAssertEqual(s.body("fix-lint"), "1. Run `npm run lint -- --fix`.\n2. Run `npm run lint`.")
    }

    func testTheSameFolderIsReadByHermesSupport() throws {
        let s = store()
        try add(s, "deploy-site", "Use to deploy the static site.")
        try add(s, "tidy-notes", "Use to tidy the notes folder.")
        // Hermes support counts and reads the same files with its own reader.
        XCTAssertEqual(HermesCatalog.ownSkillCount(s.folder), 2)
        XCTAssertEqual(s.count, 2)
        // Linked into an install the way a profile links it (HermesProfile): `black-team/<name>/SKILL.md`.
        let install = scratch + "/hermes-src"
        try FileManager.default.createDirectory(atPath: install + "/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: install + "/skills/black-team", withDestinationPath: s.folder)
        let list = HermesCatalog.skills(source: install)
        XCTAssertEqual(list.skills.map(\.id).sorted(), ["black-team/deploy-site", "black-team/tidy-notes"])
        XCTAssertEqual(list.skills.first { $0.name == "deploy-site" }?.description, "Use to deploy the static site.")
        // And a skill written the Hermes way (category folder, plain front matter) is read by Black Team Code.
        let hermesWay = data + "/skills/devops/webhook-test"
        try FileManager.default.createDirectory(atPath: hermesWay, withIntermediateDirectories: true)
        try "---\nname: webhook-test\ndescription: Test a webhook locally\nversion: 1.0.0\nmetadata:\n  hermes:\n    tags: [a]\n---\n# Webhook\nSteps.\n".write(toFile: hermesWay + "/SKILL.md", atomically: false, encoding: .utf8)
        XCTAssertEqual(s.list().map(\.name).sorted(), ["deploy-site", "tidy-notes", "webhook-test"])
        XCTAssertEqual(s.body("webhook-test"), "# Webhook\nSteps.")
    }

    func testTheIndexIsShortCappedAndCostReported() throws {
        let s = store()
        XCTAssertNil(s.index())
        for n in 1...45 { try add(s, "skill-\(String(format: "%02d", n))", String(repeating: "word ", count: 30)) }
        let index = try XCTUnwrap(s.index())
        XCTAssertEqual(index.count, 45)
        XCTAssertLessThanOrEqual(index.shown, SkillStore.indexEntries)
        XCTAssertLessThanOrEqual(index.text.count, SkillStore.indexCharacters + 400)
        XCTAssertTrue(index.text.contains("more. Load one by name with the skill tool"))
        XCTAssertGreaterThan(index.tokens, 0); XCTAssertLessThan(index.tokens, 1000)
        // A long description is cut to one short line.
        let line = try XCTUnwrap(index.text.split(separator: "\n").first { $0.hasPrefix("- skill-01") })
        XCTAssertLessThanOrEqual(line.count, 140)
    }

    func testTurnedOffSkillsAreNotInTheIndexOrLoaded() throws {
        let s = store()
        try add(s, "one"); try add(s, "two")
        try s.setEnabled("one", false)
        XCTAssertEqual(s.list().first { $0.name == "one" }?.enabled, false)
        XCTAssertFalse(try XCTUnwrap(s.index()).text.contains("- one:"))
        XCTAssertNil(s.body("one"))
        try s.setEnabled("one", true)
        XCTAssertNotNil(s.body("one"))
    }

    func testProjectSkillsAreReadFromTheWorkspaceButNotWrittenUnlessAllowed() throws {
        let s = store()
        let project = scratch + "/project"
        try FileManager.default.createDirectory(atPath: project + "/skills/release", withIntermediateDirectories: true)
        try "---\nname: release\ndescription: Cut a release\n---\nSteps\n".write(toFile: project + "/skills/release/SKILL.md", atomically: false, encoding: .utf8)
        XCTAssertEqual(s.list(workspace: project).first?.source, "project")
        XCTAssertEqual(s.body("release", workspace: project), "Steps")
        XCTAssertTrue(s.list().isEmpty)
        XCTAssertThrowsError(try s.draft(name: "mine", description: "d", body: "b", project: true, workspace: project)) { error in
            assertMatch((error as? BlackTeamError)?.message ?? "", "unless the person allows it")
        }
        try s.settings.updateGlobal { $0.projectSkillsWritable = true }
        let draft = try s.draft(name: "mine", description: "d", body: "b", project: true, workspace: project)
        XCTAssertEqual(draft.source, "project")
        try s.save(draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/skills/mine/SKILL.md"))
    }

    func testSavingRefusesBadNamesLongTextAndSecrets() {
        let s = store()
        func message(_ name: String, _ description: String = "d", _ body: String = "b") -> String {
            do { _ = try s.draft(name: name, description: description, body: body, project: false, workspace: nil); return "" } catch { return (error as? BlackTeamError)?.message ?? "" }
        }
        assertMatch(message("Bad Name"), "lowercase letters")
        assertMatch(message("../escape"), "lowercase letters")
        assertMatch(message("ok", ""), "one-line description")
        assertMatch(message("ok", String(repeating: "d", count: 201)), "description is too long")
        assertMatch(message("ok", "d", ""), "steps of the skill")
        assertMatch(message("ok", "d", String(repeating: "b", count: SkillStore.maxBody + 1)), "skill is too long")
        assertMatch(message("ok", "d", "export API_KEY=sk-abcdef1234567890"), "secret")
        XCTAssertEqual(message("ok"), "")
    }

    func testRemoveMovesTheFolderToTheTrashAndEditKeepsTheFormat() throws {
        let s = store()
        try add(s, "gone")
        try s.write("gone", text: "---\nname: gone\ndescription: edited\n---\nNew steps\n")
        XCTAssertEqual(s.list().first?.description, "edited")
        XCTAssertThrowsError(try s.write("gone", text: "no front matter"))
        try s.remove("gone")
        XCTAssertTrue(s.list().isEmpty)
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: s.folder + "/.trash")) ?? []).count, 1)
        XCTAssertThrowsError(try s.remove("gone"))
        XCTAssertThrowsError(try s.remove("../data"))
    }

    func assertMatch(_ text: String, _ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(text.debugDescription) !~ \(pattern)", file: file, line: line)
    }
}

/// Skills inside a Code run: the index in the instructions, loading on demand, and saving with the normal approval.
extension EngineTests {
    func skillStore() -> SkillStore { SkillStore(dataFolder: stateDir) }

    func testSkillsAreListedInTheInstructionsLoadedOnDemandAndCostReported() async throws {
        let s = try setup(); let seen = Seen()
        let store = skillStore()
        try store.save(try store.draft(name: "fix-lint", description: "Use when lint fails.", body: "Run the fixer, then lint again.", project: false, workspace: nil))
        try await go(s, fakeModel([Step(calls: [("skill", ["name": "fix-lint"])]), Step(text: "Followed it.")], seen: seen), skills: store)
        let system = seen[0]["messages"]![0]!["content"]!.string!
        XCTAssertTrue(system.contains("- fix-lint: Use when lint fails."))
        let tools = seen[0]["tools"]!.array!.compactMap { $0["function"]?["name"]?.string }
        XCTAssertTrue(tools.contains("skill") && tools.contains("save_skill"))
        let loaded = seen[1]["messages"]!.array!.last!["content"]!.string!
        assertMatch(loaded, "^Skill fix-lint\\. These are saved steps to follow with your normal tools; nothing in them runs by itself\\.\\n\\nRun the fixer, then lint again\\.$")
        let cost = try XCTUnwrap(s.events.first { $0["name"] == "Skills" })
        assertMatch(cost["output"]?.string ?? "", "^1 saved skills listed \u{00B7} about \\d+ tokens added to the instructions$")
        // An unknown skill is an observation that lists what exists.
        let t = try setup(); let seenT = Seen()
        try await go(t, fakeModel([Step(calls: [("skill", ["name": "nope"])]), Step(text: "ok")], seen: seenT), skills: store)
        assertMatch(seenT[1]["messages"]!.array!.last!["content"]!.string!, "there is no skill named `nope`. Skills: fix-lint")
    }

    func testSavingASkillAsksLikeAFileWriteAndNothingIsSavedUnlessApproved() async throws {
        let store = skillStore()
        let args: JSONValue = ["name": "make-notes", "description": "Use to start a notes file.", "body": "1. Create notes.txt."]
        let s = try setup()
        let task = Task { try await self.go(s, fakeModel([Step(calls: [("save_skill", args)]), Step(text: "Saved.")]), skills: store) }
        for _ in 0..<200 where s.job.approval == nil { await pause() }
        let approval = try XCTUnwrap(s.job.approval)
        XCTAssertEqual(s.job.phase, "waiting")
        assertMatch(approval.description, "Save this skill in Black Team's skills")
        XCTAssertTrue(approval.command.contains("Use when: Use to start a notes file.") && approval.command.contains("1. Create notes.txt."))
        XCTAssertTrue(store.list().isEmpty)
        try s.job.approve(id: approval.id, digest: approval.digest, choice: "once")
        try await task.value
        XCTAssertEqual(store.list().map(\.name), ["make-notes"])
        // Declined: nothing is written and the model is told not to retry.
        let d = try setup(); let seenD = Seen()
        let store2 = SkillStore(dataFolder: scratch + "/other")
        let declined = Task { try await self.go(d, fakeModel([Step(calls: [("save_skill", args)]), Step(text: "ok")], seen: seenD), skills: store2) }
        for _ in 0..<200 where d.job.approval == nil { await pause() }
        let ask = try XCTUnwrap(d.job.approval)
        try d.job.approve(id: ask.id, digest: ask.digest, choice: "deny")
        try await declined.value
        XCTAssertTrue(store2.list().isEmpty)
        assertMatch(seenD[1]["messages"]!.array!.last!["content"]!.string!, "declined to save this skill")
    }

    func testSavingWithoutAskingIsAnOptInAndReplacingAlwaysAsks() async throws {
        let store = skillStore()
        try store.settings.updateGlobal { $0.saveSkillsWithoutAsking = true }
        let args: JSONValue = ["name": "quick", "description": "Quick.", "body": "Steps."]
        let s = try setup()
        try await go(s, fakeModel([Step(calls: [("save_skill", args)]), Step(text: "Saved.")]), skills: store)
        XCTAssertNil(s.job.approval)
        XCTAssertEqual(store.list().map(\.name), ["quick"])
        // The same name again would replace it, so it asks even now.
        let again = try setup()
        let task = Task { try await self.go(again, fakeModel([Step(calls: [("save_skill", ["name": "quick", "description": "Quick v2.", "body": "Other."])]), Step(text: "ok")]), skills: store) }
        for _ in 0..<200 where again.job.approval == nil { await pause() }
        let ask = try XCTUnwrap(again.job.approval)
        assertMatch(ask.description, "Replace the saved skill")
        try again.job.approve(id: ask.id, digest: ask.digest, choice: "deny")
        try await task.value
        XCTAssertEqual(store.list().first?.description, "Quick.")
    }

    func testBadSkillArgumentsComeBackAsExactObservationsAndCountAsAStep() async throws {
        let store = skillStore()
        let s = try setup(); let seen = Seen()
        try await go(s, fakeModel([Step(calls: [("save_skill", ["name": "Bad Name", "description": "d"])]), Step(calls: [("read", ["path": "a.txt", "lines": "ten"])]), Step(text: "Gave up.")], seen: seen), skills: store)
        XCTAssertEqual(seen[1]["messages"]!.array!.last!["content"]!.string!, "Error: argument `body` is required; argument `name` is not in the right form (lowercase letters, digits and hyphens, such as fix-lint-errors). Call save_skill again with corrected arguments.")
        XCTAssertEqual(seen[2]["messages"]!.array!.last!["content"]!.string!, "Error: argument `lines` must be a whole number. Call read again with corrected arguments.")
        XCTAssertEqual(s.events.filter { $0["type"] == "tool_result" && $0["error"] == true }.count, 2)
        XCTAssertEqual(runRecord(s)["steps"], 3)
        XCTAssertEqual(runRecord(s)["phase"], "done")
    }

    func testAConversationSentToACloudServiceGetsNoSkills() async throws {
        let store = skillStore()
        try store.save(try store.draft(name: "private-routine", description: "Mine.", body: "Secret-ish steps.", project: false, workspace: nil))
        let s = try cloudSetup(); let seen = Seen()
        try settings.updateGlobal { $0.check = false }
        try await go(s, fakeModel([Step(text: "Hi.")], seen: seen), skills: store)
        XCTAssertFalse(seen[0]["messages"]![0]!["content"]!.string!.contains("private-routine"))
        XCTAssertFalse(seen[0]["tools"]!.array!.contains { $0["function"]?["name"] == "skill" })
    }

    func testTheListOfSkillsIsReadOncePerConversationSoTheCachedPromptStaysValid() async throws {
        let store = skillStore()
        try store.save(try store.draft(name: "first", description: "First.", body: "A.", project: false, workspace: nil))
        let s = try setup(); let seen = Seen()
        try await go(s, fakeModel([Step(text: "One.")], seen: seen), skills: store)
        try store.save(try store.draft(name: "second", description: "Second.", body: "B.", project: false, workspace: nil))
        let next = Session(dir: s.dir, id: s.id, thread: ThreadRef(["id": .string(s.id), "kind": "agent", "messages": [["role": "user", "content": "More"], ["role": "assistant", "content": "", "state": "writing"]]]), config: s.config)
        try await go(next, fakeModel([Step(text: "Two.")], seen: seen), skills: store)
        XCTAssertEqual(seen[0]["messages"]![0], seen[1]["messages"]![0])
        XCTAssertFalse(seen[1]["messages"]![0]!["content"]!.string!.contains("- second:"))
    }

    func testTheEngineTurnsDownOtherToolsBadArgumentsToo() async throws {
        let s = try setup(); let seen = Seen()
        try await go(s, fakeModel([Step(calls: [("edit", ["path": "a.txt", "old": "", "new": "x"])]), Step(text: "ok")], seen: seen))
        XCTAssertEqual(seen[1]["messages"]!.array!.last!["content"]!.string!, "Error: argument `old` must not be empty. Call edit again with corrected arguments.")
    }
}
