import SwiftUI
import AppKit
import BlackTeamKit

// Pieces both windows share, written from the daily app's app.css.

/// `.switch`: 38 by 22, a 14 point knob; the accent fills it when on.
struct BTSwitch: View {
    let isOn: Bool
    let label: String
    let action: () -> Void
    @Environment(\.btTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Circle().fill(isOn ? theme.onAccent : theme.muted).frame(width: 14, height: 14)
                .frame(width: 30, alignment: isOn ? .trailing : .leading)
                .padding(3)
                .frame(width: 38, height: 22)
                .background(RoundedRectangle(cornerRadius: 11).fill(isOn ? theme.accent : theme.field))
                .overlay(RoundedRectangle(cornerRadius: 11).inset(by: 0.5).stroke(isOn ? theme.accent : theme.line2, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// `.online`: a 30 point pill with a status dot, in the header of the Command center and under the Camp title.
struct DailyPill: View {
    let text: String
    let live: Bool
    var ink: Color?
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(live ? theme.ok : theme.muted).frame(width: 6, height: 6).padding(.trailing, 8)
            Text(text).font(BTFont.mono(10)).tracking(0.4).lineLimit(1).fixedSize()
        }
        .foregroundStyle(ink ?? theme.ink2)
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(Capsule().stroke(theme.line2, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// `.eyebrow` plus the page title and its line, shared by every page of both windows.
struct DailyTitle: View {
    let eyebrow: String
    let title: String
    let line: String
    @Environment(\.btTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow).font(BTFont.mono(10)).tracking(1.6).foregroundStyle(theme.faint).frame(height: 15, alignment: .leading)
            Text(title).font(BTFont.body(26, .semibold)).tracking(-1.04).foregroundStyle(theme.ink).btLines(26, 1.2).padding(.top, 9).padding(.bottom, 9)
            Text(line).btBody(12.5, 1.6, theme.muted)
        }
    }
}

/// The Covert / Light / Ghost picker (`.theme-picker`). Each button is named for what it says.
/// "Bold" / "Plain": whether headings and labels are drawn in the bold face.
struct TextWeightPicker: View {
    @AppStorage(TextWeightSetting.storageKey) private var plain = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { option in
                let selected = plain == option
                Button { plain = option } label: {
                    Text(option ? "PLAIN TEXT" : "BOLD TEXT").font(BTFont.mono(9)).tracking(1.08)
                        .foregroundStyle(selected ? theme.ink : theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.surface2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(selected ? theme.line2 : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option ? "Plain text" : "Bold text")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct ThemePicker: View {
    @Binding var stored: String
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach([ThemeSetting.covert, .light, .ghost]) { option in
                let selected = theme.id.rawValue == option.rawValue
                Button { stored = option.rawValue } label: {
                    Text(option.label).font(BTFont.mono(9)).tracking(1.08)
                        .foregroundStyle(selected ? theme.ink : theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.surface2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(selected ? theme.line2 : .clear, lineWidth: 1))
                        .btShadow(selected ? theme.shadow : .none)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).inset(by: 0.5).stroke(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// One row of a sidebar's navigation (`.nav`, `.companion-nav nav button`): 38 high, the accent bar when selected.
struct NavRow: View {
    let title: String
    var icon: BTIcon?
    var arrow = false
    let selected: Bool
    let action: () -> Void
    @Environment(\.btTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                if let icon { IconView(icon, size: 16) }
                Text(title).font(BTFont.body(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if arrow { IconView(.arrow, size: 14).foregroundStyle(theme.faint) }
            }
            .foregroundStyle(selected ? theme.ink : theme.muted)
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 2).padding(.vertical, 11) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The two windows' frame: a sidebar, a main column, and the metrics of the current width.
struct WindowShell<Sidebar: View, Content: View>: View {
    let sidebar: Sidebar
    let content: Content
    @State private var width: CGFloat = 1280
    @State private var height: CGFloat = 800
    @Environment(\.btFlatLayout) private var flat

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) { self.sidebar = sidebar(); self.content = content() }

    var body: some View {
        let metrics = Metrics(windowWidth: width, windowHeight: flat ? height : height)
        HStack(alignment: .top, spacing: 0) {
            sidebar
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(\.btMetrics, metrics)
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width; height = geo.size.height }.onChange(of: geo.size) { width = $0.width; height = $0.height } })
    }
}

/// Errors and notices appear here, in place, never as an alert (`.notice`, `.error`).
struct Banners: View {
    @ObservedObject var model: AppModel
    var camp = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            if let text = model.startupNotice { BTBanner(kind: .warn, message: text) { model.startupNotice = nil } }
            if let text = model.error { BTBanner(kind: .error, message: text) { model.error = nil } }
            if model.pending != nil, !camp {
                HStack(spacing: 12) {
                    Text("Your last message needs to reconnect before you start another conversation.").font(BTFont.body(12)).foregroundStyle(theme.ink)
                    Spacer()
                    Button("Recover last message") { model.campPage = .chat; model.openCamp() }.buttonStyle(.btSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
            }
            if let text = model.notice { BTBanner(kind: .notice, message: text) { model.notice = nil } }
        }
        .padding(.bottom, model.error == nil && model.notice == nil && model.startupNotice == nil && (camp || model.pending == nil) ? 0 : 16)
    }
}

/// Gives a window a name so macOS remembers its size and place between launches.
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
