import SwiftUI

// Every colour, radius, spacing and shadow token from src/theme.css, for the three themes
// the Linux app defines: Covert (matte black), Light (cool paper) and Ghost (lights off).

extension Color {
    /// "#rrggbb" or "#rrggbbaa", as written in the CSS.
    init(css: String) {
        var hex = css.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The person's appearance choice. Stored in `@AppStorage(ThemeSetting.storageKey)`.
public enum ThemeSetting: String, CaseIterable, Identifiable {
    case system, covert, light, ghost
    public var id: String { rawValue }
    public static let storageKey = "black-team-theme"
    public var label: String {
        switch self {
        case .system: return "Match system"
        case .covert: return "Covert"
        case .light: return "Light"
        case .ghost: return "Ghost"
        }
    }
}

struct ShadowSpec {
    struct Layer { var color: Color; var radius: CGFloat; var y: CGFloat }
    var layers: [Layer]
    static let none = ShadowSpec(layers: [])
}

struct HazeLayer {
    var cx: CGFloat, cy: CGFloat   // centre as a fraction of the window
    var rx: CGFloat, ry: CGFloat   // radii in points
    var color: Color
    var stop: CGFloat              // where the colour has faded to nothing, as a fraction of the radius
}

struct Theme {
    enum ID: String { case covert, light, ghost }
    var id: ID
    var isDark: Bool

    // Surfaces
    var bg: Color, sidebar: Color, surface: Color, surface2: Color, field: Color, edge: Color
    // Type
    var ink: Color, ink2: Color, muted: Color, faint: Color
    // Lines
    var line: Color, line2: Color
    // Accent and buttons
    var accent: Color, accent2: Color, onAccent: Color, ring: Color
    var btnPrimaryBg: Color, btnPrimaryInk: Color, btnPrimaryLine: Color, btnPrimaryHover: Color
    // Status
    var ok: Color, okBg: Color, okLine: Color
    var warn: Color, warnBg: Color, warnLine: Color
    var bad: Color, badBg: Color, badLine: Color
    // Depth
    var shadow: ShadowSpec, shadowLg: ShadowSpec
    // Brand artwork
    var brandBg: Color, brandCaption: Color, mist1: Color, mist2: Color, mist3: Color
    // Background haze
    var hazeLayers: [HazeLayer]
    var hazeBase: [Gradient.Stop]

    // Shape and spacing (the CSS has one radius pair and a 38px control height).
    static let radius: CGFloat = 6
    static let radiusLg: CGFloat = 10
    static let control: CGFloat = 38
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    static func resolve(_ setting: ThemeSetting, system: ColorScheme) -> Theme {
        switch setting {
        case .system: return system == .light ? .light : .covert
        case .covert: return .covert
        case .light: return .light
        case .ghost: return .ghost
        }
    }

    static let covert: Theme = {
        let accent = Color(css: "#d8dee6")
        return Theme(
            id: .covert, isDark: true,
            bg: Color(css: "#07090c"), sidebar: Color(css: "#090b0f"), surface: Color(css: "#10141a"),
            surface2: Color(css: "#161b22"), field: Color(css: "#0a0d11"), edge: Color(css: "#ffffff08"),
            ink: Color(css: "#e9edf2"), ink2: Color(css: "#c2c9d2"), muted: Color(css: "#8b95a2"), faint: Color(css: "#626c78"),
            line: Color(css: "#232931"), line2: Color(css: "#353d48"),
            accent: accent, accent2: Color(css: "#f2f5f8"), onAccent: Color(css: "#0b0e12"), ring: Color(css: "#d8dee628"),
            btnPrimaryBg: accent, btnPrimaryInk: Color(css: "#0b0e12"), btnPrimaryLine: accent, btnPrimaryHover: Color(css: "#f2f5f8"),
            ok: Color(css: "#a3c7b2"), okBg: Color(css: "#111f19"), okLine: Color(css: "#2a4236"),
            warn: Color(css: "#d9c18d"), warnBg: Color(css: "#211d14"), warnLine: Color(css: "#51442a"),
            bad: Color(css: "#e5a8a8"), badBg: Color(css: "#281a1d"), badLine: Color(css: "#5c353b"),
            shadow: ShadowSpec(layers: [.init(color: Color(css: "#00000045"), radius: 15, y: 10), .init(color: Color(css: "#00000030"), radius: 1, y: 1)]),
            shadowLg: ShadowSpec(layers: [.init(color: Color(css: "#00000070"), radius: 35, y: 24)]),
            brandBg: .black, brandCaption: Color(css: "#b3b9c3"),
            mist1: Color(css: "#8a94a366"), mist2: Color(css: "#5c667455"), mist3: Color(css: "#2b313a99"),
            hazeLayers: [
                HazeLayer(cx: 0.18, cy: -0.06, rx: 1400, ry: 800, color: Color(css: "#434c5a"), stop: 0.58),
                HazeLayer(cx: 0.5, cy: 0, rx: 1800, ry: 700, color: Color(css: "#1b212a"), stop: 0.70),
                HazeLayer(cx: 1.05, cy: 0.72, rx: 900, ry: 600, color: Color(css: "#182028"), stop: 0.62),
            ],
            hazeBase: [.init(color: Color(css: "#0b0e12"), location: 0), .init(color: Color(css: "#07090c"), location: 0.55), .init(color: Color(css: "#040506"), location: 1)])
    }()

    static let light: Theme = {
        var t = covert
        t.id = .light; t.isDark = false
        t.bg = Color(css: "#eef0f3"); t.sidebar = Color(css: "#f7f8fa"); t.surface = Color(css: "#ffffff")
        t.surface2 = Color(css: "#f3f5f7"); t.field = Color(css: "#f7f8fa"); t.edge = Color(css: "#ffffff")
        t.ink = Color(css: "#14171c"); t.ink2 = Color(css: "#363c45"); t.muted = Color(css: "#646d78"); t.faint = Color(css: "#8a929d")
        t.line = Color(css: "#dfe3e8"); t.line2 = Color(css: "#c5ccd4")
        t.accent = Color(css: "#1a1e24"); t.accent2 = Color(css: "#2c323b"); t.onAccent = Color(css: "#f5f7fa"); t.ring = Color(css: "#1a1e2422")
        t.btnPrimaryBg = t.accent; t.btnPrimaryInk = t.onAccent; t.btnPrimaryLine = t.accent; t.btnPrimaryHover = t.accent2
        t.ok = Color(css: "#2f6b4a"); t.okBg = Color(css: "#e9f3ed"); t.okLine = Color(css: "#bcd8c7")
        t.warn = Color(css: "#7a5a14"); t.warnBg = Color(css: "#f9f2dd"); t.warnLine = Color(css: "#e4d3a4")
        t.bad = Color(css: "#9a3843"); t.badBg = Color(css: "#f9e9eb"); t.badLine = Color(css: "#e5bfc4")
        t.shadow = ShadowSpec(layers: [.init(color: Color(css: "#1a1e2412"), radius: 12, y: 8), .init(color: Color(css: "#1a1e240f"), radius: 1, y: 1)])
        t.shadowLg = ShadowSpec(layers: [.init(color: Color(css: "#1a1e2428"), radius: 30, y: 24)])
        t.brandCaption = Color(css: "#5a6370")
        t.mist1 = Color(css: "#3a414c55"); t.mist2 = Color(css: "#5a626e44"); t.mist3 = Color(css: "#15181d66")
        t.hazeLayers = [
            HazeLayer(cx: 0.10, cy: -0.10, rx: 1100, ry: 650, color: Color(css: "#ffffff"), stop: 0.60),
            HazeLayer(cx: 1.0, cy: 0.80, rx: 900, ry: 600, color: Color(css: "#dbe0e6"), stop: 0.60),
        ]
        t.hazeBase = [.init(color: Color(css: "#f4f5f7"), location: 0), .init(color: Color(css: "#edeff2"), location: 0.6), .init(color: Color(css: "#e7eaee"), location: 1)]
        return t
    }()

    static let ghost: Theme = {
        var t = covert
        t.id = .ghost; t.isDark = true
        t.bg = .black; t.sidebar = .black; t.surface = .black; t.surface2 = Color(css: "#0b0c0e"); t.field = .black; t.edge = .clear
        t.ink = Color(css: "#d6d9dd"); t.ink2 = Color(css: "#a4a9b0"); t.muted = Color(css: "#6e737b"); t.faint = Color(css: "#4e535a")
        t.line = Color(css: "#1c1f23"); t.line2 = Color(css: "#30343a")
        t.accent = Color(css: "#e4e7eb"); t.accent2 = .white; t.onAccent = .black; t.ring = Color(css: "#e4e7eb22")
        t.btnPrimaryBg = .clear; t.btnPrimaryInk = t.accent; t.btnPrimaryLine = Color(css: "#8e949c"); t.btnPrimaryHover = Color(css: "#ffffff12")
        t.ok = Color(css: "#8fb8a0"); t.okBg = .clear; t.okLine = Color(css: "#2b4637")
        t.warn = Color(css: "#c9b27f"); t.warnBg = .clear; t.warnLine = Color(css: "#4a4027")
        t.bad = Color(css: "#d49a9a"); t.badBg = .clear; t.badLine = Color(css: "#55343a")
        t.shadow = .none
        t.shadowLg = ShadowSpec(layers: [])
        t.mist1 = Color(css: "#3a3f4733"); t.mist2 = Color(css: "#2a2e3433"); t.mist3 = .clear
        t.hazeLayers = [HazeLayer(cx: 0.15, cy: -0.10, rx: 900, ry: 500, color: Color(css: "#0c0e11"), stop: 0.60)]
        t.hazeBase = [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        return t
    }()
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.covert }
private struct FlatLayoutKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var btTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    /// True when rendering to an image: scroll views draw nothing there, so views lay out in full instead.
    var btFlatLayout: Bool {
        get { self[FlatLayoutKey.self] }
        set { self[FlatLayoutKey.self] = newValue }
    }
}

/// The window background: base colour plus the soft haze of light.
struct ThemeBackground: View {
    let theme: Theme
    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.bg
                LinearGradient(stops: theme.hazeBase, startPoint: UnitPoint(x: 0.38, y: 0), endPoint: UnitPoint(x: 0.62, y: 1))
                Canvas { ctx, size in
                    for layer in theme.hazeLayers.reversed() {
                        var c = ctx
                        c.translateBy(x: layer.cx * size.width, y: layer.cy * size.height)
                        c.scaleBy(x: 1, y: layer.ry / layer.rx)
                        let radius = layer.rx * layer.stop
                        let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
                        c.fill(Path(ellipseIn: rect),
                               with: .radialGradient(Gradient(colors: [layer.color, layer.color.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: radius))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
    }
}

private struct Themed: ViewModifier {
    @AppStorage(ThemeSetting.storageKey) private var stored = ThemeSetting.system.rawValue
    @Environment(\.colorScheme) private var scheme
    let forced: ThemeSetting?

    func body(content: Content) -> some View {
        let setting = forced ?? ThemeSetting(rawValue: stored) ?? .system
        let theme = Theme.resolve(setting, system: scheme)
        content
            .environment(\.btTheme, theme)
            .font(BTFont.body())
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .background(ThemeBackground(theme: theme))
            // Following the system must not feed back into the scheme it follows.
            .preferredColorScheme(setting == .system ? nil : (theme.isDark ? .dark : .light))
    }
}

public extension View {
    /// Applies the saved appearance (or `forcing`) to this view and everything inside it.
    /// Put it once on the root of each window.
    func blackTeamTheme(forcing: ThemeSetting? = nil) -> some View {
        modifier(Themed(forced: forcing))
    }
}

extension View {
    func btShadow(_ spec: ShadowSpec) -> some View {
        spec.layers.reduce(AnyView(self)) { view, layer in
            AnyView(view.shadow(color: layer.color, radius: layer.radius, x: 0, y: layer.y))
        }
    }
}
