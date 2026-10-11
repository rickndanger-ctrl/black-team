import SwiftUI
import BlackTeamKit

/// The top of the main column (`.app-main > header`): eyebrow, page title and description on the left, the runtime pill on the right.
/// Chat / Code shows the mark switch instead of a title.
struct HeaderView: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    private var titles: (String, String, String) {
        switch model.page {
        case .memory: return ("BLACK TEAM VAULT", "Memory", "What your local models remember. It never leaves this computer.")
        case .workspace: return ("YOUR LOCAL AI", "Your local AI command center.", "Models, harnesses, tools and performance. On your computer.")
        case .settings: return ("CONNECTIONS", "Make yourself at home.", "Connect your models and agents. Keep the details out of your way.")
        case .conversation:
            return ("LOCAL CONVERSATIONS", model.thread?["title"]?.string ?? "Your private conversation.", "A direct connection to the model on your computer.")
        }
    }

    var body: some View {
        if model.page == .conversation {
            HStack(alignment: .center, spacing: 20) {
                PageMark(model: model)
                Spacer(minLength: 0)
                RuntimePill(model: model)
            }
            .padding(.bottom, 18)
        } else if metrics.compact {
            VStack(alignment: .leading, spacing: 12) { titleBlock; RuntimePill(model: model) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 30)
        } else {
            HStack(alignment: .center, spacing: 20) {
                titleBlock
                Spacer(minLength: 0)
                RuntimePill(model: model)
            }
            .padding(.bottom, 30)
        }
    }

    private var titleBlock: some View {
        let (eyebrow, title, description) = titles
        return VStack(alignment: .leading, spacing: 0) {
            BTEyebrow(eyebrow)
            Text(title).font(BTFont.body(26, .semibold)).tracking(-0.52).foregroundStyle(theme.ink)
                .btLines(26, 1.2).padding(.top, 10).padding(.bottom, 8)
            Text(description).btBody(12.5, 1.6, theme.muted)
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
                .frame(height: 34)
            mark(.terminal, .agent, "Code")
        }
        // `.app-main header h1` puts 10 points above and 8 below the mark.
        .padding(.top, 10).padding(.bottom, 8)
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
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// "Model ready", "Starting model" and so on (`StatusPill` in App.jsx).
struct RuntimePill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let runtime = model.status?.runtime
        let server = model.status?.config.model.source == "server"
        let label: String = {
            if runtime?.state == "starting" { return server ? "Connecting model" : "Starting model" }
            if runtime?.busy == true { return "Model responding" }
            if runtime?.ready == true { return "Model ready" }
            return "Model stopped"
        }()
        let kind: BTStatusPill.Kind = runtime?.ready == true ? .ok : .neutral
        BTStatusPill(text: label, kind: kind, showsDot: true).accessibilityLabel(label)
    }
}
