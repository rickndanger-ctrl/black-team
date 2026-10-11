import SwiftUI
import BlackTeamKit

/// Agents & apps in Settings (Integrations.jsx without Hermes): Code, the code map, and other apps to open from the workspace.
struct IntegrationsPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @State private var form = IntegrationSettings()
    @State private var loaded = false
    @State private var appChoice = ""
    @State private var failure = ""

    private var installed: DiscoveryResult? { model.installed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BTEyebrow("Agents & apps")
            Text("Give your model tools").font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink).btLines(18, 1.5).padding(.top, 8)
            Text("Code is built in and needs no setup. Add other apps below to open them from your workspace.")
                .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
            // `fieldset` is a grid with a 20 point gap, and each card also has a 20 point bottom margin.
            VStack(alignment: .leading, spacing: 20) {
                BTConnectionCard(title: "Black Team Code",
                                 text: "Black Team\u{2019}s own engine, built for local models: it measures your model\u{2019}s speed and sizes its work to match. Reads, searches and edits files, runs commands, shows every change with Undo, and remembers across conversations.",
                                 status: "Built in", ready: true) {
                    Button("Open Code") { model.startChat(.agent) }.buttonStyle(.btPrimary).disabled(!model.setupComplete)
                }
                .padding(.bottom, 20)
                BTConnectionCard(title: "Code map",
                                 text: "With graphify installed, Code can ask a map of the project which files and functions matter before it reads, which saves a local model a lot of reading. The map is built from the code on this computer and kept in Black Team's data folder.",
                                 status: model.status?.codeMap == true ? "graphify found" : "graphify not installed", ready: model.status?.codeMap == true,
                                 aside: model.status?.codeMap == true ? nil : "Install with uv tool install graphifyy or pip install graphifyy, then reopen Black Team.") { EmptyView() }
                    .padding(.bottom, 20)
                HStack { Button("Find again") { Task { await model.scanApps() } }.buttonStyle(.btQuiet); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Other apps").font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                    Text("Open an installed app in its own window. Set that app to use your local provider first.")
                        .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
                }
                ForEach(form.harnesses.indices, id: \.self) { editor($0) }
                addRow
                BTFormActions {
                    Button("Save changes") { Task { await model.saveIntegrations(form) } }.buttonStyle(.btPrimary).disabled(model.busy || model.status?.runtime.busy == true)
                    Text("Saved apps appear on your workspace.").btBody(12, 1.5, theme.muted)
                }
            }
            .disabled(model.busy || model.status?.runtime.busy == true)
            if !failure.isEmpty { BTInlineNote { Text(failure).btBody(12, 1.8, theme.bad) }.padding(.top, 20) }
        }
        .padding(29)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
        .btShadow(theme.shadow)
        .padding(.bottom, 18)
        .onAppear {
            if !loaded { loaded = true; form = model.status?.integrations ?? IntegrationSettings() }
        }
        .task { if model.installed == nil { await model.scanApps() } }
    }

    // MARK: Editing one app

    private func editor(_ index: Int) -> some View {
        let item = form.harnesses[index]
        let terminals = installed?.terminals ?? []
        let known = item.terminal.isEmpty || terminals.contains { $0.executable == item.terminal[0] }
        var options: [(String, String)] = [("", "Its own app window")] + terminals.map { ($0.executable, $0.name) }
        if !known { options.append((item.terminal[0], Fmt.basename(item.terminal[0]))) }
        return VStack(alignment: .leading, spacing: 16) {
            BTFormField(label: "App name") { BTTextField("My app", text: Binding(get: { form.harnesses[index].name }, set: { form.harnesses[index].name = $0 })) }
            Text(item.executable).btBody(11, 1.6, theme.muted)
            BTPlainDetails(title: "Launch options") {
                VStack(alignment: .leading, spacing: 18) {
                    Button { if let path = model.choose("executable") { form.harnesses[index].executable = path } } label: { Text("Choose executable").frame(maxWidth: .infinity) }.buttonStyle(.btSecondary)
                    BTFormField(label: "Open in") {
                        BTSelect(options: options, selection: Binding(get: { form.harnesses[index].terminal.first ?? "" },
                                                                       set: { form.harnesses[index].terminal = $0.isEmpty ? [] : [$0] }), height: 38, fontSize: 13, fill: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App argument").font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink)
                        ForEach(form.harnesses[index].args.indices, id: \.self) { arg in
                            HStack(spacing: 10) {
                                BTTextField("", text: Binding(get: { form.harnesses[index].args[arg] }, set: { form.harnesses[index].args[arg] = $0 }))
                                Button("Remove") { form.harnesses[index].args.remove(at: arg) }.buttonStyle(.btQuiet)
                            }
                        }
                        HStack { Button("Add argument") { form.harnesses[index].args.append("") }.buttonStyle(.btSecondary); Spacer(minLength: 0) }
                        Text("One value per field. Use {endpoint}, {model} or {workspace} where your app expects them. Values are passed literally.").btBody(12, 1.5, theme.muted)
                    }
                }
                .padding(.top, 20)
            }
            HStack { Button("Remove \(item.name)") { form.harnesses.remove(at: index) }.buttonStyle(.btQuiet); Spacer(minLength: 0) }
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
    }

    private var addRow: some View {
        let apps = installed?.apps ?? []
        return HStack(spacing: 10) {
            BTFormField(label: "Add an app") {
                BTSelect(options: [("", "Choose an app file\u{2026}")] + apps.map { ($0.executable, "\($0.name) \u{2014} installed") },
                         selection: $appChoice, minWidth: 0, height: 38, fontSize: 13)
            }
            .fixedSize()
            Button("Add app") { addApp() }.buttonStyle(.btSecondary).disabled(form.harnesses.count >= 20)
            Spacer(minLength: 0)
        }
    }

    private func addApp() {
        failure = ""
        var found = installed?.apps.first { $0.executable == appChoice }
        let executable = found?.executable ?? model.choose("executable")
        guard let executable else { return }
        // A known harness chosen by hand is connected the same way as one found automatically.
        let base = Fmt.basename(executable)
        if found == nil, let preset = installed?.presets.first(where: { $0.command == base }) {
            found = FoundApp(id: preset.id, name: preset.name, executable: executable, preset: true)
        }
        let terminal = installed?.terminals.first
        if found != nil, terminal == nil {
            failure = "A terminal is needed to open this command-line app. Install a terminal, then choose Find again."
            return
        }
        form.harnesses.append(HarnessEntry(id: UUID().uuidString.lowercased(), name: found?.name ?? (base == "Not selected" ? "My app" : base), executable: executable, args: [],
                                           terminal: terminal.map { [$0.executable] + $0.args } ?? [], preset: found?.preset == true ? found?.id : nil))
        appChoice = ""
    }
}
