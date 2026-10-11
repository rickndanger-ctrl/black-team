import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BlackTeamKit

// Small pieces the screens share, built on the Design tokens. Anything AppKit draws (menus, text
// views) is replaced by its label when rendering to an image, so the snapshots stay readable.

/// The main column of a page: header, page and footer, scrolling together as the browser page does
/// (`.app-main`: padding 40 and 4vw, content up to 1570 points wide). Rendering to an image lays it out in full instead.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btMetrics) private var metrics

    var body: some View {
        if flat { inner } else { ScrollView { inner } }
    }

    private var inner: some View {
        content
            .padding(.top, metrics.mainTop).padding(.horizontal, metrics.mainSide).padding(.bottom, metrics.mainBottom)
            .frame(maxWidth: metrics.maxMain, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BTEyebrow: View {
    let text: String
    @Environment(\.btTheme) private var theme
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).btEyebrow(theme) }
}

/// A label above a control, with an optional hint under it (`.form-field`).
struct BTLabeled<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink2)
            content
            if let hint { Text(hint).font(BTFont.body(11)).foregroundStyle(theme.muted) }
        }
    }
}

struct BTSecureField: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btTheme) private var theme
    var body: some View {
        if flat {
            HStack { Text(text.isEmpty ? title : String(repeating: "\u{2022}", count: text.count)).font(BTFont.body(13)).foregroundStyle(text.isEmpty ? theme.faint : theme.ink); Spacer(minLength: 0) }.btFieldChrome()
        } else {
            SecureField(title, text: $text).focused($focused).btFieldChrome(focused: focused)
        }
    }
}

struct BTNumberField: View {
    @Binding var value: Int
    @FocusState private var focused: Bool
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btTheme) private var theme
    var body: some View {
        if flat {
            HStack { Text("\(value)").font(BTFont.body(13)).foregroundStyle(theme.ink); Spacer(minLength: 0) }.btFieldChrome()
        } else {
            TextField("", value: $value, format: .number.grouping(.never)).focused($focused).btFieldChrome(focused: focused)
        }
    }
}

struct BTCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.btTheme) private var theme
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).font(BTFont.body(12.5)).foregroundStyle(theme.ink) }
            .toggleStyle(.checkbox)
    }
}

/// A menu styled like a field. Its label is drawn alone when rendering to an image.
struct BTSelect<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var placeholder = "Choose"
    var minWidth: CGFloat = 0
    /// 34 points and 12 point text for the Thinking menu, 38 and 13 for a form field.
    var height: CGFloat = 34
    var fontSize: CGFloat = 12
    var fill = false
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.isEnabled) private var enabled

    private var current: String { options.first { $0.value == selection }?.label ?? placeholder }

    /// A browser sizes a menu to its widest option, so the closed control is as wide as the longest label.
    private var widest: CGFloat {
        Fonts.register()
        let font = NSFont(name: "AdwaitaSans-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let labels = options.map(\.label) + [current]
        return labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    var body: some View {
        Group {
            if flat { chip.fixedSize(horizontal: !fill, vertical: true) } else {
                Menu {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Button { selection = option.value } label: {
                            if option.value == selection { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        }
                    }
                } label: { chip }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: !fill, vertical: true)
            }
        }
        .opacity(enabled ? 1 : 0.5)
    }

    private var chip: some View {
        HStack(spacing: 0) {
            Text(current).font(BTFont.body(fontSize)).foregroundStyle(theme.ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, fontSize > 12 ? 12 : 12).padding(.trailing, fontSize > 12 ? 32 : 30)
        .frame(maxWidth: fill ? .infinity : nil)
        .frame(minWidth: max(minWidth, fill ? 0 : ceil(widest) + 12 + (fontSize > 12 ? 32 : 30)), minHeight: height, maxHeight: height)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
        .overlay(alignment: .trailing) {
            // Chromium's select arrow: a thin chevron, 10 points from the edge.
            Path { path in path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 4, y: 4)); path.addLine(to: CGPoint(x: 8, y: 0)) }
                .stroke(theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 8, height: 4).padding(.trailing, 12)
        }
        .contentShape(Rectangle())
    }
}

/// `<details class="context-inspector">`: a hairline above, a mono summary line (title left, detail and "+" right) and the body under it.
struct BTDisclosure<Content: View>: View {
    let title: String
    var detail: String?
    @State private var open: Bool
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    init(_ title: String, detail: String? = nil, open: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self._open = State(initialValue: open); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 14) {
                    Text(title).font(BTFont.mono(10)).foregroundStyle(theme.muted)
                    Spacer(minLength: 0)
                    if let detail { Text(detail).font(BTFont.mono(10)).foregroundStyle(theme.muted) }
                    Text(open ? "\u{2212}" : "+").font(BTFont.mono(10)).foregroundStyle(theme.ink2)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { VStack(alignment: .leading, spacing: 0) { content }.padding(.top, 14) }
        }
        .padding(.top, 10)
        .btRule()
    }
}

/// A plain `<details>` with the browser's own disclosure triangle (Advanced connection and performance).
struct BTPlainDetails<Content: View>: View {
    let title: String
    @State private var open = false
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Text("\u{25B6}").font(.system(size: 8)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Text(title).btBody(12, 1.7, theme.ink2)
                }
                .foregroundStyle(theme.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { content }
        }
    }
}

/// A download or usage bar thick enough to read (the Design `BTGauge` is a 2 point hairline).
struct BTProgressBar: View {
    let value: Double?   // nil: not known yet
    var height: CGFloat = 8
    @Environment(\.btTheme) private var theme
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line)
                if let value {
                    Capsule().fill(theme.accent).frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, value)))))
                } else {
                    Capsule().fill(theme.accent.opacity(0.35)).frame(width: geo.size.width * 0.3)
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "in progress")
    }
}

struct BTSpinner: View {
    @Environment(\.btTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.7).stroke(theme.muted, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 13, height: 13)
        .accessibilityLabel("Working")
    }
}

/// A file path or note in the mono face, truncated in the middle.
struct BTPathText: View {
    let text: String
    @Environment(\.btTheme) private var theme
    var body: some View {
        Text(text).font(BTFont.mono(11)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
}

/// A row of a list inside a panel: text on the left, actions on the right.
struct BTListRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) { leading }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) { trailing }
        }
    }
}

struct BTDivider: View {
    @Environment(\.btTheme) private var theme
    var body: some View { Rectangle().fill(theme.line).frame(height: 1) }
}

/// Opens a file or folder chooser described by the backend (`pickerRequest`).
enum FileChooser {
    @MainActor static func choose(_ request: PickerRequest) -> String? {
        let panel = NSOpenPanel()
        panel.title = request.title
        panel.message = request.title
        panel.canChooseFiles = !request.directory
        panel.canChooseDirectories = request.directory
        panel.canCreateDirectories = request.directory
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if !request.extensions.isEmpty {
            panel.allowedContentTypes = request.extensions.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

