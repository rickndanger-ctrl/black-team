import SwiftUI
import CoreText
import AppKit

/// The bundled typefaces. The Linux app serves WOFF2 files, which macOS cannot load, so the
/// same fonts ship here as TrueType (converted with fontTools; licences sit beside them).
public enum Fonts {
    private static let files = ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "AdwaitaSans-Regular", "AdwaitaSans-SemiBold"]

    private static let registered: Bool = {
        var ok = true
        for name in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { ok = false; continue }
            var error: Unmanaged<CFError>?
            // An "already registered" error on a second launch path is harmless.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeUnretainedValue()) } ?? 0
                if code != CFIndex(CTFontManagerError.alreadyRegistered.rawValue) { ok = false }
            }
        }
        return ok
    }()

    /// Call once at start. Safe to call again.
    public static func register() { _ = registered }

    /// True when every bundled face loaded (otherwise SwiftUI falls back to the system fonts).
    static var isAvailable: Bool { registered }
}

enum BTWeight { case regular, medium, semibold }

/// The person can turn bold headings off. Stored in `@AppStorage(TextWeightSetting.storageKey)`.
public enum TextWeightSetting {
    public static let storageKey = "black-team-plain-headings"
    static var plain: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

/// Font helpers: Adwaita Sans for text, JetBrains Mono for headings, status labels and code.
enum BTFont {
    static func body(_ size: CGFloat = 13, _ weight: BTWeight = .regular) -> Font {
        Fonts.register()
        return .custom(weight == .semibold && !TextWeightSetting.plain ? "AdwaitaSans-SemiBold" : "AdwaitaSans-Regular", fixedSize: size)
    }
    static func mono(_ size: CGFloat = 12, _ weight: BTWeight = .regular) -> Font {
        Fonts.register()
        return .custom(weight == .semibold && !TextWeightSetting.plain ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", fixedSize: size)
    }
}


// MARK: - Line height

extension BTFont {
    /// The height SwiftUI gives one line of the bundled face: ascent plus descent plus leading.
    static func natural(_ size: CGFloat, mono: Bool = false) -> CGFloat {
        Fonts.register()
        let name = mono ? "JetBrainsMono-Regular" : "AdwaitaSans-Regular"
        guard let font = NSFont(name: name, size: size) else { return size * 1.2 }
        return font.ascender - font.descender + font.leading
    }
}

extension Text {
    /// Body text with the CSS `font-size` and `line-height` (a multiple of the size), in one colour.
    /// The half-leading CSS puts above and below each line is split the same way here.
    func btBody(_ size: CGFloat, _ lineHeight: CGFloat, _ color: Color, weight: BTWeight = .regular, mono: Bool = false, floor: CGFloat = 0) -> some View {
        let extra = max(0, max(size * lineHeight, floor) - BTFont.natural(size, mono: mono))
        return self.font(mono ? BTFont.mono(size, weight) : BTFont.body(size, weight)).foregroundStyle(color)
            .lineSpacing(extra)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, extra / 2)
    }
    /// The same for a heading that already has its font and colour.
    func btLines(_ size: CGFloat, _ lineHeight: CGFloat, mono: Bool = false) -> some View {
        let extra = max(0, size * lineHeight - BTFont.natural(size, mono: mono))
        return self.lineSpacing(extra)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, extra / 2)
    }
}
