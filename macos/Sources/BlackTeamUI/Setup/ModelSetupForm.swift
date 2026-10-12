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
    Provider(id: "cloud", name: "Cloud model", summary: "Use a service with your own API key. What you send leaves this Mac.", endpoint: nil),
]

/// Presets only fill in the address. Each base address and its models route (`GET <base>/models`) was checked against the provider\u{2019}s
/// own documentation; "Another service" is any OpenAI-compatible API reached over https.
private struct CloudPreset: Identifiable {
    var id: String
    var name: String
    var address: String
}

private let cloudPresets = [
    CloudPreset(id: "openrouter", name: "OpenRouter", address: "https://openrouter.ai/api/v1"),
    CloudPreset(id: "openai", name: "OpenAI", address: "https://api.openai.com/v1"),
    CloudPreset(id: "anthropic", name: "Anthropic", address: "https://api.anthropic.com/v1"),
    CloudPreset(id: "google", name: "Google", address: "https://generativelanguage.googleapis.com/v1beta/openai"),
    CloudPreset(id: "other", name: "Another service", address: ""),
]

/// The manual paths of ModelSetup.jsx: Ollama, LM Studio, another server, or a GGUF file; advanced settings folded away.
struct ModelSetupForm: View {
    @ObservedObject var model: AppModel
    var settings = false
    @Environment(\.btTheme) private var theme

    init(model: AppModel, settings: Bool = false) {
        _model = ObservedObject(wrappedValue: model)
        self.settings = settings
    }

    /// The cloud form filled in as it looks when a key was pasted and the service listed its models, for the screen renders.
    init(model: AppModel, settings: Bool = false, previewCloud: Bool) {
        self.init(model: model, settings: settings)
        guard previewCloud else { return }
        _provider = State(initialValue: "cloud")
        _cloudPreset = State(initialValue: "openai")
        _endpoint = State(initialValue: "https://api.openai.com/v1")
        _apiKey = State(initialValue: String(repeating: "x", count: 51))
        _apiKeyEdited = State(initialValue: true)
        _found = State(initialValue: ["gpt-5.1", "gpt-5.1-mini", "gpt-4.1", "o4-mini"])
        _message = State(initialValue: "4 models from api.openai.com. Choose one below.")
        _modelID = State(initialValue: "gpt-5.1")
        _name = State(initialValue: "GPT 5.1")
        _context = State(initialValue: 400_000)
        _workspace = State(initialValue: "/Users/me/Black Team")
        _loaded = State(initialValue: true)
    }

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
    @State private var cloudPreset = "openrouter"
    @State private var cloudContexts: [String: Int] = [:]
    @State private var freeAgents: Set<String> = []
    @State private var freeOnly = false
    @State private var checking = false
    @State private var failure = ""
    @State private var message = ""
    @State private var loaded = false

    private var cloud: Bool { provider == "cloud" }
    private var server: Bool { provider != "gguf" }
    /// A local model that is loaded or loading. A cloud model has nothing loaded, so it never blocks the form.
    private var running: Bool { model.status?.runtime.kind != "cloud" && (model.status?.runtime.ready == true || ["starting", "running"].contains(model.status?.runtime.state ?? "")) }
    private var hasRuntime: Bool { !runtime.isEmpty || model.status?.downloadedRuntime != nil }
    /// The saved key is kept only for the address it was entered for.
    private var keepsSavedKey: Bool {
        guard let saved = model.status?.config.model, saved.source == "cloud", model.status?.serverKeyConfigured == true, !apiKeyEdited else { return false }
        return saved.endpoint == endpoint
    }
    private var canSave: Bool {
        if cloud { return !modelID.trimmingCharacters(in: .whitespaces).isEmpty && !endpoint.isEmpty && (!apiKey.isEmpty || keepsSavedKey) }
        return server ? !modelID.trimmingCharacters(in: .whitespaces).isEmpty && !endpoint.isEmpty : !file.isEmpty && hasRuntime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BTEyebrow(settings ? "Add a model" : "Your models")
            Text(settings ? "Add or change a model" : "Connect a model. Start a conversation.").font(BTFont.body(18, .semibold)).tracking(-0.27)
                .foregroundStyle(theme.ink).btLines(18, 1.5).padding(.top, 8)
            Text("Choose where your model lives. Black Team fills in the connection details. Use a downloaded model to keep inference on this computer; a cloud model needs your own key and sends what you write to its service.")
                .btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
            if running { runningCard.padding(.bottom, 20) }
            VStack(alignment: .leading, spacing: 20) {
                providerGrid
                if cloud { cloudFields } else if server { serverFields } else { fileFields }
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
                BTInlineNote { Text(failure + (cloud ? "" : " If your server uses a key, add it under Advanced connection and performance, then choose Find models again.")).btBody(12, 1.8, theme.bad) }
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
            ForEach(0..<3, id: \.self) { row in
                BTTwoColumns(gap: 10) {
                    ForEach(providers[(row * 2)..<min(providers.count, row * 2 + 2)]) { item in
                        BTProviderCard(name: item.name, summary: item.summary, selected: provider == item.id) { choose(item) }
                    }
                    if row * 2 + 2 > providers.count { Color.clear.frame(height: 1) }
                }
            }
        }
    }

    // MARK: Cloud model

    @ViewBuilder private var cloudFields: some View {
        BTInlineNote {
            Text("Conversations with a cloud model leave this Mac: Black Team sends your messages, and in Code the contents of files the agent reads and the output of commands it runs, to the service you name. Memory is not used. Your key stays on this Mac and goes only to this service\u{2019}s address.")
                .btBody(12, 1.8, theme.warn)
        }
        BTFormField(label: "Service") {
            BTSelect(options: cloudPresets.map { ($0.id, $0.name) }, selection: Binding(get: { cloudPreset }, set: { chooseCloud($0) }), height: 38, fontSize: 13, fill: true)
        }
        BTFormField(label: "Service address", hint: "https only. The key is sent here and nowhere else.") {
            BTTextField("https://api.example.com/v1", text: Binding(get: { endpoint }, set: { cloudAddressChanged($0) }))
        }
        BTFormField(label: "API key") {
            BTSecureField(title: keepsSavedKey ? "Saved key \u{2014} leave unchanged to keep" : "Paste your key. It is not shown again.",
                          text: Binding(get: { apiKey }, set: { apiKey = $0; apiKeyEdited = true; found = []; message = "" }))
        }
        HStack(spacing: 10) {
            Button(checking ? "Finding models\u{2026}" : "Find models") { Task { await discoverCloud() } }.buttonStyle(.btSecondary)
                .disabled(endpoint.isEmpty || (apiKey.isEmpty && !keepsSavedKey))
            Text("Asks the service for the models your key can use. You can also type a model id.").btBody(12, 1.5, theme.ink)
            Spacer(minLength: 0)
        }
        if checking { Text("Asking the service\u{2026}").btBody(13, 1.5, theme.ink) }
        if !message.isEmpty { Text(message).btBody(13, 1.5, theme.ink) }
        if !found.isEmpty {
            if !freeAgents.isEmpty {
                BTCheckbox(title: "Free models that can use tools (\(freeAgents.count))", isOn: $freeOnly)
                    .accessibilityLabel("Free models that can use tools")
                if freeOnly {
                    Text("Free models have daily limits, and the service may use what you send to train its models. Do not send anything private through one.").btBody(12, 1.5, theme.muted)
                }
            }
            BTFormField(label: "Models from the service") {
                BTSelect(options: found.filter { !freeOnly || freeAgents.contains($0) }.map { ($0, $0) }, selection: Binding(get: { found.contains(modelID) ? modelID : "" }, set: { pickCloudModel($0) }),
                         placeholder: "Choose a model", height: 38, fontSize: 13, fill: true)
            }
        }
        BTFormField(label: "Model id") {
            BTTextField("For example gpt-5.1 or anthropic/claude-sonnet", text: Binding(get: { modelID }, set: { modelID = $0; if name.isEmpty { name = Fmt.modelLabel($0) } }))
        }
        BTTwoColumns(gap: 18) {
            BTFormField(label: "Display name") { BTTextField("Uses the model id automatically", text: Binding(get: { name }, set: { name = String($0.prefix(120)) })) }
            BTFormField(label: "Context window", hint: "The most the model can read at once. Code works within 60% of it.") { BTNumberField(value: $context) }
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

    @ViewBuilder private var advanced: some View {
        if !cloud { advancedLocal } else {
            BTFileRow(title: "Workspace", value: workspace) {
                Button("Change folder") { if let path = model.choose("workspace") { workspace = path } }.buttonStyle(.btSecondary)
            }
        }
    }

    private var advancedLocal: some View {
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
            Button(model.busy ? "Saving\u{2026}" : cloud ? "Save cloud model" : "Save and open chat") { save() }.buttonStyle(.btPrimary).disabled(!canSave)
            Text(cloud ? "The key is stored on this Mac and never shown again." : "Your first message connects the model automatically.").btBody(12, 1.5, theme.muted)
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
        provider = fresh ? "ollama" : current.source == "cloud" ? "cloud" : current.source == "gguf" ? "gguf" : providers.first { $0.endpoint == current.endpoint }?.id ?? "custom"
        if current.source == "cloud" { cloudPreset = cloudPresets.first { $0.address == current.endpoint }?.id ?? "other" }
    }

    private func choose(_ item: Provider) {
        let before = provider
        provider = item.id
        failure = ""; found = []; message = ""
        if item.id == "cloud" {
            // A local server's key never becomes a cloud key, and the other way round.
            if before != "cloud" { apiKey = ""; apiKeyEdited = true; modelID = ""; name = ""; endpoint = cloudPresets.first { $0.id == cloudPreset }?.address ?? ""; context = max(context, 128_000) }
            return
        }
        if before == "cloud" { apiKey = ""; apiKeyEdited = true; modelID = ""; name = ""; endpoint = "http://127.0.0.1:11434/v1"; context = 4096 }
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

    private func chooseCloud(_ id: String) {
        cloudPreset = id
        failure = ""; found = []; message = ""; modelID = ""; name = ""; apiKey = ""; apiKeyEdited = true
        endpoint = cloudPresets.first { $0.id == id }?.address ?? ""
    }

    /// Typing a new address makes the key, the list and the model start again: a key goes only to the address it was entered for.
    private func cloudAddressChanged(_ value: String) {
        if value != endpoint { found = []; message = ""; failure = ""; modelID = ""; apiKey = ""; apiKeyEdited = true }
        endpoint = value
        cloudPreset = cloudPresets.first { $0.address == value }?.id ?? "other"
    }

    private func pickCloudModel(_ id: String) {
        guard !id.isEmpty else { return }
        modelID = id; name = Fmt.modelLabel(id)
        if let reported = cloudContexts[id] { context = min(reported, 2_000_000) }
    }

    private func discoverCloud() async {
        failure = ""; message = ""; checking = true; found = []
        defer { checking = false }
        do {
            let result = try await model.backend.discoverCloud(endpoint: endpoint, apiKey: apiKeyEdited ? apiKey : nil)
            found = result.models.map(\.id)
            cloudContexts = Dictionary(result.models.compactMap { item in item.context.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
            freeAgents = Set(result.models.filter(\.freeAgent).map(\.id)); freeOnly = false
            message = "\(result.models.count) \(result.models.count == 1 ? "model" : "models") from \(result.host). Choose one below."
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
        if cloud {
            var fields: [String: JSONValue] = ["source": "cloud", "endpoint": .string(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                                               "id": .string(modelID.trimmingCharacters(in: .whitespaces)), "name": .string(label), "context": .number(Double(context))]
            if apiKeyEdited { fields["apiKey"] = .string(apiKey) }
            let form: JSONValue = ["model": .object(fields), "workspace": .string(workspace)]
            Task { await model.saveModel(form); apiKey = ""; apiKeyEdited = false }
            return
        }
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
