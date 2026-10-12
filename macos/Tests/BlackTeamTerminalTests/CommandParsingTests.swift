import XCTest
@testable import BlackTeamTerminal

final class SlashTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Slash.parse("hello"), .notCommand)
        XCTAssertEqual(Slash.parse("/help"), .command("help", argument: ""))
        XCTAssertEqual(Slash.parse("  /pace   deep "), .command("pace", argument: "deep"))
        XCTAssertEqual(Slash.parse("/team \"ship it\""), .command("team", argument: "\"ship it\""))
        XCTAssertEqual(Slash.parse("/Quit"), .command("quit", argument: ""))
        XCTAssertEqual(Slash.parse("/exit"), .command("quit", argument: ""))
        XCTAssertEqual(Slash.parse("/nope now"), .unknown("nope"))
        XCTAssertEqual(Slash.parse("/"), .unknown(""))
    }

    func testPathsAreNotCommands() {
        XCTAssertEqual(Slash.parse("/home/me/file.txt what is in it"), .notCommand)
    }

    func testEveryCommandInTheBriefExists() {
        let names = Set(Slash.all.map(\.name))
        for name in ["chat", "code", "new", "resume", "model", "agent", "permission", "pace", "project", "image", "undo", "team", "status", "memory", "quit", "help"] {
            XCTAssertTrue(names.contains(name), name)
            XCTAssertEqual(Slash.parse("/\(name)"), .command(name, argument: ""))
        }
        XCTAssertTrue(Slash.helpText().contains("/resume"))
    }

    func testWordsKeepQuotedPiecesTogether() {
        XCTAssertEqual(Slash.words("a b  c"), ["a", "b", "c"])
        XCTAssertEqual(Slash.words("\"make it work\" now"), ["make it work", "now"])
        XCTAssertEqual(Slash.words("'x y'"), ["x y"])
        XCTAssertEqual(Slash.words(""), [])
        XCTAssertEqual(Slash.words("\"\""), [""])
    }

    func testCompletion() {
        XCTAssertEqual(Slash.complete("/he"), "/help")
        XCTAssertEqual(Slash.complete("/res"), "/resume ")
        XCTAssertEqual(Slash.complete("/st"), "/status")
        XCTAssertNil(Slash.complete("/c"))                 // chat or code: nothing certain
        XCTAssertEqual(Slash.complete("/ch"), "/chat")
        XCTAssertEqual(Slash.complete("/p"), nil)          // permission, pace, project
        XCTAssertEqual(Slash.complete("/pe"), "/permission ")
        XCTAssertNil(Slash.complete("/zzz"))
        XCTAssertNil(Slash.complete("hello"))
        XCTAssertNil(Slash.complete("/help"))
    }

    func testArgumentCompletion() {
        XCTAssertEqual(Slash.complete("/agent cl"), "/agent claude")
        XCTAssertEqual(Slash.complete("/agent o"), "/agent off")
        XCTAssertEqual(Slash.complete("/pace ex"), "/pace extended")
        XCTAssertEqual(Slash.complete("/permission a"), nil)   // ask or auto
        XCTAssertEqual(Slash.complete("/permission as"), "/permission ask")
        XCTAssertNil(Slash.complete("/model 1"))
    }
}

final class PromptAndStyleTests: XCTestCase {
    func testPromptText() {
        XCTAssertEqual(PromptText.plain(mode: "chat", who: "Ornith 1.5 9B"), "chat \u{00B7} Ornith 1.5 9B \u{203A} ")
        XCTAssertEqual(PromptText.plain(mode: "code", who: "Claude Code", permission: "edit"), "code \u{00B7} Claude Code [edit] \u{203A} ")
    }

    func testStyledPromptMeasuresLikePlain() {
        let on = Style(enabled: true)
        let styled = PromptText.styled(mode: "code", who: "Claude Code", permission: "edit", style: on)
        XCTAssertTrue(styled.contains("\u{1B}["))
        XCTAssertEqual(DisplayWidth.visible(styled), DisplayWidth.of(PromptText.plain(mode: "code", who: "Claude Code", permission: "edit")))
        let off = Style(enabled: false)
        XCTAssertEqual(PromptText.styled(mode: "chat", who: "X", style: off), PromptText.plain(mode: "chat", who: "X"))
        XCTAssertFalse(off.red("x").contains("\u{1B}"))
    }

    func testColourRules() {
        XCTAssertTrue(Style.decide(isTerminal: true, environment: ["TERM": "xterm-256color"]))
        XCTAssertFalse(Style.decide(isTerminal: false, environment: ["TERM": "xterm"]))
        XCTAssertFalse(Style.decide(isTerminal: true, environment: ["NO_COLOR": "1", "TERM": "xterm"]))
        XCTAssertFalse(Style.decide(isTerminal: true, environment: ["NO_COLOR": "", "TERM": "xterm"]))
        XCTAssertFalse(Style.decide(isTerminal: true, environment: ["TERM": "dumb"]))
    }
}

final class OneShotTests: XCTestCase {
    func testWhenItApplies() {
        XCTAssertTrue(OneShotOptions.isOneShot(["-p", "hi"]))
        XCTAssertTrue(OneShotOptions.isOneShot(["--json", "--print", "hi"]))
        XCTAssertTrue(OneShotOptions.isOneShot(["-p"]))
        XCTAssertFalse(OneShotOptions.isOneShot(["chat", "hi", "-p"]))
        XCTAssertFalse(OneShotOptions.isOneShot([]))
        XCTAssertFalse(OneShotOptions.isOneShot(["status"]))
    }

    func testDefaults() throws {
        let o = try OneShotOptions.parse(["-p", "hello", "there"])
        XCTAssertEqual(o.message, "hello there")
        XCTAssertEqual(o.approve, "deny"); XCTAssertFalse(o.allowCloud); XCTAssertFalse(o.code); XCTAssertFalse(o.json)
        XCTAssertEqual(o.pace, "balanced")
    }

    func testNoMessageMeansReadStandardInput() throws {
        XCTAssertNil(try OneShotOptions.parse(["-p"]).message)
    }

    func testOptions() throws {
        let o = try OneShotOptions.parse(["-p", "--code", "--json", "--approve", "once", "--allow-cloud", "--pace", "deep", "--workspace", "/tmp/x", "fix it"])
        XCTAssertTrue(o.code); XCTAssertTrue(o.json); XCTAssertEqual(o.approve, "once"); XCTAssertTrue(o.allowCloud)
        XCTAssertEqual(o.pace, "deep"); XCTAssertEqual(o.workspace, "/tmp/x"); XCTAssertEqual(o.message, "fix it")
    }

    func testRefusals() {
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--approve", "always", "x"]))
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--mode", "slow", "x"]))
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--approve"]))
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--nonsense", "x"]))
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--code", "--image", "a.png", "x"]))
        XCTAssertThrowsError(try OneShotOptions.parse(["-p", "--workspace", "/tmp", "x"]))
    }

    func testDoubleDashEndsOptions() throws {
        XCTAssertEqual(try OneShotOptions.parse(["-p", "--", "--code", "is", "text"]).message, "--code is text")
    }

    func testImagesAndThread() throws {
        let o = try OneShotOptions.parse(["-p", "--image", "a.png", "--image", "b.png", "--thread", "abc", "what is this"])
        XCTAssertEqual(o.images, ["a.png", "b.png"]); XCTAssertEqual(o.thread, "abc")
    }
}
