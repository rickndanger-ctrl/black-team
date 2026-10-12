import SwiftUI
import UniformTypeIdentifiers
import BlackTeamKit

/// Chat and Code share one screen (`view==='chat'` in Companion.jsx): controls, the conversation, the composer.
struct ChatPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatControls(model: model, drafts: model.drafts)
            ChatNotices(model: model)
            PrivacyNotices(model: model)
            ConversationLog(model: model)
            ChatFooter(model: model, drafts: model.drafts)
        }
        .id(model.chatKey)
    }
}

/// The model menu, the response depth menu, the speed meter and the project chip (`.chat-controls`).
struct ChatControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme

    var body: some View {
        let locked = model.sending || model.activeJob || model.pending != nil
        let models = model.status?.models ?? []
        // Saved models first, then the subscription agents found on this Mac (`agent:<engine>`), chosen as the next message's agent.
        let options = models.map { ($0.key, label($0)) } + model.agentMenu.map { ($0.key, $0.label) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if options.count > 1 {
                    BTSelect(options: options,
                             selection: Binding(get: { model.activeAgent.map { "agent:\($0.engine)" } ?? models.first(where: \.active)?.key ?? "" },
                                                set: { key in
                                                    if key.hasPrefix("agent:") {
                                                        model.chooseAgent(AgentService.allCases.first { "agent:\($0.engine)" == key })
                                                    } else {
                                                        model.chooseAgent(nil)
                                                        Task { await model.switchModel(key) }
                                                    }
                                                }),
                             placeholder: model.modelName, browser: true)
                        .disabled(locked || model.busy)
                        .accessibilityLabel("Model")
                } else {
                    BTSelect(options: [("", models.first.map(label) ?? model.modelName)], selection: .constant(""), placeholder: model.modelName, browser: true)
                        .accessibilityLabel("Model")
                }
                if model.activeAgent != nil {
                    // The pace menu has no effect on a subscription agent, so it is not shown for one.
                    BTSelect(options: AgentPermission.allCases.map { ($0, permissionLabel($0)) },
                             selection: Binding(get: { model.agentPermission }, set: { model.setAgentPermission($0) }), browser: true)
                        .disabled(locked)
                        .accessibilityLabel("Permission")
                } else {
                    BTSelect(options: AppModel.paceWords.map { ($0.id, $0.id) },
                             selection: Binding(get: { drafts.draft(model.draftKey).mode }, set: { drafts.set(model.draftKey, mode: $0) }), browser: true)
                        .disabled(locked)
                        .accessibilityLabel("Response depth")
                }
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
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                }
                let leaves = model.leavesThisMac
                PrivacyTag(leaves: leaves.cloud, provider: leaves.provider)
                Spacer(minLength: 0)
                if let usage = model.usage { UsageLine(usage: usage) } else if let meter = model.meter { SpeedMeterView(meter: meter) }
            }
            if let agent = model.activeAgent {
                Text(permissionHint(agent, model.agentPermission)).btBody(11, 1.5, theme.muted)
                if let status = model.agentUpdates[agent], status.updateAvailable, let installed = status.installed, let latest = status.latest {
                    AgentUpdateLine(model: model, agent: agent, installed: installed, latest: latest)
                }
            }
        }
        .padding(.vertical, 15)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
        .padding(.bottom, 14)
    }

    private func label(_ item: SavedModelSummary) -> String {
        if item.isCloud { return "\(item.name) \u{00B7} Cloud" }
        return Fmt.modelSize(item).map { "\(item.name) \u{00B7} \($0)" } ?? item.name
    }

    private func permissionLabel(_ permission: AgentPermission) -> String {
        switch permission {
        case .ask: return "Ask"
        case .edit: return "Edit"
        case .auto: return "Auto"
        }
    }

    /// The line under the selects: what the chosen tool may do at this level.
    private func permissionHint(_ agent: AgentService, _ permission: AgentPermission) -> String {
        switch (agent, permission) {
        case (.claudeCode, .ask): return "Claude Code asks before it changes or runs anything. You approve each step."
        case (.claudeCode, .edit): return "Claude Code can read and edit files in this project and run simple file commands. Other commands are refused."
        case (.claudeCode, .auto): return "Claude Code works on its own judgement inside this project. Roll back is still available."
        case (.codex, .ask): return "Codex can only read here. It cannot ask for approval; switch to Edit or Auto to let it make changes."
        case (.codex, .edit): return "Codex can read, edit and run commands inside its sandbox."
        case (.codex, .auto): return "Codex works on its own inside its sandbox, with its automatic review. Roll back is still available."
        }
    }
}

/// "Codex 0.163.0 is available (you have 0.162.1)." with a quiet button that opens the update in Terminal.
private struct AgentUpdateLine: View {
    let model: AppModel
    let agent: AgentService
    let installed: String
    let latest: String
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text("\(agent.displayName) \(latest) is available (you have \(installed)).").btBody(11, 1.5, theme.muted)
            Button("Update") { update() }
                .buttonStyle(.btQuiet)
                .accessibilityLabel("Update \(agent.displayName)")
        }
    }

    private func update() {
        Task {
            do { try await model.openAgentUpdate(agent) } catch { model.error = plainMessage(error) }
        }
    }
}

/// Setup and model state, shown in place above the conversation (`.notice`).
struct ChatNotices: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        if !model.setupComplete, model.activeAgent == nil {
            notice("Connect a model to start.") { Button("Connect a model") { model.openCommand() }.buttonStyle(.btSecondary) }
        } else if model.status?.runtime.ready != true, !model.cloudSelected {
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
        .padding(.horizontal, 17).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
        .padding(.bottom, 16)
    }
}

/// The messages, kept at the newest text unless the person has scrolled up (`.conversation`: 300 points at least, 55 percent of the window at most).
struct ConversationLog: View {
    @ObservedObject var model: AppModel
    @State private var pinned = true
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    var body: some View {
        let messages = model.messages
        let tick = messages.count * 1_000_000 + (messages.last?.content.count ?? 0) + (messages.last?.events.count ?? 0) * 7 + (model.status?.job?.progress.count ?? 0)
        let maxHeight = max(300, metrics.windowHeight * 0.55)
        if flat {
            ClampedHeight(minimum: 300, maximum: maxHeight) { list(messages) }.clipped()
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
            .frame(minHeight: 300, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: false)
        }
    }

    private func list(_ messages: [ChatMessage]) -> some View {
        let activity = model.activity
        let busy = model.sending || model.activeJob
        return VStack(alignment: .leading, spacing: 0) {
            if messages.isEmpty && activity == nil {
                ChatEmpty(model: model)
            } else {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let live = activity.map { $0.messageId == nil ? index == messages.count - 1 : $0.messageId == message.id } ?? false
                    MessageView(message: message, fallbackModel: model.modelName, glowing: live && activity?.glowing == true,
                                liveLabel: live && activity?.messageId == message.id ? activity?.label : nil, busy: busy,
                                canRemember: model.status?.memory == true && !(model.thread?["privacy"]?.string == "cloud"), canRetry: index == messages.count - 1 && !busy,
                                cloud: model.thread?["privacy"]?.string == "cloud", model: model, threadId: model.threadId)
                        .equatable()
                        .padding(.vertical, 6)
                }
            }
            if let activity, activity.messageId == nil {
                HStack(spacing: 12) {
                    AgentAvatar(state: activity.glowing ? .working : .idle, diameter: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BLACK TEAM / \(model.modelName.uppercased())").font(BTFont.mono(10)).tracking(0.6).foregroundStyle(theme.ink2)
                        Text(activity.label).font(BTFont.mono(10)).foregroundStyle(activity.phase == .approval ? theme.warn : theme.muted)
                    }
                }
                .padding(.horizontal, 23).padding(.vertical, 21).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
            Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 2).padding(.top, 11).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// `.chat-empty`: the emblem, a heading and two lines.
struct ChatEmpty: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let code = model.currentKind == .agent
        VStack(spacing: 0) {
            AgentAvatar(state: .idle, large: true).padding(.bottom, 20)
            Text(code ? "Ready to work." : "Start a conversation.").font(BTFont.body(20, .medium)).tracking(-0.4).foregroundStyle(theme.ink)
                .btLines(20, 1.5)
            VStack(spacing: 0) {
                Text(code ? "Describe a task. Your agent can edit files, run commands, and deliver the result."
                          : "Choose a model and send a message. Switch to Code for hands-on work.").btBody(12.5, 1.8, theme.muted)
                Text(model.leavesThisMac.cloud ? "This conversation is sent to \(model.leavesThisMac.provider). Memory is not used." : "Your conversations stay on this computer.")
                    .btBody(12.5, 1.8, theme.muted)
            }
            .multilineTextAlignment(.center).padding(.vertical, 12)
        }
        .padding(.horizontal, 20).padding(.vertical, 56)
        .frame(maxWidth: .infinity)
    }
}

/// The approval card moved to the top of the page; what remains is the retry note and the composer.
struct ChatFooter: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pending != nil, !model.sending {
                BTInlineNote {
                    Text("Your last message may already be saved. Retry to reconnect to that same response without sending it twice.").btBody(11, 1.8, theme.muted)
                }
                .padding(.vertical, 8)
            }
            ImageArea(model: model, drafts: drafts)
            ComposerBar(model: model, drafts: drafts).padding(.top, model.imageAreaShown ? 0 : 16)
            VStack(spacing: 0) {
                Text(note).font(BTFont.mono(8)).tracking(0.64).foregroundStyle(theme.faint)
                    .btLines(8, 1.8, mono: true)
            }
            .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center).padding(.top, 12)
        }
    }

    private var note: String {
        let job = model.status?.job
        if model.activeJob, job?.threadId != model.threadId {
            return job?.kind == "memory" ? "Black Team is tidying memory with your model." : "A response is running in another conversation."
        }
        // The daily wording, truthful for the Mac: drafts here are in memory, not in the browser.
        return "Enter to send \u{00B7} Shift + Enter for a new line \u{00B7} Images require a vision model (Chat mode). Draft images stay in memory until sent; reattach after reopening."
    }
}

/// The pictures waiting to be sent, and, when the model cannot read them yet, the notice with its one button (Chat only).
struct ImageArea: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore

    var body: some View {
        if model.imageAreaShown {
            VStack(alignment: .leading, spacing: 0) {
                ImagePreviews(items: model.previewItems, onRemove: { model.removeImage($0) }, disabled: model.sending || model.pending != nil || model.preparing)
                if model.visionNoticeShown, let vision = model.status?.vision { VisionNotice(model: model, bytes: vision.bytes) }
            }
        }
    }
}

/// The text box with Send / Run / Retry / Stop beside it (`.composer`: 12 points of padding, a 10 point radius).
struct ComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: DraftStore
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flatLayout
    @State private var dropping = false

    var body: some View {
        let key = model.draftKey
        let kind = model.currentKind
        let text = drafts.draft(key).message
        let activeJob = model.activeJob
        // A subscription agent needs no local model, so the composer works without one.
        let available = (model.setupComplete || model.activeAgent != nil) && !model.sending && (model.pending != nil || !activeJob)
        let hasImages = kind == .chat && !model.draftImages.isEmpty
        let canSend = available && !model.preparing && !(hasImages && model.visionNoticeShown)
            && (model.pending != nil || hasImages || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        HStack(alignment: .bottom, spacing: 10) {
            // Images are Chat only: in Code the button is absent, not disabled.
            if kind == .chat { filesButton }
            composerField(key: key, kind: kind)
                .frame(height: 64)
                .accessibilityLabel(kind == .agent ? "Describe a task for Code" : model.cloudSelected ? "Message your cloud model" : "Message your local model")
            if activeJob && model.pending == nil {
                Button(model.status?.job?.kind == "memory" ? "Stop upkeep" : "Stop") { model.cancel() }
                    .buttonStyle(.btSecondary).disabled(model.sending)
            } else {
                Button(action: submit) {
                    Text(model.sending ? "Sending\u{2026}" : model.pending != nil ? "Retry message" : kind == .agent ? "Run \u{2191}" : "Send \u{2191}")
                }
                .buttonStyle(.btPrimary).disabled(!canSend)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
        .btShadow(theme.shadow)
        .modifier(DropTarget(enabled: !flatLayout, dropping: $dropping, perform: drop))
        .overlay { if dropping { RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.accent, lineWidth: 2) } }
    }

    private var filesButton: some View {
        Button { model.chooseImages() } label: { Text(model.preparing ? "Preparing\u{2026}" : "+ Files") }
            .buttonStyle(.btSecondary)
            .disabled(!model.setupComplete || model.preparing || model.sending || model.pending != nil || model.activeJob || model.draftImages.count >= ImageRules.maxImages)
            .accessibilityLabel("Add image files")
    }

    /// Image files dropped on the composer are prepared like chosen ones.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard model.setupComplete, !model.sending, model.pending == nil, !model.activeJob else { return false }
        let found = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !found.isEmpty else { return false }
        let collected = DroppedURLs()
        let group = DispatchGroup()
        for provider in found {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collected.add(url) }
                else if let url = item as? URL { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [model] in model.addImages(collected.urls.map { .url($0) }) }
        return true
    }

    /// An image render cannot draw the AppKit text view, so it gets the same text drawn by SwiftUI.
    @ViewBuilder private func composerField(key: String, kind: ChatKind) -> some View {
        let placeholder = kind == .agent ? "Describe what you want built, checked or delivered..." : model.cloudSelected ? "Message your cloud model..." : "Message your local model..."
        let binding = Binding(get: { model.pending?.message ?? drafts.draft(key).message }, set: { drafts.set(key, message: $0) })
        if flatLayout {
            let text = binding.wrappedValue
            Text(text.isEmpty ? placeholder : text).font(BTFont.body(13)).foregroundStyle(text.isEmpty ? theme.faint : theme.ink)
                .padding(.horizontal, 6).padding(.top, 4 + (13 * 1.7 - BTFont.natural(13)) / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ComposerField(text: binding, placeholder: placeholder, enabled: (model.setupComplete || model.activeAgent != nil) && !model.sending && model.pending == nil,
                          theme: theme, onSubmit: submit, onPasteImages: { model.addImages($0) })
        }
    }

    private func submit() {
        let key = model.draftKey
        let draft = drafts.draft(key)
        let text = model.pending?.message ?? draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = model.currentKind == .chat && !draft.images.isEmpty
        guard model.setupComplete, !model.sending, !model.preparing, model.pending != nil || !model.activeJob, !text.isEmpty || hasImages,
              !(hasImages && model.visionNoticeShown) else { return }
        model.send(text, mode: draft.mode)
    }
}


/// A view as tall as its content, but at least `minimum` and at most `maximum`; content that is taller shows its bottom.
/// Image renders use this where the window uses a scroll view.
struct ClampedHeight<Content: View>: View {
    var minimum: CGFloat
    var maximum: CGFloat
    @ViewBuilder var content: Content

    var body: some View { ClampLayout(minimum: minimum, maximum: maximum) { content } }
}

private struct ClampLayout: Layout {
    var minimum: CGFloat
    var maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height
        return CGSize(width: proposal.width ?? 0, height: min(max(height, minimum), maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let y = height > bounds.height ? bounds.maxY - height : bounds.minY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
    }
}


/// File addresses collected from a drop, which arrives on several threads.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list.sorted { $0.path < $1.path } }
}


/// The drop target is an AppKit view, which an image render draws as a yellow placeholder; renders go without it.
struct DropTarget: ViewModifier {
    let enabled: Bool
    @Binding var dropping: Bool
    let perform: ([NSItemProvider]) -> Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onDrop(of: [.fileURL], isTargeted: $dropping, perform: perform) } else { content }
    }
}


/// The refusal with its choices, or, before the first send of a new cloud conversation, what will leave this Mac.
struct PrivacyNotices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let refusal = model.refusal {
            PrivacyRefusalView(model: model, check: refusal)
        } else if model.threadId == nil, model.privacyNow.outcome == .startsCloud, model.pending == nil {
            CloudSendNotice(check: model.privacyNow)
        }
    }
}
