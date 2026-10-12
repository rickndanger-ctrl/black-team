import Foundation

/// How many terminal columns text takes. Wide characters (Chinese, Japanese, Korean, emoji) take two,
/// combining marks and joiners none, everything else one.
public enum DisplayWidth {
    public static func of(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v == 0 || v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if v == 0x200B || v == 0x200D || (v >= 0xFE00 && v <= 0xFE0F) { return 0 }
        if (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0x303E) || (v >= 0x3041 && v <= 0x33FF) || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x4E00 && v <= 0xA4CF) || (v >= 0xA960 && v <= 0xA97F) || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0xFFE0 && v <= 0xFFE6)
            || (v >= 0x1F300 && v <= 0x1F64F) || (v >= 0x1F680 && v <= 0x1F6FF) || (v >= 0x1F900 && v <= 0x1FAFF)
            || (v >= 0x20000 && v <= 0x3FFFD) { return 2 }
        return 1
    }

    /// One character as the terminal draws it (a letter with its marks, or an emoji sequence, is one character).
    public static func of(_ character: Character) -> Int {
        if character == "\n" { return 1 } // drawn as a return mark
        var width = 0
        var wide = false
        for scalar in character.unicodeScalars {
            width = max(width, of(scalar))
            if scalar.value == 0xFE0F { wide = true }
        }
        return wide ? 2 : width
    }

    public static func of(_ text: String) -> Int { text.reduce(0) { $0 + of($1) } }

    /// The width of text that may contain colour codes (they take no room).
    public static func visible(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape { if scalar.value >= 0x40 && scalar.value <= 0x7E && scalar != "[" { inEscape = false }; continue }
            if scalar.value == 0x1B { inEscape = true; continue }
            count += of(scalar)
        }
        return count
    }
}
