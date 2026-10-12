import Foundation

// The Black Team vault: local memory only. Plain Markdown notes joined by [[links]], kept in
// Black Team's own data folder, apart from any notes other tools or hosted assistants use.
//   Core.md                     what every conversation is told (edited by the user only)
//   Notes/<topic>.md            facts that are true everywhere
//   Projects/<name>/...         one folder per project: Overview, Journal and its own facts
//   Archive/...                 older material: kept, but left out of recall

private let CORE = MemoryConstants.CORE, NOTES = MemoryConstants.NOTES, PROJECTS = MemoryConstants.PROJECTS, ARCHIVE = MemoryConstants.ARCHIVE
private let MAX_NOTE = 200_000
private let linkPattern = try! NSRegularExpression(pattern: #"\[\[([^\]|#\n]{1,180})(?:#[^\]|\n]*)?(?:\|[^\]\n]*)?\]\]"#)
private let commentPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
private let corePattern = try! NSRegularExpression(pattern: "^# Core\(JS.wsClass)*$", options: .anchorsMatchLines)
private let wordPattern = try! NSRegularExpression(pattern: #"[a-z0-9][a-z0-9_.-]{3,}"#)
private let STOP: Set<String> = Set("about after again also because been before being could does doing done each ever every from have having here into just know like make many more most much must need only other over please really same should some such than that their them then there these they thing things this those through very want what when where which while will with would your yours could help tell show give think about".split(separator: " ").map(String.init))

public final class Memory: @unchecked Sendable {
    public let root: String
    public let limits: MemoryLimits
    private let now: () -> Date
    private var unusable: [String: Int] = [:] // Notes the model could not shorten, by size, so the same attempt is not repeated.
    private let lock = NSLock()

    public init(vault: String, limits: MemoryLimits = .default, now: @escaping () -> Date = Date.init) throws {
        guard vault.hasPrefix("/") else { throw BlackTeamError("The memory vault needs an absolute folder path.") }
        try FS.makeFolder(vault)
        if FS.facts(vault, follow: false)?.isSymlink == true { throw BlackTeamError("The memory vault must not be a symbolic link.") }
        self.root = try FS.realPath(vault)
        self.limits = limits
        self.now = now

        // A new vault is set up on first start, so memory is ready before anything is saved:
        // the folders the models file into, and a Core note for the user to write.
        let coreTemplate = """
        # Core

        <!-- This note is told to every conversation, in full. Keep it short.
        Write how you like answers, what you are working on, and anything the models should always keep in mind.
        Only you edit this note; the models never change it. Delete this comment when you write yours. -->

        """
        if walk(root).isEmpty && !FS.exists("\(root)/\(CORE).md") {
            for folder in [NOTES, PROJECTS, ARCHIVE] { try FS.makeFolder("\(root)/\(folder)") }
            let core = "\(root)/\(CORE).md"
            guard FileManager.default.createFile(atPath: core, contents: Data(coreTemplate.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw BlackTeamError("The memory vault could not be set up.")
            }
            chmod(core, 0o600)
        }
    }

    // MARK: - Paths

    /// No hidden parts, no odd characters, 1 to 180 UTF-16 units: the JavaScript's NOTE_ID pattern.
    private static func isValidNoteID(_ id: String) -> Bool {
        let units = Array(id.utf16)
        guard (1...180).contains(units.count) else { return false }
        let forbidden: Set<UInt16> = [0x5C, 0x00, 0x3C, 0x3E, 0x3A, 0x22, 0x7C, 0x3F, 0x2A, 0x0A]
        if units.contains(where: forbidden.contains) { return false }
        // The two look-aheads use `.`, which stops at a line terminator, so they only see the text before one.
        let end = units.firstIndex(where: { [0x0A, 0x0D, 0x2028, 0x2029].contains($0) }) ?? units.count
        let head = units[..<end]
        if head.first == 0x2E { return false }
        var previous: UInt16?
        for unit in head {
            if previous == 0x2F, unit == 0x2E || unit == 0x2F { return false }
            previous = unit
        }
        return true
    }

    private func fileFor(_ id: String) throws -> String {
        if !Memory.isValidNoteID(id) || id.components(separatedBy: "/").contains(where: { $0 == ".." || JS.trim($0).isEmpty }) {
            throw BlackTeamError("That is not a valid note name.")
        }
        let file = "\(root)/\(id).md"
        var existing = FS.dirname(file)
        while !FS.exists(existing) { existing = FS.dirname(existing) }
        let real = try FS.realPath(existing)
        if real != root && !real.hasPrefix(root + "/") { throw BlackTeamError("Notes stay inside the vault.") }
        return file
    }
    private func title(_ id: String) -> String { id.components(separatedBy: "/").last ?? id }
    private func isJournal(_ id: String) -> Bool { id.hasPrefix("\(PROJECTS)/") && id.hasSuffix("/Journal") }

    private func walk(_ dir: String) -> [String] {
        var found: [String] = []
        for name in (FS.names(dir) ?? []).sorted() {
            if name.hasPrefix(".") { continue } // .obsidian, .trash
            let full = "\(dir)/\(name)"
            guard let facts = FS.facts(full, follow: false) else { continue }
            if facts.isDirectory { found += walk(full) }
            else if facts.isFile && name.hasSuffix(".md") { found.append(full) }
        }
        return found
    }
    private func idFor(_ file: String) -> String { String(file.dropFirst(root.count + 1).dropLast(3)) }

    // MARK: - The vault

    public func notes() -> [NoteInfo] {
        walk(root).compactMap { file -> NoteInfo? in
            guard let facts = FS.facts(file) else { return nil }
            let id = idFor(file)
            let text = facts.size <= MAX_NOTE * 2 ? ((try? FS.readText(file)) ?? "") : ""
            let ns = text as NSString
            var links: [String] = []; var seen = Set<String>()
            for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if name.utf16.count > 180 { continue } // ICU counts characters where JavaScript counts UTF-16 units.
                let trimmed = JS.trim(name)
                if seen.insert(trimmed).inserted { links.append(trimmed) }
            }
            let kind: NoteKind = id == CORE ? .core : id.hasPrefix("\(ARCHIVE)/") ? .archive : id.hasPrefix("\(PROJECTS)/") ? .project : .note
            return NoteInfo(id: id, title: title(id), folder: id.contains("/") ? String(id.split(separator: "/", omittingEmptySubsequences: false)[0]) : "", updated: facts.mtimeMs, size: facts.size, links: links, kind: kind)
        }.stableSorted { $0.updated > $1.updated }
    }

    /// Notes and the links between them. A link matches a note by name, as Obsidian does;
    /// a link to a note that does not exist yet is kept as an empty node.
    public func graph() -> MemoryGraph {
        let all = notes()
        var byName: [String: String] = [:]
        for note in all {
            byName[note.id.lowercased()] = note.id
            if byName[note.title.lowercased()] == nil { byName[note.title.lowercased()] = note.id }
        }
        let nodes = all.filter { $0.kind != .archive }.map {
            GraphNode(id: $0.id, title: $0.title, folder: $0.folder, kind: $0.kind, project: $0.kind == .project ? ($0.id.components(separatedBy: "/").dropFirst().first ?? "") : "", updated: $0.updated, missing: false)
        }
        var edges: [GraphEdge] = []; var seen = Set<String>(); var ghosts: [GraphNode] = []; var ghostIDs = Set<String>()
        for note in all where note.kind != .archive {
            for link in note.links {
                var target = byName[link.lowercased()]
                if target == nil {
                    let ghost = "?\(link)"; target = ghost
                    if ghostIDs.insert(ghost).inserted { ghosts.append(GraphNode(id: ghost, title: link, folder: "", kind: .missing, project: "", updated: 0, missing: true)) }
                }
                let key = "\(note.id)\n\(target!)"
                if target! != note.id && seen.insert(key).inserted { edges.append(GraphEdge(from: note.id, to: target!)) }
            }
        }
        return MemoryGraph(nodes: nodes + ghosts, edges: edges)
    }

    public func read(_ id: String) throws -> NoteContent {
        let file = try fileFor(id)
        guard FS.exists(file), let facts = FS.facts(file) else { throw BlackTeamError("No such note.") }
        if facts.size > MAX_NOTE * 2 { throw BlackTeamError("That note is too large to open here.") }
        return NoteContent(id: id, title: title(id), content: try FS.readText(file), updated: facts.mtimeMs)
    }

    @discardableResult
    public func write(_ id: String, _ content: String) throws -> NoteContent {
        if JS.length(content) > MAX_NOTE { throw BlackTeamError("A note can hold up to 200,000 characters.") }
        let file = try fileFor(id)
        try FS.makeFolder(FS.dirname(file))
        try FS.writeText(file, content)
        return try read(id)
    }

    /// Removed notes go to the vault's .trash folder, as Obsidian does, so nothing is lost by a wrong click.
    public func remove(_ id: String) throws {
        let file = try fileFor(id)
        guard FS.exists(file) else { throw BlackTeamError("No such note.") }
        let trash = "\(root)/.trash"
        try FS.makeFolder(trash)
        try FS.move(file, "\(trash)/\(title(id)) \(JS.millis(Date())).md")
    }

    /// Search reads the notes directly: the vault is kept small by its limits, so no outside tool is needed.
    public func search(_ query: String?, limit: Int = 12, includeArchive: Bool = false) async throws -> [SearchHit] {
        guard let query, !JS.trim(query).isEmpty, JS.length(query) <= 200 else { return [] }
        let words = Array(JS.words(JS.trim(query).lowercased()).prefix(6))
        var hits: [(hit: SearchHit, updated: Double)] = []
        for file in walk(root) {
            let id = idFor(file)
            if !includeArchive && id.hasPrefix("\(ARCHIVE)/") { continue }
            guard let facts = FS.facts(file) else { continue }
            if facts.size > MAX_NOTE * 2 { continue }
            let name = id.lowercased()
            var found = 0
            for (index, line) in JS.lines(try FS.readText(file)).enumerated() {
                let text = JS.trim(line); if text.isEmpty { continue }
                let lower = text.lowercased()
                if !words.contains(where: { JS.includes(lower, $0) }) { continue }
                let score = words.filter { JS.includes(lower, $0) || JS.includes(name, $0) }.count
                hits.append((SearchHit(id: id, title: title(id), line: index + 1, text: JS.prefix(text, 260), score: score), facts.mtimeMs))
                found += 1; if found >= 4 { break }
            }
        }
        // Best matches first; among equals, the most recently written note.
        let sorted = hits.stableSorted { $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.updated > $1.updated }
        return sorted.prefix(max(0, limit)).map(\.hit)
    }

    // MARK: - What the models use

    private func stamp() -> String { String(JS.iso(JS.millis(Date())).prefix(10)) }

    /// `text` with path-unsafe characters turned to spaces, no leading dots, at most 80 UTF-16 units.
    private func clean(_ text: String) -> String {
        let bad: Set<Unicode.Scalar> = ["\\", "\0", "<", ">", ":", "\"", "|", "?", "*", "\n", "\r", "/"]
        var replaced = String.UnicodeScalarView(); var inRun = false
        for scalar in text.unicodeScalars {
            if bad.contains(scalar) { if !inRun { replaced.append(" "); inRun = true } }
            else { replaced.append(scalar); inRun = false }
        }
        var scalars = Substring(JS.squash(String(replaced))).unicodeScalars
        while let f = scalars.first, f == "." || JS.isSpace(f) { scalars.removeFirst() }
        return JS.prefix(JS.trim(String(scalars)), 80)
    }

    /// Guidance comments in the note are for the user, not the model.
    public func core() -> String {
        guard let file = try? fileFor(CORE), var text = try? FS.readText(file) else { return "" }
        var ns = text as NSString
        text = commentPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        ns = text as NSString
        if let match = corePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            text = ns.replacingCharacters(in: match.range, with: "")
        }
        return JS.prefix(JS.trim(text), 1500)
    }

    private func projectFolder(_ workspace: String?) -> String {
        let name = clean(JS.basename(workspace ?? ""))
        return "\(PROJECTS)/\(name.isEmpty ? "workspace" : name)"
    }

    /// A model saves one fact per note. Saving to an existing title adds a dated line instead of replacing it.
    /// With a workspace, the note is filed in that project's folder beside its journal.
    @discardableResult
    public func remember(_ noteTitle: String, _ text: String, _ workspace: String? = nil) throws -> String {
        let name = clean(noteTitle)
        if name.isEmpty || ["core", "journal"].contains(name.lowercased()) {
            throw BlackTeamError("Give the note a short title. Core memory is edited by the user only.")
        }
        if JS.trim(text).isEmpty || JS.length(text) > 4000 { throw BlackTeamError("Give the fact to remember, up to 4,000 characters.") }
        let id = "\(workspace.map { $0.isEmpty ? NOTES : projectFolder($0) } ?? NOTES)/\(name)"
        let file = try fileFor(id)
        let entry = "- \(stamp()): \(JS.trim(text))\n"
        if FS.exists(file) { try FS.appendText(file, entry) }
        else { try write(id, "# \(name)\n\n\(entry)") }
        return id
    }

    /// With a note name, returns that whole note; otherwise the lines that match. These are memory notes, not workspace files.
    /// Inside a project, that project's own notes come first, so the model is not handed other projects' context.
    public func recall(_ query: String?, _ note: String? = nil, _ workspace: String? = nil) async throws -> String {
        if let note, !JS.trim(note).isEmpty {
            var id = JS.trim(note)
            if id.hasPrefix("[[") { id.removeFirst(2) }
            if id.hasSuffix("]]") { id.removeLast(2) }
            if id.hasSuffix(".md") { id.removeLast(3) }
            if let content = try? read(id).content { return JS.prefix(content, limits.noteChars) }
            return "There is no memory note named \"\(id)\". Call recall with a query to see what exists."
        }
        let here: String? = (workspace?.isEmpty == false) ? "\(projectFolder(workspace))/" : nil
        let found = try await search(query, limit: 24)
        var ordered = found
        if let here {
            ordered = found.filter { $0.id.hasPrefix(here) } + found.filter { !$0.id.hasPrefix("\(PROJECTS)/") }
                + found.filter { $0.id.hasPrefix("\(PROJECTS)/") && !$0.id.hasPrefix(here) }
        }
        let hits = ordered.prefix(8)
        if hits.isEmpty { return "Nothing saved matches that." }
        return "\(hits.map { "[[\($0.id)]] line \($0.line): \($0.text)" }.joined(separator: "\n"))\n(These are memory notes, not files in the workspace. For a whole note, call recall with note set to its name.)"
    }

    /// For Chat, which has no tools: find the few saved lines that share the message's distinctive words.
    /// Returns nothing unless the match is real, so an ordinary message is not padded with noise.
    public func lookup(_ message: String?, _ workspace: String? = nil, limit: Int = 4, maxChars: Int = 700) async throws -> [LookupHit] {
        let lower = (message ?? "").lowercased(); let ns = lower as NSString
        var unique: [String] = []; var seenWords = Set<String>()
        for match in wordPattern.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            if seenWords.insert(word).inserted { unique.append(word) }
        }
        let words = Array(unique.filter { !STOP.contains($0) }.stableSorted { $0.utf16.count > $1.utf16.count }.prefix(6))
        if words.isEmpty { return [] }
        let here: String? = (workspace?.isEmpty == false) ? "\(projectFolder(workspace))/" : nil
        let need = words.count >= 3 ? 2 : 1
        let found = try await search(words.joined(separator: " "), limit: 40).filter {
            $0.score >= need && $0.id != CORE && !isJournal($0.id) && !$0.text.hasPrefix("#")
        }
        func bonus(_ hit: SearchHit) -> Int { (here != nil && hit.id.hasPrefix(here!)) ? 1 : 0 }
        let ranked = found.stableSorted { bonus($0) != bonus($1) ? bonus($0) > bonus($1) : $0.score > $1.score }
        var picked: [LookupHit] = []; var used = 0; var seen = Set<String>()
        for hit in ranked {
            let key = "\(hit.id):\(hit.line)"
            if !seen.insert(key).inserted { continue }
            var body = hit.text
            if let first = body.first, first == "-" || first == "*" { body.removeFirst(); body = JS.trimStart(body) }
            let text = JS.prefix(body, 220)
            if picked.count >= limit || used + JS.length(text) > maxChars { break }
            picked.append(LookupHit(id: hit.id, title: hit.title, text: text)); used += JS.length(text)
        }
        return picked
    }

    /// Written by the engine after each Code turn, with no model call: what was asked, what was done.
    @discardableResult
    public func journal(_ workspace: String, request: String, log: [String] = [], outcome: String = "") throws -> String {
        let cleaned = clean(JS.basename(workspace))
        let name = cleaned.isEmpty ? "workspace" : cleaned
        let id = "\(projectFolder(workspace))/Journal"
        let file = try fileFor(id)
        let result = JS.prefix(JS.squash(outcome), 300)
        var lines = ["\n## \(JS.iso(JS.millis(Date())).prefix(16).replacingOccurrences(of: "T", with: " "))", "Asked: \(JS.prefix(JS.squash(request), 300))"]
        if !log.isEmpty { lines += ["Did:"] + log.suffix(12).map { "- \(JS.prefix($0, 200))" } }
        lines += ["Result: \(result.isEmpty ? "(no summary)" : result)", ""]
        if !FS.exists(file) { try write(id, "# \(name) journal\n\nWork done in `\(workspace)`, newest last. Written by Black Team after each Code turn.\n") }
        try FS.appendText(file, lines.joined(separator: "\n"))
        return id
    }

    // MARK: - The keeper: holds memory within its limits

    private func active() -> [NoteInfo] { notes().filter { $0.kind == .note || $0.kind == .project } }

    public func usage() -> MemoryUsage {
        let mine = active()
        let chars = mine.reduce(0) { $0 + $1.size }
        let ratio = Double(chars) / Double(limits.totalChars) * 100
        let percent = ratio.isNaN ? 0 : ratio.isInfinite ? Int.max : Int(ratio.rounded())
        return MemoryUsage(notes: mine.count, chars: chars, limit: limits.totalChars, percent: percent,
                           oversized: mine.filter { !isJournal($0.id) && $0.size > limits.noteChars }.map(\.id),
                           archived: notes().filter { $0.kind == .archive }.count)
    }

    private func triedSize(_ id: String) -> Int? { lock.lock(); defer { lock.unlock() }; return unusable[id] }
    private func markTried(_ id: String, _ size: Int?) { lock.lock(); defer { lock.unlock() }; unusable[id] = size }

    private func nowMillis() -> Int64 { JS.millis(now()) }

    /// Many notes share a title (every project has an Overview), so an archive name is never reused.
    private func archive(_ id: String, _ content: String) throws {
        let date = String(JS.iso(nowMillis()).prefix(10))
        let base = "\(ARCHIVE)/\(clean(title(id))) \(date) \(String(String(nowMillis()).suffix(5)))"
        var name = base; var n = 2
        while FS.exists(try fileFor(name)) { name = "\(base) \(n)"; n += 1 }
        try write(name, content)
    }

    /// Housekeeping that needs no model: old journal entries and the stalest notes move to the archive.
    public func sweep() throws -> [String] {
        var actions: [String] = []
        // Deleted notes leave the trash after 30 days.
        let trash = "\(root)/.trash"
        if let entries = FS.names(trash) {
            for entry in entries {
                let file = "\(trash)/\(entry)"
                guard let facts = FS.facts(file) else { break }
                if Double(nowMillis()) - facts.mtimeMs > 30 * 86_400_000 { FS.delete(file) }
            }
        }
        for note in active().filter({ isJournal($0.id) }) {
            let text = try FS.readText(try fileFor(note.id))
            let parts = JS.splitBeforeHeadings(text)
            let head = parts[0], entries = Array(parts.dropFirst())
            if entries.count <= limits.journalEntries { continue }
            let old = Array(entries.prefix(entries.count - limits.journalEntries))
            let project = note.id.components(separatedBy: "/").dropLast().last ?? ""
            try archive(project, "# \(project) journal (older entries)\n\n\(old.joined(separator: "\n"))")
            // `slice(-0)` is the whole list in JavaScript, so a limit of 0 keeps every entry.
            let kept = limits.journalEntries == 0 ? entries : Array(entries.suffix(limits.journalEntries))
            try write(note.id, ([head] + kept).joined(separator: "\n"))
            actions.append("Moved \(old.count) older journal entries for \(project) to the archive.")
        }
        let mine = active(); var total = mine.reduce(0) { $0 + $1.size }
        for note in mine.stableSorted(by: { $0.updated < $1.updated }) {
            if total <= limits.totalChars { break }
            let file = try fileFor(note.id)
            try archive(note.id, try FS.readText(file)); unlink(file); total -= note.size
            actions.append("Memory was over its limit, so the oldest note, \(note.title), moved to the archive.")
        }
        return actions
    }

    /// One oversized note is rewritten shorter by the model it is delegated to. The original is archived first,
    /// and a result that is empty, not shorter, or has lost its heading is thrown away.
    /// Idle upkeep skips a note it already failed on; asking by hand (again: true) tries it once more.
    public func condense(_ delegate: CondenseDelegate, again: Bool = false) async throws -> String? {
        var chosen: String?
        for item in usage().oversized {
            let size = FS.facts(try fileFor(item))?.size
            let tried = triedSize(item)
            if again || tried != size { chosen = item; break }
        }
        guard let id = chosen else { return nil }
        let file = try fileFor(id)
        let original = try FS.readText(file)
        markTried(id, FS.facts(file)?.size)
        // A note too long to hand over whole is left alone rather than shortened from a part of it.
        if JS.length(original) > 40000 { return "\(title(id)) is too long to condense automatically. Split it into smaller notes." }
        let target = Int((Double(limits.noteChars) * 0.6).rounded(.down))
        let shorter = JS.trim(try await delegate(CondenseRequest(title: title(id), content: original, target: target)))
        if shorter.isEmpty || JS.length(shorter) >= JS.length(original) || JS.length(shorter) > limits.noteChars {
            return "Tried to condense \(title(id)), but the result was not usable. The note is unchanged."
        }
        try archive(id, original)
        let body = shorter.hasPrefix("#") ? shorter : "# \(title(id))\n\n\(shorter)"
        try write(id, "\(body)\n\n_Condensed by Black Team on \(JS.iso(nowMillis()).prefix(10)). The full earlier version is in the archive._\n")
        return "Condensed \(title(id)) from \(JS.grouped(JS.length(original))) to \(JS.grouped(JS.length(shorter))) characters. The original is in the archive."
    }
}
