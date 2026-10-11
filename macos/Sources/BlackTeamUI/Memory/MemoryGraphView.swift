import SwiftUI
import BlackTeamKit

/// The link graph drawn with Canvas: notes as dots, links as lines (the `Graph` of Memory.jsx).
struct MemoryGraphView: View {
    let graph: MemoryGraph
    let positions: [String: CGPoint]
    let selected: String?
    let onOpen: (String) -> Void
    @State private var hover: String?
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    private var degree: [String: Int] {
        var d: [String: Int] = [:]
        for edge in graph.edges { d[edge.from, default: 0] += 1; d[edge.to, default: 0] += 1 }
        return d
    }

    private func radius(_ id: String, _ degree: [String: Int]) -> CGFloat { 5 + min(9, CGFloat(degree[id] ?? 0) * 1.6) }

    /// `.own` (project notes) are the accent, `.core` is green, the rest are muted.
    private func colour(_ node: GraphNode) -> Color {
        if node.missing { return theme.line2 }
        switch node.kind {
        case .project: return theme.accent
        case .core: return theme.ok
        default: return theme.muted
        }
    }

    var body: some View {
        if graph.nodes.isEmpty {
            Text("No notes yet. Notes and the links between them appear here.").font(BTFont.body(12.5)).foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            let degree = degree
            GraphFrame(maxHeight: metrics.windowHeight * 0.68) { GeometryReader { geo in
                let s = min(geo.size.width / GraphLayout.width, geo.size.height / GraphLayout.height)
                let ox = (geo.size.width - GraphLayout.width * s) / 2, oy = (geo.size.height - GraphLayout.height * s) / 2
                Canvas { ctx, _ in draw(ctx, degree: degree, scale: s, ox: ox, oy: oy) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover = hit(point, degree: degree, scale: s, ox: ox, oy: oy)
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture { point in
                        if let id = hit(point, degree: degree, scale: s, ox: ox, oy: oy),
                           let node = graph.nodes.first(where: { $0.id == id }), !node.missing { onOpen(id) }
                    }
            } }
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).stroke(theme.line, lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel("Memory graph: \(graph.nodes.count) notes, \(graph.edges.count) links")
        }
    }

    private func hit(_ point: CGPoint, degree: [String: Int], scale s: CGFloat, ox: CGFloat, oy: CGFloat) -> String? {
        let p = CGPoint(x: (point.x - ox) / s, y: (point.y - oy) / s)
        var best: (String, CGFloat)?
        for node in graph.nodes {
            guard let at = positions[node.id] else { continue }
            let d = hypot(at.x - p.x, at.y - p.y)
            if d <= radius(node.id, degree) + 8, d < (best?.1 ?? .infinity) { best = (node.id, d) }
        }
        return best?.0
    }

    private func draw(_ context: GraphicsContext, degree: [String: Int], scale s: CGFloat, ox: CGFloat, oy: CGFloat) {
        var ctx = context
        ctx.translateBy(x: ox, y: oy)
        ctx.scaleBy(x: s, y: s)
        let focus = hover ?? selected
        var near: Set<String>?
        if let focus {
            var set: Set<String> = [focus]
            for edge in graph.edges { if edge.from == focus { set.insert(edge.to) }; if edge.to == focus { set.insert(edge.from) } }
            near = set
        }
        for edge in graph.edges {
            guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
            var path = Path(); path.move(to: a); path.addLine(to: b)
            let lit = near != nil && (edge.from == focus || edge.to == focus)
            let dim = near != nil && !lit
            ctx.stroke(path, with: .color((lit ? theme.accent : theme.line2).opacity(dim ? 0.18 : 1)), lineWidth: lit ? 1.4 : 1)
        }
        for node in graph.nodes {
            guard let at = positions[node.id] else { continue }
            let r = radius(node.id, degree)
            let dim = near != nil && !(near!.contains(node.id))
            let selectedNode = node.id == selected || node.id == hover
            let rect = CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)
            var layer = ctx
            layer.opacity = dim ? 0.18 : 1
            if node.missing {
                layer.stroke(Path(ellipseIn: rect), with: .color(theme.line2), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            } else {
                layer.fill(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(theme.field))
                layer.fill(Path(ellipseIn: rect.insetBy(dx: 0, dy: 0)), with: .color(selectedNode ? theme.accent2 : colour(node)))
                if selectedNode { layer.stroke(Path(ellipseIn: rect), with: .color(theme.accent), lineWidth: 2) }
            }
            let title = node.title.count > 26 ? String(node.title.prefix(25)) + "\u{2026}" : node.title
            let bright = node.kind == .project || selectedNode
            layer.draw(Text(title).font(BTFont.body(10)).foregroundColor(bright ? theme.ink : theme.muted), at: CGPoint(x: at.x, y: at.y + r + 13 - 4), anchor: .center)
        }
    }
}


/// `width: 100%; height: auto; max-height: 68vh` on a 1000 by 620 drawing.
struct GraphFrame: Layout {
    var maxHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 930
        return CGSize(width: width, height: min(width * 0.62, maxHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
