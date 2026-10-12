import SwiftUI
import BlackTeamKit

// Plugins ("Tools & workspace"), DSH sessions and Servers & access (Companion.jsx, AgentPanels.jsx, MobileApp.jsx).

/// `.notice`: a quiet outlined line.
struct CampNotice: View {
    let text: String
    @Environment(\.btTheme) private var theme
    var body: some View {
        Text(text).btBody(12, 1.6, theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
    }
}

/// A field-looking, read-only line (`input` in `.workspace-setting`).
private struct FieldText: View {
    let text: String
    var mono = false
    var disabled = false
    @Environment(\.btTheme) private var theme
    var body: some View {
        HStack { Text(text).font(mono ? BTFont.mono(11) : BTFont.body(12)).foregroundStyle(disabled ? theme.faint : theme.ink).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0) }
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
            .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Plugins

struct PluginsPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    private let plugins: [(icon: String, name: String, text: String, on: Bool)] = [
        ("\u{2318}", "Build & edit", "Hermes terminal, file editing, searches and task planning.", true),
        ("\u{21A7}", "Files to your phone", "Attach workspace files and send them to your own devices with Taildrop.", true),
        ("\u{25CE}", "Browser", "Navigate, inspect and operate a separate local browser.", false),
        ("\u{25A3}", "Desktop control", "Inspect and control supported desktop apps through the installed computer-use driver.", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkCard(label: "WORKSPACE", title: "Where your agent works") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folder on this computer").font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink).frame(height: 18, alignment: .leading)
                    HStack(spacing: 10) {
                        FieldText(text: model.status?.config.workspace ?? "")
                        Button("Choose folder") { chooseFolder() }.buttonStyle(.btSecondary).disabled(model.busy)
                    }
                }
                .padding(.top, 16)
                CardText("Choose an existing folder. Agent tools run as your Mac user; this folder is the starting location, not a sandbox.").padding(.bottom, 10)
            }
            WorkCard(label: "ENGINE", title: "What runs your Code conversations") {
                HStack(spacing: 2) {
                    engineButton("Black Team", selected: true)
                    engineButton("Hermes", selected: false).disabled(true)
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
                .padding(.top, 0)
                NotYet().padding(.top, 8)
                CardText("Black Team\u{2019}s own engine, built for local models: it measures your model\u{2019}s speed and sizes its work to match. Browser and Desktop control use Hermes. Applies to new conversations.").padding(.bottom, 10)
            }
            EqualColumns(columns: 2, spacing: 14) {
                ForEach(plugins, id: \.name) { plugin in
                    WorkCard(verticalMargin: 0) {
                        HStack {
                            Text(plugin.icon).font(BTFont.body(24)).foregroundStyle(theme.ink2)
                            Spacer(minLength: 0)
                            BTSwitch(isOn: plugin.on, label: plugin.name) {}.disabled(true)
                        }
                        .padding(.bottom, 14)
                        Text(plugin.name).font(BTFont.body(18, .semibold)).tracking(-0.41).foregroundStyle(theme.ink).btLines(18, 1.5)
                        CardText(plugin.text)
                        NotYet().padding(.top, 4).padding(.bottom, 10)
                    }
                }
            }
            CampNotice(text: "These plugins need the Hermes engine, which is not on the Mac yet. Code mode uses Black Team\u{2019}s own engine and shows every change.").padding(.top, 16)
        }
        .padding(.top, 16)
    }

    private func engineButton(_ title: String, selected: Bool) -> some View {
        Button {} label: {
            Text(title).font(BTFont.body(12, .medium)).foregroundStyle(selected ? theme.ink : theme.muted)
                .padding(.horizontal, 14).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.surface2 : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(selected ? theme.line2 : .clear, lineWidth: 1))
                .btShadow(selected ? theme.shadow : .none)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func chooseFolder() {
        guard let path = model.choose("workspace") else { return }
        Task { await model.action(success: "Workspace set to \(path).", { try await model.backend.saveSetup(["workspace": .string(path)]) }) }
    }
}

// MARK: - DSH sessions

/// DeepSeek Harness keeps its sessions in a folder that belongs to its own install; Black Team has no stable place to
/// read them from on a Mac, so the page shows the daily page's empty state.
struct SessionsPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CampNotice(text: "Open a harness, choose its session in the sidebar, then review changes or send your next instruction.")
            Text("No saved DSH sessions yet.").font(BTFont.body(13)).foregroundStyle(theme.ink).btLines(13, 1.5).padding(.top, 16)
        }
    }
}

// MARK: - Servers & access

struct ServersPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let runtime = model.status?.runtime
        VStack(alignment: .leading, spacing: 0) {
            pairing
            ForEach(model.status?.models ?? [], id: \.key) { item in
                let ready = item.active && runtime?.ready == true
                let starting = item.active && runtime?.state == "starting"
                let on = ready || starting
                WorkCard(label: ready ? "READY" : starting ? "STARTING" : "OFFLINE", title: item.name) {
                    CardText(item.active && runtime?.busy == true ? "Model is working" : ready ? "Ready for your next request" : "Start this model to chat or launch an agent.").padding(.bottom, 4)
                    HStack(spacing: 10) {
                        Button(on ? "Stop server" : "Start server") { Task { await model.setServer(item.key, on: !on) } }.buttonStyle(.btPrimary).disabled(model.busy)
                        Button("Open agent workspace") { Task { await model.openAgentWorkspace(item.key) } }.buttonStyle(.btSecondary).disabled(model.busy)
                    }
                    .padding(.top, 4)
                }
            }
            phoneApp
        }
        .padding(.top, 16)
    }

    private var pairing: some View {
        WorkCard(label: "PRIVATE ACCESS", title: "Take Camp with you.") {
            CardText("Scan this with your phone while it is connected to your Tailscale account. The code pairs that phone with this computer; share it only with your own devices.")
            HStack(spacing: 24) {
                RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field).frame(width: 200, height: 200)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                    .opacity(0.45).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    FieldText(text: "Pairing link", mono: true, disabled: true)
                    HStack(spacing: 10) {
                        Button("Copy pairing link") {}.buttonStyle(.btSecondary).disabled(true)
                        Button("Reset phone pairing") {}.buttonStyle(.btSecondary).disabled(true)
                    }
                    NotYet()
                }
            }
            .padding(.vertical, 16)
            CardText("This computer must stay powered on and awake. Chats are saved here; running requests continue after you close the app.").padding(.bottom, 10)
        }
    }

    private var phoneApp: some View {
        WorkCard(label: "PHONE APP", title: "Install Black Team") {
            CardText("On iPhone: open this private address in Safari, tap Share \u{2192} Add to Home Screen, and enable Open as Web App. Keep Tailscale connected.")
            CardText("Tasks run on your computer while the phone is closed. Reconnect to review progress. The computer must stay awake.")
            Button("Enable notifications") {}.buttonStyle(.btSecondary).disabled(true).padding(.top, 6)
            CardText("Optional encrypted alerts use your browser\u{2019}s notification service. Alerts contain only task status; open Black Team over Tailscale to review details or approve actions.", small: true)
            NotYet().padding(.top, 4).padding(.bottom, 10)
        }
    }
}
