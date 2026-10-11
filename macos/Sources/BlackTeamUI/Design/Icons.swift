import SwiftUI

/// The icon set from src/Icons.jsx. The Linux app draws these as SVG strokes on a 24 point grid;
/// the same path data is drawn here so every icon has exactly the same shape and weight.
/// Unknown names fall back to `grid`, as the JavaScript does.
enum BTIcon: String, CaseIterable {
    case grid, power, play, chip, chat, folder, terminal, arrow, check, activity, globe, close
    case refresh, work, bolt, send, mic

    init(named name: String) { self = BTIcon(rawValue: name) ?? .grid }

    /// The `d` attribute of the SVG path, copied from Icons.jsx.
    var pathData: String {
        switch self {
        case .grid: return "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z"
        case .power: return "M12 3v9 M6.4 5.6a9 9 0 1 0 11.2 0"
        case .play: return "m8 4 12 8-12 8z"
        case .chip: return "M7 7h10v10H7z M9 3v4 M15 3v4 M9 17v4 M15 17v4 M3 9h4 M3 15h4 M17 9h4 M17 15h4"
        case .chat: return "M21 11a8 8 0 0 1-8 8H6l-4 3V11a9 9 0 0 1 19 0Z"
        case .folder: return "M3 5h6l2 3h10v12H3z"
        case .terminal: return "m5 7 5 5-5 5 M13 17h6"
        case .arrow: return "M5 12h14 m-6-6 6 6-6 6"
        case .check: return "m5 12 4 4L19 6"
        case .activity: return "M2 12h5l3-8 4 16 3-8h5"
        case .globe: return "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18"
        case .close: return "m6 6 12 12 M6 18 18 6"
        case .refresh: return "M20 7v5h-5 M4 17v-5h5 M5 8a8 8 0 0 1 13-3l2 3 M4 16l2 3a8 8 0 0 0 13-3"
        case .work: return "M3 7h18v14H3z M8 7V3h8v4 M3 12h18 M10 12v3h4v-3"
        case .bolt: return "m13 2-9 12h7l-1 8 10-13h-7z"
        case .send: return "m3 3 19 9-19 9 4-9z M7 12h15"
        case .mic: return "M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z M6 11a6 6 0 0 0 12 0 M12 17v4 M9 21h6"
        }
    }

    /// Parsed once, in the 24 by 24 grid.
    var path: Path { BTIcon.cache.path(for: self) }

    private final class Cache: @unchecked Sendable {
        private var items: [BTIcon: Path] = [:]
        private let lock = NSLock()
        func path(for icon: BTIcon) -> Path {
            lock.lock(); defer { lock.unlock() }
            if let hit = items[icon] { return hit }
            let made = SVGPath.parse(icon.pathData)
            items[icon] = made
            return made
        }
    }
    private static let cache = Cache()
}

/// An icon at the Linux app's sizes. `stroke` is in grid units (1.6 in Icons.jsx, 1.5 for the page mark).
struct IconView: View {
    let icon: BTIcon
    var size: CGFloat = 20
    var stroke: CGFloat = 1.6
    init(_ icon: BTIcon, size: CGFloat = 20, stroke: CGFloat = 1.6) { self.icon = icon; self.size = size; self.stroke = stroke }
    var body: some View {
        icon.path
            .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            .frame(width: 24, height: 24)
            .scaleEffect(size / 24, anchor: .topLeading)
            .frame(width: size, height: size, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

/// A small SVG path reader: the commands the icon set uses (M L H V C A Z, absolute and relative).
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in data {
            if ch.isLetter { flush(); tokens.append(String(ch)) }
            else if ch == "-" { flush(); number = "-" }
            else if ch == "." {
                if number.contains(".") { flush() }
                number.append(ch)
            }
            else if ch.isNumber { number.append(ch) }
            else { flush() }
        }
        flush()

        var path = Path()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        func next() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
        func isCommand(_ t: String) -> Bool { t.count == 1 && t.first!.isLetter }

        while index < tokens.count {
            if isCommand(tokens[index]) { command = tokens[index].first!; index += 1 }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                var p = CGPoint(x: next(), y: next())
                if relative { p = CGPoint(x: current.x + p.x, y: current.y + p.y) }
                path.move(to: p); current = p; start = p
                command = relative ? "l" : "L"
            case "L":
                var p = CGPoint(x: next(), y: next())
                if relative { p = CGPoint(x: current.x + p.x, y: current.y + p.y) }
                path.addLine(to: p); current = p
            case "H":
                let x = next(); let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p); current = p
            case "V":
                let y = next(); let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p); current = p
            case "C":
                var c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next()), p = CGPoint(x: next(), y: next())
                if relative {
                    c1 = CGPoint(x: current.x + c1.x, y: current.y + c1.y)
                    c2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                    p = CGPoint(x: current.x + p.x, y: current.y + p.y)
                }
                path.addCurve(to: p, control1: c1, control2: c2); current = p
            case "A":
                let rx = next(), ry = next(), rotation = next(), large = next() != 0, sweep = next() != 0
                var p = CGPoint(x: next(), y: next())
                if relative { p = CGPoint(x: current.x + p.x, y: current.y + p.y) }
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case "Z":
                path.closeSubpath(); current = start
            default:
                index += 1
            }
        }
        return path
    }

    /// SVG's endpoint arc, turned into cubic curves (the standard conversion from the SVG specification).
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy, y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry, cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        func point(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(angle) * cosPhi - ry * sin(angle) * sinPhi, y: cy + rx * cos(angle) * sinPhi + ry * sin(angle) * cosPhi)
        }
        func derivative(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(angle) * cosPhi - ry * cos(angle) * sinPhi, y: -rx * sin(angle) * sinPhi + ry * cos(angle) * cosPhi)
        }
        for _ in 0..<segments {
            let b = a + step
            let s = point(a), e = point(b), ds = derivative(a), de = derivative(b)
            path.addCurve(to: e, control1: CGPoint(x: s.x + t * ds.x, y: s.y + t * ds.y), control2: CGPoint(x: e.x - t * de.x, y: e.y - t * de.y))
            a = b
        }
    }
}
