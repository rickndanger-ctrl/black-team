import SwiftUI
import BlackTeamKit

/// "Available configurations": every saved model, the ones found on this Mac, and the form that adds or changes one,
/// as a sheet over the Command center in the same panel and heading patterns.
struct ConfigSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Available configurations").font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.buttonStyle(.btSecondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.error { BTBanner(kind: .error, message: error) { model.error = nil }.padding(.bottom, 16) }
                    ModelListPanel(model: model)
                    FoundModelsPanel(model: model, finder: model.finder)
                    ModelSetupForm(model: model, settings: true)
                }
                .padding(28)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 720)
        .blackTeamTheme()
        .background(theme.bg)
    }
}

/// Every model set up, with the one in use marked and a way to remove the others.
struct ModelListPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        let models = model.status?.models ?? []
        let working = model.status?.runtime.busy == true
        if !models.isEmpty {
            BTPanel {
                VStack(alignment: .leading, spacing: 0) {
                    BTSectionHeader(eyebrow: "Your models", title: "Switch between your models",
                                    intro: "Every model you set up is kept here. Choosing one stops the model in use; your next message starts the new one.")
                        .padding(.bottom, 22)
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
            }
            .padding(.bottom, 20)
        }
    }
}

/// No saved model yet: the starter download and the models found on this Mac, as section 01 of the page.
struct FirstModelSetup: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let found = !model.finder.offers.isEmpty
            if found {
                FoundModelsPanel(model: model, finder: model.finder, heading: "Here is what is on this computer", auto: true, onManual: { model.showConfig = true })
                    .disabled(model.starter.phase == .running)
                StarterPanel(model: model, starter: model.starter)
            } else {
                StarterPanel(model: model, starter: model.starter)
                FoundModelsPanel(model: model, finder: model.finder, heading: "Or use what is already on this computer", auto: true, onManual: { model.showConfig = true })
                    .disabled(model.starter.phase == .running)
            }
        }
        .onAppear { model.starter.load(model.backend) }
    }
}
