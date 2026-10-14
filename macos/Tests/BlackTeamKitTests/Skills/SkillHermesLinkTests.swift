import XCTest
@testable import BlackTeamKit

/// The Hermes screen links the same skills folder into a conversation's profile.
final class SkillHermesLinkTests: XCTestCase {
    func testTheProfileLinksBlackTeamsSkillsFolderAndTheSwitchTurnsItOff() async throws {
        let runner = "#!/bin/sh\necho '{\"type\":\"result\",\"text\":\"Done\",\"session_id\":\"s\",\"exit_code\":0}'\n"
        let rig = try HermesRig(self, runner: runner)
        let store = SkillStore(dataFolder: rig.data)
        try store.save(try store.draft(name: "shared-routine", description: "Used by both.", body: "Steps.", project: false, workspace: nil))
        let sent = try rig.backend.submit(message: "Work", kind: "agent", requestId: newID())
        await rig.backend.waitForIdle()
        let profile = rig.data + "/hermes/" + sent.threadId
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile + "/skills/black-team"), store.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile + "/skills/black-team/shared-routine/SKILL.md"))
        // Switched off on the Hermes screen, a new conversation's profile does not carry it.
        let abilities = HermesAbilityStore(dataFolder: rig.data)
        var chosen = abilities.read()
        chosen.blackTeamSkills = false
        try abilities.write(chosen)
        let next = try rig.backend.submit(message: "Work again", kind: "agent", requestId: newID())
        await rig.backend.waitForIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.data + "/hermes/" + next.threadId + "/skills/black-team"))
    }
}
