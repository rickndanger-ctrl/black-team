import SwiftUI
import BlackTeamKit

/// The agents found on this Mac, each one step from opening with the model in use (Harnesses.jsx).
struct AgentAppsPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    private var saved: [HarnessEntry] { model.status?.integrations?.harnesses ?? [] }
    private var apps: [FoundApp] { model.installed?.apps ?? [] }

    private func savedFor(_ app: FoundApp) -> HarnessEntry? { saved.first { $0.id == app.id || $0.executable == app.executable } }

    var body: some View {
        let own = saved.filter { item in !apps.contains { savedFor($0)?.id == item.id } }
        let ready = model.setupComplete
        let working = model.busy || model.status?.runtime.busy == true
        BTPanel {
            VStack(alignment: .leading, spacing: 0) {
                BTEyebrow("Agents & apps")
                Text("Choose how you work").font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink).btLines(18, 1.5)
                    .padding(.top, 8).padding(.bottom, 10)
                Text("Black Team Chat and Code are built in. The agents found on this computer are listed here: connect one once, then open it any time with the model you are using.")
                    .btBody(12.5, 1.7, theme.muted).padding(.bottom, 18)
                VStack(spacing: 0) {
                    row(title: "Black Team Code", detail: "Built in. Edits files, runs commands, shows every change.") {
                        Button { model.startChat(.agent) } label: { BTIconLabel("Open Code", .terminal) }
                            .buttonStyle(.btPrimary).disabled(model.busy || !ready)
                    }
                    ForEach(apps, id: \.id) { app in
                        let item = savedFor(app)
                        row(title: app.name, detail: describe(app, item)) {
                            if let item {
                                Button { Task { await model.open(harness: item) } } label: { Text("Open").frame(minWidth: 64) }.buttonStyle(.btSecondary).disabled(working || !ready)
                            } else {
                                Button { Task { await model.connect(app: app) } } label: { Text("Connect").frame(minWidth: 64) }.buttonStyle(.btSecondary).disabled(working)
                            }
                        }
                    }
                    ForEach(own, id: \.id) { item in
                        row(title: item.name, detail: "Your own launcher.") {
                            Button { Task { await model.open(harness: item) } } label: { Text("Open").frame(minWidth: 64) }.buttonStyle(.btSecondary).disabled(working || !ready)
                        }
                    }
                }
                .padding(.bottom, 6)
                if model.installed != nil, apps.isEmpty, own.isEmpty {
                    BTInlineNote {
                        Text("No other agents were found on this computer. Claude Code, Codex, Pi, OpenCode, DeepSeek Harness and Aider are recognised once installed.")
                            .btBody(12, 1.8, theme.muted)
                    }.padding(.top, 20)
                }
                if !ready { BTInlineNote { Text("Set up a model above to open these.").btBody(12, 1.8, theme.muted) }.padding(.top, 20) }
                HStack {
                    Button("Add another app or change launch options") { model.showSettings(.agents) }.buttonStyle(.btQuiet)
                    Spacer(minLength: 0)
                }
                .frame(height: 18).padding(.top, 0)
                Text("Each agent opens in its own terminal and keeps its own history. Keep Black Team open while one uses a model Black Team started.")
                    .btBody(11, 1.6, theme.faint).padding(.top, 14)
            }
        }
        .task { if model.installed == nil { await model.scanApps() } }
    }

    private func describe(_ app: FoundApp, _ item: HarnessEntry?) -> String {
        if let item { return item.preset != nil ? "Connected. Opens in a terminal using \(model.modelName)." : "Connected. Opens in a terminal with its own settings." }
        return app.preset ? "Found on this computer. Connect it to use your local model." : "Found on this computer. Uses its own model settings."
    }

    /// `.harnesses li`: 13 points above and below, a hairline on top, a 96 point minimum button.
    private func row<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                Text(detail).btBody(11.5, 1.6, theme.muted, floor: 20.4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 13)
        .btRule()
    }
}
