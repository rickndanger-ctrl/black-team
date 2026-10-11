import SwiftUI
import BlackTeamKit

// The panels under and beside a reply (Panels.jsx and ContextReport in App.jsx).

/// How much of the model's window the conversation takes, and what was left out (`ContextReport` in App.jsx).
struct ContextReportView: View {
    let info: ContextInfo
    var open = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        let used = max(0, min(100, Double(info.measured) / Double(info.context) * 100))
        let reserve = info.maxTokens.map { max(0, min(100 - used, Double($0) / Double(info.context) * 100)) } ?? 0
        BTDisclosure("Context control", detail: "\(Int(used.rounded()))% used\(info.omitted > 0 ? " \u{00B7} Adjusted" : " \u{00B7} Within budget")", open: open) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(theme.accent).frame(width: geo.size.width * CGFloat(used / 100))
                    Rectangle().fill(theme.line2).frame(width: geo.size.width * CGFloat(reserve / 100))
                    Spacer(minLength: 0)
                }
                .background(theme.line)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 4).padding(.top, 1).padding(.bottom, 16)
            .accessibilityElement()
            .accessibilityLabel("Input context used")
            .accessibilityValue("\(Fmt.number(info.measured)) input tokens of \(Fmt.number(info.context))")
            WrapRow(spacing: 30, lineSpacing: 14) {
                stat(info.estimated ? "Estimated conversation input" : "Conversation input", "\(Fmt.number(info.measured)) tokens")
                stat("Reserved for reply", info.maxTokens.map { "\(Fmt.number($0)) tokens" } ?? "\u{2014}")
                stat("Model context", "\(Fmt.number(info.context)) tokens")
            }
            Text(info.omitted > 0
                 ? "\(info.omitted) older \(info.omitted == 1 ? "message was" : "messages were") left out of this reply\u{2019}s context. The full conversation stays saved on your computer."
                 : "This reply includes all eligible completed turns. Your current message and system instructions are preserved.")
                .btBody(11, 1.8, theme.muted).padding(.top, 12)
            Text(info.estimated ? "Estimated locally, not a tokenizer measurement. Match context settings to your server; its template and truncation behavior can differ." : "Measured locally \u{00B7} No hosted context service")
                .font(BTFont.body(9)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading).padding(.bottom, 5)
            Text(value).font(BTFont.mono(11)).foregroundStyle(theme.ink)
        }
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

/// Every tool step the agent took, in order (`WorkLog`).
struct WorkLogView: View {
    let events: [ToolEvent]
    var open = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        BTDisclosure("Work log", detail: "\(events.filter { $0.type == "tool_use" }.count) tool actions", open: open) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 0) {
                    Text(prefix(event) + event.name).font(BTFont.body(12, .semibold)).foregroundStyle(event.error ? theme.bad : theme.ink)
                        .btLines(12, 1.5)
                    if !event.output.isEmpty {
                        Text(event.output).font(BTFont.mono(10)).foregroundStyle(theme.ink2).lineLimit(14)
                            .padding(.horizontal, 17).padding(.vertical, 15).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func prefix(_ event: ToolEvent) -> String {
        switch event.type {
        case "tool_use": return "\u{2197} "
        case "tool_result": return event.error ? "! " : "\u{2713} "
        default: return ""
        }
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

/// Files the agent published: a link to open each one, as the web app offers a download (`{name} · Download`).
struct PublishedFilesView: View {
    let files: [PublishedFile]
    let model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Button { model.open(file: file) } label: {
                        Text("\(file.name) \u{00B7} Open").font(BTFont.body(13)).underline().foregroundStyle(theme.ink2)
                    }
                    .buttonStyle(.plain)
                    Button("Reveal in Finder") { model.reveal(file) }.buttonStyle(.btQuiet)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// A command the agent wants to run, waiting for the person's answer (`.approval-card`).
struct ApprovalCard: View {
    let approval: ApprovalSummary
    let disabled: Bool
    let answer: (String) -> Void
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your decision").font(BTFont.body(14, .semibold)).foregroundStyle(theme.ink).padding(.bottom, 8)
            Text(approval.description).btBody(12, 1.6, theme.ink2).padding(.bottom, 12)
            Text(approval.command)
                .font(BTFont.mono(11)).foregroundStyle(theme.ink2)
                .textSelection(.enabled)
                .padding(.horizontal, 17).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
                .padding(.bottom, 14)
            HStack(spacing: 10) {
                Button("Approve once") { answer("once") }.buttonStyle(.btPrimary).disabled(disabled)
                Button("Deny") { answer("deny") }.buttonStyle(.btSecondary).disabled(disabled)
            }
        }
        .padding(21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous).fill(theme.warnBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous).stroke(theme.warnLine, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
