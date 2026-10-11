import Foundation

/// Small formatting helpers shared by the screens (the helpers at the top of App.jsx).
enum Fmt {
    /// "12.5 GB", as byteSize in App.jsx.
    static func gb(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.1f GB", Double(value) / 1_073_741_824)
    }

    static func gb(_ value: Int64) -> String { String(format: "%.1f GB", Double(value) / 1_073_741_824) }

    /// "532 MB" or "2.7 GB" for a download size.
    static func size(_ bytes: Int64) -> String {
        // Decimal, as Finder and Hugging Face show file sizes.
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return mb >= 1 ? String(format: "%.0f MB", mb) : String(format: "%.0f KB", Double(bytes) / 1000)
    }

    static func speed(bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    /// "about 4 min left"
    static func remaining(seconds: Double) -> String {
        if seconds < 45 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(max(1, minutes)) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
    }

    static func mhz(_ value: Int?) -> String {
        guard let value, value > 0 else { return "" }
        return value >= 1000 ? String(format: "%.1f GHz", Double(value) / 1000) : "\(value) MHz"
    }

    static func basename(_ path: String?) -> String {
        guard let path, let last = path.split(separator: "/").last else { return "Not selected" }
        return String(last)
    }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(iso: String) -> Date? { isoFraction.date(from: iso) ?? isoPlain.date(from: iso) }

    /// "Oct 11", as the sidebar's date().
    static func shortDate(iso: String) -> String {
        guard let date = parse(iso: iso) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func shortDate(millis: Double) -> String {
        Date(timeIntervalSince1970: millis / 1000).formatted(.dateTime.month(.abbreviated).day())
    }

    static func dateTime(millis: Double) -> String {
        Date(timeIntervalSince1970: millis / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    /// Where a model lives, without the scheme and version path: "127.0.0.1:11434".
    static func place(_ endpoint: String) -> String {
        var text = endpoint
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix("/v1/") { text.removeLast(4) } else if text.hasSuffix("/v1") { text.removeLast(3) }
        return text
    }

    /// The model name shown for a file or id, as modelLabel in ModelSetup.jsx.
    static func modelLabel(_ value: String) -> String {
        var name = basename(value)
        if name == "Not selected" { name = "" }
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        return String(name.prefix(120))
    }
}
