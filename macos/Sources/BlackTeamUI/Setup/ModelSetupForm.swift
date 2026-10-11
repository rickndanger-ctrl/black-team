import SwiftUI
import BlackTeamKit

private struct Provider: Identifiable {
    var id: String
    var name: String
    var summary: String
    var endpoint: String?
}

private let providers = [
    Provider(id: "ollama", name: "Ollama", summary: "Use models downloaded in Ollama", endpoint: "http://127.0.0.1:11434/v1"),
    Provider(id: "lmstudio", name: "LM Studio", summary: "Use its running local server", endpoint: "http://127.0.0.1:1234/v1"),
    Provider(id: "gguf", name: "Model file", summary: "Choose a GGUF on this computer", endpoint: nil),
    Provider(id: "custom", name: "Another server", summary: "Enter a local address", endpoint: nil),
]

/// The manual paths of ModelSetup.jsx: Ollama, LM Studio, another server, or a GGUF file; advanced settings folded away.
struct ModelSetupForm: View {
    @ObservedObject var model: AppModel
    var settings = false
    @Environment(\.btTheme) private var theme

    @State private var provider = "ollama"
    @State private var endpoint = "http://127.0.0.1:11434/v1"
    @State private var modelID = ""
    @State private var name = ""
    @State private var apiKey = ""
    @State private var apiKeyEdited = false
    @State private var file = ""
    @State private var runtime = ""
    @State private var mmproj = ""
    @State private var draft = ""
    @State private var context = 4096
    @State private var threads = 4
    @State private var gpuLayers = 0
    @State private var workspace = ""
    @State private var found: [String] = []
    @State private var checking = false
    @State private var failure = ""
    @State private var message = ""
    @State private var loaded = false

    private var server: Bool { provider != "gguf" }
    private var running: Bool { model.status?.runtime.ready == true || ["starting", "running"].contains(model.status?.runtime.state ?? "") }
    private var hasRuntime: Bool { !runtime.isEmpty || model.status?.downloadedRuntime != nil }
    private var canSave: Bool { server ? !modelID.trimmingCharacters(in: .whitespaces).isEmpty && !endpoint.isEmpty : !file.isEmpty && hasRuntime }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BTEyebrow(settings ? "Add a model" : "Your models")
            Text(settings ? "Add or change a model" : "Connect a model. Start a conversation.").font(BTFont.body(18, .semibold)).tracking(-0.27)
                .foregroundStyle(theme.ink).btLines(18, 1.5).padding(.top, 8)
            Text("Choose where your model lives. Black Team fills in the connection details. Use a downloaded model to keep inference on this computer.")
                .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
            if running { runningCard.padding(.bottom, 20) }
            VStack(alignment: .leading, spacing: 20) {
                providerGrid
                if server { serverFields } else { fileFields }
                advanced
                saveRow
            }
            .disabled(model.busy || checking || running)
            .opacity(model.busy || checking || running ? 0.6 : 1)
            if server, provider == "ollama" || provider == "lmstudio" {
                HStack { Button("Get \(provider == "ollama" ? "Ollama" : "LM Studio")") { model.openHelp(provider) }
                    .buttonStyle(.btQuiet).disabled(model.busy || checking); Spacer(minLength: 0) }.padding(.top, 20)
            }
            if !failure.isEmpty {
                BTInlineNote { Text(failure + " If your server uses a key, add it under Advanced connection and performance, then choose Find models again.").btBody(12, 1.8, theme.bad) }
                    .padding(.top, 20)
            }
        }
        .padding(29)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
        .btShadow(theme.shadow)
        .padding(.bottom, 18)
        .onAppear(perform: load)
    }

    // MARK: Pieces

    private var runningCard: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.modelName).font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading).padding(.bottom, 6)
                Text(model.status?.runtime.busy == true ? "Finish or stop the current response before changing models." : "Connected. Disconnect here to choose another model.")
                    .btBody(12, 1.6, theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Change model") {
                Task { await model.action(success: "Ready to choose another model.") { try await model.backend.stopModel() } }
            }.buttonStyle(.btSecondary).disabled(model.busy || model.status?.runtime.busy == true)
        }
        .padding(.horizontal, 21).padding(.vertical, 19)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
    }

    private var providerGrid: some View {
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { row in
                BTTwoColumns(gap: 10) {
                    ForEach(providers[(row * 2)..<(row * 2 + 2)]) { item in
                        BTProviderCard(name: item.name, summary: item.summary, selected: provider == item.id) { choose(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var serverFields: some View {
        if provider == "custom" {
            BTFormField(label: "Local server address") {
                BTTextField("http://127.0.0.1:1234/v1", text: Binding(get: { endpoint }, set: { endpoint = $0; found = []; message = ""; modelID = ""; apiKey = ""; apiKeyEdited = true }))
            }
        }
        HStack(spacing: 10) {
            Button(checking ? "Finding models\u{2026}" : "Find models") { Task { await discover() } }.buttonStyle(.btSecondary)
            Text(provider == "ollama" ? "Start Ollama first." : provider == "lmstudio" ? "Turn on the local server in LM Studio first." : "Start your server and enable its API first.")
                .btBody(12, 1.5, theme.ink)
            Spacer(minLength: 0)
        }
        if checking { Text("Checking your local server\u{2026}").btBody(13, 1.5, theme.ink) }
        if !message.isEmpty { Text(message).btBody(13, 1.5, theme.ink) }
        if !found.isEmpty || !modelID.isEmpty {
            let ids = Array(NSOrderedSet(array: ([modelID] + found).filter { !$0.isEmpty })) as? [String] ?? found
            BTFormField(label: "Model") {
                BTSelect(options: ids.map { ($0, Fmt.modelLabel($0)) },
                         selection: Binding(get: { modelID }, set: { modelID = $0; name = Fmt.modelLabel($0) }), height: 38, fontSize: 13, fill: true)
            }
        }
    }

    @ViewBuilder private var fileFields: some View {
        BTFileRow(title: "Model file", value: file.isEmpty ? "Choose a GGUF already on your computer" : Fmt.basename(file)) {
            Button("Choose model") { pickModel() }.buttonStyle(.btSecondary)
        }
        if !mmproj.isEmpty { companionRow("Vision projector", "\(Fmt.basename(mmproj)) \u{00B7} found beside the model; lets it see images") { mmproj = "" } }
        if !draft.isEmpty { companionRow("Draft model for faster replies", "\(Fmt.basename(draft)) \u{00B7} found beside the model") { draft = "" } }
        if runtime.isEmpty, let downloaded = model.status?.downloadedRuntime {
            BTFileRow(title: "llama.cpp ready", value: "Downloaded by Black Team \u{00B7} \(downloaded.tag)") { Button("Choose another") { pickRuntime() }.buttonStyle(.btSecondary) }
        } else {
            BTFileRow(title: runtime.isEmpty ? "Choose llama.cpp once" : "llama.cpp ready",
                      value: runtime.isEmpty ? "Select the llama-server program from your installation" : runtime) {
                Button(runtime.isEmpty ? "Choose runtime" : "Change") { pickRuntime() }.buttonStyle(.btSecondary)
            }
        }
    }

    private func companionRow(_ title: String, _ detail: String, leaveOut: @escaping () -> Void) -> some View {
        BTFileRow(title: title, value: detail) { Button("Leave out", action: leaveOut).buttonStyle(.btQuiet) }
    }

    private var advanced: some View {
        BTPlainDetails(title: "Advanced connection and performance") {
            VStack(alignment: .leading, spacing: 18) {
                BTFormField(label: "Display name (optional)") {
                    BTTextField("Uses the model name automatically", text: Binding(get: { name }, set: { name = String($0.prefix(120)) }))
                }
                if server {
                    if provider != "custom" {
                        BTFormField(label: "Server address") {
                            BTTextField("", text: Binding(get: { endpoint }, set: { provider = "custom"; endpoint = $0; found = []; message = ""; modelID = ""; apiKey = ""; apiKeyEdited = true }))
                        }
                    }
                    BTFormField(label: "Server API key (only if required)") {
                        BTSecureField(title: model.status?.serverKeyConfigured == true && !apiKeyEdited ? "Saved key \u{2014} leave unchanged to keep" : "Most local servers need no key",
                                      text: Binding(get: { apiKey }, set: { apiKey = $0; apiKeyEdited = true }))
                    }
                    if model.status?.serverKeyConfigured == true {
                        HStack { Button("Clear saved key on save") { apiKey = ""; apiKeyEdited = true }.buttonStyle(.btQuiet); Spacer(minLength: 0) }
                    }
                    BTFormField(label: "Model ID (manual override)") { BTTextField("", text: $modelID) }
                }
                BTFileRow(title: "Workspace", value: workspace) {
                    Button("Change folder") { if let path = model.choose("workspace") { workspace = path } }.buttonStyle(.btSecondary)
                }
                BTTwoColumns(gap: 18) {
                    BTFormField(label: "Context window", hint: server ? "Use no more than the context loaded by your server." : "Larger values use more memory.") {
                        BTNumberField(value: $context)
                    }
                    if !server {
                        BTFormField(label: "CPU threads") { BTNumberField(value: $threads) }
                    }
                }
                if !server {
                    BTTwoColumns(gap: 18) {
                        BTFormField(label: "GPU layers", hint: SystemInfo.isAppleSilicon ? "0 lets Black Team put the whole model on this Mac’s GPU." : "Start with 0 for CPU operation.") { BTNumberField(value: $gpuLayers) }
                        Color.clear.frame(height: 1)
                    }
                }
            }
            .padding(.top, 20)
        }
        .padding(.top, 16).btRule()
        .padding(.top, 4)
    }

    private var saveRow: some View {
        BTFormActions {
            Button(model.busy ? "Saving\u{2026}" : "Save and open chat") { save() }.buttonStyle(.btPrimary).disabled(!canSave)
            Text("Your first message connects the model automatically.").btBody(12, 1.5, theme.muted)
        }
    }

    // MARK: Behaviour

    private func load() {
        guard !loaded, let config = model.status?.config else { return }
        loaded = true
        let current = config.model
        let fresh = !model.setupComplete
        endpoint = current.endpoint
        modelID = fresh ? "" : current.id
        name = fresh ? "" : current.name
        file = current.file; runtime = current.runtime; mmproj = current.mmproj; draft = current.draft
        context = current.context; threads = current.threads; gpuLayers = current.gpuLayers
        workspace = config.workspace
        provider = fresh ? "ollama" : current.source == "gguf" ? "gguf" : providers.first { $0.endpoint == current.endpoint }?.id ?? "custom"
    }

    private func choose(_ item: Provider) {
        provider = item.id
        failure = ""; found = []; message = ""
        if let target = item.endpoint {
            if target != endpoint { apiKey = ""; apiKeyEdited = true }
            endpoint = target; modelID = ""; name = ""
            Task { await discover() }
        } else if item.id == "gguf", runtime.isEmpty {
            Task {
                let backend = model.backend
                let apps = await Task.detached { backend.discoverApps() }.value
                if !apps.runtime.isEmpty { runtime = apps.runtime }
            }
        }
    }

    private func discover() async {
        failure = ""; message = ""; checking = true; found = []
        defer { checking = false }
        do {
            let result = try await model.backend.discoverServer(endpoint: endpoint, apiKey: apiKeyEdited ? apiKey : nil)
            found = result.models
            if let first = result.models.first, !result.models.contains(modelID) { modelID = first; name = Fmt.modelLabel(first) }
            message = "\(result.models.count) \(result.models.count == 1 ? "model found" : "models found"). Choose one below."
        } catch { failure = plainMessage(error) }
    }

    private func pickModel() {
        guard let path = model.choose("model") else { return }
        file = path
        do {
            let info = try model.backend.inspectModelFile(path)
            name = info.name; context = info.context; mmproj = info.mmproj; draft = info.draft
        } catch {
            failure = plainMessage(error)
            name = Fmt.modelLabel(path); mmproj = ""; draft = ""
        }
    }

    private func pickRuntime() { if let path = model.choose("runtime") { runtime = path } }

    private func save() {
        let label = String((name.trimmingCharacters(in: .whitespaces).isEmpty ? (server ? modelID : Fmt.basename(file)) : name).prefix(120))
        var fields: [String: JSONValue] = [
            "source": .string(server ? "server" : "gguf"), "endpoint": .string(endpoint), "id": .string(modelID), "name": .string(label),
            "file": .string(file), "runtime": .string(runtime), "context": .number(Double(context)), "gpuLayers": .number(Double(gpuLayers)),
            "threads": .number(Double(threads)), "mmproj": .string(mmproj), "draft": .string(draft),
        ]
        if apiKeyEdited { fields["apiKey"] = .string(apiKey) }
        let form: JSONValue = ["model": .object(fields), "workspace": .string(workspace)]
        Task { await model.saveModel(form) }
    }
}
