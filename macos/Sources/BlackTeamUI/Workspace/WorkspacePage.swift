import SwiftUI
import BlackTeamKit

/// The command center: the model, this computer, and the agent apps (Workspace in App.jsx).
struct WorkspacePage: View {
    @ObservedObject var model: AppModel
    var body: some View { WorkspaceContent(model: model) }
}

struct WorkspaceContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Telemetry(status: model.status).padding(.bottom, 18)
            if !model.setupComplete {
                FirstRunView(model: model)
            } else {
                if model.welcome == .agents { FirstRunView(model: model) }
                else { ModelCard(model: model).padding(.bottom, 18) }
                notes
                if model.welcome == nil { FoundPrompt(model: model, finder: model.finder).padding(.bottom, 20) }
                if model.welcome != .agents { AgentAppsPanel(model: model).padding(.bottom, 18) }
            }
            principles
        }
    }

    @ViewBuilder private var notes: some View {
        if let warnings = model.status?.hardware.warnings, !warnings.isEmpty {
            BTInlineNote {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Hardware notes").font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink).btLines(12, 1.8)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}").font(BTFont.body(12)).foregroundStyle(theme.muted)
                                Text(warning).btBody(12, 1.8, theme.muted)
                            }
                        }
                    }
                    .padding(.leading, 5).padding(.top, 7)
                }
            }
            .padding(.top, 20).padding(.bottom, 18)
        }
        if let failure = model.status?.runtime.error, !failure.isEmpty {
            let server = model.status?.config.model.source == "server"
            BTBanner(kind: .error, message: (server ? "The local server could not connect. " : "The model could not start. ") + failure)
                .padding(.bottom, 16)
        }
    }

    private var principles: some View {
        FractionalColumns(fractions: [1, 1, 1], spacing: 26) {
            principle("01 / YOUR COMPUTER", "Local by default", "Conversation history lives on your machine. No Black Team account needed. Use a local model in your server to keep inference here.")
            principle("02 / YOUR CHOICE", "Bring your model", "Load a GGUF model or connect your existing local model server.")
            // The phone companion is not part of the Mac app, so the third column stays empty.
            Color.clear.frame(height: 1)
        }
        .padding(.top, 30).padding(.bottom, 20)
    }

    private func principle(_ step: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step).font(BTFont.mono(9)).tracking(0.54).foregroundStyle(theme.faint).frame(height: 13.5)
            Text(title).font(BTFont.body(13, .medium)).foregroundStyle(theme.ink).frame(height: 19.5).padding(.top, 12).padding(.bottom, 7)
            Text(text).btBody(12, 1.75, theme.muted).padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }
}

// MARK: - This computer

/// CPU, memory and disk in one joined panel (`.telemetry`).
struct Telemetry: View {
    let status: BackendStatus?
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    var body: some View {
        let performance = status?.performance, hardware = status?.hardware
        let cpu = hardware?.cpu
        let memoryFree = performance?.memory.free ?? hardware?.memory.free
        let swapUsed = performance?.memory.swapUsed ?? 0
        let cells: [TelemetryCell] = [
            TelemetryCell(icon: .chip, label: "CPU IN USE", value: "\(performance?.cpu ?? 0)%",
                          small: "\u{00B7} load \(String(format: "%.1f", performance?.load ?? 0)) of \(cpu?.threads ?? hardware?.cores ?? 0)"
                            + (performance?.temperature.map { " \u{00B7} \($0)\u{00B0}C" } ?? ""),
                          caption: cpuCaption(cpu)),
            TelemetryCell(icon: .activity, label: "MEMORY AVAILABLE", value: Fmt.gb(memoryFree), small: "/ \(Fmt.gb(hardware?.memory.total))",
                          caption: performance?.model.map { memory in
                              "Model holding \(Fmt.gb(memory.resident))" + (memory.swapped > 256 * 1_048_576 ? ", \(Fmt.gb(memory.swapped)) pushed to swap" : "")
                          } ?? (swapUsed > 256 * 1_048_576 ? "\(Fmt.gb(swapUsed)) of swap in use" : "Free for a model to load")),
            TelemetryCell(icon: .folder, label: "DISK AVAILABLE", value: Fmt.gb(hardware?.disk?.available ?? hardware?.disk?.free),
                          small: "/ \(Fmt.gb(hardware?.disk?.total))", caption: "Where Black Team keeps its data"),
        ]
        Group {
            if metrics.compact {
                VStack(spacing: 0) {
                    FractionalColumns(fractions: [1, 1]) {
                        cell(cells[0], divider: true)
                        cell(cells[1], divider: false)
                    }
                    cell(cells[2], divider: false).btRule()
                }
            } else {
                FractionalColumns(fractions: [1, 1.3, 1]) {
                    cell(cells[0], divider: true)
                    cell(cells[1], divider: true)
                    cell(cells[2], divider: false)
                }
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
        .btShadow(theme.shadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This computer")
    }

    private func cpuCaption(_ cpu: CPUInfo?) -> String {
        guard let cpu else { return "CPU" }
        var parts = [cpu.name.isEmpty ? "CPU" : cpu.name]
        if let p = cpu.performanceCores, let e = cpu.efficiencyCores, p + e > 0 {
            parts.append("\(cpu.cores) cores (\(p) performance + \(e) efficiency)")
        } else {
            parts.append("\(cpu.cores) physical \(cpu.cores == 1 ? "core" : "cores")")
        }
        parts.append("\(cpu.threads) threads")
        if let mhz = cpu.mhz, mhz > 0 { parts.append("\(Fmt.mhz(mhz)) now") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func cell(_ item: TelemetryCell, divider: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconView(item.icon, size: 17).foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.label).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 19.5, alignment: .leading)
                (Text(item.value + " ").font(BTFont.mono(20)).tracking(-0.8).foregroundStyle(theme.ink)
                    + Text(item.small).font(BTFont.body(11)).tracking(-0.8).foregroundStyle(theme.muted))
                    .lineLimit(1).fixedSize().frame(height: 26.9, alignment: .leading).padding(.top, 4)
                Text(item.caption).btBody(10.5, 1.5, theme.muted).padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { if divider { Rectangle().fill(theme.line).frame(width: 1) } }
        .accessibilityElement(children: .combine)
    }
}

private struct TelemetryCell {
    let icon: BTIcon, label: String, value: String, small: String, caption: String
}

// MARK: - The model

struct ModelCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let status = model.status
        let config = status?.config.model
        let runtime = status?.runtime
        let server = config?.source == "server"
        let running = runtime?.ready == true || runtime?.state == "starting"
        BTPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 22) {
                    AgentAvatar(state: runtime?.busy == true ? .working : .idle, large: true)
                    VStack(alignment: .leading, spacing: 0) {
                        BTEyebrow("Your local model")
                        Text(config?.name.isEmpty == false ? config!.name : "Local model").font(BTFont.body(24, .semibold)).tracking(-0.36)
                            .foregroundStyle(theme.ink).btLines(24, 1.5).padding(.vertical, 8)
                        Text(blurb(runtime, server: server)).btBody(12.5, 1.7, theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                FractionalColumns(fractions: [1.7, 1, 1], spacing: 24) {
                    fact("Model", server ? (config?.id ?? "") : Fmt.basename(config?.file))
                    fact("Processing", server ? "Local server" : processing(config, runtime))
                    fact("Context window", "\(Fmt.number(config?.context ?? 4096)) tokens")
                }
                .padding(.top, 20).btRule().padding(.vertical, 26)
                HStack(spacing: 10) {
                    if running {
                        Button { Task { await model.stopModel() } } label: { BTIconLabel(server ? "Disconnect model" : "Stop model", .power) }
                            .buttonStyle(.btSecondary).disabled(model.busy || runtime?.busy == true)
                    } else {
                        Button { Task { await model.startModel() } } label: { BTIconLabel(server ? "Connect model" : "Start model", .power) }
                            .buttonStyle(.btPrimary).disabled(model.busy)
                    }
                    Button { model.startChat(.chat) } label: { BTIconLabel("Open chat", .chat) }
                        .buttonStyle(running ? .btPrimary : .btSecondary).disabled(model.busy)
                    Button { model.showSettings(.model) } label: { BTIconLabel("Change model", .arrow, trailing: true) }.buttonStyle(.btQuiet)
                    Spacer(minLength: 0)
                }
                if runtime?.busy == true {
                    BTInlineNote {
                        Text("A response is running. Open Conversations to stop the response before stopping the model.").btBody(12, 1.8, theme.muted)
                    }
                    .padding(.top, 20)
                }
            }
        }
    }

    private func blurb(_ runtime: RuntimeSummary?, server: Bool) -> String {
        if runtime?.ready == true { return "Ready on this computer. Open a conversation to begin." }
        if runtime?.state == "starting" { return server ? "Connecting to your local server. The server manages model loading." : "Loading the model into memory. This can take a moment." }
        return "Start your model when you need it. Your conversations stay here."
    }

    private func processing(_ config: PublicModelConfig?, _ runtime: RuntimeSummary?) -> String {
        var parts = [(config?.gpuLayers ?? 0) > 0 ? "\(config!.gpuLayers) GPU layers" : "CPU"]
        if let features = runtime?.features, !features.isEmpty { parts += features } else { parts.append("\(config?.threads ?? 0) threads") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading).padding(.bottom, 6)
            Text(value).btBody(12, 1.625, theme.ink, weight: .medium)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
