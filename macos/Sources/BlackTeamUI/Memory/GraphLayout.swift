import Foundation
import CoreGraphics
import BlackTeamKit

/// A small force layout: notes push apart, links pull together. A port of `layout` in Memory.jsx;
/// enough for a few hundred notes. Positions are in a 1000 by 620 space.
enum GraphLayout {
    static let width: Double = 1000
    static let height: Double = 620

    static func positions(nodes: [GraphNode], edges: [GraphEdge]) -> [String: CGPoint] {
        let count = nodes.count
        if count == 0 { return [:] }
        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        var x = (0..<count).map { cos(Double($0) / Double(count) * .pi * 2) * 220 + sin(Double($0) * 7.3) * 40 }
        var y = (0..<count).map { sin(Double($0) / Double(count) * .pi * 2) * 220 + cos(Double($0) * 5.1) * 40 }
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.from], let b = index[edge.to] else { return nil }
            return (a, b)
        }
        let spread = max(70, min(170, 1000 / Double(count).squareRoot()))
        let steps = 260
        for step in 0..<steps {
            var fx = [Double](repeating: 0, count: count), fy = [Double](repeating: 0, count: count)
            let cool = 1 - Double(step) / Double(steps)
            for a in 0..<count {
                for b in (a + 1)..<max(a + 1, count) {
                    var dx = x[a] - x[b], dy = y[a] - y[b]
                    let d2 = dx * dx + dy * dy
                    let f = spread * spread / (d2 == 0 ? 0.01 : d2)
                    dx *= f; dy *= f
                    fx[a] += dx; fy[a] += dy; fx[b] -= dx; fy[b] -= dy
                }
            }
            for (a, b) in links {
                let dx = x[b] - x[a], dy = y[b] - y[a]
                let raw = (dx * dx + dy * dy).squareRoot()
                let d = raw == 0 ? 0.01 : raw
                let f = (d - spread) / d * 0.5
                fx[a] += dx * f; fy[a] += dy * f; fx[b] -= dx * f; fy[b] -= dy * f
            }
            for i in 0..<count {
                fx[i] -= x[i] * 0.11; fy[i] -= y[i] * 0.11
                let raw = (fx[i] * fx[i] + fy[i] * fy[i]).squareRoot()
                let m = raw == 0 ? 1 : raw
                let cap = min(m, 30 * cool + 2)
                x[i] += fx[i] / m * cap; y[i] += fy[i] / m * cap
            }
        }
        let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
        let pad = 70.0
        let sx = (width - pad * 2) / max(1, maxX - minX), sy = (height - pad * 2) / max(1, maxY - minY)
        let scale = min(sx, sy, 3.2)
        let ox = (width - (maxX - minX) * scale) / 2, oy = (height - (maxY - minY) * scale) / 2
        var out: [String: CGPoint] = [:]
        for (i, node) in nodes.enumerated() { out[node.id] = CGPoint(x: (x[i] - minX) * scale + ox, y: (y[i] - minY) * scale + oy) }
        return out
    }
}
