import SwiftUI
import BlackTeamKit

// Where a conversation's words go, said plainly and always: a tag in the header, a notice before the first send to a cloud model,
// the choices when a send is refused, and the token count of a cloud conversation. Built from the panels, tags and notices the
// rest of the app uses (the amber "warn" colours mark everything that leaves this Mac).

/// Shown at all times beside the model and depth menus: "On this Mac", or "Leaves this Mac · <service host>".
struct PrivacyTag: View {
    let leaves: Bool
    let provider: String

    var body: some View {
        BTStatusPill(text: leaves ? "Leaves this Mac" + (provider.isEmpty ? "" : " \u{00B7} \(provider)") : "On this Mac", kind: leaves ? .warn : .neutral, showsDot: true, compact: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(leaves ? "This conversation leaves this Mac. It is sent to \(provider)." : "This conversation stays on this Mac.")
    }
}

/// "12,480 tokens in · 1,930 out", where the speed meter sits for a local model. Tokens only: prices change.
struct UsageLine: View {
    let usage: CloudUsage
    @Environment(\.btTheme) private var theme

    static func text(_ usage: CloudUsage) -> String {
        "\(Fmt.number(usage.prompt)) tokens in \u{00B7} \(Fmt.number(usage.completion)) out" + (usage.cached > 0 ? " \u{00B7} \(Fmt.number(usage.cached)) cached" : "")
    }

    var body: some View {
        Text(Self.text(usage)).font(BTFont.mono(10)).tracking(0.4).foregroundStyle(theme.faint).lineLimit(1).fixedSize()
            .help("What the service reported for this conversation so far. Black Team shows tokens, not prices.")
            .accessibilityLabel(Self.text(usage))
    }
}

/// The small "Cloud" tag a model card carries where a local one says Ready or Off.
struct CloudTag: View {
    @Environment(\.btTheme) private var theme
    var body: some View {
        Text("Cloud").font(BTFont.mono(9)).tracking(0.54).foregroundStyle(theme.warn)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.warnBg))
            .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(theme.warnLine, lineWidth: 1))
    }
}

/// Before the first send of a new cloud conversation: exactly what will leave this Mac.
struct CloudSendNotice: View {
    let check: PrivacyCheck
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconView(.globe, size: 17).foregroundStyle(theme.warn).padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("THIS CONVERSATION LEAVES THIS MAC").font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.warn).frame(height: 13.5, alignment: .leading)
                Text("It is sent to \(check.provider), the service behind \(check.modelName), which you chose for it.")
                    .font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).btLines(13, 1.5).padding(.top, 8)
                Text("What leaves this Mac with each message:").btBody(12, 1.6, theme.ink2).padding(.top, 8)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(check.willLeave, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\u{2022}").font(BTFont.body(12)).foregroundStyle(theme.warn)
                            Text(line).btBody(12, 1.6, theme.ink)
                        }
                    }
                }
                .padding(.top, 6)
                Text("Memory is not used in cloud conversations: nothing from your vault is sent, and nothing is written to it from here.")
                    .btBody(11, 1.6, theme.muted).padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 17).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.warnBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.warnLine, lineWidth: 1))
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A send that was refused for privacy, with the choices, in the place errors appear (above the conversation).
struct PrivacyRefusalView: View {
    @ObservedObject var model: AppModel
    let check: PrivacyCheck
    @State private var confirming = false
    @Environment(\.btTheme) private var theme

    private var title: String {
        switch check.outcome {
        case .projectLocalOnly: return "This project is local only"
        case .phoneNeedsMac: return "Open Black Team on your Mac"
        default: return "This conversation is private to this Mac"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOT SENT").font(BTFont.mono(10)).tracking(1.6).foregroundStyle(theme.warn).frame(height: 15, alignment: .leading)
            Text(confirming ? "Send this conversation to \(check.provider)?" : title)
                .font(BTFont.body(16, .semibold)).tracking(-0.24).foregroundStyle(theme.ink).btLines(16, 1.5).padding(.top, 8)
            Text(confirming ? check.convertWarning : check.message).btBody(12.5, 1.6, theme.ink2).padding(.top, 8).frame(maxWidth: 760, alignment: .leading)
            if confirming { confirmRow } else { choices }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.warnBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.warnLine, lineWidth: 1))
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var choices: some View {
        HStack(spacing: 10) {
            if check.outcome == .needsChoice {
                Button("Start a new cloud conversation") { model.startNewCloudConversation() }.buttonStyle(.btPrimary)
                if !check.localModelKey.isEmpty {
                    Button("Switch back to \(check.localModelName)") { Task { await model.switchBackToLocal(check) } }.buttonStyle(.btSecondary).disabled(model.busy)
                }
                Button("Send this conversation to \(check.provider)") { confirming = true }.buttonStyle(.btSecondary)
            } else if check.outcome == .projectLocalOnly {
                if !check.localModelKey.isEmpty {
                    Button("Switch back to \(check.localModelName)") { Task { await model.switchBackToLocal(check) } }.buttonStyle(.btPrimary).disabled(model.busy)
                }
                Button("Dismiss") { model.refusal = nil }.buttonStyle(.btSecondary)
            } else {
                Button("Dismiss") { model.refusal = nil }.buttonStyle(.btSecondary)
            }
        }
        .padding(.top, 16)
    }

    private var confirmRow: some View {
        HStack(spacing: 10) {
            Button("Send it to \(check.provider)") { confirming = false; model.sendToCloud(check) }.buttonStyle(.btPrimary)
            Button("Cancel") { confirming = false }.buttonStyle(.btSecondary)
        }
        .padding(.top, 16)
    }
}
