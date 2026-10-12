import Foundation

/// JavaScript string behaviour the engine depends on. JavaScript counts UTF-16 units, so every
/// character limit here does too, and a cut never lands inside a surrogate pair.
enum EText {
    static func length(_ text: String) -> Int { text.utf16.count }

    /// `text.slice(0, count)`, without splitting a pair.
    static func prefix(_ text: String, _ count: Int) -> String {
        guard count >= 0 else { return "" }
        let units = text.utf16
        if units.count <= count { return text }
        var end = count
        if end > 0, UTF16.isLeadSurrogate(units[units.index(units.startIndex, offsetBy: end - 1)]) { end -= 1 }
        return String(decoding: Array(units.prefix(end)), as: UTF16.self)
    }

    /// The characters `String.prototype.trim` removes.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// `number.toLocaleString()` in English, for whole numbers.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return number < 0 ? "-" + out : out
    }

    /// `Math.round`: halves go up.
    static func round(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    /// `new Date(ms).toISOString()`.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func hex(_ bytes: Int) -> String { (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    static func replaceAll(_ text: String, _ target: String, _ replacement: String) -> String {
        target.isEmpty ? text : text.replacingOccurrences(of: target, with: replacement, options: .literal)
    }
}
