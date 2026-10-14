import XCTest
@testable import BlackTeamKit

// Working from an Obsidian board: the note format (kept byte for byte), claims with leases, compare-and-set against other writers, atomic
// writes, the stages written back with artifacts and Log lines, gates answered in Black Team or in the note, and the rule that nothing is ever
// merged. Everything uses temporary folders and temporary git repositories, and the scripted models of OrgTests. The real vault is never touched.

final class OrgBoardNoteTests: XCTestCase {
    static let sample = """
    ---
    id: T-7
    title: Add dark mode
    status: ready
    stage: intake
    priority: p1
    owner:
    claimed:
    lease_until:
    role:
    branch:
    pr:
    created: 2026-10-01T09:00:00Z
    updated: 2026-10-01
    labels: [ui, theme]
    reviewers:
      - hermes
      - codex
    custom_field: "keep: me"
    ---
    ## Context
    The app only has a light theme.

    ## Acceptance criteria
    - A toggle in Settings
    - Remembered after restart

    ## Plan

    ## Design notes (from Codex)
    Keep the contrast above 4.5.

    ## Log
    - 2026-10-01T09:00 hermes: created
    - 2026-10-02T10:00 codex: looked at it

    """

    func testReadsTheFieldsAndSections() {
        let n = BoardNote(Self.sample)
        XCTAssertTrue(n.valid)
        XCTAssertEqual(n.id, "T-7"); XCTAssertEqual(n.title, "Add dark mode"); XCTAssertEqual(n.status, "ready"); XCTAssertEqual(n.stage, "intake")
        XCTAssertEqual(n.priority, "p1"); XCTAssertEqual(n.rank, 1); XCTAssertEqual(n.owner, "")
        XCTAssertNotNil(n.created)
        XCTAssertEqual(n.section("Context"), "The app only has a light theme.")
        XCTAssertEqual(n.section("Acceptance criteria"), "- A toggle in Settings\n- Remembered after restart")
        XCTAssertEqual(n.section("Design notes (from Codex)"), "Keep the contrast above 4.5.")
        XCTAssertEqual(n.log, ["- 2026-10-01T09:00 hermes: created", "- 2026-10-02T10:00 codex: looked at it"])
        XCTAssertTrue(n.free(at: Date()))
    }

    func testEditingChangesOnlyTheLinesItMeansToAndKeepsEverythingElseByteForByte() {
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        var n = BoardNote(Self.sample)
        n.set("owner", "black-team-local@box"); n.set("status", "in-progress"); n.set("lease_until", BoardTime.stamp(moment)); n.set("branch", "org/T-7-add-dark-mode")
        n.log(moment, who: "black-team-local@box", "Claimed it")
        let before = Self.sample.components(separatedBy: "\n"), after = n.text.components(separatedBy: "\n")
        XCTAssertEqual(after.count, before.count + 1, "only one line (the Log line) was added")
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 && $0.offset < 20 }.map(\.offset)
        // owner, status, lease_until and branch were rewritten in place; nothing else moved.
        XCTAssertEqual(changed.count, 4, "\(changed)")
        for line in ["labels: [ui, theme]", "reviewers:", "  - hermes", "  - codex", "custom_field: \"keep: me\"", "## Design notes (from Codex)", "Keep the contrast above 4.5.",
                     "- 2026-10-01T09:00 hermes: created", "- 2026-10-02T10:00 codex: looked at it", "updated: 2026-10-01", "The app only has a light theme."] {
            XCTAssertTrue(after.contains(line), "kept: \(line)")
        }
        XCTAssertEqual(n.owner, "black-team-local@box"); XCTAssertEqual(n.status, "in-progress"); XCTAssertEqual(n.branch, "org/T-7-add-dark-mode")
        XCTAssertEqual(n.log.last?.hasSuffix("black-team-local@box: Claimed it"), true)
        XCTAssertTrue(n.text.hasSuffix("looked at it\n- " + BoardTime.log(moment) + " black-team-local@box: Claimed it\n"), "the new line follows the last Log line, before the closing blank line")
        XCTAssertFalse(n.free(at: moment.addingTimeInterval(-60)), "a live lease belongs to its owner")
        XCTAssertTrue(n.free(at: moment.addingTimeInterval(60)), "an expired lease is free")
        // Clearing writes an empty value and leaves the key where it was.
        n.set("owner", ""); n.set("lease_until", "")
        XCTAssertEqual(n.owner, ""); XCTAssertTrue(n.text.contains("\nowner:\n"))
    }

    func testMissingFieldsAreAddedAboveTheClosingBarAndAMissingLogIsMade() {
        var n = BoardNote("---\nid: T-3\ntitle: Small\n---\nJust a body.\n")
        XCTAssertTrue(n.valid)
        XCTAssertEqual(n.status, ""); XCTAssertEqual(n.rank, 9); XCTAssertNil(n.leaseUntil)
        XCTAssertTrue(n.free(at: Date()), "no owner means free")
        n.set("status", "in-progress")
        n.log(Date(), who: "me", "Hello\nthere")
        XCTAssertEqual(n.text.components(separatedBy: "\n").prefix(5).joined(separator: "|"), "---|id: T-3|title: Small|status: in-progress|---")
        XCTAssertTrue(n.text.contains("Just a body.\n\n## Log\n- "), n.text)
        XCTAssertTrue(n.text.hasSuffix("me: Hello there\n"), n.text)
    }

    func testNotesWithoutUsableFrontMatterAreNotValidAndAnOwnerWithoutALeaseHoldsIt() {
        XCTAssertFalse(BoardNote("# Just a page\nno front matter\n").valid)
        XCTAssertFalse(BoardNote("---\ntitle: No id\n---\n").valid)
        XCTAssertFalse(BoardNote("---\nid: has space\n---\n").valid)
        XCTAssertFalse(BoardNote("---\nid: T-1\nnever closed\n").valid)
        XCTAssertFalse(BoardNote("---\nid: ../../etc\n---\n").valid)
        let held = BoardNote("---\nid: T-1\nowner: rick\n---\n")
        XCTAssertFalse(held.free(at: Date()), "an owner with no lease holds it")
    }

    func testWindowsLineEndingsAreKept() {
        var n = BoardNote("---\r\nid: T-1\r\nstatus: ready\r\n---\r\n## Log\r\n- 2026-10-01T09:00 a: x\r\n")
        XCTAssertTrue(n.valid); XCTAssertEqual(n.status, "ready")
        n.set("status", "in-progress"); n.set("owner", "me")
        n.log(Date(), who: "me", "ok")
        XCTAssertFalse(n.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line still ends with \\r\\n")
        XCTAssertEqual(n.status, "in-progress"); XCTAssertEqual(n.owner, "me")
    }

    func testTimesAreReadWithOrWithoutAZone() {
        XCTAssertEqual(BoardTime.parse("2026-10-13T20:00:00Z")?.timeIntervalSince1970, 1_791_921_600)
        XCTAssertEqual(BoardTime.parse("2026-10-13T22:00:00+02:00")?.timeIntervalSince1970, 1_791_921_600)
        XCTAssertNotNil(BoardTime.parse("2026-10-13T22:10")); XCTAssertNotNil(BoardTime.parse("2026-10-13")); XCTAssertNil(BoardTime.parse("soon")); XCTAssertNil(BoardTime.parse(""))
    }
}

extension BoardNote {
    var branch: String { field("branch") }
}

extension OrgTests {
    // MARK: Helpers

    struct BoardRig {
        var r: Rig
        var board: String
        var tickets: String { board + "/Tickets" }
        var artifacts: String { board + "/Artifacts" }
    }

    /// A rig, a temporary board folder and a linked organization (not working yet). Every role is on the local model.
    func boardRig(repo: Bool = true, emptyRepo: Bool = false, gates: [String]? = nil, backlog: Bool = false, template: String = "software") async throws -> BoardRig {
        let r = try await rig(repo: repo)
        if emptyRepo { XCTAssertTrue(OrgGit.run(["init", "-q", "-b", "main"], in: r.folder).ok) }
        let board = NSTemporaryDirectory() + "/bt-board-" + UUID().uuidString.lowercased() + "/Board"
        try FileManager.default.createDirectory(atPath: board + "/Tickets", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: (board as NSString).deletingLastPathComponent) }
        try await make(r, template, gates: gates)
        r.backend.orgBoardRuntime.host = "testbox"
        r.backend.orgBoardRuntime.scanEvery = 0
        _ = try r.backend.orgLink(projectId: r.pid, folder: board, repo: nil, takeBacklog: backlog)
        return BoardRig(r: r, board: try XCTUnwrap(r.backend.orgLoad(r.pid)?.board?.folder))
    }

    var me: String { "black-team-local@testbox" }

    @discardableResult
    func writeNote(_ b: BoardRig, _ file: String? = nil, id: String, title: String = "Add dark mode", status: String = "ready", priority: String = "p2", owner: String = "",
                   lease: String = "", created: String = "2026-10-01T09:00:00Z", extra: String = "") throws -> String {
        let path = b.tickets + "/" + (file ?? "\(id) \(title).md")
        let text = """
        ---
        id: \(id)
        title: \(title)
        status: \(status)
        stage: intake
        priority: \(priority)
        owner: \(owner)
        claimed:
        lease_until: \(lease)
        role:
        branch:
        pr:
        created: \(created)
        updated: 2026-10-01
        custom_field: "keep: me"
        \(extra)---
        ## Context
        The app has only a light theme.

        ## Acceptance criteria
        - A toggle in Settings

        ## Plan

        ## Notes from Codex
        Do not remove me.

        ## Log
        - 2026-10-01T09:00 hermes: created

        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func read(_ path: String) throws -> BoardNote { BoardNote(try String(contentsOfFile: path, encoding: .utf8)) }

    func work(_ b: BoardRig) throws {
        // A stand-in for the loop, so starting the work does not start the real one: the tests step by hand.
        b.r.backend.orgRuntime.loop = Task {}
        _ = try b.r.backend.orgWork(projectId: b.r.pid, on: true)
    }

    func tick(_ b: BoardRig) async { await b.r.backend.orgBoardTick(b.r.pid) }

    func boardTicket(_ b: BoardRig) throws -> OrgTicket { try XCTUnwrap(b.r.backend.orgBoardTickets(b.r.pid).last) }

    func leftovers(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".tmp") } }

    func iso(_ date: Date) -> String { BoardTime.stamp(date) }

    // MARK: Linking

    func testLinkChecksTheFolderTheRepositoryAndTheDataFolder() async throws {
        let r = try await rig()
        let tmp = NSTemporaryDirectory() + "/bt-link-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: tmp + "/Board/Tickets", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmp + "/Elsewhere", withIntermediateDirectories: true)
        try "x".write(toFile: tmp + "/file.txt", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: "Board") }, contains: "full path")
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/missing") }, contains: "does not exist")
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/file.txt") }, contains: "does not exist")
        // Inside Black Team's data folder, or holding it.
        try FileManager.default.createDirectory(atPath: r.fixture.stateDir + "/inside", withIntermediateDirectories: true)
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: r.fixture.stateDir + "/inside") }, contains: "data folder")
        // A link to somewhere else, and a Tickets folder that leads out of the board.
        try FileManager.default.createSymbolicLink(atPath: tmp + "/Linked", withDestinationPath: tmp + "/Board")
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Linked") }, contains: "link")
        try FileManager.default.createDirectory(atPath: tmp + "/Escape", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tmp + "/Escape/Tickets", withDestinationPath: tmp + "/Elsewhere")
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Escape") }, contains: "outside")
        if getuid() != 0 {
            try FileManager.default.createDirectory(atPath: tmp + "/ReadOnly", withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmp + "/ReadOnly")
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp + "/ReadOnly") }
            await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/ReadOnly") }, contains: "read and write")
        }
        // The repository must be a git repository.
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Board", repo: tmp + "/Elsewhere") }, contains: "not a git repository")
        await fail({ _ = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Board", repo: tmp + "/nope") }, contains: "does not exist")
        XCTAssertNil(r.backend.orgLoad(r.pid), "a refused link makes nothing")
        // A good link makes the organization (all local), stores only paths, and starts nothing.
        let state = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Board")
        let board = try XCTUnwrap(state.organization?.board)
        XCTAssertEqual(board.repo, r.folder.hasPrefix("/private") ? r.folder : (realpath(r.folder, nil).map { String(cString: $0) } ?? r.folder))
        XCTAssertFalse(board.working); XCTAssertFalse(try XCTUnwrap(state.organization).running)
        XCTAssertTrue(state.organization!.roles.allSatisfy { $0.modelKey == r.localKey }, "every role is local")
        XCTAssertEqual(state.board?.statusText.hasPrefix("Not working"), true)
        let stored = try String(contentsOfFile: r.fixture.stateDir + "/orgs/\(r.pid)/org.json", encoding: .utf8)
        XCTAssertFalse(stored.contains(secret))
        // A different repository can be chosen.
        let other = tmp + "/Repo"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        XCTAssertTrue(OrgGit.run(["init", "-q", "-b", "main"], in: other).ok)
        let moved = try r.backend.orgLink(projectId: r.pid, folder: tmp + "/Board", repo: other)
        XCTAssertTrue(moved.organization!.board!.repo.hasSuffix("/Repo"))
        // Unlinking takes the link away and keeps the organization.
        let un = try r.backend.orgUnlink(projectId: r.pid)
        XCTAssertNil(un.organization?.board); XCTAssertNil(un.board); XCTAssertNotNil(un.organization)
    }

    func testWorkNeedsAYesWhenARoleIsPaidAndNothingOtherwise() async throws {
        let b = try await boardRig()
        var role = try XCTUnwrap(b.r.backend.orgLoad(b.r.pid)?.roles(of: "reviewer").first)
        role.modelKey = b.r.cloudKey
        _ = try b.r.backend.orgSaveRole(projectId: b.r.pid, role: role)
        await fail({ _ = try b.r.backend.orgWork(projectId: b.r.pid, on: true) }, contains: "paid service")
        XCTAssertEqual(try b.r.backend.orgState(projectId: b.r.pid).organization?.board?.working, false)
        b.r.backend.orgRuntime.loop = Task {}
        _ = try b.r.backend.orgWork(projectId: b.r.pid, on: true, confirmPaid: true)
        XCTAssertEqual(b.r.backend.orgLoad(b.r.pid)?.confirmed.isEmpty, false)
    }

    // MARK: Claiming

    func testClaimsTheHighestPriorityOldestFreeTicketSkipsLiveLeasesAndTakesExpiredOnes() async throws {
        let b = try await boardRig()
        let now = Date()
        try writeNote(b, id: "T-1", title: "Low", priority: "p3")
        try writeNote(b, id: "T-2", title: "Held by Codex", priority: "p0", owner: "codex@laptop", lease: iso(now.addingTimeInterval(3600)))
        try writeNote(b, id: "T-3", title: "Newer p1", priority: "p1", created: "2026-10-05T09:00:00Z")
        let older = try writeNote(b, id: "T-4", title: "Older p1", priority: "p1", created: "2026-10-02T09:00:00Z")
        try writeNote(b, id: "T-5", title: "Not ready", status: "backlog", priority: "p0")
        try writeNote(b, id: "T-6", title: "Expired claim", priority: "p2", owner: "hermes@laptop", lease: iso(now.addingTimeInterval(-60)))
        let before = try String(contentsOfFile: older, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: older)
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        XCTAssertEqual(t.boardId, "T-4", "highest priority first, then the oldest; a live lease and a backlog note are skipped")
        XCTAssertEqual(t.label, "T-4"); XCTAssertEqual(t.source, "board"); XCTAssertEqual(t.title, "Older p1")
        XCTAssertTrue(t.body.contains("The app has only a light theme.") && t.body.contains("A toggle in Settings"))
        let n = try read(older)
        XCTAssertEqual(n.owner, me); XCTAssertEqual(n.status, "in-progress")
        XCTAssertNotNil(n.leaseUntil)
        XCTAssertEqual(n.leaseUntil!.timeIntervalSince(now), 7200, accuracy: 30, "the lease is two hours")
        XCTAssertFalse(n.field("claimed").isEmpty)
        XCTAssertTrue(n.log.last?.contains("black-team-local@testbox: Claimed by Black Team") == true, "\(n.log)")
        // Everything else in the note is as it was, and the file keeps its mode.
        let kept = before.components(separatedBy: "\n").filter { !["owner:", "status: ready", "lease_until:"].contains($0) && !$0.hasPrefix("owner:") }
        let after = (try String(contentsOfFile: older, encoding: .utf8)).components(separatedBy: "\n")
        for line in kept where !line.hasPrefix("updated:") && !line.hasPrefix("stage:") && !line.hasPrefix("claimed:") && !line.hasPrefix("lease_until:") && !line.hasPrefix("status:") { XCTAssertTrue(after.contains(line), "kept: \(line)") }
        XCTAssertEqual(CoreFS.stat(older).mode & 0o7777, 0o640)
        XCTAssertTrue(leftovers(b.tickets).isEmpty)
        // The ticket it holds is the only one it takes: nothing else is claimed while it waits for its turn.
        await tick(b)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).count, 1)
        XCTAssertEqual(try read(b.tickets + "/T-3 Newer p1.md").owner, "")
        XCTAssertEqual(try read(b.tickets + "/T-2 Held by Codex.md").owner, "codex@laptop", "another owner's live lease is respected")
        // Finish it (cancel), and the next in line is the other p1; the expired claim is free to take.
        _ = try b.r.backend.ticketCancel(projectId: b.r.pid, ticketId: t.id)
        await tick(b)
        XCTAssertEqual(try boardTicket(b).boardId, "T-3")
        _ = try b.r.backend.ticketCancel(projectId: b.r.pid, ticketId: try boardTicket(b).id)
        await tick(b)
        XCTAssertEqual(try boardTicket(b).boardId, "T-6", "p2 next; an expired lease is free")
        XCTAssertEqual(try read(b.tickets + "/T-6 Expired claim.md").owner, me)
    }

    func testTheStyleOfTheNoteIsKeptCapitalStagesUppercasePrioritiesAndQuotedTitles() async throws {
        let b = try await boardRig()
        let path = b.tickets + "/T-5 Styled.md"
        try "---\nid: T-5\ntitle: \"Styled title\"\nstatus: ready\nstage: Spec\npriority: P0\nowner:\nclaimed:\nlease_until:\ncreated: 2026-10-13\nupdated: 2026-10-13\n---\n# T-5\n\n## Context\nx\n\n## Log\n- 2026-10-13 org-seed (claude): ticket created\n".write(toFile: path, atomically: true, encoding: .utf8)
        try writeNote(b, id: "T-6", priority: "p3")
        try work(b)
        await tick(b)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).first?.boardId, "T-5", "P0 sorts first whatever the case")
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).first?.title, "Styled title")
        let n = try read(path)
        XCTAssertEqual(n.field("stage"), "Intake"); XCTAssertEqual(n.field("updated").count, 10, "a date stays a date")
        XCTAssertTrue(n.text.contains("title: \"Styled title\""), "the quoted title was not rewritten")
        XCTAssertTrue(n.log.contains("- 2026-10-13 org-seed (claude): ticket created"))
    }

    func testBacklogIsTakenOnlyWhenThePersonAllowsIt() async throws {
        let b = try await boardRig()
        try writeNote(b, id: "T-1", status: "backlog")
        try work(b)
        await tick(b)
        XCTAssertTrue(b.r.backend.orgBoardTickets(b.r.pid).isEmpty)
        _ = try b.r.backend.orgBoardOptions(projectId: b.r.pid, takeBacklog: true)
        await tick(b)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).first?.boardId, "T-1")
    }

    func testAClaimLosesToAConcurrentWriterAndLeavesTheirTextAlone() async throws {
        let b = try await boardRig()
        let path = try writeNote(b, id: "T-1")
        try work(b)
        // Another agent claims the note between Black Team's read and its write.
        let rival = "---\nid: T-1\ntitle: Add dark mode\nstatus: in-progress\nowner: codex@laptop\nlease_until: \(iso(Date().addingTimeInterval(3600)))\n---\n## Log\n- 2026-10-13T22:00 codex: mine\n"
        b.r.backend.orgBoardRuntime.beforeRename = { p in
            b.r.backend.orgBoardRuntime.beforeRename = nil
            try rival.write(toFile: p, atomically: true, encoding: .utf8)
        }
        await tick(b)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), rival, "the other writer's note is exactly as they left it")
        XCTAssertTrue(b.r.backend.orgBoardTickets(b.r.pid).isEmpty, "no ticket was made")
        XCTAssertTrue(leftovers(b.tickets).isEmpty, "the temporary file was removed")
        // With the rival's lease live, it stays theirs on the next pass too.
        await tick(b)
        XCTAssertEqual(try read(path).owner, "codex@laptop"); XCTAssertTrue(b.r.backend.orgBoardTickets(b.r.pid).isEmpty)
    }

    func testAWriteThatFailsLeavesNoPartialNoteAndNoTemporaryFile() async throws {
        let b = try await boardRig()
        let path = try writeNote(b, id: "T-1")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        try work(b)
        b.r.backend.orgBoardRuntime.beforeRename = { _ in throw BlackTeamError("The disk is full.") }
        await tick(b)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "the note is byte for byte what it was")
        XCTAssertTrue(leftovers(b.tickets).isEmpty)
        XCTAssertTrue(b.r.backend.orgBoardTickets(b.r.pid).isEmpty)
        // And once the disk works again, the claim goes through.
        b.r.backend.orgBoardRuntime.beforeRename = nil
        await tick(b)
        XCTAssertEqual(try read(path).owner, me)
    }

    // MARK: Leases

    func testTheLeaseIsRenewedEveryHalfHourAndGivenBackOnStopPauseAndQuit() async throws {
        let b = try await boardRig()
        let path = try writeNote(b, id: "T-1")
        try work(b)
        await tick(b)
        let first = try XCTUnwrap(try read(path).leaseUntil)
        // Twenty minutes in: nothing to renew yet. Thirty-five minutes in: renewed to two hours from then.
        b.r.backend.orgBoardRuntime.skew = 20 * 60
        await tick(b)
        XCTAssertEqual(try read(path).leaseUntil, first)
        b.r.backend.orgBoardRuntime.skew = 35 * 60
        await tick(b)
        let renewed = try XCTUnwrap(try read(path).leaseUntil)
        XCTAssertEqual(renewed.timeIntervalSince(first), 35 * 60, accuracy: 5)
        XCTAssertEqual(try read(path).owner, me)
        // Pause gives it back: owner and lease cleared, back in the queue, with a Log line.
        _ = try b.r.backend.orgPause(projectId: b.r.pid)
        var n = try read(path)
        XCTAssertEqual(n.owner, ""); XCTAssertNil(n.leaseUntil); XCTAssertEqual(n.status, "ready")
        XCTAssertTrue(n.log.last?.contains("Released the ticket") == true, "\(n.log)")
        XCTAssertTrue(n.free(at: Date()), "another team can take it over")
        // Resume takes the same ticket back, carrying on where it was.
        let ticketId = try boardTicket(b).id
        _ = try b.r.backend.orgResume(projectId: b.r.pid)
        await tick(b)
        n = try read(path)
        XCTAssertEqual(n.owner, me); XCTAssertEqual(n.status, "in-progress")
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).map(\.id), [ticketId], "the same ticket, not a second one")
        // Stop gives it back too.
        _ = try b.r.backend.orgWork(projectId: b.r.pid, on: false)
        n = try read(path)
        XCTAssertEqual(n.owner, ""); XCTAssertEqual(n.status, "ready")
        let org = try XCTUnwrap(b.r.backend.orgLoad(b.r.pid))
        XCTAssertFalse(org.running); XCTAssertEqual(org.board?.working, false)
        XCTAssertEqual(try b.r.backend.orgState(projectId: b.r.pid).board?.statusText.hasPrefix("Not working"), true)
        // Quitting gives it back as well, and the work carries on next time.
        try work(b)
        await tick(b)
        XCTAssertEqual(try read(path).owner, me)
        await b.r.backend.shutdown()
        n = try read(path)
        XCTAssertEqual(n.owner, ""); XCTAssertNil(n.leaseUntil); XCTAssertEqual(n.status, "ready")
        XCTAssertTrue(n.log.last?.contains("Black Team is closing") == true, "\(n.log)")
    }

    func testAnotherOwnerTakingATicketMakesBlackTeamLetGoAndTouchNothingButALogLine() async throws {
        let b = try await boardRig()
        let path = try writeNote(b, id: "T-1")
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        // Codex takes it after the lease ran out (a stalled laptop), with its own live lease.
        var n = try read(path)
        n.set("owner", "codex@laptop"); n.set("lease_until", iso(Date().addingTimeInterval(3600))); n.set("status", "in-progress"); n.set("role", "Reviewer")
        try n.text.write(toFile: path, atomically: true, encoding: .utf8)
        let theirs = n.text
        await tick(b)
        let after = try read(path)
        XCTAssertEqual(after.owner, "codex@laptop"); XCTAssertEqual(after.status, "in-progress"); XCTAssertEqual(after.field("role"), "Reviewer")
        XCTAssertEqual(after.leaseUntil, n.leaseUntil, "their lease is not renewed or changed")
        // The only difference is one Log line about Black Team's own work.
        let a = after.text.components(separatedBy: "\n"), o = theirs.components(separatedBy: "\n")
        XCTAssertEqual(a.count, o.count + 1)
        XCTAssertTrue(after.log.last?.contains("Black Team stopped working on this") == true, "\(after.log)")
        XCTAssertEqual(try boardTicket(b).state, "cancelled"); XCTAssertEqual(try boardTicket(b).id, t.id)
        let notes = b.r.backend.orgInbox().waiting().filter { $0.kind == "note" }
        XCTAssertTrue(notes.contains { $0.question.contains("codex@laptop") }, "\(notes.map(\.question))")
        // Stepping does not run it.
        let ran = try await b.r.backend.orgStep(projectId: b.r.pid)
        XCTAssertFalse(ran)
    }

    // MARK: Stages

    func testATicketGoesThroughEveryStageWritingItsProgressArtifactsAndLogBackAndNeverMerges() async throws {
        let b = try await boardRig(gates: [])
        let note = try writeNote(b, id: "T-7", title: "Add dark mode")
        let before = (head: git(["rev-parse", "HEAD"], in: b.r.folder), branch: git(["branch", "--show-current"], in: b.r.folder), status: git(["status", "--porcelain"], in: b.r.folder))
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        let done = try await drive(b.r, t.id)
        XCTAssertEqual(done.state, "done")
        XCTAssertEqual(done.branch, "org/T-7-add-dark-mode")
        // The note: done, let go, on its stage, with the branch, and a Log line per step.
        let n = try read(note)
        XCTAssertEqual(n.status, "done"); XCTAssertEqual(n.owner, ""); XCTAssertNil(n.leaseUntil)
        XCTAssertEqual(n.stage, "ship"); XCTAssertEqual(n.branch, "org/T-7-add-dark-mode"); XCTAssertEqual(n.field("role"), "Release manager")
        XCTAssertEqual(n.field("custom_field"), "keep: me"); XCTAssertEqual(n.section("Notes from Codex"), "Do not remove me.")
        XCTAssertEqual(n.log.first, "- 2026-10-01T09:00 hermes: created", "other agents' lines stay where they were")
        let log = n.log.joined(separator: "\n")
        for word in ["Claimed by Black Team", "Intake:", "Spec:", "Plan:", "Build:", "Review:", "QA:", "Ship:", "Made branch org/T-7-add-dark-mode", "Done. The work is on branch org/T-7-add-dark-mode"] {
            XCTAssertTrue(log.contains(word), "Log has \(word):\n\(log)")
        }
        // Each stage's artifact is a file under Artifacts/T-7/, linked from the Log.
        for file in ["spec.md", "plan.md", "review.md", "test-report.md", "release-notes.md", "diff-summary.md", "diff.patch"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: b.artifacts + "/T-7/" + file), "Artifacts/T-7/\(file)")
            XCTAssertTrue(log.contains("(../Artifacts/T-7/\(file))"), "linked: \(file)\n\(log)")
        }
        XCTAssertTrue(try String(contentsOfFile: b.artifacts + "/T-7/spec.md", encoding: .utf8).contains("Add feature.txt."))
        XCTAssertTrue(try String(contentsOfFile: b.artifacts + "/T-7/diff-summary.md", encoding: .utf8).contains("feature.txt"))
        XCTAssertFalse(log.contains("# Spec"), "big text goes in files, not in the note")
        // The branch is kept; nothing is merged or pushed; the owner's branch and folder are untouched.
        XCTAssertEqual(git(["rev-parse", "HEAD"], in: b.r.folder), before.head)
        XCTAssertEqual(git(["rev-parse", "main"], in: b.r.folder), before.head)
        XCTAssertEqual(git(["branch", "--show-current"], in: b.r.folder), before.branch)
        XCTAssertEqual(git(["status", "--porcelain"], in: b.r.folder), before.status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.r.folder + "/feature.txt"))
        XCTAssertTrue(git(["branch", "--list", "org/T-7-add-dark-mode"], in: b.r.folder).contains("org/T-7-add-dark-mode"))
        XCTAssertTrue(git(["ls-tree", "-r", "--name-only", "org/T-7-add-dark-mode"], in: b.r.folder).contains("feature.txt"))
        XCTAssertEqual(git(["remote"], in: b.r.folder), "", "no remote, so nothing could be pushed")
        XCTAssertTrue(leftovers(b.tickets).isEmpty)
        // A finished ticket is not taken again, and the next pass finds the board idle.
        await tick(b)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).count, 1)
        XCTAssertEqual(try b.r.backend.orgState(projectId: b.r.pid).board?.statusText, "Idle: no ready tickets")
    }

    func testAGateIsInTheInboxAndCanBeApprovedInBlackTeamOrByEditingTheNote() async throws {
        let b = try await boardRig()   // default gates: spec and ship
        let path = try writeNote(b, id: "T-3", title: "Gate me")
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        var now = try await drive(b.r, t.id)
        XCTAssertEqual(now.state, "gate"); XCTAssertEqual(now.gate?.stage, "spec")
        var n = try read(path)
        XCTAssertEqual(n.status, "review"); XCTAssertEqual(n.owner, me, "it is still Black Team's, waiting for you")
        XCTAssertTrue(n.log.last?.contains("Waiting for you: Approve the spec for T-3") == true, "\(n.log)")
        XCTAssertEqual(b.r.backend.orgInbox().waiting().filter { $0.kind == "gate" }.count, 1)
        XCTAssertEqual(try b.r.backend.orgState(projectId: b.r.pid).board?.statusText, "Waiting for you on T-3")
        // Approve in Black Team: it carries on, and the note follows.
        _ = try b.r.backend.ticketApprove(projectId: b.r.pid, ticketId: t.id)
        XCTAssertTrue(b.r.backend.orgInbox().waiting().isEmpty)
        XCTAssertEqual(try read(path).status, "in-progress")
        now = try await drive(b.r, t.id)
        XCTAssertEqual(now.gate?.stage, "ship")
        XCTAssertEqual(try read(path).status, "review")
        // Not approved yet: setting the status to ready without saying "approved" changes nothing, and Black Team says what is needed once.
        n = try read(path)
        n.set("status", "ready")
        try n.text.write(toFile: path, atomically: true, encoding: .utf8)
        await tick(b)
        XCTAssertEqual(try ticket(b.r, t.id).state, "gate")
        XCTAssertTrue(try read(path).log.last?.contains("still waiting for approval") == true)
        await tick(b)
        XCTAssertEqual(try read(path).log.filter { $0.contains("still waiting for approval") }.count, 1, "said once")
        // Approve from the note: status ready and a Log line saying approved, by someone else.
        n = try read(path)
        n.log(Date(), who: "rick", "approved")
        try n.text.write(toFile: path, atomically: true, encoding: .utf8)
        await tick(b)
        now = try ticket(b.r, t.id)
        XCTAssertEqual(now.state, "done")
        XCTAssertEqual(try read(path).status, "done"); XCTAssertEqual(try read(path).owner, "")
        XCTAssertTrue(b.r.backend.orgInbox().waiting().isEmpty, "the Inbox item was settled")
        XCTAssertEqual(git(["rev-parse", "main"], in: b.r.folder), git(["rev-parse", "HEAD"], in: b.r.folder))
    }

    func testAGateReleasedOnStopIsApprovedFromTheNoteAndTakenBack() async throws {
        let b = try await boardRig()
        let path = try writeNote(b, id: "T-3", title: "Gate me")
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        _ = try await drive(b.r, t.id)
        _ = try b.r.backend.orgWork(projectId: b.r.pid, on: false)
        var n = try read(path)
        XCTAssertEqual(n.owner, ""); XCTAssertEqual(n.status, "review", "a ticket waiting for you stays in review")
        // Nobody approved: starting again does not take a review ticket.
        try work(b)
        await tick(b)
        XCTAssertEqual(try read(path).owner, "")
        // The person approves in the note; the next pass takes it back and carries on.
        n = try read(path)
        n.set("status", "ready"); n.log(Date(), who: "rick", "approved")
        try n.text.write(toFile: path, atomically: true, encoding: .utf8)
        await tick(b)
        XCTAssertEqual(try read(path).owner, me)
        XCTAssertEqual(try ticket(b.r, t.id).state, "ready"); XCTAssertEqual(try ticket(b.r, t.id).gate == nil, true)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).count, 1)
    }

    func testEditsMadeToTheNoteMidRunAreReadAtTheNextStage() async throws {
        let b = try await boardRig(gates: [])
        let path = try writeNote(b, id: "T-9", title: "Original title")
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        XCTAssertEqual(t.title, "Original title")
        // Someone sharpens the title and the criteria while Black Team holds it.
        var text = try String(contentsOfFile: path, encoding: .utf8)
        text = text.replacingOccurrences(of: "title: Original title", with: "title: Sharper title").replacingOccurrences(of: "- A toggle in Settings", with: "- A toggle in Settings\n- Works with high contrast")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        _ = try await b.r.backend.orgStep(projectId: b.r.pid)
        let now = try ticket(b.r, t.id)
        XCTAssertEqual(now.title, "Sharper title")
        XCTAssertTrue(now.body.contains("Works with high contrast"))
        XCTAssertTrue(now.history.contains { $0.text.contains("changed on the board") })
        let intake = try XCTUnwrap(b.r.script.prompts("Intake").first)
        XCTAssertTrue(intake.contains("Sharper title") && intake.contains("Works with high contrast"), "the stage ran with the new text")
        XCTAssertEqual(try read(path).title, "Sharper title", "Black Team never rewrites the title")
    }

    func testAFailureSetsTheNoteBlockedWithTheReasonAndLetsGo() async throws {
        let b = try await boardRig(repo: false, emptyRepo: true, gates: [])   // a repository with no commit yet
        let path = try writeNote(b, id: "T-2", title: "Stuck")
        try work(b)
        await tick(b)
        let t = try boardTicket(b)
        let stuck = try await drive(b.r, t.id)
        XCTAssertEqual(stuck.state, "blocked")
        let n = try read(path)
        XCTAssertEqual(n.status, "blocked"); XCTAssertEqual(n.owner, ""); XCTAssertNil(n.leaseUntil)
        XCTAssertTrue(n.log.last?.contains("Stuck: ") == true && n.log.last?.contains("no commits yet") == true, "\(n.log)")
        // A blocked note is not taken again by itself.
        await tick(b)
        XCTAssertEqual(try ticket(b.r, t.id).state, "blocked")
        // Set back to ready by a person, with a commit made, it is tried again.
        try "x\n".write(toFile: b.r.folder + "/a.txt", atomically: true, encoding: .utf8)
        _ = OrgGit.run(["add", "-A"], in: b.r.folder)
        XCTAssertTrue(OrgGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "first"], in: b.r.folder).ok)
        var again = try read(path)
        again.set("status", "ready")
        try again.text.write(toFile: path, atomically: true, encoding: .utf8)
        await tick(b)
        XCTAssertEqual(try ticket(b.r, t.id).state, "ready")
        XCTAssertEqual(try read(path).owner, me)
    }

    func testABoardFolderThatDisappearsStopsTheWorkAndSaysSoInTheInbox() async throws {
        let b = try await boardRig()
        try writeNote(b, id: "T-1")
        try work(b)
        await tick(b)
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).count, 1)
        try FileManager.default.removeItem(atPath: b.board)
        await tick(b)
        let org = try XCTUnwrap(b.r.backend.orgLoad(b.r.pid))
        XCTAssertTrue(org.paused); XCTAssertTrue(org.pausedReason.contains("not there any more"), org.pausedReason)
        let notes = b.r.backend.orgInbox().waiting().filter { $0.kind == "note" }
        XCTAssertTrue(notes.contains { $0.scheduleName.contains("stopped working for the board") && $0.question.contains("not there any more") }, "\(notes.map(\.question))")
        let state = try b.r.backend.orgState(projectId: b.r.pid)
        XCTAssertEqual(state.board?.reachable, false); XCTAssertTrue(state.board?.statusText.contains("not there any more") == true)
        await tick(b)
        XCTAssertEqual(b.r.backend.orgInbox().waiting().filter { $0.kind == "note" }.count, notes.count, "told once")
        let ran = try await b.r.backend.orgStep(projectId: b.r.pid)
        XCTAssertFalse(ran, "nothing runs while it is stopped")
        // Stepping a ticket does not recreate the folder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.board))
    }

    func testNotesWithoutFrontMatterAreIgnoredAndReportedAndTheBoardShowsWhoOwnsWhat() async throws {
        let b = try await boardRig()
        try "# Just a page\nNo front matter here.\n".write(toFile: b.tickets + "/Plain page.md", atomically: true, encoding: .utf8)
        try "---\ntitle: No id\nstatus: ready\n---\n".write(toFile: b.tickets + "/No id.md", atomically: true, encoding: .utf8)
        try "not a note".write(toFile: b.tickets + "/readme.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: b.board + "/Elsewhere", withIntermediateDirectories: true)
        try "---\nid: T-99\nstatus: ready\n---\n".write(toFile: b.board + "/Elsewhere/Secret.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: b.tickets + "/Linked.md", withDestinationPath: b.board + "/Elsewhere/Secret.md")
        try writeNote(b, id: "T-1", title: "Good")
        try writeNote(b, id: "T-1", title: "Duplicate id", extra: "")
        try writeNote(b, id: "T-2", title: "Held", status: "in-progress", owner: "codex@laptop", lease: iso(Date().addingTimeInterval(3000)))
        let plain = try String(contentsOfFile: b.tickets + "/Plain page.md", encoding: .utf8)
        try work(b)
        await tick(b)
        XCTAssertEqual(try String(contentsOfFile: b.tickets + "/Plain page.md", encoding: .utf8), plain, "ignored notes are not touched")
        XCTAssertEqual(try String(contentsOfFile: b.tickets + "/No id.md", encoding: .utf8), "---\ntitle: No id\nstatus: ready\n---\n")
        XCTAssertEqual(b.r.backend.orgBoardTickets(b.r.pid).map(\.boardId), ["T-1"])
        let status = try b.r.backend.orgBoardStatus(projectId: b.r.pid)
        XCTAssertEqual(status.ignored.count, 4, "\(status.ignored)")
        XCTAssertTrue(status.ignored.contains { $0.hasPrefix("Plain page.md") } && status.ignored.contains { $0.hasPrefix("No id.md") } && status.ignored.contains { $0.hasPrefix("Linked.md") })
        XCTAssertTrue(status.ignored.contains { $0.contains("already has the id T-1") })
        let byId = Dictionary(uniqueKeysWithValues: status.rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["T-2"]?.holder, "other"); XCTAssertEqual(byId["T-2"]?.owner, "codex@laptop")
        XCTAssertEqual(byId["T-1"]?.holder, "mine"); XCTAssertEqual(byId["T-1"]?.status, "in-progress")
        XCTAssertEqual(status.info.owner, me); XCTAssertEqual(status.info.holding, ["T-1"])
    }
}
