import SwiftUI
import AppKit
import BlackTeamKit

/// The "Black Team" window: the Command center.
public struct CommandRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @MainActor public init(model: AppModel) { self.model = model }

    public var body: some View {
        CommandShell(model: model)
            .frame(minWidth: 980, minHeight: 640)
            .blackTeamTheme()
            .background(WindowMemory(name: "BlackTeamMainWindow"))
            .onAppear { link(model, openWindow) }
    }
}

/// The "Black Team Camp" window: Chat and Code, Memory, Plugins, DSH sessions, Servers & access.
public struct CampRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @MainActor public init(model: AppModel) { self.model = model }

    public var body: some View {
        CampShell(model: model)
            .frame(minWidth: 980, minHeight: 640)
            .blackTeamTheme()
            .background(WindowMemory(name: "BlackTeamCampWindow"))
            .background(LaunchGuard())
            .onAppear { link(model, openWindow) }
    }
}

/// Each window can bring the other one forward; `Window` scenes open once and are focused when asked again.
@MainActor private func link(_ model: AppModel, _ openWindow: OpenWindowAction) {
    model.openCamp = { openWindow(id: "camp"); NSApp.activate(ignoringOtherApps: true) }
    model.openCommand = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}

/// The shells without the theme or window settings, so the snapshot tests can draw them with a chosen theme.
struct CommandShell: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WindowShell(sidebar: { CommandSidebar(model: model) }, content: { CommandMain(model: model) })
    }
}

struct CampShell: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WindowShell(sidebar: { CampSidebar(model: model) }, content: { CampMain(model: model) })
    }
}

/// Shown until the first status arrives.
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
                Text("Opening Black Team").font(BTFont.body(20, .medium)).foregroundStyle(theme.ink)
                Text("Checking model servers and harnesses\u{2026}").font(BTFont.body(12.5)).foregroundStyle(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Camp opens when asked for, not at launch. Some macOS releases open every `Window` scene at start, so a Camp window
/// that appears in the first moments of the app, while the Command center is up, is put away again.
struct LaunchGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if Date().timeIntervalSince(AppModel.launched) < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak view] in
                guard let window = view?.window else { return }
                if NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }) { window.close() }
            }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
