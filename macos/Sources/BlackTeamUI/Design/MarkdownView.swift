import SwiftUI
import AppKit
import BlackTeamKit

/// Draws the Markdown parser's blocks. Text is selectable. Links open in the browser only when they
/// are http or https (the parser already refuses anything else), and their address stays visible,
/// as in the web app, so a reply cannot send anyone anywhere unseen.
struct MarkdownView: View {
    private let blocks: [MarkdownBlock]
    var size: CGFloat = 13

    init(_ text: String, size: CGFloat = 13) {
        self.blocks = Markdown.parse(text)
        self.size = size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], size: size, first: index == 0, last: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// Builds styled text from inline nodes.
struct MarkdownInlineStyle {
    let theme: Theme
    let size: CGFloat
    var bold = false
    var italic = false
    var strike = false
    var color: Color?

    func text(_ nodes: [MarkdownInline]) -> Text { Text(attributed(nodes)) }

    func attributed(_ nodes: [MarkdownInline]) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            switch node {
            case .text(let s):
                out.append(run(s))
            case .code(let s):
                var a = AttributedString("\u{2009}\u{2009}" + s + "\u{2009}\u{2009}")
                a.font = BTFont.mono(12)
                a.foregroundColor = theme.ink
                a.backgroundColor = theme.field
                if strike { a.strikethroughStyle = .single }
                out.append(a)
            case .strong(let c):
                var inner = self; inner.bold = true
                out.append(inner.attributed(c))
            case .em(let c):
                var inner = self; inner.italic = true
                out.append(inner.attributed(c))
            case .strike(let c):
                var inner = self; inner.strike = true
                out.append(inner.attributed(c))
            case .link(let label, let href):
                var a = run(label)
                a.underlineStyle = .single
                if let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { a.link = url }
                out.append(a)
                if label != href {
                    var small = AttributedString(" (\(href))")
                    small.font = BTFont.body(size - 1)
                    small.foregroundColor = theme.muted
                    out.append(small)
                }
            }
        }
        return out
    }

    private func run(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        var font = BTFont.body(size, bold ? .semibold : .regular)
        if italic { font = font.italic() }
        a.font = font
        a.foregroundColor = color ?? theme.ink
        if strike { a.strikethroughStyle = .single }
        return a
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let size: CGFloat
    var first = false
    var last = false
    @Environment(\.btTheme) private var theme

    /// 13 point text on a 1.8 line, as `.message-body` sets it.
    private func lined(_ text: Text, _ lineSize: CGFloat, _ lineHeight: CGFloat = 1.8) -> some View {
        let extra = max(0, lineSize * lineHeight - BTFont.natural(lineSize))
        return text.lineSpacing(extra).fixedSize(horizontal: false, vertical: true).padding(.vertical, extra / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ level: Int, _ c: [MarkdownInline]) -> some View {
        let headingSize: CGFloat = level == 1 ? 17 : (level == 2 ? 15 : 13)
        var s = MarkdownInlineStyle(theme: theme, size: headingSize)
        s.bold = true
        return lined(s.text(c).tracking(-0.01 * headingSize), headingSize, 1.4)
            .padding(.top, first ? 0 : 16).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var style: MarkdownInlineStyle { MarkdownInlineStyle(theme: theme, size: size) }

    var body: some View {
        let bottom: CGFloat = last ? 0 : 10
        switch block {
        case .paragraph(let c):
            lined(style.text(c), size).padding(.bottom, bottom)
        case .heading(let level, let c):
            heading(level, c)
        case .code(_, let text):
            MarkdownCodeBlock(text: text).padding(.bottom, bottom)
        case .rule:
            Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 14)
        case .quote(let children):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children.indices, id: \.self) { MarkdownBlockView(block: children[$0], size: size, first: $0 == 0, last: $0 == children.count - 1) }
            }
            .foregroundStyle(theme.ink2)
            .padding(.leading, 14).padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(theme.line2).frame(width: 2) }
            .padding(.bottom, bottom)
        case .list(let list):
            MarkdownListView(list: list, level: 0, size: size).padding(.bottom, bottom)
        case .table(let head, let rows):
            MarkdownTable(head: head, rows: rows, size: size).padding(.bottom, bottom)
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let level: Int
    let size: CGFloat
    @Environment(\.btTheme) private var theme

    var body: some View {
        let extra = max(0, size * 1.8 - BTFont.natural(size))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineStyle(theme: theme, size: size).text(item.children)
                        .lineSpacing(extra).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let nested = item.list { MarkdownListView(list: nested, level: level + 1, size: size).padding(.top, 2) }
                }
                .padding(.vertical, extra / 2)
                .overlay(alignment: .topLeading) {
                    Text(marker(index)).font(BTFont.body(size)).foregroundStyle(theme.ink)
                        .frame(width: 22, alignment: .trailing).offset(x: -28, y: extra / 2)
                }
            }
        }
        .padding(.leading, 22)
    }

    private func marker(_ index: Int) -> String {
        if list.ordered { return "\(list.start + index)." }
        return ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(level, 2)]
    }
}

/// `pre.md-code`: 14 by 16 padding, a field-coloured box with a hairline, 12 point mono on a 1.6 line, no header.
private struct MarkdownCodeBlock: View {
    let text: String
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        codeBody
            .padding(.horizontal, 17).padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
    }

    @ViewBuilder private var codeBody: some View {
        let extra = max(0, 12 * 1.6 - BTFont.natural(12, mono: true))
        let label = Text(text.isEmpty ? " " : text).font(BTFont.mono(12)).foregroundStyle(theme.ink).lineSpacing(extra)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if flat {
            label.padding(.vertical, extra / 2).frame(maxWidth: .infinity, alignment: .leading)
        } else if lines > 28 {
            ScrollView([.horizontal, .vertical]) { label.fixedSize().frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 420)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { label.fixedSize().padding(.vertical, extra / 2).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

private struct MarkdownTable: View {
    let head: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
    let size: CGFloat
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        if flat { grid } else { ScrollView(.horizontal, showsIndicators: false) { grid } }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(head.indices, id: \.self) { cell(head[$0], header: true) }
            }
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { cell(rows[r][$0], header: false) }
                }
            }
        }
        .overlay(Rectangle().stroke(theme.line, lineWidth: 1))
    }

    private func cell(_ nodes: [MarkdownInline], header: Bool) -> some View {
        var style = MarkdownInlineStyle(theme: theme, size: 12)
        style.bold = header
        return style.text(nodes)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(header ? theme.field : .clear)
            .overlay(Rectangle().stroke(theme.line, lineWidth: 0.5))
    }
}
