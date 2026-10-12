import SwiftUI

/// One line of a unified diff, as the Linux app classes it: hunk and file headers faint, added green, removed red.
struct DiffLine: Equatable {
    enum Kind { case hunk, added, removed, context }
    var kind: Kind
    var text: String
}

enum DiffParser {
    static func parse(_ diff: String) -> [DiffLine] {
        diff.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { raw in
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("@@") { return DiffLine(kind: .hunk, text: raw) }
            if raw.hasPrefix("+") { return DiffLine(kind: .added, text: raw) }
            if raw.hasPrefix("-") { return DiffLine(kind: .removed, text: raw) }
            return DiffLine(kind: .context, text: raw)
        }
    }
}

/// `pre.diff`: 11 point mono on a 1.6 line, 14 by 16 padding, a hairline above, one coloured line per row.
struct DiffView: View {
    let lines: [DiffLine]
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat

    init(_ diff: String) { self.lines = DiffParser.parse(diff) }

    var body: some View {
        let extra = max(0, 11 * 1.6 - BTFont.natural(11, mono: true))
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index].text.isEmpty ? " " : lines[index].text).font(BTFont.mono(11)).foregroundStyle(color(lines[index]))
                    .lineSpacing(extra).padding(.vertical, extra / 2).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if flat { rows } else { ScrollView([.horizontal, .vertical]) { rows }.frame(maxHeight: 320) }
        }
        .btRule()
        .textSelection(.enabled)
    }

    private func color(_ line: DiffLine) -> Color {
        switch line.kind {
        case .hunk: return theme.faint
        case .added: return theme.ok
        case .removed: return theme.bad
        case .context: return theme.ink2
        }
    }
}
