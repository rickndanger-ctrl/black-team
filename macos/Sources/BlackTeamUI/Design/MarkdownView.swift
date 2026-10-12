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

    /// Inline code is drawn as a chip (a field-coloured box with a hairline and rounded corners, as `.md code` is),
    /// so the text is built from runs of styled text and chip images joined together.
    func text(_ nodes: [MarkdownInline]) -> Text {
        var parts: [Text] = []
        var run = AttributedString()
        func flush() { if !run.characters.isEmpty { parts.append(Text(run)); run = AttributedString() } }
        func walk(_ nodes: [MarkdownInline], _ style: MarkdownInlineStyle) {
            for node in nodes {
                switch node {
                case .code(let s):
                    flush()
                    parts.append(Text(Image(nsImage: CodeChip.image(s, theme: theme, strike: style.strike))).baselineOffset(-5.5))
                case .strong(let c):
                    var inner = style; inner.bold = true; walk(c, inner)
                case .em(let c):
                    var inner = style; inner.italic = true; walk(c, inner)
                case .strike(let c):
                    var inner = style; inner.strike = true; walk(c, inner)
                default:
                    run.append(style.attributed([node]))
                }
            }
        }
        walk(nodes, self)
        flush()
        return parts.reduce(Text("")) { $0 + $1 }
    }

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

    var body: some View {
        let columns = max(1, head.count)
        TableLayout(columns: columns) {
            ForEach(head.indices, id: \.self) { cell(head[$0], header: true) }
            ForEach(rows.indices, id: \.self) { r in
                ForEach(0..<columns, id: \.self) { c in cell(c < rows[r].count ? rows[r][c] : [], header: false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ nodes: [MarkdownInline], header: Bool) -> some View {
        var style = MarkdownInlineStyle(theme: theme, size: 12)
        style.bold = header
        let hasCode = nodes.contains { if case .code = $0 { return true } else { return false } }
        let extra = max(0, 12 * 1.8 - BTFont.natural(12))
        return style.text(nodes).lineSpacing(hasCode ? 1.6 : extra).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 5 + (hasCode ? 0 : extra / 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(header ? theme.field : .clear)
            .overlay(Rectangle().stroke(theme.line, lineWidth: 1))
    }
}

/// `table` with automatic layout: each column is as wide as its longest line when there is room; otherwise the room is
/// shared between the columns in proportion to how much each could still shrink, so no column is narrower than its
/// longest word. Cells are top aligned.
private struct TableLayout: Layout {
    var columns: Int

    private func columnWidths(_ subviews: Subviews, available: CGFloat) -> [CGFloat] {
        var mins = [CGFloat](repeating: 0, count: columns), maxs = mins
        for (index, view) in subviews.enumerated() {
            let c = index % columns
            mins[c] = max(mins[c], view.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
            maxs[c] = max(maxs[c], view.sizeThatFits(.unspecified).width)
        }
        let sumMax = maxs.reduce(0, +), sumMin = mins.reduce(0, +)
        if sumMax <= available { return maxs }
        if available <= sumMin { return mins }
        let ratio = (available - sumMin) / (sumMax - sumMin)
        return zip(mins, maxs).map { $0 + ($1 - $0) * ratio }
    }

    private func rowHeights(_ subviews: Subviews, _ widths: [CGFloat]) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            (0..<columns).compactMap { c -> CGFloat? in
                start + c < subviews.count ? subviews[start + c].sizeThatFits(ProposedViewSize(width: widths[c], height: nil)).height : nil
            }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(subviews, available: proposal.width ?? 600)
        return CGSize(width: widths.reduce(0, +), height: rowHeights(subviews, widths).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(subviews, available: bounds.width)
        let heights = rowHeights(subviews, widths)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for c in 0..<columns where row * columns + c < subviews.count {
                subviews[row * columns + c].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: widths[c], height: height))
                x += widths[c]
            }
            y += height
        }
    }
}

/// `.md code`: 12 point mono, 1 by 5 padding, a hairline border and a 5 point radius.
enum CodeChip {
    static func image(_ text: String, theme: Theme, strike: Bool) -> NSImage {
        Fonts.register()
        let font = NSFont(name: "JetBrainsMono-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(theme.ink)]
        if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        let width = ceil(size.width) + 12, height: CGFloat = 20
        let fill = NSColor(theme.field), line = NSColor(theme.line)
        let image = NSImage(size: NSSize(width: width + 2, height: height), flipped: false) { rect in
            let box = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            fill.setFill(); path.fill()
            line.setStroke(); path.lineWidth = 1; path.stroke()
            label.draw(at: NSPoint(x: 7, y: (height - size.height) / 2))
            return true
        }
        image.accessibilityDescription = text
        return image
    }
}
