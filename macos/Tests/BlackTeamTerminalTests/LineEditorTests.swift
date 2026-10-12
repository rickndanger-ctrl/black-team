import XCTest
@testable import BlackTeamTerminal

final class LineBufferTests: XCTestCase {
    func testTypingAndCursorKeys() {
        var b = LineBuffer()
        b.insert("hello")
        XCTAssertEqual(b.text, "hello"); XCTAssertEqual(b.cursor, 5)
        b.moveLeft(); b.moveLeft()
        b.insert("XY")
        XCTAssertEqual(b.text, "helXYlo")
        b.home(); XCTAssertEqual(b.cursor, 0)
        b.moveLeft(); XCTAssertEqual(b.cursor, 0)
        b.end(); XCTAssertEqual(b.cursor, 7)
        b.moveRight(); XCTAssertEqual(b.cursor, 7)
    }

    func testBackspaceAndDelete() {
        var b = LineBuffer("abcd")
        b.backspace(); XCTAssertEqual(b.text, "abc")
        b.home(); b.backspace(); XCTAssertEqual(b.text, "abc")
        b.deleteForward(); XCTAssertEqual(b.text, "bc")
        b.end(); b.deleteForward(); XCTAssertEqual(b.text, "bc")
    }

    func testKillToStartEndAndWord() {
        var b = LineBuffer("one two  three")
        b.deleteWord(); XCTAssertEqual(b.text, "one two  ")
        b.deleteWord(); XCTAssertEqual(b.text, "one ")
        b.moveLeft(); b.moveLeft()
        b.killToStart(); XCTAssertEqual(b.text, "e "); XCTAssertEqual(b.cursor, 0)
        b.killToEnd(); XCTAssertEqual(b.text, "")
    }

    func testBackspaceRemovesWholeCharacters() {
        var b = LineBuffer("e\u{301}x")           // e + combining accent, then x
        XCTAssertEqual(b.count, 2)
        b.backspace(); b.backspace()               // x, then the whole accented letter
        XCTAssertEqual(b.text, "")
        var emoji = LineBuffer("a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")
        XCTAssertEqual(emoji.count, 2)
        emoji.backspace(); XCTAssertEqual(emoji.text, "a")
    }

    func testCombiningMarkTypedAfterLetterJoinsIt() {
        var b = LineBuffer()
        b.insert("e"); b.insert("\u{301}")
        XCTAssertEqual(b.count, 1)
        b.moveLeft(); XCTAssertEqual(b.cursor, 0)
    }

    func testPasteKeepsNewlinesAndNormalisesCarriageReturns() {
        var b = LineBuffer()
        b.insert("line one\r\nline two\rline three")
        XCTAssertEqual(b.text, "line one\nline two\nline three")
        XCTAssertEqual(b.text.split(separator: "\n").count, 3)
    }

    func testControlCharactersAreNotInserted() {
        var b = LineBuffer()
        b.insert("a\u{07}b\u{1B}c")
        XCTAssertEqual(b.text, "abc")
    }

    func testRenderFitsAndNewlineIsAMark() {
        let b = LineBuffer("a\nb")
        let r = b.render(promptWidth: 6, columns: 40)
        XCTAssertEqual(r.text, "a\u{21B5}b"); XCTAssertEqual(r.cursorColumn, 9)
    }

    func testRenderScrollsToKeepCursorVisible() {
        var b = LineBuffer(String(repeating: "x", count: 100))
        var r = b.render(promptWidth: 10, columns: 40)
        XCTAssertLessThanOrEqual(DisplayWidth.of(r.text) + 10, 39)
        XCTAssertLessThan(r.cursorColumn, 40)
        b.home()
        r = b.render(promptWidth: 10, columns: 40)
        XCTAssertEqual(r.cursorColumn, 10)
        XCTAssertTrue(r.text.hasPrefix("xxx"))
    }

    func testRenderMeasuresWideCharacters() {
        let b = LineBuffer("\u{4F60}\u{597D}ab")      // two wide characters
        let r = b.render(promptWidth: 2, columns: 40)
        XCTAssertEqual(r.cursorColumn, 2 + 6)
        var c = b; c.home(); c.moveRight()
        XCTAssertEqual(c.render(promptWidth: 2, columns: 40).cursorColumn, 4)
        // never cut a wide character in half
        let long = LineBuffer(String(repeating: "\u{4F60}", count: 40))
        let shown = long.render(promptWidth: 2, columns: 21)
        XCTAssertLessThanOrEqual(DisplayWidth.of(shown.text), 18)
    }
}

final class DisplayWidthTests: XCTestCase {
    func testWidths() {
        XCTAssertEqual(DisplayWidth.of("abc"), 3)
        XCTAssertEqual(DisplayWidth.of("\u{4F60}\u{597D}"), 4)
        XCTAssertEqual(DisplayWidth.of("\u{1F600}"), 2)
        XCTAssertEqual(DisplayWidth.of("e\u{301}"), 1)
        XCTAssertEqual(DisplayWidth.of("\u{2764}\u{FE0F}"), 2)
        XCTAssertEqual(DisplayWidth.of("\u{AC00}"), 2)
        XCTAssertEqual(DisplayWidth.visible("\u{1B}[36mhi\u{1B}[0m"), 2)
    }
}

final class KeyDecoderTests: XCTestCase {
    func decode(_ text: String) -> [Key] { var d = KeyDecoder(); return d.feed(Array(text.utf8)) }

    func testPlainTextAndEnter() {
        XCTAssertEqual(decode("hi\r"), [.text("h"), .text("i"), .enter])
    }

    func testArrowsHomeEndDelete() {
        XCTAssertEqual(decode("\u{1B}[D\u{1B}[C\u{1B}[A\u{1B}[B"), [.left, .right, .up, .down])
        XCTAssertEqual(decode("\u{1B}[H\u{1B}[F\u{1B}OH\u{1B}OF"), [.home, .end, .home, .end])
        XCTAssertEqual(decode("\u{1B}[1~\u{1B}[4~\u{1B}[3~"), [.home, .end, .delete])
    }

    func testControlKeys() {
        XCTAssertEqual(decode("\u{01}\u{05}\u{15}\u{17}\u{04}\u{03}\u{7F}\t"), [.home, .end, .killToStart, .deleteWord, .eof, .interrupt, .backspace, .tab])
    }

    func testUTF8SplitAcrossReads() {
        var d = KeyDecoder()
        let bytes = Array("\u{4F60}".utf8)
        XCTAssertEqual(d.feed([bytes[0]]), [])
        XCTAssertTrue(d.isMidSequence)
        XCTAssertEqual(d.feed([bytes[1]]), [])
        XCTAssertEqual(d.feed([bytes[2]]), [.text("\u{4F60}")])
        XCTAssertEqual(d.feed(Array("\u{1F600}".utf8)), [.text("\u{1F600}")])
    }

    func testBrokenUTF8IsDroppedNotHalfKept() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0xE4, 0xBD, 0x41]), [.text("A")])
    }

    func testBracketedPasteIsOneKeyAndKeepsLines() {
        let keys = decode("\u{1B}[200~first\nsecond \u{4F60}\u{1B}[201~x")
        XCTAssertEqual(keys, [.paste("first\nsecond \u{4F60}"), .text("x")])
    }

    func testPasteSplitAcrossReads() {
        var d = KeyDecoder()
        var keys = d.feed(Array("\u{1B}[200~ab".utf8))
        keys += d.feed(Array("c\r\n\u{1B}[20".utf8))
        keys += d.feed(Array("1~".utf8))
        XCTAssertEqual(keys, [.paste("abc\r\n")])
    }

    func testLoneEscapeAfterQuiet() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.flush(), [.escape])
        XCTAssertFalse(d.isMidSequence)
    }

    func testSequencePutIntoBufferEndToEnd() {
        var d = KeyDecoder()
        var b = LineBuffer()
        for key in d.feed(Array("hello\u{1B}[D\u{1B}[DXX\u{1B}[3~".utf8)) {
            switch key {
            case .text(let s): b.insert(s)
            case .left: b.moveLeft()
            case .delete: b.deleteForward()
            default: break
            }
        }
        XCTAssertEqual(b.text, "helXXo")
    }
}

final class InputHistoryTests: XCTestCase {
    func testUpDownAndDraft() {
        var h = InputHistory()
        h.add("one"); h.add("two"); h.add("three")
        XCTAssertEqual(h.previous(current: "draft"), "three")
        XCTAssertEqual(h.previous(current: "three"), "two")
        XCTAssertEqual(h.previous(current: "two"), "one")
        XCTAssertNil(h.previous(current: "one"))
        XCTAssertEqual(h.next(), "two")
        XCTAssertEqual(h.next(), "three")
        XCTAssertEqual(h.next(), "draft")
        XCTAssertNil(h.next())
    }

    func testSkipsBlankAndRepeatedLines() {
        var h = InputHistory()
        h.add("a"); h.add("a"); h.add("   "); h.add("b")
        XCTAssertEqual(h.entries, ["a", "b"])
    }

    func testKeepsNewest500() {
        var h = InputHistory()
        for n in 0..<650 { h.add("line \(n)") }
        XCTAssertEqual(h.entries.count, 500)
        XCTAssertEqual(h.entries.first, "line 150")
        XCTAssertEqual(h.entries.last, "line 649")
    }

    func testSavedPrivatelyAndReadBackWithMultilineEntries() throws {
        let folder = NSTemporaryDirectory() + "bt-hist-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/history"
        var h = InputHistory()
        h.add("simple"); h.add("two\nlines \\ and a slash"); h.add("\u{4F60}\u{597D}")
        XCTAssertTrue(h.save(path: path))
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(InputHistory.load(path: path).entries, h.entries)
        XCTAssertEqual(InputHistory.load(path: folder + "/missing").entries, [])
    }

    func testSaveTrimsToLimit() throws {
        let path = NSTemporaryDirectory() + "bt-hist-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var h = InputHistory()
        for n in 0..<700 { h.add("l\(n)") }
        h.save(path: path)
        XCTAssertEqual(InputHistory.load(path: path).entries.count, 500)
    }
}
