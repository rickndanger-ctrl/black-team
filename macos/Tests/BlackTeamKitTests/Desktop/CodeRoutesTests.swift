import XCTest
@testable import BlackTeamKit

// The window's controls for a Code run and its skills: the HTTP routes, with the same rig the other window tests use.
final class CodeRoutesTests: XCTestCase {
    func testSettingsShowWhatAppliesAndRefuseBadValues() async throws {
        let r = try await WindowRig(self)
        var view = await r.desktop("GET", "/api/code/settings")
        XCTAssertEqual(view.status, 200)
        XCTAssertEqual(view["tokenCeiling"], JSONValue.number(Double(CodeGlobalSettings.defaultTokenCeiling)))
        XCTAssertEqual(view["check"], false, "a model on this computer does not check by default")
        XCTAssertEqual(view["model"]?["cloud"], false)
        view = await r.desktop("POST", "/api/code/settings", ["tokenCeiling": 50000, "check": true])
        XCTAssertEqual(view["tokenCeiling"], 50000)
        XCTAssertEqual(view["check"], true)
        for (input, message) in [(["tokenCeiling": -1] as JSONValue, "whole number, 0 or more"), (["tokenCeiling": 1.5], "whole number"), (["moneyCeiling": "lots"], "must be a number"),
                                 (["check": "yes"], "must be on or off"), (["wat": 1], "Unsupported Code setting."),
                                 (["price": ["input": 1, "output": -2]], "Give both prices"), (["price": ["input": 1, "output": 2]], "Prices are for cloud models")] {
            let answer = await r.desktop("POST", "/api/code/settings", input)
            XCTAssertEqual(answer.status, 400, "\(input)")
            XCTAssertTrue(answer.error.contains(message), "\(answer.error) !~ \(message)")
        }
    }

    func testAPriceIsKeptPerCloudModelAndAMoneyLimitAppliesOnlyThere() async throws {
        let r = try await WindowRig(self)
        try await r.addCloud()
        var view = await r.desktop("POST", "/api/code/settings", ["price": ["input": 3, "output": 15], "moneyCeiling": 2.5])
        XCTAssertEqual(view["model"]?["cloud"], true)
        XCTAssertEqual(view["model"]?["price"], ["input": 3, "output": 15])
        XCTAssertEqual(view["moneyCeiling"], 2.5)
        XCTAssertEqual(view["check"], true, "a cloud model checks by default")
        XCTAssertEqual(r.backend.codeSettings.global().prices.count, 1)
        try await r.useLocal()
        view = await r.desktop("GET", "/api/code/settings")
        XCTAssertEqual(view["moneyCeiling"], 0, "a model on this computer has no money limit")
        XCTAssertNil(view["model"]?["price"])
    }

    func testChoicesForOneConversationStayWithThatConversation() async throws {
        let r = try await WindowRig(self)
        let sent = await r.chat("hello")
        let id = try XCTUnwrap(sent["threadId"]?.string ?? r.backend.threads().first?.id)
        _ = await r.desktop("POST", "/api/code/settings", ["thread": .string(id), "check": true, "tokenCeiling": 1234])
        XCTAssertEqual(r.backend.codeSettings.thread(id).check, true)
        XCTAssertEqual(r.backend.codeSettings.thread(id).tokenCeiling, 1234)
        XCTAssertNil(r.backend.codeSettings.global().check)
        XCTAssertEqual(r.backend.codeSettings.global().tokenCeiling, CodeGlobalSettings.defaultTokenCeiling)
        let other = await r.desktop("POST", "/api/code/settings", ["thread": "no-such-thread", "check": true])
        XCTAssertEqual(other.error, "Conversation not found.")
    }

    func testPauseAndResumeDoNothingWhenNothingIsRunningAndAPhoneCannotUseThem() async throws {
        let r = try await WindowRig(self)
        let paused = await r.desktop("POST", "/api/pause", [:])
        XCTAssertEqual(paused["paused"], false)
        let resumed = await r.desktop("POST", "/api/resume", [:])
        XCTAssertEqual(resumed["resumed"], false)
        let phone = await r.phone("POST", "/api/pause", [:])
        XCTAssertEqual(phone.status, 403)
        let skills = await r.phone("GET", "/api/skills")
        XCTAssertEqual(skills.status, 403)
    }

    func testSkillsCanBeListedViewedEditedTurnedOffAndRemoved() async throws {
        let r = try await WindowRig(self)
        var list = await r.desktop("GET", "/api/skills")
        XCTAssertEqual(list["skills"]?.array?.count, 0)
        let store = r.backend.skills
        try store.save(try store.draft(name: "tidy", description: "Use to tidy.", body: "Steps.", project: false, workspace: nil))
        list = await r.desktop("GET", "/api/skills")
        XCTAssertEqual(list["skills"]?[0]?["name"], "tidy")
        XCTAssertEqual(list["skills"]?[0]?["enabled"], true)
        let view = await r.desktop("GET", "/api/skills/view?name=tidy")
        XCTAssertTrue(view["text"]?.string?.hasPrefix("---\nname: tidy\n") == true)
        let edited = await r.desktop("POST", "/api/skills/save", ["name": "tidy", "text": "---\nname: tidy\ndescription: Edited.\n---\nNew.\n"])
        XCTAssertEqual(edited["skills"]?[0]?["description"], "Edited.")
        let broken = await r.desktop("POST", "/api/skills/save", ["name": "tidy", "text": "no front matter"])
        XCTAssertEqual(broken.status, 400)
        let off = await r.desktop("POST", "/api/skills/enable", ["name": "tidy", "on": false])
        XCTAssertEqual(off["skills"]?[0]?["enabled"], false)
        let gone = await r.desktop("POST", "/api/skills/remove", ["name": "tidy"])
        XCTAssertEqual(gone["skills"]?.array?.count, 0)
        let missing = await r.desktop("POST", "/api/skills/remove", ["name": "tidy"])
        XCTAssertEqual(missing.error, "That skill was not found.")
        let traversal = await r.desktop("GET", "/api/skills/view?name=../x")
        XCTAssertEqual(traversal.status, 400)
    }

    func testTheSkillSwitchesAreGlobalChoices() async throws {
        let r = try await WindowRig(self)
        let view = await r.desktop("POST", "/api/code/settings", ["saveSkillsWithoutAsking": true, "projectSkillsWritable": true])
        XCTAssertEqual(view["saveSkillsWithoutAsking"], true)
        XCTAssertEqual(view["projectSkillsWritable"], true)
        XCTAssertTrue(r.backend.codeSettings.global().saveSkillsWithoutAsking)
        let skills = await r.desktop("GET", "/api/skills")
        XCTAssertEqual(skills["saveWithoutAsking"], true)
    }
}
