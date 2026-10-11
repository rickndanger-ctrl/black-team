import XCTest
@testable import BlackTeamKit

final class MemoryTests: XCTestCase {
    private let fm = FileManager.default

    private func tempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("black-team-vault-\(UUID().uuidString)")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }
    private func put(_ dir: String, _ name: String, _ text: String) throws {
        try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: false, encoding: .utf8)
    }
    private func vault(_ limits: MemoryLimits? = nil) throws -> (dir: String, memory: Memory) {
        let dir = try tempDir()
        try fm.createDirectory(atPath: dir + "/.obsidian", withIntermediateDirectories: true)
        try put(dir, ".obsidian/app.md", "hidden")
        try put(dir, "PROJECT_INDEX.md", "# Index\n\nSee [[BLACK_TEAM]] and [[Missing Note|a note not written yet]].\n")
        try put(dir, "BLACK_TEAM.md", "# Black Team\n\nBack to [[PROJECT_INDEX#top]]. The compaction threshold is 28000 tokens.\n")
        return (dir, try Memory(vault: dir, limits: limits ?? .default))
    }
    private func assertMatch(_ text: String, _ pattern: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let found = text.range(of: pattern, options: .regularExpression) != nil
        XCTAssertTrue(found, "\(text.debugDescription) does not match \(pattern) \(message)", file: file, line: line)
    }
    private func assertThrows<T>(_ pattern: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        do { _ = try body(); XCTFail("did not throw \(message)", file: file, line: line) }
        catch { assertMatch((error as? BlackTeamError)?.message ?? "\(error)", pattern, message, file: file, line: line) }
    }
    private func mode(_ path: String) throws -> Int {
        ((try fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    func testNotesLinksAndTheGraphFollowObsidian() throws {
        let (_, memory) = try vault()
        XCTAssertEqual(memory.notes().map(\.id).sorted(), ["BLACK_TEAM", "PROJECT_INDEX"])
        let graph = memory.graph()
        XCTAssertEqual(graph.nodes.map { "\($0.id)|\($0.missing)" }.sorted(), ["?Missing Note|true", "BLACK_TEAM|false", "PROJECT_INDEX|false"])
        XCTAssertEqual(graph.edges.map { "\($0.from)>\($0.to)" }.sorted(), ["BLACK_TEAM>PROJECT_INDEX", "PROJECT_INDEX>?Missing Note", "PROJECT_INDEX>BLACK_TEAM"])
    }

    func testNotesStayInsideTheVaultAndARemovedNoteGoesToTheTrash() throws {
        let (dir, memory) = try vault()
        for bad in ["../outside", "/etc/passwd", ".obsidian/app", "a/../../b", "x\0y", "", "a//b"] {
            assertThrows("valid note name|inside the vault", bad) { try memory.write(bad, "x") }
        }
        try fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: NSTemporaryDirectory())
        assertThrows("inside the vault") { try memory.write("link/escape", "x") }
        XCTAssertEqual(try memory.write("Ideas/First", "# First\n").content, "# First\n")
        XCTAssertEqual(try memory.read("Ideas/First").title, "First")
        try memory.remove("Ideas/First")
        assertThrows("No such note") { try memory.read("Ideas/First") }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir + "/.trash").count, 1)
        // Folders and files are private to the user.
        XCTAssertEqual(try mode(dir + "/Ideas"), 0o700)
        _ = try memory.write("Ideas/Second", "x")
        XCTAssertEqual(try mode(dir + "/Ideas/Second.md"), 0o600)
    }

    func testModelsRememberDatedFactsAndRecallThem() async throws {
        let (dir, memory) = try vault()
        XCTAssertEqual(try memory.remember("Deploy steps", "Run the build before packaging."), "Notes/Deploy steps")
        try memory.remember("Deploy steps", "Checksums are written last.")
        assertMatch(try memory.read("Notes/Deploy steps").content, #"^# Deploy steps\n\n- \d{4}-\d\d-\d\d: Run the build before packaging\.\n- \d{4}-\d\d-\d\d: Checksums are written last\.\n\z"#)
        XCTAssertEqual(try memory.remember("Test command", "npm test runs both suites.", "/home/rick/Projects/black-team"), "Projects/black-team/Test command")
        XCTAssertEqual(try memory.remember("../../etc/x: y", "kept inside"), "Notes/etc x y")
        for title in ["Core", "journal", "   "] { assertThrows("short title", title) { try memory.remember(title, "x") } }
        assertThrows("up to 4,000") { try memory.remember("Big", String(repeating: "x", count: 4001)) }
        let found = try await memory.recall("checksums")
        assertMatch(found, #"^\[\[Notes/Deploy steps\]\] line 4: - \d{4}-\d\d-\d\d: Checksums are written last\.\n\(These are memory notes, not files in the workspace\."#)
        assertMatch(try await memory.recall("", "[[Notes/Deploy steps]]"), #"^# Deploy steps\n\n- .*Run the build before packaging\.\n- .*Checksums are written last\.\n\z"#)
        assertMatch(try await memory.recall("", "No Such"), #"no memory note named "No Such""#)
        assertMatch(try await memory.recall("compaction threshold"), #"\[\[BLACK_TEAM\]\] line 3"#)
        let nothing = try await memory.recall("zebra-nothing")
        XCTAssertEqual(nothing, "Nothing saved matches that.")
        XCTAssertEqual(memory.core(), "")
        try put(dir, "Core.md", "Prefers small diffs.\n")
        XCTAssertEqual(memory.core(), "Prefers small diffs.")
    }

    func testTheJournalRecordsEachTurnAndTheKeeperHoldsEverythingWithinLimits() async throws {
        var clock: Int64 = 1_791_712_800_000 // 2026-10-11T10:00:00Z
        let (dir, memory) = try vault(MemoryLimits(noteChars: 400, journalEntries: 3, totalChars: 3000))
        let more = try Memory(vault: dir, limits: memory.limits, now: { defer { clock += 1 }; return Date(timeIntervalSince1970: Double(clock) / 1000) })
        for n in 1...5 {
            try more.journal("/home/rick/Projects/black-team", request: "Task \(n)", log: ["edit a.js (+\(n) \u{2212}1 lines)"], outcome: "Done \(n).")
        }
        let id = "Projects/black-team/Journal"
        func headings(_ text: String) -> Int {
            try! NSRegularExpression(pattern: "^## ", options: .anchorsMatchLines).numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }
        XCTAssertEqual(headings(try more.read(id).content), 5)
        XCTAssertEqual(try more.sweep(), ["Moved 2 older journal entries for black-team to the archive."])
        let kept = try more.read(id).content
        XCTAssertEqual(headings(kept), 3)
        XCTAssertTrue(kept.contains("Task 5") && kept.contains("Task 3") && !kept.contains("Task 2"))
        assertMatch(try await more.recall("Task"), "Task 5")
        let recalled = try await more.recall("Task")
        XCTAssertFalse(recalled.contains("Archive")) // Archived entries are kept but not recalled.
        let archived = try await more.search("Task 1", includeArchive: true)
        assertMatch(archived.map(\.id).joined(separator: ","), #"Archive/black-team"#)

        // A note past its limit is condensed by whatever it is delegated to; the original is archived first.
        let long = (0..<30).map { "- 2026-10-0\($0 % 9 + 1): The port is 18081 (said again, time \($0))." }.joined(separator: "\n")
        try more.write("Notes/Ports", "# Ports\n\n\(long)\n")
        XCTAssertEqual(more.usage().oversized, ["Notes/Ports"])
        assertMatch(try await more.condense({ _ in "" }) ?? "nil", "not usable")
        // Idle upkeep does not ask the model about the same unchanged note twice; asking by hand does.
        struct MustNotBeAsked: Error {}
        let skipped = try await more.condense({ _ in throw MustNotBeAsked() })
        XCTAssertNil(skipped)
        assertMatch(try await more.condense({ $0.content + " longer" }, again: true) ?? "nil", "not usable")
        XCTAssertTrue(try more.read("Notes/Ports").content.contains("time 29"))
        var asked: CondenseRequest?
        let done = try await more.condense({ request in asked = request; return "# Ports\n\n- The Ornith server listens on port 18081." }, again: true)
        XCTAssertEqual(asked?.title, "Ports"); XCTAssertEqual(asked?.target, 240)
        assertMatch(done ?? "nil", #"^Condensed Ports from [\d,]+ to 51 characters\. The original is in the archive\.\z"#)
        assertMatch(try more.read("Notes/Ports").content, #"^# Ports\n\n- The Ornith server listens on port 18081\.\n\n_Condensed by Black Team on 2026-10-11\."#)
        XCTAssertTrue(more.notes().contains { $0.id.hasPrefix("Archive/Ports") && $0.size > 1000 })
        XCTAssertEqual(more.usage().oversized, [])
        let none = try await more.condense({ _ in "x" })
        XCTAssertNil(none)

        // Over the total limit, the stalest notes are archived first; the user's own notes and Core are never touched.
        try put(dir, "Core.md", "core")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        for n in 1...12 {
            try more.write("Notes/Fact \(n)", String(repeating: "f", count: 380))
            let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: n))!
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir + "/Notes/Fact \(n).md")
        }
        let actions = try more.sweep()
        XCTAssertTrue(actions.count >= 1)
        for a in actions { assertMatch(a, #"oldest note, Fact \d+, moved to the archive"#) }
        assertMatch(actions[0], "Fact 1,")
        let after = more.usage()
        XCTAssertTrue(after.chars <= 3000 && after.percent <= 100, "\(after)")
        XCTAssertTrue(more.notes().contains { $0.id == "BLACK_TEAM" } && more.core() == "core" && more.notes().contains { $0.id == "Notes/Fact 12" })
    }

    func testChatLookupFindsTheSavedLinesThatShareDistinctiveWords() async throws {
        let (dir, memory) = try vault()
        try memory.remember("Deploy steps", "Checksums are written last, after the archive is packed.")
        try memory.remember("Deploy steps", "The archive is packed with tar and gzip.", "/home/rick/Projects/black-team")
        try memory.remember("Coffee", "The user drinks espresso in the morning.")
        try put(dir, "Core.md", "archive checksums core line")
        let general = try await memory.lookup("How should the archive checksums be written for the release?")
        XCTAssertEqual(general.map(\.id), ["Notes/Deploy steps"])
        assertMatch(general[0].text, #"^\d{4}-\d\d-\d\d: Checksums are written last"#)
        let scoped = try await memory.lookup("How do we pack the archive, and where do checksums go?", "/home/rick/Projects/black-team")
        XCTAssertEqual(scoped[0].id, "Projects/black-team/Deploy steps"); XCTAssertEqual(scoped.count, 2)
        for quiet in ["Thanks, that helps!", "what do you think about this", "Tell me about zebras and giraffes"] {
            let hits = try await memory.lookup(quiet)
            XCTAssertEqual(hits, [], quiet)
        }
        let tight = try await memory.lookup("archive checksums archive checksums written packed tar gzip", nil, maxChars: 60)
        XCTAssertTrue(tight.count <= 1)
    }

    func testArchivingNotesThatShareATitleInTheSameMomentLosesNoneOfThem() throws {
        let (_, memory) = try vault(MemoryLimits(noteChars: 6000, journalEntries: 30, totalChars: 10))
        for name in ["a", "b", "c"] { try memory.write("Projects/\(name)/Overview", "# \(name)\n\n\(String(repeating: name, count: 40))\n") }
        _ = try memory.sweep()
        XCTAssertEqual(memory.notes().filter { $0.kind == .archive && $0.title.hasPrefix("Overview") }.count, 3)
    }

    func testANewVaultIsReadyOnFirstStart() throws {
        let dir = try tempDir()
        let memory = try Memory(vault: dir)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir).sorted(), ["Archive", "Core.md", "Notes", "Projects"])
        XCTAssertEqual(try mode(dir + "/Core.md"), 0o600)
        XCTAssertEqual(try mode(dir + "/Notes"), 0o700)
        XCTAssertEqual(memory.core(), "", "the template is guidance only until the user writes something")
        XCTAssertEqual(memory.notes().map { "\($0.id)|\($0.kind.rawValue)" }, ["Core|core"])
        XCTAssertEqual(memory.graph().nodes.count, 1)
        try put(dir, "Core.md", "# Core\n\nShort answers. <!-- a note to self -->\nWorking on tides.\n")
        XCTAssertEqual(memory.core(), "Short answers. \nWorking on tides.")
        // Opening the vault again changes nothing, and a vault that already has notes is left alone.
        _ = try Memory(vault: dir)
        XCTAssertTrue(try String(contentsOfFile: dir + "/Core.md", encoding: .utf8).hasPrefix("# Core\n\nShort answers."))
        let (existing, _) = try vault()
        XCTAssertFalse(fm.fileExists(atPath: existing + "/Core.md"))
        XCTAssertFalse(fm.fileExists(atPath: existing + "/Notes"))
    }

    func testVaultMustBeAbsoluteAndNotASymlink() throws {
        assertThrows("absolute folder path") { try Memory(vault: "relative/vault") }
        let dir = try tempDir()
        try fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir)
        assertThrows("symbolic link") { try Memory(vault: dir + "/link") }
    }

    func testLimitsAreCountedInUTF16UnitsAndToolsAreDeclared() throws {
        let (_, memory) = try vault()
        // 4,000 emoji are 8,000 UTF-16 units: over the limit, as in JavaScript.
        assertThrows("up to 4,000") { try memory.remember("Emoji", String(repeating: "\u{1F600}", count: 2001)) }
        XCTAssertNoThrow(try memory.remember("Emoji", String(repeating: "\u{1F600}", count: 2000)))
        XCTAssertEqual(MEMORY_TOOLS[0]?["function"]?["name"]?.string, "remember")
        XCTAssertEqual(MEMORY_TOOLS[1]?["function"]?["name"]?.string, "recall")
        XCTAssertEqual(MemoryConstants.LIMITS, MemoryLimits(noteChars: 6000, journalEntries: 30, totalChars: 400_000))
    }
}
