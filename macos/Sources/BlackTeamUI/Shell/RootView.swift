import SwiftUI
import BlackTeamKit

/// The single main window: sidebar on the left, header and the current page on the right.
public struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    @MainActor public init(model: AppModel) { self.model = model }

    public var body: some View {
        MainShell(model: model)
            .frame(minWidth: 980, minHeight: 640)
            .blackTeamTheme()
            .background(WindowMemory(name: "BlackTeamMainWindow"))
    }
}

/// The shell without the theme or window settings, so the snapshot tests can draw it with a chosen theme.
struct MainShell: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @State private var width: CGFloat = 1280
    @State private var height: CGFloat = 800
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        let metrics = Metrics(windowWidth: width, windowHeight: flat ? 800 : height)
        HStack(alignment: .top, spacing: 0) {
            SidebarView(model: model)
            MainColumn(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(\.btMetrics, metrics)
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width; height = geo.size.height }.onChange(of: geo.size) { width = $0.width; height = $0.height } })
    }
}

struct MainColumn: View {
    @ObservedObject var model: AppModel
    @Environment(\.btMetrics) private var metrics
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        if model.status == nil {
            BootView(model: model)
        } else if model.page == .conversation {
            // Chat / Code fills the window: the conversation scrolls, the header and composer stay.
            VStack(spacing: 0) {
                HeaderView(model: model)
                Banners(model: model)
                ChatPage(model: model)
            }
            .padding(.top, metrics.mainTop).padding(.horizontal, metrics.mainSide).padding(.bottom, metrics.mainBottom)
            .frame(maxWidth: metrics.maxMain, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PageScroll {
                VStack(alignment: .leading, spacing: 0) {
                    HeaderView(model: model)
                    Banners(model: model)
                    pageContent
                    PageFooter(model: model)
                }
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .workspace: WorkspacePage(model: model)
        case .conversation: EmptyView()
        case .memory: MemoryPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}

/// `PRIVATE AI. TOTAL CONTROL.` on the left and the platform on the right, under every page but Chat / Code.
struct PageFooter: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    var body: some View {
        HStack {
            Text("PRIVATE AI. TOTAL CONTROL.").font(BTFont.mono(8)).tracking(1.6).foregroundStyle(theme.faint)
            Spacer(minLength: 0)
            Text("macOS \u{00B7} \(model.status?.hardware.arch ?? "")").font(BTFont.mono(9)).foregroundStyle(theme.faint)
        }
        .padding(.top, 24)
    }
}

/// Errors and notices appear here, in place, never as an alert.
struct Banners: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            if let text = model.startupNotice { BTBanner(kind: .warn, message: text) { model.startupNotice = nil } }
            if let text = model.error { BTBanner(kind: .error, message: text) { model.error = nil } }
            if model.pending != nil, model.page != .conversation {
                HStack(spacing: 12) {
                    Text("Your last message needs to reconnect before you start another conversation.").font(BTFont.body(12)).foregroundStyle(theme.ink)
                    Spacer()
                    Button("Recover last message") { model.navigate(.conversation) }.buttonStyle(.btSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
            }
            if let text = model.notice { BTBanner(kind: .notice, message: text) { model.notice = nil } }
        }
        .padding(.bottom, model.error == nil && model.notice == nil && model.startupNotice == nil && model.pending == nil ? 0 : 16)
    }
}

/// Shown until the first status arrives (App.jsx "Opening your workspace").
struct BootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            BrandWordmark().frame(maxWidth: 360)
            if let failure = model.statusFailure {
                Text("Black Team could not read its settings").font(BTFont.body(18, .semibold)).foregroundStyle(theme.ink)
                Text(failure).font(BTFont.body(12.5)).foregroundStyle(theme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Try again") { Task { await model.refresh() } }.buttonStyle(.btPrimary)
            } else {
                BTSpinner()
                Text("Opening your workspace").font(BTFont.body(18, .semibold)).foregroundStyle(theme.ink)
                Text("Starting Black Team on this Mac.").font(BTFont.body(12.5)).foregroundStyle(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gives the window a name so macOS remembers its size and place between launches.
struct WindowMemory: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(name)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
