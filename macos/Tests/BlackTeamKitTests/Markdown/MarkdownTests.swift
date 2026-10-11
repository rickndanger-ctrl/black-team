import XCTest
@testable import BlackTeamKit

final class MarkdownTests: XCTestCase {
    private func plain(_ nodes: [MarkdownInline]) -> String { nodes.plain }
    private func kind(_ n: MarkdownInline) -> String {
        switch n {
        case .text: return "text"
        case .code: return "code"
        case .strong: return "strong"
        case .em: return "em"
        case .strike: return "strike"
        case .link: return "link"
        }
    }
    private func kind(_ b: MarkdownBlock) -> String {
        switch b {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .code: return "code"
        case .rule: return "rule"
        case .quote: return "quote"
        case .list: return "list"
        case .table: return "table"
        }
    }

    func testFormatsBoldItalicCodeAndStrikeInsideALine() {
        let nodes = Markdown.inline("Ran **`count.py`** and it *worked*, ~~no~~ really: `1 2 3`.")
        XCTAssertEqual(nodes.map(kind), ["text", "strong", "text", "em", "text", "strike", "text", "code", "text"])
        if case .strong(let children) = nodes[1] { XCTAssertEqual(kind(children[0]), "code") } else { XCTFail() }
        XCTAssertEqual(plain(nodes), "Ran count.py and it worked, no really: 1 2 3.")
    }

    func testLeavesArithmeticFileNamesAndCodeContentsAlone() {
        XCTAssertEqual(Markdown.inline("2 * 3 * 4 and my_file_name.py and a_b").count, 1)
        XCTAssertEqual(Markdown.inline("use `**kwargs` here")[1], .code("**kwargs"))
        XCTAssertEqual(Markdown.inline("``a ` b``")[0], .code("a ` b"))
    }

    func testKeepsOnlyWebLinksAndKeepsTheirAddressVisible() {
        XCTAssertEqual(Markdown.inline("[docs](https://example.org/a)")[0], .link(text: "docs", href: "https://example.org/a"))
        XCTAssertFalse(Markdown.inline("[x](javascript:alert(1))").contains { kind($0) == "link" })
    }

    func testReadsHeadingsListsQuotesRulesAndParagraphsAsBlocks() {
        let tree = Markdown.parse("# Done\n\nHere is what changed:\n\n- **Modified** `a.py`\n  wrapped line\n  - nested\n- Ran it\n\n3. one\n4. two\n   - under two\n\n> noted\n\n---\nlast line\nsame paragraph")
        XCTAssertEqual(tree.map(kind), ["heading", "paragraph", "list", "list", "quote", "rule", "paragraph"])
        guard case .list(let first) = tree[2], case .list(let second) = tree[3],
              case .quote(let quoted) = tree[4], case .paragraph(let last) = tree[6] else { return XCTFail() }
        XCTAssertFalse(first.ordered)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(plain(first.items[0].list!.items[0].children), "nested")
        XCTAssertTrue(plain(first.items[0].children).contains("wrapped line"))
        XCTAssertTrue(second.ordered)
        XCTAssertEqual(second.start, 3)
        XCTAssertFalse(second.items[1].list!.ordered)
        XCTAssertEqual(kind(quoted[0]), "paragraph")
        XCTAssertEqual(plain(last), "last line\nsame paragraph")
    }

    func testKeepsCodeBlocksVerbatimIncludingOneStillBeingWritten() {
        let tree = Markdown.parse("Before\n```python\nprint(\"**not bold**\")\n\n# not a heading\n```\nAfter\n```sh\nls -la")
        XCTAssertEqual(tree.map(kind), ["paragraph", "code", "paragraph", "code"])
        XCTAssertEqual(tree[1], .code(lang: "python", text: "print(\"**not bold**\")\n\n# not a heading"))
        XCTAssertEqual(tree[3], .code(lang: "sh", text: "ls -la"))
    }

    func testReadsATableAndPadsShortRows() {
        let tree = Markdown.parse("| Name | Speed |\n|---|---:|\n| read | **49** |\n| write |\n\nafter")
        guard case .table(let head, let rows) = tree[0] else { return XCTFail("not a table") }
        XCTAssertEqual(head.map(plain), ["Name", "Speed"])
        XCTAssertEqual(rows.map { $0.map(plain) }, [["read", "49"], ["write", ""]])
        XCTAssertEqual(kind(tree[1]), "paragraph")
    }

    func testALineWithAPipeButNoDividerStaysAParagraph() {
        XCTAssertEqual(kind(Markdown.parse("a | b\nplain")[0]), "paragraph")
        XCTAssertEqual(Markdown.parse(""), [])
        XCTAssertEqual(Markdown.parse(nil), [])
    }
}
