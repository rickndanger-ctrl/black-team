import SwiftUI
import BlackTeamKit

/// Chat and Code share one screen (`Chat` in App.jsx): controls, the conversation, an approval card, the composer.
struct ChatPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ChatControls(model: model, drafts: model.drafts)
            ChatNotices(model: model)
            ConversationLog(model: model)
            ChatFooter(model: model, drafts: model.drafts)
        }
        .id(model.chatKey)
    }
}

/// The thinking level, the project chip, the speed meter and the model in use (`.chat-controls`).
struct ChatControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme

    var body: some View {
        let locked = model.sending || model.activeJob || model.pending != nil
        HStack(spacing: 12) {
            Text("THINKING").font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint)
            BTSelect(options: [("fast", "Off \u{00B7} fastest"), ("balanced", "Standard"), ("deep", "Deep"), ("extended", "Extended")],
                     selection: Binding(get: { drafts.draft(model.draftKey).mode }, set: { drafts.set(model.draftKey, mode: $0) }), minWidth: 128)
                .disabled(locked)
                .help("How much the model thinks before answering. Off is fastest; each level thinks longer and may reply at more length.")
                .accessibilityLabel("Thinking")
            if let project = model.activeProject {
                HStack(spacing: 7) {
                    IconView(.folder, size: 13).foregroundStyle(theme.accent)
                    Text(project.name).font(BTFont.body(12)).foregroundStyle(theme.ink)
                    if model.threadId == nil {
                        Button { model.leaveProject() } label: {
                            Text("\u{00D7}").font(BTFont.body(14)).foregroundStyle(theme.muted).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).help("Leave project").accessibilityLabel("Leave project")
                    }
                }
                .padding(.leading, 12).padding(.trailing, 10).frame(height: 34)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
            }
            // Both the meter and the model name carry `margin-left: auto`, so the free space is shared between them.
            Spacer(minLength: 0)
            if let meter = model.meter { SpeedMeterView(meter: meter); Spacer(minLength: 0) }
            ModelNameOrSwitch(model: model, locked: locked)
        }
        .frame(height: 34)
        .padding(.bottom, 14)
    }
}

/// The model in use: plain text with one model, a menu with more (`ModelSwitch` in Models.jsx).
private struct ModelNameOrSwitch: View {
    @ObservedObject var model: AppModel
    let locked: Bool
    @Environment(\.btTheme) private var theme

    var body: some View {
        let models = model.status?.models ?? []
        if models.count < 2 {
            Text(model.modelName).font(BTFont.body(10)).foregroundStyle(theme.muted).lineLimit(1)
        } else {
            BTSelect(options: models.map { ($0.key, $0.name) },
                     selection: Binding(get: { models.first(where: \.active)?.key ?? "" }, set: { key in Task { await model.switchModel(key) } }),
                     placeholder: model.modelName)
                .frame(maxWidth: 220)
                .disabled(locked || model.busy)
                .help("Switch model")
                .accessibilityLabel("Model in use")
        }
    }
}

/// Setup and model state, shown in place above the conversation (`.notice`).
struct ChatNotices: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        if !model.setupComplete {
            notice("Connect a model to start.") { Button("Connect a model") { model.showSettings(.model) }.buttonStyle(.btSecondary) }
        } else if model.status?.runtime.ready != true {
            let starting = model.status?.runtime.state == "starting"
            let server = model.status?.config.model.source == "server"
            notice(starting ? (server ? "Connecting to your local server. It will be ready when the connection finishes." : "Your model is starting. It will be ready when it finishes loading.")
                            : "Send a message to start or connect your configured local model.") { EmptyView() }
        }
    }

    private func notice<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Text(text).btBody(12, 1.6, theme.ink)
            Spacer(minLength: 0)
            action()
        }
        .padding(.horizontal, 17).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
        .padding(.bottom, 16)
    }
}

/// The messages, kept at the newest text unless the person has scrolled up (`.conversation`).
struct ConversationLog: View {
    @ObservedObject var model: AppModel
    @State private var pinned = true
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btTheme) private var theme

    var body: some View {
        let messages = model.messages
        let tick = messages.count * 1_000_000 + (messages.last?.content.count ?? 0) + (messages.last?.events.count ?? 0) * 7 + (model.status?.job?.progress.count ?? 0)
        if flat {
            list(messages).frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    list(messages)
                        .background(ScrollPinTracker(pinned: $pinned))
                }
                .onChange(of: tick) { _ in if pinned { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: messages.count) { _ in pinned = true; proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(minHeight: 180)
        }
    }

    private func list(_ messages: [ChatMessage]) -> some View {
        let activity = model.activity
        let busy = model.sending || model.activeJob
        return VStack(alignment: .leading, spacing: 0) {
            if messages.isEmpty {
                ChatEmpty(model: model, glowing: activity?.glowing == true)
            } else {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let live = activity.map { $0.messageId == nil ? index == messages.count - 1 : $0.messageId == message.id } ?? false
                    MessageView(message: message, fallbackModel: model.modelName, glowing: live && activity?.glowing == true,
                                liveLabel: live && activity?.messageId == message.id ? activity?.label : nil, busy: busy,
                                canRemember: model.status?.memory == true, canRetry: index == messages.count - 1 && !busy, model: model)
                        .equatable()
                        .padding(.vertical, 6)
                }
            }
            if let activity, activity.messageId == nil {
                HStack(spacing: 14) {
                    AgentAvatar(state: activity.glowing ? .working : .idle)
                    Text("\(activity.label)\u{2026}").font(BTFont.mono(11)).foregroundStyle(theme.ink2)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }
            Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 2).padding(.top, 12).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ChatEmpty: View {
    @ObservedObject var model: AppModel
    let glowing: Bool
    @Environment(\.btTheme) private var theme

    var body: some View {
        let code = model.currentKind == .agent
        VStack(spacing: 16) {
            AgentAvatar(state: glowing ? .working : .idle, large: true)
            Text(code ? "Ready to work." : "A space to think freely.").font(BTFont.body(21, .medium)).tracking(-0.42).foregroundStyle(theme.ink)
                .btLines(21, 1.5)
            VStack(spacing: 0) {
                Text(code ? "Describe a task. Code reads and edits files in \(model.activeProject?.name ?? "your workspace"), runs commands and shows every change."
                          : "Start a conversation with your local model.").btBody(12.5, 1.8, theme.muted).multilineTextAlignment(.center)
                Text("History is saved on your computer.").btBody(12.5, 1.8, theme.muted).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 260)
        .frame(maxHeight: .infinity)
    }
}

/// Live progress, the approval card, the retry note and the composer.
struct ChatFooter: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme

    var body: some View {
        let job = model.status?.job
        let mine = job?.threadId == model.threadId && model.threadId != nil
        VStack(alignment: .leading, spacing: 0) {
            if model.activity != nil, model.messages.last?.context == nil, let info = ContextInfo(job?.context) { ContextReportView(info: info).padding(.bottom, 0) }
            if let approval = job?.approval {
                if mine {
                    ApprovalCard(approval: approval, disabled: model.sending) { model.approve($0) }.padding(.vertical, 12)
                } else {
                    HStack(spacing: 14) {
                        Text("Code is waiting for your approval in another conversation.").btBody(12, 1.6, theme.ink)
                        Spacer(minLength: 0)
                        Button("Open that task") { if let id = job?.threadId { model.openThread(id) } }
                            .buttonStyle(.btSecondary).disabled(model.sending || model.pending != nil)
                    }
                    .padding(.horizontal, 17).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
                    .padding(.bottom, 16)
                }
            }
            if model.pending != nil, !model.sending {
                BTInlineNote {
                    Text("Your last message may already be saved. Retry to reconnect to that same response without sending it twice.").btBody(11, 1.8, theme.muted)
                }
                .padding(.vertical, 8)
            }
            ComposerBar(model: model, drafts: drafts).padding(.top, 10)
            Text(note).font(BTFont.mono(8)).tracking(0.8).foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .center).frame(height: 14.4).padding(.top, 12)
        }
    }

    private var note: String {
        let job = model.status?.job
        if model.activeJob, job?.threadId != model.threadId {
            return job?.kind == "memory" ? "Black Team is tidying memory with your model." : "A response is running in another conversation."
        }
        return "LOCAL INFERENCE \u{00B7} HISTORY SAVED ON YOUR COMPUTER"
    }
}

/// The text box with Send / Run / Retry / Stop beside it (`.composer`: 12 points of padding, a 10 point radius).
struct ComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flatLayout

    var body: some View {
        let key = model.draftKey
        let kind = model.currentKind
        let text = drafts.draft(key).message
        let activeJob = model.activeJob
        let available = model.setupComplete && !model.sending && (model.pending != nil || !activeJob)
        let canSend = available && (model.pending != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        HStack(alignment: .bottom, spacing: 12) {
            composerField(key: key, kind: kind)
                .frame(height: 74)
                .accessibilityLabel(kind == .agent ? "Describe a task for Code" : "Message your local model")
            if activeJob && model.pending == nil {
                Button(model.status?.job?.kind == "memory" ? "Stop upkeep" : "Stop") { model.cancel() }
                    .buttonStyle(.btSecondary).disabled(model.sending)
            } else {
                Button(action: submit) {
                    BTIconLabel(model.sending ? "Sending\u{2026}" : model.pending != nil ? "Retry message" : kind == .agent ? "Run" : "Send", .send)
                }
                .buttonStyle(.btPrimary).disabled(!canSend)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line2, lineWidth: 1))
        .btShadow(theme.shadow)
    }

    /// An image render cannot draw the AppKit text view, so it gets the same text drawn by SwiftUI.
    @ViewBuilder private func composerField(key: String, kind: ChatKind) -> some View {
        let placeholder = kind == .agent ? "Describe what you want built, checked or changed\u{2026}" : "Message your local model\u{2026}"
        let binding = Binding(get: { model.pending?.message ?? drafts.draft(key).message }, set: { drafts.set(key, message: $0) })
        if flatLayout {
            let text = binding.wrappedValue
            Text(text.isEmpty ? placeholder : text).font(BTFont.body(13)).foregroundStyle(text.isEmpty ? theme.faint : theme.ink)
                .padding(.horizontal, 6).padding(.top, 4 + (13 * 1.7 - BTFont.natural(13)) / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ComposerField(text: binding, placeholder: placeholder, enabled: model.setupComplete && !model.sending && model.pending == nil,
                          theme: theme, onSubmit: submit)
        }
    }

    private func submit() {
        let key = model.draftKey
        let draft = drafts.draft(key)
        let text = model.pending?.message ?? draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.setupComplete, !model.sending, model.pending != nil || !model.activeJob, !text.isEmpty else { return }
        model.send(text, mode: draft.mode)
    }
}
