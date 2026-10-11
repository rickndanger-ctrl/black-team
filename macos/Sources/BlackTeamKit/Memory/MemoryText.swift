import Foundation

// JavaScript string semantics and small file helpers, kept apart from Memory so that
// the class's own `read`, `write` and `remove` do not hide the C functions used here.

enum JS {
    /// JavaScript's whitespace (`\s`, `trim`): not the same set as Swift's `whitespacesAndNewlines`.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
    /// The same set, as an ICU regular-expression class.
    static let wsClass = #"[\t\n\u000B\f\r    -     　﻿]"#

    static func length(_ s: String) -> Int { s.utf16.count }

    static func trim(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isSpace(l) { scalars.removeLast() }
        return String(scalars)
    }
    static func trimStart(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        return String(scalars)
    }

    /// `text.slice(0, n)` in UTF-16 units, without leaving half of a surrogate pair.
    static func prefix(_ s: String, _ n: Int) -> String {
        let n = max(0, n)
        if s.utf16.count <= n { return s }
        var units = Array(s.utf16.prefix(n))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// `text.replace(/\s+/g, ' ')`
    static func squash(_ s: String) -> String {
        var out = String.UnicodeScalarView(); var inSpace = false
        for scalar in s.unicodeScalars {
            if isSpace(scalar) { if !inSpace { out.append(" "); inSpace = true } }
            else { out.append(scalar); inSpace = false }
        }
        return String(out)
    }

    /// `text.split(/\s+/)` for text already trimmed.
    static func words(_ s: String) -> [String] {
        var out: [String] = []; var current = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if isSpace(scalar) { if !current.isEmpty { out.append(String(current)); current = .init() } }
            else { current.append(scalar) }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// `text.split('\n')` (Swift treats "\r\n" as one character, so this walks scalars).
    static func lines(_ s: String) -> [String] {
        var out: [String] = []; var current = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == "\n" { out.append(String(current)); current = .init() } else { current.append(scalar) }
        }
        out.append(String(current))
        return out
    }

    /// `text.includes(part)` by UTF-16 units, with no Unicode equivalence.
    static func includes(_ s: String, _ part: String) -> Bool {
        part.isEmpty || s.range(of: part, options: .literal) != nil
    }

    /// `text.split(/\n(?=## )/)`
    static func splitBeforeHeadings(_ s: String) -> [String] {
        let bytes = Array(s.utf8); var parts: [String] = []; var start = 0; var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A, i + 3 < bytes.count, bytes[i + 1] == 0x23, bytes[i + 2] == 0x23, bytes[i + 3] == 0x20 {
                parts.append(String(decoding: bytes[start..<i], as: UTF8.self)); start = i + 1
            }
            i += 1
        }
        parts.append(String(decoding: bytes[start...], as: UTF8.self))
        return parts
    }

    /// `new Date(ms).toISOString()`, always UTC.
    static func iso(_ ms: Int64) -> String {
        var seconds = ms / 1000; var milli = ms % 1000
        if milli < 0 { milli += 1000; seconds -= 1 }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(seconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, Int(milli))
    }
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// `number.toLocaleString()` in English.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n)); var out = ""
        for (i, ch) in digits.enumerated() { if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }; out.append(ch) }
        return n < 0 ? "-" + out : out
    }

    /// `path.basename` for POSIX paths.
    static func basename(_ path: String) -> String {
        var s = Substring(path)
        while s.count > 1, s.last == "/" { s.removeLast() }
        if s == "/" { return "" }
        if let slash = s.lastIndex(of: "/") { return String(s[s.index(after: slash)...]) }
        return String(s)
    }
}

extension Array {
    /// Swift does not promise that `sort` keeps equal items in order; JavaScript does.
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

struct FileFacts { var size: Int; var mtimeMs: Double; var isDirectory: Bool; var isFile: Bool; var isSymlink: Bool }

enum FS {
    static func facts(_ path: String, follow: Bool = true) -> FileFacts? {
        var st = stat()
        let result = follow ? stat(path, &st) : lstat(path, &st)
        if result != 0 { return nil }
        #if canImport(Darwin)
        let mtime = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec) / 1_000_000
        #else
        let mtime = Double(st.st_mtim.tv_sec) * 1000 + Double(st.st_mtim.tv_nsec) / 1_000_000
        #endif
        let type = st.st_mode & S_IFMT
        return FileFacts(size: Int(st.st_size), mtimeMs: mtime, isDirectory: type == S_IFDIR, isFile: type == S_IFREG, isSymlink: type == S_IFLNK)
    }
    static func exists(_ path: String) -> Bool { facts(path) != nil }

    static func realPath(_ path: String) throws -> String {
        guard let raw = realpath(path, nil) else { throw BlackTeamError("The memory vault could not be opened.") }
        defer { free(raw) }
        return String(cString: raw)
    }
    static func dirname(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    static func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func readText(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else { throw BlackTeamError("That note could not be read.") }
        return String(decoding: data, as: UTF8.self)
    }
    /// Written beside the note and renamed over it, so a note is never half written.
    static func writeText(_ path: String, _ content: String) throws {
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw BlackTeamError("That note could not be saved.")
        }
        chmod(tmp, 0o600)
        if rename(tmp, path) != 0 { unlink(tmp); throw BlackTeamError("That note could not be saved.") }
    }
    static func appendText(_ path: String, _ text: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else { throw BlackTeamError("That note could not be saved.") }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    static func move(_ from: String, _ to: String) throws {
        if rename(from, to) != 0 { throw BlackTeamError("That note could not be moved.") }
    }
    static func delete(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
    static func names(_ path: String) -> [String]? { try? FileManager.default.contentsOfDirectory(atPath: path) }
}
