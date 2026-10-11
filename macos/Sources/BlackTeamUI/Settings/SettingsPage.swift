import SwiftUI
import BlackTeamKit

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    var body: some View { SettingsContent(model: model) }
}

/// Models, agents & apps, and app & data (the three settings sections of App.jsx).
struct SettingsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BTSegmented(options: [(SettingsSection.model, "Models"), (.agents, "Agents & apps"), (.data, "App & data")],
                            selection: Binding(get: { model.settingsSection }, set: { model.settingsSection = $0 }))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 20)
            switch model.settingsSection {
            case .model:
                ModelListPanel(model: model)
                FoundModelsPanel(model: model, finder: model.finder)
                ModelSetupForm(model: model, settings: true)
            case .agents:
                IntegrationsPanel(model: model)
            case .data:
                AppDataSection(model: model)
            }
        }
    }
}

/// Every model set up, with the one in use marked (`ModelList` in Models.jsx).
struct ModelListPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let models = model.status?.models ?? []
        let working = model.status?.runtime.busy == true
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                BTEyebrow("Your models")
                Text("Switch between your models").font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink).btLines(18, 1.5).padding(.top, 8)
                Text("Every model you set up is kept here. Choosing one stops the model in use; your next message starts the new one.")
                    .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
                VStack(spacing: 0) {
                    ForEach(models, id: \.key) { item in
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                                Text("\(item.source == "server" ? "Local server" : "Model file") \u{00B7} \(item.location) \u{00B7} \(Fmt.number(item.context)) tokens")
                                    .btBody(11, 1.5, theme.muted, floor: 19.5)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if item.active {
                                Text("In use").font(BTFont.body(10)).tracking(0.4).foregroundStyle(theme.ink2)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .overlay(Capsule().stroke(theme.line2, lineWidth: 1))
                            } else {
                                HStack(spacing: 10) {
                                    Button("Use") { Task { await model.switchModel(item.key) } }.buttonStyle(.btSecondary).disabled(model.busy || working)
                                    Button("Remove") { Task { await model.forgetModel(item.key) } }.buttonStyle(.btQuiet).disabled(model.busy || working)
                                        .accessibilityLabel("Remove \(item.name) from your list")
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .btRule()
                    }
                }
                if working { BTInlineNote { Text("Finish or stop the current response before switching models.").btBody(12, 1.8, theme.muted) }.padding(.top, 20) }
            }
            .padding(.horizontal, 29).padding(.vertical, 27)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
            .btShadow(theme.shadow)
            .padding(.bottom, 20)
        }
    }
}

/// "Your data stays here", the optional research note and the update row (the App & data section of App.jsx).
struct AppDataSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updates: RuntimeUpdates
    @Environment(\.btTheme) private var theme

    init(model: AppModel) { self.model = model; self.updates = model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.settings-data`: a title and line on the left, one button on the right, a hairline under it.
            settingsRow(title: "Your data stays here", text: "Settings and conversations are saved on this computer.") {
                Button("Open data folder") { model.openDataFolder() }.buttonStyle(.btSecondary).disabled(model.busy)
            }
            updatesRow
            BTPlainDetails(title: "Optional research: JEV") {
                Text("Chat and agent work use local context management and need no JEV key. Optional research setup is described in docs/JEV.md.")
                    .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
            }
            .padding(.top, 16)
            BTInlineNote { Text("Updates are your choice. Black Team does not automatically download models or new app versions.").btBody(12, 1.8, theme.muted) }
                .padding(.top, 20)
        }
    }

    private func settingsRow<Action: View>(title: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink).btLines(18, 1.5)
                Text(text).btBody(12.5, 1.7, theme.muted).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
        .padding(.bottom, 8)
    }

    /// The runtime update row, built like the data row above it.
    private var updatesRow: some View {
        let runtime = model.status?.downloadedRuntime
        return VStack(alignment: .leading, spacing: 0) {
            settingsRow(title: "llama.cpp runtime", text: runtime.map { "Build \($0.tag) \u{00B7} downloaded by Black Team. Updates are checked only when you ask." } ?? "Not downloaded. Black Team downloads it when you get a starter model.") {
                switch updates.phase {
                case .available:
                    Button("Install update") { updates.install(model) }.buttonStyle(.btPrimary).disabled(isModelRunning)
                case .installing:
                    BTSpinner()
                default:
                    Button("Check for runtime update") { updates.check(model) }.buttonStyle(.btSecondary).disabled(updates.phase == .checking)
                }
            }
            switch updates.phase {
            case .idle: EmptyView()
            case .checking: BTInlineNote { Text("Looking for a newer llama.cpp\u{2026}").btBody(12, 1.8, theme.muted) }.padding(.bottom, 8)
            case .upToDate: BTInlineNote { Text("The llama.cpp runtime is up to date.").btBody(12, 1.8, theme.ok) }.padding(.bottom, 8)
            case .available(let tag):
                BTInlineNote { Text("Build \(tag) is available." + (isModelRunning ? " Stop the model, then install it." : "")).btBody(12, 1.8, theme.muted) }.padding(.bottom, 8)
            case .installing(let tag, let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installing build \(tag)\u{2026}").btBody(12, 1.5, theme.muted)
                    BTProgressBar(value: fraction)
                }.padding(.bottom, 8)
            case .installed(let tag):
                BTBanner(kind: .ok, message: "Build \(tag) is installed. Models you set up from now on use it.").padding(.bottom, 8)
            case .failed(let text):
                BTBanner(kind: .error, message: text).padding(.bottom, 8)
            }
        }
    }

    private var isModelRunning: Bool { model.status?.runtime.ready == true || model.status?.runtime.state == "starting" }
}

/// The standard About panel, with the version and the runtime in the credits.
enum AboutPanel {
    @MainActor static func show(version: String, runtime: String?) {
        let credits = NSAttributedString(string: "Private AI. Total control.\nEverything runs on this Mac." + (runtime.map { "\nllama.cpp build \($0)" } ?? ""),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Black Team", .applicationVersion: version, .version: "", .credits: credits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
