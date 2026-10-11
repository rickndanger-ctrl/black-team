import SwiftUI
import BlackTeamKit

/// Setup is not complete: step 1 gets a model working (one click on a brand-new Mac), step 2 shows the agents found here.
struct FirstRunView: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.setupComplete, model.welcome == .agents {
                agentsStep
            } else {
                modelsStep
            }
        }
        .onAppear { model.starter.load(model.backend) }
    }

    // MARK: Step 1

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            BTEyebrow("Step 1 of 2 \u{00B7} Your models").padding(.bottom, 10)
            if model.manualSetup {
                HStack { Button("\u{2190} Back to the easy way") { model.manualSetup = false }.buttonStyle(.btQuiet); Spacer() }.padding(.bottom, 18)
                ModelSetupForm(model: model)
            } else {
                let found = !model.finder.offers.isEmpty
                if found {
                    FoundModelsPanel(model: model, finder: model.finder, heading: "Here is what is on this computer", auto: true,
                                     onManual: { model.manualSetup = true })
                        .disabled(model.starter.phase == .running)
                    StarterPanel(model: model, starter: model.starter)
                } else {
                    StarterPanel(model: model, starter: model.starter)
                    FoundModelsPanel(model: model, finder: model.finder, heading: "Or use what is already on this computer", auto: true,
                                     onManual: { model.manualSetup = true })
                        .disabled(model.starter.phase == .running)
                }
                AgentAppsPanel(model: model).padding(.bottom, 18)
            }
        }
    }

    // MARK: Step 2

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    BTEyebrow("Step 2 of 2 \u{00B7} Your agents")
                    Text("\(model.modelName) is ready.").font(BTFont.body(18, .medium)).tracking(-0.27).foregroundStyle(theme.ink)
                        .btLines(18, 1.5).padding(.top, 6).padding(.bottom, 4)
                    Text("Connect any agents you want from the list just below, then start. You can do this later too.").btBody(12.5, 1.5, theme.muted)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button("Start chatting") { model.welcome = nil; model.startChat(.chat) }.buttonStyle(.btPrimary).disabled(model.busy)
                    Button("Stay here") { model.welcome = nil }.buttonStyle(.btSecondary).disabled(model.busy)
                }
            }
            .padding(.horizontal, 27).padding(.vertical, 23)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line2, lineWidth: 1))
            .padding(.bottom, 20)
            AgentAppsPanel(model: model).padding(.bottom, 18)
        }
    }
}
