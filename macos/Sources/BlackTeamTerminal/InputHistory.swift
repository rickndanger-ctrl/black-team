import Foundation
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

/// The lines typed before, for the up and down keys. Kept for the session and saved privately, newest 500.
public struct InputHistory: Equatable {
    public static let limit = 500
    public private(set) var entries: [String]
    private var position: Int?
    private var draft = ""

    public init(entries: [String] = []) { self.entries = Array(entries.suffix(InputHistory.limit)) }

    public mutating func add(_ line: String) {
        position = nil
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || entries.last == line { return }
        entries.append(line)
        if entries.count > InputHistory.limit { entries.removeFirst(entries.count - InputHistory.limit) }
    }

    /// Up: the line before; the first press remembers what was being typed.
    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if position == nil { draft = current; position = entries.count }
        guard let at = position, at > 0 else { return nil }
        position = at - 1
        return entries[at - 1]
    }

    /// Down: the line after, and at the end what was being typed.
    public mutating func next() -> String? {
        guard let at = position else { return nil }
        if at + 1 < entries.count { position = at + 1; return entries[at + 1] }
        position = nil
        return draft
    }

    public mutating func resetPosition() { position = nil }

    // MARK: File

    static func encode(_ line: String) -> String {
        line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func decode(_ line: String) -> String {
        var out = "", escaped = false
        for c in line {
            if escaped { out.append(c == "n" ? "\n" : c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return out
    }

    public static func load(path: String) -> InputHistory {
        guard let data = FileManager.default.contents(atPath: path) else { return InputHistory() }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map { decode(String($0)) }
        return InputHistory(entries: lines)
    }

    /// Saves the newest lines to a private file (mode 0600), replacing it in one step.
    @discardableResult
    public func save(path: String) -> Bool {
        let body = entries.suffix(InputHistory.limit).map { InputHistory.encode($0) }.joined(separator: "\n") + "\n"
        let temporary = path + ".tmp.\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return false }
        let bytes = Array(body.utf8)
        let written = write(fd, bytes, bytes.count)
        close(fd)
        chmod(temporary, 0o600)
        guard written == bytes.count, rename(temporary, path) == 0 else { unlink(temporary); return false }
        return true
    }
}
