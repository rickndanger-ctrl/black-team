import SwiftUI

/// The sizes the daily app's media queries give at the current window width (app.css: 1050, 760 and 1550 points).
struct Metrics: Equatable {
    var windowWidth: CGFloat = 1280
    var windowHeight: CGFloat = 800

    /// Up to 1050 points: the narrow desktop layout.
    var compact: Bool { windowWidth <= 1050 }
    var wide: Bool { windowWidth >= 1550 }
    var sidebarWidth: CGFloat { compact ? 208 : 240 }
    var sidebarTop: CGFloat { compact ? 24 : 28 }
    var sidebarSide: CGFloat { compact ? 12 : 16 }
    /// `clamp(24px, 4vw, 56px)`; the narrow layout uses 24.
    var mainSide: CGFloat { compact ? 24 : min(56, max(24, windowWidth * 0.04)) }
    var mainTop: CGFloat { compact ? 28 : 40 }
    var mainBottom: CGFloat { compact ? 28 : 26 }
    var maxMain: CGFloat { 1500 }
}

private struct ControlHeightKey: EnvironmentKey { static let defaultValue: CGFloat = Theme.control }
extension EnvironmentValues {
    /// 38 points, or 32 for a button the CSS shrinks (`.memory-usage .secondary`).
    var btControlHeight: CGFloat {
        get { self[ControlHeightKey.self] }
        set { self[ControlHeightKey.self] = newValue }
    }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics() }
extension EnvironmentValues {
    var btMetrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

/// A divider-topped block: `border-top: 1px solid var(--line)` with the padding above the content.
struct BTRule: ViewModifier {
    @Environment(\.btTheme) private var theme
    var top: CGFloat = 0
    func body(content: Content) -> some View {
        content.padding(.top, top).overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }
}
extension View {
    func btRule(paddingTop: CGFloat = 0) -> some View { modifier(BTRule(top: paddingTop)) }
}

/// A quiet outlined note: the `.inline-note` left rule with muted text.
struct BTInlineNote<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme
    var body: some View {
        content
            .padding(.leading, 14).padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(theme.line2).frame(width: 2) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The browser's own checkbox on a dark page (Chromium): 13 points, a pale blue fill with a dark tick when ticked.
struct BTCheckMark: View {
    let on: Bool
    var size: CGFloat = 13
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5).fill(on ? Color(css: "#99c8ff") : Color(css: "#3b3b3b"))
            if !on { RoundedRectangle(cornerRadius: 2.5).stroke(Color(css: "#767676"), lineWidth: 1) }
            if on { IconView(.check, size: size * 0.8, stroke: 3).foregroundStyle(Color(css: "#3b3b3b")) }
        }
        .frame(width: size, height: size)
    }
}

/// CSS grid columns of unequal width: `grid-template-columns: 1fr 1.3fr 1fr` with a gap. Every child gets its column's
/// width and the full row height; the row is as tall as its tallest child.
struct FractionalColumns: Layout {
    var fractions: [CGFloat]
    var spacing: CGFloat = 0

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let fr = Array(fractions.prefix(max(count, 0)))
        let sum = fractions.reduce(0, +)
        let available = total - spacing * CGFloat(fractions.count - 1)
        return fr.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let columnWidths = widths(total, count: subviews.count)
        var height: CGFloat = 0
        for (index, view) in subviews.enumerated() where index < columnWidths.count {
            height = max(height, view.sizeThatFits(ProposedViewSize(width: columnWidths[index], height: nil)).height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidths = widths(bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() where index < columnWidths.count {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: columnWidths[index], height: bounds.height))
            x += columnWidths[index] + spacing
        }
    }
}

/// A wrapping row: `display: flex; flex-wrap: wrap; gap`. Children keep their own width; a row breaks when the next does not fit.
struct WrapRow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += rowHeight + lineSpacing; x = 0; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowHeight + lineSpacing; x = bounds.minX; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y + (rowHeight == 0 ? 0 : 0)), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}


/// CSS `display: grid` with equal columns: every child gets its column's width, and a row is as tall as its tallest child.
struct EqualColumns: Layout {
    var columns: Int
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat?

    private func width(_ total: CGFloat) -> CGFloat { (total - spacing * CGFloat(columns - 1)) / CGFloat(columns) }

    private func rows(_ subviews: Subviews, _ w: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let heights = rows(subviews, width(total))
        return CGSize(width: total, height: heights.reduce(0, +) + (rowSpacing ?? spacing) * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = width(bounds.width)
        let heights = rows(subviews, w)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (w + spacing), y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: w, height: height))
            }
            y += height + (rowSpacing ?? spacing)
        }
    }
}
