import SwiftUI
import BlackTeamKit

/// One message in the conversation (the `<article class="message">` of App.jsx): a bordered card, the person's own
/// message pushed 10 percent in from the left on a slightly lighter ground.
struct MessageView: View, Equatable {
    let message: ChatMessage
    let fallbackModel: String
    let glowing: Bool
    let liveLabel: String?
    let busy: Bool
    let canRemember: Bool
    let canRetry: Bool
    unowned let model: AppModel

    static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.fallbackModel == b.fallbackModel && a.glowing == b.glowing && a.liveLabel == b.liveLabel
            && a.busy == b.busy && a.canRemember == b.canRemember && a.canRetry == b.canRetry
    }

    @Environment(\.btTheme) private var theme
    @State private var hover = false

    var body: some View {
        PercentIndent(fraction: message.isUser ? 0.10 : 0) { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if !message.thinking.isEmpty {
                BTPlainDetails(title: "Reasoning") {
                    Text(message.thinking).btBody(12, 1.8, theme.muted).padding(.top, 10)
                }
                .padding(.bottom, 14)
            }
            bodyText
            if !message.recalled.isEmpty {
                Text("Memory used: \(unique(message.recalled.map(\.title)).joined(separator: ", "))")
                    .font(BTFont.mono(10)).tracking(0.4).foregroundStyle(theme.faint).padding(.top, 10)
                    .help(message.recalled.map { "\($0.title): \($0.text)" }.joined(separator: "\n"))
            }
            if !message.isUser, let context = message.context { ContextReportView(info: context).padding(.top, 16) }
            if !message.changes.isEmpty { ChangesView(changes: message.changes, busy: busy) { model.undo($0) }.padding(.top, 14) }
            if !message.events.isEmpty { WorkLogView(events: message.events).padding(.top, 16) }
            if !message.artifacts.isEmpty { PublishedFilesView(files: message.artifacts, model: model).padding(.top, 10) }
            footer
        }
        .padding(.horizontal, 23).padding(.vertical, 21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(message.isUser ? theme.surface2 : theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(message.isUser ? theme.line2 : theme.line, lineWidth: 1))
        .btShadow(message.isUser ? .none : theme.shadow)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(spacing: 12) {
            if !message.isUser { AgentAvatar(state: glowing ? .working : .idle, diameter: 30) }
            Text(message.isUser ? "YOU" : (message.model.isEmpty ? fallbackModel : message.model))
                .font(BTFont.mono(10)).tracking(0.6).foregroundStyle(theme.ink2).lineLimit(1)
            Spacer(minLength: 0)
            if let liveLabel { Text(liveLabel).font(BTFont.mono(9)).foregroundStyle(theme.muted) }
        }
        .frame(minHeight: 15)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var bodyText: some View {
        if !message.isUser, !message.content.isEmpty {
            MarkdownView(message.content)
        } else {
            Text(message.content.isEmpty ? (message.state == "writing" ? "\u{2026}" : "") : message.content)
                .btBody(13, 1.8, theme.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var footer: some View {
        if !message.isUser, canRemember, message.state == "done", !message.content.isEmpty {
            // Shown on hover in the Linux app; here it stays out of the way until the pointer is over the card.
            if hover { RememberLink(model: model, message: message) }
        }
        if !message.note.isEmpty { note(message.note) }
        if message.state == "interrupted" { note("Response stopped. Any text already received is saved here.") }
        if !message.isUser, message.finishReason == "length" {
            note("This reply reached its length limit. Ask the model to continue, or choose a longer reply length for your next message.")
        }
        if message.state == "error" { note(message.error ?? "The response was interrupted. Try again when your model is ready.") }
        if canRetry, ["error", "interrupted"].contains(message.state) {
            Button("Retry") { model.retryLast() }.buttonStyle(.btSecondary).disabled(busy).padding(.top, 10)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).btBody(11, 1.5, theme.warn).textSelection(.enabled).padding(.top, 10)
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// `margin-left: 10%`: the child is placed that fraction of the available width in from the left.
struct PercentIndent: Layout {
    var fraction: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let inner = subviews[0].sizeThatFits(ProposedViewSize(width: width * (1 - fraction), height: nil))
        return CGSize(width: width, height: inner.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let indent = bounds.width * fraction
        subviews[0].place(at: CGPoint(x: bounds.minX + indent, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width - indent, height: bounds.height))
    }
}

/// "Remember this": underlined, 10.5 points, revealed when the pointer is over the message (`.message .remember`).
private struct RememberLink: View {
    let model: AppModel
    let message: ChatMessage
    @Environment(\.btTheme) private var theme
    @State private var hover = false
    var body: some View {
        Button { model.remember(message) } label: {
            Text("Remember this").font(BTFont.body(10.5)).underline().foregroundStyle(hover ? theme.ink : theme.muted)
        }
        .buttonStyle(.plain).padding(.top, 10)
        .help("Save this reply to the Black Team vault")
        .onHover { hover = $0 }
    }
}
