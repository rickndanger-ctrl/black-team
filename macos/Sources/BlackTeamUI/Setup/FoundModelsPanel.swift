import SwiftUI
import BlackTeamKit

/// Models already on this Mac: running local servers and model files in the usual folders (FindModels.jsx).
struct FoundModelsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var finder: ModelFinder
    var heading = "Models found on this computer"
    var auto = false
    var onManual: (() -> Void)?
    @Environment(\.btTheme) private var theme

    var body: some View {
        BTPanel {
            VStack(alignment: .leading, spacing: 0) {
                BTEyebrow("Find models")
                Text(heading).font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink).btLines(18, 1.5).padding(.top, 8)
                content
            }
        }
        .padding(.bottom, 20)
        .task { if auto && finder.report == nil && !finder.looking { await finder.look(model.backend) } }
    }

    private func intro(_ text: String) -> some View {
        Text(text).btBody(12.5, 1.8, theme.muted).frame(maxWidth: 680, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
    }

    @ViewBuilder private var content: some View {
        if finder.report == nil && !finder.looking {
            intro("Black Team can look for local model servers that are running and for model files in the usual folders. Nothing leaves this computer.")
            HStack { Button("Find my models") { Task { await finder.look(model.backend) } }.buttonStyle(.btSecondary).disabled(model.busy); Spacer() }
        } else if finder.looking {
            intro("Looking for local servers and model files\u{2026}")
        } else if let report = finder.report {
            if finder.items.isEmpty { none } else { list }
            Text(looked(report)).btBody(10.5, 1.7, theme.muted).padding(.top, 14)
        }
        if let failure = finder.failure { BTInlineNote { Text(failure).btBody(12, 1.8, theme.bad) }.padding(.top, 20) }
    }

    private var none: some View {
        VStack(alignment: .leading, spacing: 0) {
            intro("No running model server or model file was found. Start Ollama, LM Studio or llama.cpp, or download a GGUF model, then look again.")
            actions(items: [], showAdd: false)
        }
    }

    private var list: some View {
        let chosen = finder.items.filter { finder.picked.contains($0.key) }
        return VStack(alignment: .leading, spacing: 0) {
            intro("Tick the ones you want. You can switch between them at any time, and add or remove models later from Available configurations.")
            VStack(spacing: 0) {
                ForEach(finder.items) { item in
                    Button { finder.toggle(item) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            BTCheckMark(on: finder.picked.contains(item.key)).padding(.top, 3)
                                .opacity(item.usable ? 1 : 0.6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                                Text(item.saved ? "Already in your list" : item.detail + (item.ignored ? " \u{00B7} passed over" : ""))
                                    .btBody(11.5, 1.6, theme.muted).padding(.top, 2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!item.usable || model.busy).opacity(item.usable ? 1 : 0.6)
                    .btRule()
                }
            }
            .padding(.bottom, 16)
            actions(items: chosen, showAdd: true)
        }
    }

    private func actions(items: [FoundItem], showAdd: Bool) -> some View {
        let count = items.count
        return HStack(spacing: 18) {
            if showAdd {
                Button(model.busy ? "Adding\u{2026}" : "Add \(count) \(count == 1 ? "model" : "models")") {
                    Task {
                        if await model.addModels(items.map(\.plain)) {
                            await finder.look(model.backend)
                            
                        }
                    }
                }
                .buttonStyle(.btPrimary).disabled(model.busy || count == 0)
                Button("Look again") { Task { await finder.look(model.backend) } }.buttonStyle(.btQuiet).disabled(model.busy)
            } else {
                Button("Look again") { Task { await finder.look(model.backend) } }.buttonStyle(.btSecondary).disabled(model.busy)
            }
            if let onManual { Button("Set one up by hand", action: onManual).buttonStyle(.btQuiet).disabled(model.busy) }
            Spacer(minLength: 0)
        }
    }

    private func looked(_ report: FoundModelsReport) -> String {
        var text = "Looked for servers on local ports \(report.looked.ports.map(String.init).joined(separator: ", "))"
        if !report.looked.folders.isEmpty { text += " and for model files in \(report.looked.folders.joined(separator: ", "))" }
        return text + "."
    }
}
