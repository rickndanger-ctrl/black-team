import SwiftUI
import BlackTeamKit

/// The "Black Team" window's main column: Overview or Diagnostics (App.jsx), one page of sections under a header.
struct CommandMain: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        if model.status == nil {
            BootView(model: model)
        } else {
            PageScroll {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Banners(model: model)
                    DailyTelemetry(model: model)
                    ModelSection(model: model)
                    if model.commandPage == .overview {
                        HarnessSection(model: model)
                        PaceSection(model: model)
                        LaunchBar(model: model)
                    } else {
                        DiagnosticsSection(model: model)
                    }
                    ActivitySection(model: model)
                    PageFooter()
                }
            }
            .sheet(isPresented: $model.showConfig) { ConfigSheet(model: model) }
        }
    }

    private var header: some View {
        let overview = model.commandPage == .overview
        return HStack(alignment: .center, spacing: 20) {
            DailyTitle(eyebrow: "BLACK TEAM / \(overview ? "LAUNCHPAD" : "SYSTEM HEALTH")",
                       title: overview ? "Command center" : "System diagnostics",
                       line: overview ? "Your models. Your workspace. Your control." : "Check what is running and find the cause of a startup error.")
            Spacer(minLength: 0)
            DailyPill(text: model.pillText, live: model.activeCard?.state == "ready")
        }
        .padding(.bottom, 28)
    }
}

/// `<footer>`: the name on the left, what closing does on the right.
struct PageFooter: View {
    @Environment(\.btTheme) private var theme
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("BLACK TEAM").font(BTFont.mono(8)).tracking(1.6)
            Spacer(minLength: 0)
            Text("Closing every window quits Black Team and stops its model server.").font(BTFont.mono(9))
        }
        .foregroundStyle(theme.faint)
        .padding(.top, 24)
    }
}

/// The 13 point heading with its number and a quiet note on the right (`.section-heading`).
struct SectionHeading<Trailing: View>: View {
    var number: String?
    let title: String
    var size: CGFloat = 13
    @ViewBuilder var trailing: Trailing
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 0) {
                if let number { Text(number).font(BTFont.mono(10)).foregroundStyle(theme.faint).padding(.trailing, 13.4) }
                Text(title).font(BTFont.body(size, .semibold)).tracking(-size * 0.015).foregroundStyle(theme.ink)
            }
            .frame(height: size * 1.5)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.top, 26).padding(.bottom, number == nil ? 12 : 13.5)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeading where Trailing == Text {
    init(number: String? = nil, title: String, size: CGFloat = 13, note: String) {
        self.init(number: number, title: title, size: size) { Text(note).font(BTFont.body(12)) }
    }
}

// MARK: - CPU, memory and connection

/// `.telemetry`: three joined cells, the first two with a thin meter along the bottom.
struct DailyTelemetry: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    private func gb(_ value: Int) -> String { String(format: "%.1f", Double(value) / 1_073_741_824) }

    var body: some View {
        let perf = model.status?.performance
        let cpu = perf?.cpu ?? 0
        let used = perf?.memory.used ?? 0, total = perf?.memory.total ?? 0
        FractionalColumns(fractions: [1, 1.3, 1.2]) {
            cell(.chip, "CPU usage", meter: Double(cpu) / 100) {
                (Text("\(cpu)").font(BTFont.mono(20)).foregroundStyle(theme.ink) + Text("%").font(BTFont.body(11)).foregroundStyle(theme.muted)).tracking(-0.8)
            }
            cell(.activity, "Memory", meter: total > 0 ? Double(used) / Double(total) : 0) {
                (Text(gb(used)).font(BTFont.mono(20)).foregroundStyle(theme.ink) + Text(" / \(gb(total)) GB").font(BTFont.body(11)).foregroundStyle(theme.muted)).tracking(-0.8)
            }
            // Honest about the model in use: a cloud model is not "on this computer".
            let cloud = model.status?.cloud ?? CloudStatus()
            cell(.globe, "Connection", meter: nil, tag: cloud.selected ? "CLOUD" : "PRIVATE", tagWarn: cloud.selected, valueHeight: 22, top: 4) {
                Text(cloud.selected ? "Cloud \u{00B7} \(cloud.provider)" : "On this computer").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink).padding(.top, 4).offset(y: -1.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
        .btShadow(theme.shadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This computer")
    }

    private func cell<Value: View>(_ icon: BTIcon, _ label: String, meter: Double?, tag: String? = nil, tagWarn: Bool = false, valueHeight: CGFloat = 30, top: CGFloat = 5, @ViewBuilder value: () -> Value) -> some View {
        let padding: CGFloat = metrics.compact ? 12 : 20
        return HStack(alignment: .center, spacing: 14) {
            IconView(icon, size: 17).foregroundStyle(theme.muted).frame(width: 17)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading)
                value().lineLimit(1).fixedSize().frame(height: valueHeight, alignment: .bottomLeading).padding(.top, top).offset(y: tag == nil ? -1.5 : 0)
            }
            Spacer(minLength: 0)
            if let tag {
                Text(tag).font(BTFont.mono(8)).tracking(0.8).foregroundStyle(tagWarn ? theme.warn : theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(tagWarn ? theme.warnBg : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(tagWarn ? theme.warnLine : theme.line2, lineWidth: 1))
            }
        }
        .padding(.leading, padding).padding(.trailing, padding).padding(.top, 18).padding(.bottom, 21)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if let meter {
                Rectangle().fill(theme.line).frame(height: 2).overlay(alignment: .leading) {
                    GeometryReader { geo in Rectangle().fill(theme.accent).frame(width: geo.size.width * CGFloat(min(1, max(0, meter)))) }
                }
                .padding(.horizontal, padding)
            }
        }
        .overlay(alignment: .trailing) { if tag == nil { Rectangle().fill(theme.line).frame(width: 1) } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 01 Select your model

struct ModelSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let cards = model.modelCards
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(number: "01", title: model.setupComplete || !cards.isEmpty ? "Select your model" : "Select your model") {
                Button { model.showConfig = true } label: {
                    Text("Available configurations").font(BTFont.body(12)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain).accessibilityLabel("Available configurations")
            }
            if cards.isEmpty {
                FirstModelSetup(model: model)
            } else {
                EqualColumns(columns: 2, spacing: 12) {
                    ForEach(cards) { card in ModelCard(model: model, card: card) }
                }
                ServerRow(model: model)
            }
        }
    }
}

struct ModelCard: View {
    @ObservedObject var model: AppModel
    let card: ModelCardInfo
    @Environment(\.btTheme) private var theme

    var body: some View {
        let chosen = card.active
        Button { if !chosen { Task { await model.switchModel(card.id) } } } label: {
            HStack(spacing: 14) {
                Text(String(card.name.prefix(1)).uppercased()).font(BTFont.mono(20)).foregroundStyle(theme.ink)
                    .frame(width: 38, height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.name).font(BTFont.body(14, .semibold)).foregroundStyle(theme.ink).frame(height: 21, alignment: .leading)
                    Text(card.detail).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading).padding(.top, 4)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if card.cloud {
                    CloudTag()
                } else {
                    Text(card.state == "ready" ? "Ready" : card.state == "starting" ? "Starting" : card.state == "error" ? "Error" : "Off")
                        .font(BTFont.mono(9)).tracking(0.54).foregroundStyle(card.state == "ready" ? theme.ok : theme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(card.state == "ready" ? theme.okBg : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(card.state == "ready" ? theme.okLine : theme.line2, lineWidth: 1))
                }
                ZStack {
                    Circle().fill(chosen ? theme.accent : .clear)
                    Circle().inset(by: 0.5).stroke(chosen ? theme.accent : theme.line2, lineWidth: 1)
                    if chosen { IconView(.check, size: 12).foregroundStyle(theme.onAccent) }
                }
                .frame(width: 16, height: 16)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(chosen ? theme.surface2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(chosen ? theme.accent : theme.line2, lineWidth: 1))
            .overlay { if chosen { RoundedRectangle(cornerRadius: Theme.radiusLg - 1, style: .continuous).inset(by: 1.5).stroke(theme.accent, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityLabel("\(card.name), \(card.detail)\(card.cloud ? ", cloud model" : "")")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// `.server-bar`: the power icon, what the server is doing, and the switch.
struct ServerRow: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        // A cloud model has no server on this Mac, so there is no switch for it.
        if let card = model.activeCard, !card.cloud {
            let on = card.state == "ready" || card.state == "starting"
            let busy = model.status?.runtime.busy == true
            let text = card.state == "ready" ? (busy ? "Working on a request" : "Online and ready for requests")
                : card.state == "starting" ? "Loading the model into memory\u{2026}" : "Start it here, or launch a harness to start automatically."
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    IconView(.power, size: 17).foregroundStyle(theme.muted).frame(width: 17)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(card.name) server").font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink).frame(height: 18, alignment: .leading)
                        Text(text).font(BTFont.body(11)).foregroundStyle(theme.muted).frame(height: 16.5, alignment: .leading).padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
                BTSwitch(isOn: on, label: "\(on ? "Stop" : "Start") \(card.name) server") {
                    Task { if on { await model.stopModel() } else { await model.startModel() } }
                }
                .disabled(model.busy)
            }
            .padding(.leading, 4).padding(.trailing, 4).padding(.top, 16).padding(.bottom, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
            .padding(.top, 4)
        }
    }
}

// MARK: - 02 Choose your harness

struct HarnessSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics

    var body: some View {
        let cards = model.harnessCards
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(number: "02", title: "Choose your harness", note: "Desktop and terminal") .foregroundStyle(theme.muted)
            EqualColumns(columns: metrics.wide ? 4 : 3, spacing: 10) {
                ForEach(cards) { card in HarnessCard(model: model, card: card, chosen: card.id == model.selectedHarnessCard.id) }
            }
        }
        .task { if model.installed == nil { await model.scanApps() } }
    }
}

struct HarnessCard: View {
    @ObservedObject var model: AppModel
    let card: HarnessCardInfo
    let chosen: Bool
    @Environment(\.btTheme) private var theme

    var body: some View {
        Button { model.selectedHarness = card.id } label: {
            VStack(alignment: .leading, spacing: 0) {
                IconView(card.id == "chat" ? .chat : card.builtIn ? .grid : .terminal, size: 18).foregroundStyle(theme.ink2).padding(.bottom, 10)
                Text(card.name).font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink).frame(height: 18, alignment: .leading)
                Text(card.detail).font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading).padding(.top, 4)
            }
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                Text(card.kind).font(BTFont.mono(8)).tracking(0.48).foregroundStyle(theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                    .padding(.trailing, 12).padding(.top, 13)
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(chosen ? theme.surface2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(chosen ? theme.accent : theme.line2, lineWidth: 1))
            .overlay { if chosen { RoundedRectangle(cornerRadius: Theme.radiusLg - 1, style: .continuous).inset(by: 1.5).stroke(theme.accent, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.launching)
        .accessibilityLabel("\(card.name), \(card.detail), \(card.kind)")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 03 Set the pace

struct PaceSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(number: "03", title: "Set the pace", note: "Response depth").foregroundStyle(theme.muted)
            HStack(spacing: 4) {
                ForEach(AppModel.paceWords, id: \.id) { item in
                    let chosen = model.pace == item.id
                    Button { model.pace = item.id } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                IconView(item.id == "fast" ? .bolt : .activity, size: 17).frame(width: 17)
                                Text(item.title).font(BTFont.body(12, .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 18)
                            Text(item.detail).font(BTFont.body(9)).foregroundStyle(theme.muted).lineLimit(1).frame(height: 13.5, alignment: .leading).padding(.top, 6)
                        }
                        .foregroundStyle(chosen ? theme.ink : theme.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? theme.surface2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(chosen ? theme.accent : .clear, lineWidth: 1))
                        .btShadow(chosen ? theme.shadow : .none)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title), \(item.detail)")
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
        }
    }
}

// MARK: - The launch bar

struct LaunchBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let card = model.selectedHarnessCard
        let needsModel = model.activeCard == nil
        // Agent apps are pointed at the local model; none is launched against a cloud one for now.
        let cloudRefused = model.cloudSelected && !card.builtIn
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    IconView(.folder, size: 17).foregroundStyle(theme.muted)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(card.builtIn ? "Saved conversations and files" : "Workspace").font(BTFont.body(10)).foregroundStyle(theme.muted).frame(height: 15, alignment: .leading)
                        Text(card.builtIn ? "Black Team workspace" : model.workspaceLabel).font(BTFont.body(12, .medium)).foregroundStyle(theme.ink)
                            .lineLimit(1).frame(height: 18, alignment: .leading).padding(.top, 4)
                    }
                }
                Text(cloudRefused ? "Agent apps use your local model. Select a local model to launch one."
                        : card.builtIn ? "Depth applies to new conversations. Existing chats keep their setting." : "Opens in a dedicated terminal window.")
                    .font(BTFont.body(10)).foregroundStyle(cloudRefused ? theme.warn : theme.faint).frame(height: 15, alignment: .leading).padding(.top, 10)
            }
            Spacer(minLength: 0)
            Button { Task { await model.launchSelected() } } label: {
                HStack(spacing: 8) {
                    if model.launching { BTSpinner() } else { IconView(.play, size: 15) }
                    Text(model.launching ? "Preparing\u{2026}" : "Launch \(card.name)")
                    IconView(.arrow, size: 15)
                }
            }
            .buttonStyle(.btPrimary).environment(\.btControlHeight, 42)
            .disabled(model.launching || model.busy || (needsModel && !card.builtIn) || cloudRefused)
        }
        .padding(.top, 22)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        .padding(.top, 24)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @State private var checked = false

    private struct Check: Identifiable { let id: String; let ok: Bool; let detail: String }

    private var checks: [Check] {
        let status = model.status
        let runtime = status?.runtime
        let state = runtime?.state ?? "off"
        let server = state == "error" ? (runtime?.error ?? "Error")
            : runtime?.ready == true ? "Ready" : state == "starting" ? "Starting" : "Off"
        let perf = status?.performance
        func gb(_ v: Int) -> String { String(format: "%.1f", Double(v) / 1_073_741_824) }
        var list = [
            Check(id: "Model server", ok: runtime?.ready == true, detail: server),
            Check(id: "Model endpoint", ok: runtime?.ready == true, detail: runtime?.ready == true ? "Ready" : "Start the model to connect"),
            Check(id: "Memory", ok: (perf?.memory.swapUsed ?? 0) < 256 * 1_048_576,
                  detail: "\(gb(perf?.memory.used ?? 0)) of \(gb(perf?.memory.total ?? 0)) GB in use"),
        ]
        if let tag = status?.downloadedRuntime?.tag { list.append(Check(id: "llama.cpp runtime", ok: true, detail: "Build \(tag)")) }
        else { list.append(Check(id: "llama.cpp runtime", ok: runtime?.ready == true, detail: "Not downloaded by Black Team")) }
        list.append(Check(id: "Data folder", ok: true, detail: model.backend.dataFolder))
        return list
    }

    var body: some View {
        let name = model.activeCard?.name ?? "your model"
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Health check \u{00B7} \(name)", size: 13) {
                Button { Task { await model.refresh(); model.note("Health check: \(model.pillText)") } } label: { BTIconLabel("Refresh", .refresh) }
                    .buttonStyle(.btSecondary).disabled(model.busy)
            }
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                    HStack(spacing: 12) {
                        Circle().fill(check.ok ? theme.ok : theme.muted).frame(width: 6, height: 6).padding(.trailing, 8)
                        Text(check.id).font(BTFont.mono(11)).foregroundStyle(theme.ink).frame(width: 150, height: 18, alignment: .leading)
                        Text(check.detail).font(BTFont.body(12)).foregroundStyle(theme.muted).lineLimit(1).frame(height: 18)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .overlay(alignment: .bottom) { if index < checks.count - 1 { Rectangle().fill(theme.line).frame(height: 1) } }
                    .accessibilityElement(children: .combine)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
            LogDetails(text: logText)
        }
        .padding(.top, -1)
    }

    private var logText: String {
        var lines = model.log
        if let failure = model.status?.runtime.error, !failure.isEmpty, !lines.contains(where: { $0.hasSuffix(failure) }) { lines.append(failure) }
        return lines.isEmpty ? "No recent errors." : lines.joined(separator: "\n")
    }
}

/// `<details open>` with a `<pre>`: "Recent operational logs".
struct LogDetails: View {
    let text: String
    @State private var open = true
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    LogTriangle().fill(theme.ink2).frame(width: 8, height: 7).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8)
                    Text("Recent operational logs").font(BTFont.body(12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.ink2).frame(height: 20.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recent operational logs")
            if open {
                let body = Text(text).font(BTFont.mono(11)).foregroundStyle(theme.ink2)
                    .lineSpacing(max(0, 11 * 1.6 - BTFont.natural(11, mono: true)) + 0.5).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if flat { body.frame(maxHeight: 300, alignment: .top).clipped() } else { ScrollView { body }.frame(maxHeight: 300) }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
            }
        }
        .padding(.top, 16)
    }
}

// MARK: - Recent activity

struct ActivitySection: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Recent activity", size: 12, note: "This session").foregroundStyle(theme.muted)
            if model.events.isEmpty {
                HStack(spacing: 10) {
                    IconView(.activity, size: 17)
                    Text("All set. Your next launch will appear here.").font(BTFont.body(11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.muted).padding(.vertical, 9).padding(.horizontal, 1)
            } else {
                ForEach(model.events) { event in
                    HStack(spacing: 10) {
                        IconView(.check, size: 15).foregroundStyle(theme.ok)
                        Text(event.text).font(BTFont.body(11)).foregroundStyle(theme.muted)
                        Spacer(minLength: 0)
                        Text(event.time).font(BTFont.mono(10)).foregroundStyle(theme.faint)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 1)
                }
            }
        }
        .padding(.top, 1)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        .padding(.top, 28)
    }
}

/// The disclosure marker of a `<details>`: a small filled triangle pointing right.
struct LogTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
        return p
    }
}
