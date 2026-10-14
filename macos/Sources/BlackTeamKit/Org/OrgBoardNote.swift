import Foundation

// One ticket note of an Obsidian board: a Markdown file with YAML front matter, written by several agents (Claude Code, Codex, Hermes, Black
// Team's own models). This file only reads and edits the text. Edits are made line by line, so every field and section Black Team does not know
// about, and every other agent's words, stay byte for byte as they were; a missing field is tolerated and nothing is ever removed.
//
//   ---
//   id: T-7                  status: backlog | ready | in-progress | review | blocked | done
//   title: ...               stage: intake | spec | design | plan | build | review | qa | ship
//   priority: p1             owner / claimed / lease_until: who holds it, since when, until when
//   role / branch / pr / created / updated
//   ---
//   ## Context   ## Acceptance criteria   ## Plan   ## Log      (Log is append-only: "- 2026-10-13T22:10 <owner>: <what happened>")

struct BoardNote {
    /// The whole file as lines split on "\n" (a "\r" stays on its line), so joining them again gives back exactly what was read.
    private var lines: [String]
    /// The line numbers of the front matter's two `---` lines, or nil when the note has none.
    private var frame: (open: Int, close: Int)?
    private var fields = Manifest("")

    init(_ raw: String) {
        lines = Self.split(raw)
        refresh()
    }

    /// Splits on "\n" by scalar (Swift reads "\r\n" as one character, which a text split would miss).
    private static func split(_ raw: String) -> [String] {
        var out: [String] = [], current = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" { out.append(String(current)); current = String.UnicodeScalarView() } else { current.append(scalar) }
        }
        out.append(String(current))
        return out
    }

    private static func dropCR(_ line: String) -> String { String(String.UnicodeScalarView(line.unicodeScalars.filter { $0 != "\r" })) }

    /// The whole file, exactly as read (and as edited so far).
    var text: String { lines.joined(separator: "\n") }

    private mutating func refresh() {
        func bar(_ line: String) -> Bool { line.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) == "---" }
        if let first = lines.first, bar(first), let close = lines.indices.dropFirst().first(where: { bar(lines[$0]) }) {
            frame = (0, close)
            fields = Manifest(lines[1..<close].map(Self.dropCR).joined(separator: "\n"))
        } else {
            frame = nil
            fields = Manifest("")
        }
    }

    func field(_ key: String) -> String { EText.trim(fields.scalars[key] ?? "") }

    var id: String { field("id") }
    var title: String { field("title") }
    var status: String { field("status").lowercased() }
    var stage: String { field("stage").lowercased() }
    var priority: String { field("priority").lowercased() }
    var owner: String { field("owner") }
    var leaseUntil: Date? { BoardTime.parse(field("lease_until")) }
    var created: Date? { BoardTime.parse(field("created")) }

    /// A note Black Team can work with: it has front matter and a usable id. Everything else about it may be missing.
    var valid: Bool { frame != nil && Self.validID(id) }

    /// `T-7` and the like: letters, digits, dot, dash and underscore, so it is safe in a path and in a branch name.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "." || $0 == "_" }
    }

    /// Priority p0 (most urgent) to p3; a note with none or an odd one sorts last.
    var rank: Int {
        let p = priority
        guard p.count == 2, p.hasPrefix("p"), let n = Int(p.dropFirst()) else { return 9 }
        return n
    }

    /// Nobody holds it: no owner, or a lease that has run out. An owner with no lease at all counts as holding it (someone wrote it by hand).
    func free(at moment: Date) -> Bool {
        if owner.isEmpty { return true }
        guard let until = leaseUntil else { return false }
        return until <= moment
    }

    // MARK: Sections

    private func headingLevelTwo(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("## ") else { return nil }
        return trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
    }

    /// The line range of a `## Name` section (after its heading, up to the next heading of level one or two).
    private func sectionRange(_ name: String) -> Range<Int>? {
        let start = (frame?.close ?? -1) + 1
        guard start < lines.count, let at = (start..<lines.count).first(where: { headingLevelTwo(lines[$0])?.lowercased() == name.lowercased() }) else { return nil }
        var end = lines.count
        var i = at + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("## ") || t.hasPrefix("# ") { end = i; break }
            i += 1
        }
        return (at + 1)..<end
    }

    func section(_ name: String) -> String? {
        guard let range = sectionRange(name) else { return nil }
        return EText.trim(lines[range].map(Self.dropCR).joined(separator: "\n"))
    }

    /// The Log lines, oldest first (`- 2026-10-13T22:10 owner: text`).
    var log: [String] {
        guard let range = sectionRange("Log") else { return [] }
        return lines[range].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("- ") }
    }

    // MARK: Editing

    private var crlf: Bool { lines.first?.hasSuffix("\r") == true }

    /// Sets one front matter field in place, or adds it just above the closing `---`. Other lines are not touched.
    mutating func set(_ key: String, _ value: String) {
        guard let frame else { return }
        let written = "\(key):" + (value.isEmpty ? "" : " " + Self.scalar(value))
        for i in (frame.open + 1)..<frame.close {
            let line = lines[i]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":"), line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces) == key else { continue }
            // A value that goes on over several indented lines is left alone; only one-line fields are rewritten.
            if i + 1 < frame.close, lines[i + 1].hasPrefix(" ") || lines[i + 1].hasPrefix("\t") { return }
            lines[i] = written + (line.hasSuffix("\r") ? "\r" : "")
            refresh()
            return
        }
        lines.insert(written + (crlf ? "\r" : ""), at: frame.close)
        refresh()
    }

    /// Adds one line to the end of the `## Log` section, or makes the section at the end of the note.
    mutating func log(_ moment: Date, who: String, _ what: String) {
        let one = String(String.UnicodeScalarView(what.unicodeScalars.map { $0 == "\r" || $0 == "\n" ? " " : $0 }))
        let eol = crlf ? "\r" : ""
        let entry = "- \(BoardTime.log(moment)) \(who): \(one)" + eol
        if let range = sectionRange("Log") {
            var at = range.upperBound
            while at > range.lowerBound, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
            lines.insert(entry, at: at)
        } else {
            // The note ended with a newline (an empty last piece) or did not; either way the new section starts on its own line.
            let endsWithNewline = lines.last == ""
            if endsWithNewline { lines.removeLast() }
            lines.append(contentsOf: ["" + eol, "## Log" + eol, entry])
            if endsWithNewline { lines.append("") }
        }
        refresh()
    }

    /// A value written plain unless YAML would read it as something else.
    static func scalar(_ value: String) -> String {
        let risky = value.contains(": ") || value.contains(" #") || value.hasPrefix(" ") || value.hasSuffix(" ") || value.first.map { "[]{}&*!|>'\"%@`#,?-".contains($0) } == true
        guard risky else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The times a board uses: full ISO times with a zone for the lease (so agents in other time zones agree), minutes for the Log.
enum BoardTime {
    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `2026-10-13T22:10` in this computer's time, the way the Log reads.
    static func log(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date)
    }

    /// Tolerant: with a zone, with fractions, or none at all (taken as this computer's time).
    static func parse(_ text: String) -> Date? {
        let t = EText.trim(text)
        if t.isEmpty { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: t) { return d }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}
