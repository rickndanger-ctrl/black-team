import SwiftUI
import BlackTeamKit

/// The Camp window's main column: the page title (or the Chat / Code mark), the "On this computer" pill, notices,
/// then the page (`.companion-main`).
struct CampMain: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @ObservedObject private var phone: PhoneModel

    init(model: AppModel) { self.model = model; phone = model.phone }

    /// The daily app's pill on Servers & access once a phone can reach this computer.
    private var connectedPrivately: Bool { model.campPage == .servers && phone.state?.connected == true }

    var body: some View {
        if model.status == nil {
            BootView(model: model)
        } else {
            PageScroll {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if model.cloudSelected {
                        DailyPill(text: "Cloud \u{00B7} \(model.cloud.provider)", live: true, ink: theme.warn).padding(.bottom, 14)
                    } else {
                        DailyPill(text: connectedPrivately ? "Connected privately" : "On this computer", live: true, ink: theme.ok).padding(.bottom, 14)
                    }
                    Banners(model: model, camp: true)
                    JobNotice(model: model)
                    if let approval = model.status?.job?.approval { DecisionCard(model: model, approval: approval) }
                    page
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        switch model.campPage {
        case .chat: PageMark(model: model).padding(.bottom, 20)
        case .memory: title("Memory", "The Black Team vault: what your local models remember. It never leaves this computer.")
        case .plugins: title("Tools & workspace", "Choose what Camp can use on your next agent turn.")
        case .dsh: title("Harness sessions", "Review recent work and reopen the full DeepSeek workspace.")
        case .servers: title("Servers & access", "Control your model servers and connect privately.")
        }
    }

    private func title(_ name: String, _ line: String) -> some View {
        DailyTitle(eyebrow: "BLACK TEAM / CAMP", title: name, line: line).padding(.bottom, 20)
    }

    @ViewBuilder private var page: some View {
        switch model.campPage {
        case .chat: ChatPage(model: model)
        case .memory: MemoryPage(model: model)
        case .plugins: PluginsPage(model: model)
        case .dsh: SessionsPage(model: model)
        case .servers: ServersPage(model: model)
        }
    }
}

/// The Chat / Code mark: the speech bubble and the prompt, the lit one being the current mode (`.page-mark`).
struct PageMark: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            mark(.chat, .chat, "Chat")
            Text("/").font(BTFont.mono(34)).foregroundStyle(theme.muted)
                .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.105, d: 1, tx: 0, ty: 0))
                .frame(height: 34).offset(x: 3).accessibilityHidden(true)
            mark(.terminal, .agent, "Code")
        }
        .padding(.leading, -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    private func mark(_ icon: BTIcon, _ kind: ChatKind, _ label: String) -> some View {
        let lit = model.currentKind == kind
        return Button { if !lit { model.startChat(kind) } } label: {
            IconView(icon, size: 30, stroke: 1.5)
                .foregroundStyle(lit ? theme.accent : theme.muted)
                .shadow(color: lit ? theme.ring : .clear, radius: 3.5)
                .shadow(color: lit ? theme.ring : .clear, radius: 8)
                .frame(width: 46, height: 46)
                .opacity(lit ? 1 : (model.locked ? 0.25 : 0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lit && model.locked)
        .help(label)
        .accessibilityLabel("Black Team \(label)")
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
    }
}

/// `.notice` with the live task: what it is doing and a way to stop it.
struct JobNotice: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        if let job = model.status?.job, job.state == "running" {
            HStack(spacing: 14) {
                (Text(job.progress.isEmpty ? "Preparing\u{2026}" : job.progress).font(BTFont.body(12)).foregroundStyle(theme.ink)
                 + Text(" Requests continue only while Black Team is open.").font(BTFont.body(10)).foregroundStyle(theme.muted))
                Spacer(minLength: 0)
                if ["chat", "agent"].contains(job.kind) {
                    Button { model.cancel() } label: {
                        Text("Stop task").font(BTFont.body(11, .medium)).foregroundStyle(theme.ink)
                            .padding(.horizontal, 12).frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 17).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
            .padding(.bottom, 16)
        }
    }
}

/// `.approval-card`: a command the agent wants to run, waiting for the person's answer.
struct DecisionCard: View {
    @ObservedObject var model: AppModel
    let approval: ApprovalSummary
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR DECISION").font(BTFont.mono(10)).tracking(1.6).foregroundStyle(theme.faint).frame(height: 15, alignment: .leading)
            Text(approval.description.isEmpty ? "Approve this action?" : approval.description)
                .font(BTFont.body(16, .semibold)).tracking(-0.24).foregroundStyle(theme.ink).btLines(16, 1.5).padding(.top, 8)
            Text(approval.command).font(BTFont.mono(11)).foregroundStyle(theme.ink2)
                .lineSpacing(max(0, 11 * 1.6 - BTFont.natural(11, mono: true))).textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
                .padding(.vertical, 14)
            Text("Approve this action once, or decline and let the agent continue. Unanswered requests expire.").btBody(12, 1.5, theme.ink2)
            HStack(spacing: 10) {
                Button("Approve once") { model.approve("once") }.buttonStyle(.btPrimary).disabled(model.sending)
                Button("Decline") { model.approve("deny") }.buttonStyle(.btSecondary).disabled(model.sending)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.warnBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.warnLine, lineWidth: 1))
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }
}

/// `.work-card`: a graphite card with a small caps label, a title and the body under them.
struct WorkCard<Content: View>: View {
    var label: String?
    var title: String?
    var verticalMargin: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label { Text(label).font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint).frame(height: 13.5, alignment: .leading).padding(.bottom, 10) }
            if let title { Text(title).font(BTFont.body(18, .semibold)).tracking(-0.41).foregroundStyle(theme.ink).btLines(18, 1.5) }
            content
        }
        .padding(.horizontal, 25).padding(.vertical, 23)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(alignment: .top) {
            LinearGradient(colors: [.clear, theme.edge, .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1).padding(.horizontal, Theme.radiusLg)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
        .btShadow(theme.shadow)
        .padding(.bottom, verticalMargin)
    }
}

/// `.work-card p`: 12.5 points on a 1.7 line, muted, at most 560 wide, 10 above and below.
struct CardText: View {
    let text: String
    var small = false
    @Environment(\.btTheme) private var theme
    init(_ text: String, small: Bool = false) { self.text = text; self.small = small }
    var body: some View {
        Text(text).btBody(small ? 11 : 12.5, 1.7, theme.muted).frame(maxWidth: 560, alignment: .leading).padding(.top, 10)
    }
}

