import SwiftUI
import BlackTeamKit

// The panels under and beside a reply (Panels.jsx and ContextReport in App.jsx).

/// What the context held for this reply, as a warm line under it (`.message-note`).
struct ContextNote: View {
    let info: ContextInfo
    @Environment(\.btTheme) private var theme
    var body: some View {
        Text("Context\(info.imageReserve != nil ? " (text + image reserve)" : ""): \(Fmt.number(info.measured)) / \(Fmt.number(info.context)) tokens"
             + (info.maxTokens.map { " \u{00B7} \(Fmt.number($0)) reserved for reply" } ?? "")
             + (info.omitted > 0 ? " \u{00B7} Older turns excluded from this reply; full history stays saved." : ""))
            .btBody(11, 1.8, theme.warn).textSelection(.enabled).padding(.top, 10)
    }
}

/// Measured speed and how full the working budget is, so "why is it slow" answers itself (`.speed-meter`).
struct SpeedMeterView: View {
    let meter: SpeedInfo
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            if let read = meter.read { Text("\(read)").foregroundStyle(theme.ink2); Text("t/s read") }
            Text("\(meter.write)").foregroundStyle(theme.ink2); Text("t/s write")
            if let share = meter.share {
                Capsule().fill(theme.line).frame(width: 54, height: 3)
                    .overlay(alignment: .leading) { Rectangle().fill(share > 85 ? theme.warn : theme.accent).frame(width: 54 * CGFloat(share) / 100) }
                    .clipShape(Capsule())
                Text("\(share)%").foregroundStyle(theme.ink2)
            }
        }
        .font(BTFont.mono(10)).tracking(0.4)
        .foregroundStyle(theme.faint)
        .lineLimit(1).fixedSize()
        .help(meter.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.detail)
    }
}

/// What Code changed in files this turn: each edit as a diff, with a way to put the file back (`.changes`).
struct ChangesView: View {
    let changes: [FileChange]
    let busy: Bool
    let onUndo: (String) -> Bool
    @State private var undone: Set<String> = []
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(changes.count) file \(changes.count == 1 ? "change" : "changes")".uppercased())
                .font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint).frame(height: 11.9)
            ForEach(changes) { change in
                ChangeRow(change: change, busy: busy, isUndone: undone.contains(change.id)) {
                    if onUndo(change.id) { undone.insert(change.id) }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let busy: Bool
    let isUndone: Bool
    @State var open = false
    let undo: () -> Void
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { open.toggle() } label: {
                    HStack(spacing: 12) {
                        Text(change.path).font(BTFont.mono(12)).foregroundStyle(isUndone ? theme.muted : theme.ink).strikethrough(isUndone)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        (Text((change.created ? "new file \u{00B7} " : "")) + Text("+\(change.added)").foregroundStyle(theme.ok) + Text(" ")
                            + Text("\u{2212}\(change.removed)").foregroundStyle(theme.bad))
                            .font(BTFont.mono(11)).foregroundStyle(theme.muted).lineLimit(1).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isUndone { Text("Undone").font(BTFont.body(11)).foregroundStyle(theme.faint) }
                else {
                    Button(action: undo) {
                        Text("Undo").font(BTFont.body(11, .medium)).foregroundStyle(theme.ink)
                            .padding(.horizontal, 10).frame(height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.45 : 1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if open { DiffView(change.diff.isEmpty ? "No text difference to show." : change.diff).opacity(isUndone ? 0.5 : 1) }
        }
        .padding(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
    }
}

/// `.tool-timeline`: "N tool actions · View work", opening onto every step in order.
struct WorkLogView: View {
    let events: [ToolEvent]
    var open = false
    @State private var shown = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { shown.toggle() } label: {
                HStack(spacing: 6) {
                    Triangle().fill(theme.ink2).frame(width: 7, height: 8).rotationEffect(.degrees(shown || open ? 90 : 0))
                    Text("\(events.filter { $0.type == "tool_use" }.count) tool actions \u{00B7} View work").font(BTFont.body(12)).foregroundStyle(theme.ink2).underline(true, color: theme.ink2)
                    Spacer(minLength: 0)
                }
                .frame(height: 20.4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(events.filter { $0.type == "tool_use" }.count) tool actions, View work")
            if shown || open {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(prefix(event) + event.name).font(BTFont.mono(10)).foregroundStyle(event.error ? theme.bad : theme.ink2)
                            .frame(height: 15, alignment: .leading).padding(.bottom, 6)
                        Text(event.output.isEmpty ? "Finished" : event.output).font(BTFont.mono(10)).foregroundStyle(theme.ink2).lineLimit(14)
                            .lineSpacing(max(0, 10 * 1.6 - BTFont.natural(10, mono: true)))
                            .padding(.horizontal, 16).padding(.vertical, 14).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
                    }
                    .padding(.top, 12)
                }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func prefix(_ event: ToolEvent) -> String {
        switch event.type {
        case "tool_use": return "\u{2197} "
        case "tool_result": return event.error ? "! " : "\u{2713} "
        default: return ""
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
        return p
    }
}

/// The plan the agent keeps current while it works.
struct TodoView: View {
    let items: [TodoEntry]
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To do \u{00B7} \(items.filter(\.done).count) of \(items.count) done".uppercased()).font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BTCheckMark(on: item.done, size: 12)
                    Text(item.text).font(BTFont.body(12)).strikethrough(item.done).foregroundStyle(item.done ? theme.muted : theme.ink)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// `.file-card`: a file the agent published, with a download and the transfer row the Mac does not have yet.
struct FileCard: View {
    let file: PublishedFile
    let model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\u{21A7} \(file.name)").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                    Text(String(format: "%.1f KB", Double(file.size) / 1024) + " \u{00B7} Private attachment").font(BTFont.body(10)).foregroundStyle(theme.muted).padding(.top, 4)
                }
                Spacer(minLength: 0)
                Button { model.open(file: file) } label: { Text("Download").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink).padding(.horizontal, 16).frame(height: 38).overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(theme.line2, lineWidth: 1)).contentShape(Rectangle()) }.buttonStyle(.plain)
                Button("Reveal in Finder") { model.reveal(file) }.buttonStyle(.btQuiet)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
    }
}
