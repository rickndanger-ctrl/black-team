import SwiftUI
import BlackTeamKit

/// The "Black Team" window's sidebar (`.sidebar`): logo, Overview, Diagnostics, Base Camp, the theme switch and the footer.
struct CommandSidebar: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics
    @AppStorage(ThemeSetting.storageKey) private var storedTheme = ThemeSetting.system.rawValue

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BrandWordmark().padding(.bottom, 30)
                Text("WORKSPACE").font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint)
                    .frame(height: 13.5).padding(.horizontal, 12).padding(.bottom, 10)
                VStack(spacing: 2) {
                    NavRow(title: "Overview", icon: .play, selected: model.commandPage == .overview) { model.showCommand(.overview) }
                    NavRow(title: "Diagnostics", icon: .activity, selected: model.commandPage == .diagnostics) { model.showCommand(.diagnostics) }
                    NavRow(title: "Base Camp", icon: .chat, arrow: true, selected: false) { model.openCamp() }
                }
                Spacer(minLength: 0)
                ThemePicker(stored: $storedTheme)
                footer
            }
            .padding(.top, metrics.sidebarTop).padding(.horizontal, metrics.sidebarSide).padding(.bottom, 20)
            .frame(width: metrics.sidebarWidth - 1, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(theme.line).frame(width: 1)
        }
        .frame(width: metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(theme.sidebar.ignoresSafeArea())
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(theme.ok).frame(width: 6, height: 6)
                Text("LOCAL WORKSPACE").font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.ink2)
            }
            .frame(height: 14.4)
            Text("Connected to this computer.").btBody(11, 1.5, theme.muted).padding(.vertical, 6)
            Text("Private \u{00B7} Local-first").font(BTFont.mono(9)).tracking(0.36).foregroundStyle(theme.faint).frame(height: 14.4)
        }
        .padding(.top, 14).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .btRule()
        .padding(.top, 14)
    }
}
