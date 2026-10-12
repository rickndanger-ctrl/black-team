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
    /// The conversation has been sent to a cloud service, so memory plays no part in it.
    var cloud = false
    unowned let model: AppModel
    var threadId: String?

    static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.fallbackModel == b.fallbackModel && a.glowing == b.glowing && a.liveLabel == b.liveLabel
            && a.busy == b.busy && a.canRemember == b.canRemember && a.canRetry == b.canRetry && a.threadId == b.threadId && a.cloud == b.cloud
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
            if message.isUser, !message.images.isEmpty {
                ImagePreviews(items: message.images.map { PreviewItem(id: $0.id, name: $0.name, image: model.sentImage(threadId: threadId, $0)) })
            }
            if cloud, message.isUser {
                Text("Memory is not used in cloud conversations.")
                    .font(BTFont.mono(10)).tracking(0.4).foregroundStyle(theme.faint).padding(.top, 10)
            } else if !message.recalled.isEmpty {
                Text("Memory used: \(unique(message.recalled.map(\.title)).joined(separator: ", "))")
                    .font(BTFont.mono(10)).tracking(0.4).foregroundStyle(theme.faint).padding(.top, 10)
                    .help(message.recalled.map { "\($0.title): \($0.text)" }.joined(separator: "\n"))
            }
            if !message.isUser, let context = message.context { ContextNote(info: context) }
            if !message.changes.isEmpty { ChangesView(changes: message.changes, busy: busy) { model.undo($0) }.padding(.top, 14) }
            if !message.events.isEmpty { WorkLogView(events: message.events).padding(.top, 14) }
            ForEach(message.artifacts) { file in FileCard(file: file, model: model).padding(.top, 14) }
            footer
        }
        .padding(.horizontal, 23).padding(.vertical, 21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(message.isUser ? theme.surface2 : theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(message.isUser ? theme.line2 : theme.line, lineWidth: 1))
        .btShadow(message.isUser ? .none : theme.shadow)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        Group {
            if message.isUser {
                Text("YOU").font(BTFont.mono(10)).tracking(0.6).foregroundStyle(theme.ink2).frame(height: 18, alignment: .leading).padding(.bottom, 10)
            } else {
                HStack(spacing: 12) {
                    AgentAvatar(state: glowing ? .working : .idle, diameter: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BLACK TEAM / \((message.model.isEmpty ? fallbackModel : message.model).uppercased())")
                            .font(BTFont.mono(10)).tracking(0.6).foregroundStyle(theme.ink2).lineLimit(1).frame(height: 15, alignment: .leading)
                        if let liveLabel { Text(liveLabel).font(BTFont.mono(10)).foregroundStyle(theme.muted).frame(height: 14.5, alignment: .leading) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var bodyText: some View {
        if !message.isUser, !message.content.isEmpty {
            MarkdownView(message.content)
        } else {
            Text(message.content.isEmpty ? (message.state == "writing" ? "\u{2026}" : "No response text.") : message.content)
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
        if message.run != nil, !message.isUser, !busy, !message.rollbackNote.isEmpty, !message.rollbackReady, !message.rolledBack {
            note(message.rollbackNote)
        }
        if message.run != nil, !message.isUser, !busy, message.rollbackReady || message.rolledBack, message.state != "writing" {
            RollBackControl(model: model, message: message).padding(.top, 10)
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

/// "Roll back this task" under a subscription agent's finished reply. Asks first; then the reply reads "Rolled back".
private struct RollBackControl: View {
    let model: AppModel
    let message: ChatMessage
    @State private var confirming = false
    @Environment(\.btTheme) private var theme
    var body: some View {
        if message.rolledBack {
            Text("Rolled back").btBody(11, 1.5, theme.muted).accessibilityLabel("Rolled back")
        } else {
            Button("Roll back this task") { confirming = true }
                .buttonStyle(.btSecondary)
                .accessibilityLabel("Roll back this task")
                .confirmationDialog("Roll back this task?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Roll back", role: .destructive) { model.rollBack(message) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The files this task changed go back to how they were before it ran. Files it created are removed.")
                }
        }
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
