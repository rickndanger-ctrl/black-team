import SwiftUI

// The reusable pieces the screens are built from, styled after src/app.css.

// MARK: - Buttons

/// Solid primary, outlined secondary, destructive, and quiet text buttons (app.css `.primary`, `.secondary`, `.danger`, `.text-button`).
struct BTButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, kind: kind)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        @Environment(\.btTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.btControlHeight) private var controlHeight
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            Group {
                if kind == .quiet {
                    configuration.label
                        .font(BTFont.body(12, .medium))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(hover ? theme.ink : theme.ink2)
                        // Always underlined: a quiet button is a link, and has to read as one before the pointer is on it.
                        .underline(true, color: hover ? theme.ink : theme.ink2)
                } else {
                    configuration.label
                        .font(BTFont.body(12.5, .semibold)).tracking(0.125)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 16)
                        .frame(height: controlHeight)
                        .foregroundStyle(ink)
                        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(fill))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(border, lineWidth: 1))
                }
            }
            .labelStyle(BTButtonLabelStyle())
            .opacity(enabled ? (pressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
            .onHover { inside in
                // The pointing hand, as on a web page: one more sign that this can be pressed. It is taken off
                // only if this button put it on.
                let over = inside && enabled
                if over && !hover { NSCursor.pointingHand.push() } else if !over && hover { NSCursor.pop() }
                hover = over
            }
            .animation(.easeOut(duration: 0.15), value: hover)
        }

        private var ink: Color {
            switch kind {
            case .primary: return theme.btnPrimaryInk
            case .danger: return theme.bad
            default: return theme.ink
            }
        }
        private var fill: Color {
            switch kind {
            case .primary: return hover ? theme.btnPrimaryHover : theme.btnPrimaryBg
            case .danger: return theme.badBg
            default: return hover ? theme.surface2 : .clear
            }
        }
        private var border: Color {
            switch kind {
            case .primary: return theme.btnPrimaryLine
            case .danger: return theme.badLine
            default: return hover ? theme.muted : theme.line2
            }
        }
    }
}

private struct BTButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon; configuration.title }
    }
}

/// A button label with one of the app's icons, drawn 15 points wide as `:is(.primary, .secondary) svg` is in the CSS.
struct BTIconLabel: View {
    let title: String
    let icon: BTIcon
    var trailing = false
    init(_ title: String, _ icon: BTIcon, trailing: Bool = false) { self.title = title; self.icon = icon; self.trailing = trailing }
    var body: some View {
        HStack(spacing: trailing ? 6 : 8) {
            if !trailing { IconView(icon, size: 15) }
            Text(title)
            if trailing { IconView(icon, size: 15) }
        }
    }
}

extension ButtonStyle where Self == BTButtonStyle {
    static var btPrimary: BTButtonStyle { BTButtonStyle(kind: .primary) }
    static var btSecondary: BTButtonStyle { BTButtonStyle(kind: .secondary) }
    static var btDanger: BTButtonStyle { BTButtonStyle(kind: .danger) }
    static var btQuiet: BTButtonStyle { BTButtonStyle(kind: .quiet) }
}

// MARK: - Text

extension Text {
    /// Small mono caption in capitals, as `.eyebrow` and `.nav-label` in the CSS.
    func btEyebrow(_ theme: Theme, size: CGFloat = 10) -> some View {
        self.font(BTFont.mono(size)).tracking(size * 0.16).foregroundStyle(theme.faint).lineLimit(1)
            .frame(height: size * 1.5, alignment: .leading)
    }
}

// MARK: - Panel and section header

/// A graphite card: surface fill, hairline border, soft shadow and a faint top highlight (`.model-list`).
struct BTPanel<Content: View>: View {
    var padding: CGFloat = 28
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    var body: some View {
        content
            .padding(padding + 1)   // the 1 point border sits outside the padding, as in CSS
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
            .overlay(alignment: .top) {
                LinearGradient(colors: [.clear, theme.edge, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1).padding(.horizontal, Theme.radiusLg)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
            .btShadow(theme.shadow)
    }
}

/// An eyebrow label, a title, and an optional intro line (`.panel-heading`, `.section-intro`):
/// 10 point eyebrow, an 18 point heading 8 points under it, and an intro 14 points under that.
struct BTSectionHeader: View {
    var eyebrow: String?
    let title: String
    var intro: String?
    var introWidth: CGFloat = 680
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow { Text(eyebrow.uppercased()).btEyebrow(theme) }
            Text(title).font(BTFont.body(18, .semibold)).tracking(-0.27).foregroundStyle(theme.ink)
                .btLines(18, 1.5)
                .padding(.top, eyebrow == nil ? 0 : 8)
            if let intro {
                Text(intro).btBody(12.5, 1.8, theme.muted)
                    .frame(maxWidth: introWidth, alignment: .leading)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status pill

/// A small mono label with a restrained status colour (`.status-pill`, `.in-use`).
struct BTStatusPill: View {
    enum Kind { case neutral, ok, warn, bad }
    let text: String
    var kind: Kind = .neutral
    var showsDot = false
    var compact = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if showsDot { Circle().fill(kind == .neutral ? theme.muted : colors.ink).frame(width: 6, height: 6).padding(.trailing, 8) }
            Text(text).font(BTFont.mono(10)).tracking(0.4).lineLimit(1).fixedSize()
        }
        .foregroundStyle(colors.ink)
        .padding(.horizontal, compact ? 10 : 12)
        .frame(height: compact ? 22 : 30)
        .background(Capsule().fill(colors.bg))
        .overlay(Capsule().stroke(colors.line, lineWidth: 1))
    }

    private var colors: (ink: Color, bg: Color, line: Color) {
        switch kind {
        case .neutral: return (theme.ink2, .clear, theme.line2)
        case .ok: return (theme.ok, theme.okBg, theme.okLine)
        case .warn: return (theme.warn, theme.warnBg, theme.warnLine)
        case .bad: return (theme.bad, theme.badBg, theme.badLine)
        }
    }
}

// MARK: - Text field

/// Dark inset field with a hairline border that turns to the accent on focus (`.form-field input`: 38 points high, 12 padding).
struct BTFieldChrome: ViewModifier {
    var focused = false
    var mono = false
    var height: CGFloat = Theme.control
    var radius: CGFloat = Theme.radius
    var size: CGFloat = 13
    var padding: CGFloat = 12
    @Environment(\.btTheme) private var theme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? BTFont.mono(size - 1) : BTFont.body(size))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? theme.accent : theme.line2, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? theme.ring : .clear, lineWidth: 3).padding(-1.5))
    }
}

extension View {
    func btFieldChrome(focused: Bool = false, mono: Bool = false, height: CGFloat = Theme.control, radius: CGFloat = Theme.radius, size: CGFloat = 13, padding: CGFloat = 12) -> some View {
        modifier(BTFieldChrome(focused: focused, mono: mono, height: height, radius: radius, size: size, padding: padding))
    }
}

struct BTTextField: View {
    let title: String
    @Binding var text: String
    var mono = false
    var compactHeight: CGFloat?
    var fontSize: CGFloat?
    @FocusState private var focused: Bool
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btTheme) private var theme
    init(_ title: String, text: Binding<String>, mono: Bool = false, compactHeight: CGFloat? = nil, size: CGFloat? = nil) {
        self.title = title; self._text = text; self.mono = mono; self.compactHeight = compactHeight; self.fontSize = size
    }
    var body: some View {
        let size: CGFloat = fontSize ?? (compactHeight == nil ? 13 : 12)
        Group {
            if flat {
                // An image render cannot draw the AppKit text field, so it gets the same look drawn by SwiftUI.
                HStack { Text(text.isEmpty ? title : text).font(mono ? BTFont.mono(size - 1) : BTFont.body(size)).foregroundStyle(text.isEmpty ? theme.faint : theme.ink).lineLimit(1); Spacer(minLength: 0) }
                    .btFieldChrome(focused: false, mono: mono, height: compactHeight ?? Theme.control, radius: compactHeight == nil ? Theme.radius : 5, size: size, padding: compactHeight == nil ? 12 : 10)
            } else {
                TextField(title, text: $text)
                    .focused($focused)
                    .btFieldChrome(focused: focused, mono: mono, height: compactHeight ?? Theme.control, radius: compactHeight == nil ? Theme.radius : 5,
                                   size: size, padding: compactHeight == nil ? 12 : 10)
            }
        }
    }
}

// MARK: - Segmented switch

/// A segmented control in the Linux style (`.mode-toggle`, `.theme-picker`).
struct BTSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(BTFont.body(12, .medium))
                        .foregroundStyle(selected ? theme.ink : theme.muted)
                        .padding(.horizontal, 15)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.surface2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? theme.line2 : .clear, lineWidth: 1))
                        .btShadow(selected ? theme.shadow : .none)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)   // 3 points of padding and the 1 point border
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

enum AppMode: String, CaseIterable, Identifiable {
    case chat, code
    var id: String { rawValue }
    var label: String { self == .chat ? "Chat" : "Code" }
}

/// The Chat / Code switch.
struct BTModeSwitch: View {
    @Binding var mode: AppMode
    var body: some View {
        BTSegmented(options: AppMode.allCases.map { ($0, $0.label) }, selection: $mode)
    }
}

// MARK: - Gauge

/// A thin progress or usage bar (`.meter`): a 2 point line with an accent fill.
struct BTGauge: View {
    let value: Double   // 0...1
    @Environment(\.btTheme) private var theme
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.line)
                Rectangle().fill(theme.accent).frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 1), value: value)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}

// MARK: - Empty state

struct BTEmptyState<Action: View>: View {
    let icon: BTIcon
    let title: String
    var message: String?
    @ViewBuilder var action: Action
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            IconView(icon, size: 28).foregroundStyle(theme.faint)
            Text(title).font(BTFont.body(15, .semibold)).foregroundStyle(theme.ink)
            if let message {
                Text(message).font(BTFont.body(12.5)).lineSpacing(4).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            action
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension BTEmptyState where Action == EmptyView {
    init(icon: BTIcon, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Banner

/// An inline notice or error (`.notice`, `.notice.error`).
struct BTBanner: View {
    enum Kind { case notice, ok, warn, error }
    let kind: Kind
    let message: String
    var onDismiss: (() -> Void)?
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(message).btBody(12, 1.6, colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let onDismiss {
                Button(action: onDismiss) {
                    Text("\u{00D7}").font(BTFont.body(16)).foregroundStyle(colors.ink).opacity(0.7).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(colors.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(colors.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var colors: (ink: Color, bg: Color, line: Color) {
        switch kind {
        case .notice: return (theme.ink, theme.surface2, theme.line2)
        case .ok: return (theme.ok, theme.okBg, theme.okLine)
        case .warn: return (theme.warn, theme.warnBg, theme.warnLine)
        case .error: return (theme.bad, theme.badBg, theme.badLine)
        }
    }
}
