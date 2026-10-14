import Foundation

// Black Team Code tools. Small schemas, small results: on a local model every token read costs time.

public struct ApprovalRequest: Equatable, Sendable {
    public var command: String
    public var description: String
}

public struct TodoItem: Codable, Equatable, Sendable {
    public var text: String
    public var done: Bool
    public init(text: String, done: Bool) { self.text = text; self.done = done }
}

/// What one edit or write changed, kept so it can be shown and undone.
public struct ToolChange: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var created: Bool
    public var added: Int
    public var removed: Int
    public var diff: String
    public var json: JSONValue {
        ["id": .string(id), "path": .string(path), "created": .bool(created), "added": .number(Double(added)), "removed": .number(Double(removed)), "diff": .string(diff)]
    }
}

public struct ToolArtifact: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var size: Int
    public var sha256: String
    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "size": .number(Double(size)), "sha256": .string(sha256)]
    }
}

/// What one tool call returns: the text the model reads, a line for the work log, and any change or attachment.
public struct ToolResult: Equatable, Sendable {
    public var output: String
    public var log: String?
    public var error: Bool
    public var change: ToolChange?
    public var artifact: ToolArtifact?

    public init(output: String, log: String? = nil, error: Bool = false, change: ToolChange? = nil, artifact: ToolArtifact? = nil) {
        self.output = output; self.log = log; self.error = error; self.change = change; self.artifact = artifact
    }

    /// The same record as the JavaScript returns.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["output": .string(output), "log": log.map { .string($0) } ?? .null]
        if error { object["error"] = .bool(true) }
        if let change { object["change"] = change.json }
        if let artifact { object["artifact"] = artifact.json }
        return .object(object)
    }
}

public struct UndoResult: Equatable, Sendable {
    public var path: String
    public var removed: Bool
}

public final class Tools: @unchecked Sendable {
    public typealias Ask = @Sendable (ApprovalRequest) async -> String

    // MARK: Constants

    public static let SECRET = JSPattern(#"(^|\/)(\.ssh|\.gnupg|\.aws|\.env(\..*)?|.*\.key|.*\.pem|id_[a-z0-9]+|credentials(\..*)?|auth\.json|\.netrc)(\/|\z)"#, caseInsensitive: true)
    // Commands that change the system, reach the network, or delete things wait for the user's approval.
    public static let RISKY = JSPattern(#"(^|[;&|`(\s])(sudo|su|rm|rmdir|mv|dd|mkfs|shred|truncate|chmod|chown|kill|pkill|killall|shutdown|reboot|systemctl|loginctl|crontab|curl|wget|ssh|scp|sftp|rsync|nc|ncat|telnet|tailscale|docker|podman|pacman|yay|apt|dnf|pip3?\s+(install|uninstall)|uv\s+(pip|tool|add)|npm\s+(i|install|uninstall|publish|exec)|npx|pnpm|yarn|git\s+(push|reset|clean|rebase|checkout\s+--|restore|stash\s+drop|branch\s+-D))(\s|\z)|(^|\s)(\/etc\/|\/usr\/|\/boot\/|\/var\/|~\/\.|\$HOME\/\.)|(^|[\s\/"'=])\.(config|local|ssh|gnupg|aws|kube|docker|pki|netrc|npmrc)(\/|\s|"|'|\z)"#)

    private static func param(_ properties: [String: JSONValue], _ required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })])
    }
    private static func entry(_ name: String, _ description: String, _ parameters: JSONValue) -> JSONValue {
        .object(["type": "function", "function": .object(["name": .string(name), "description": .string(description), "parameters": parameters])])
    }
    private static let schemaList: [JSONValue] = [
        entry("read", "Read lines of a text file, numbered. Search first; read only what you need.", param(["path": ["type": "string", "minLength": 1], "start": ["type": "integer", "description": "First line, from 1"], "lines": ["type": "integer", "description": "How many lines"]], ["path"])),
        entry("search", "Search file contents with a regular expression (ripgrep). Returns path:line:text.", param(["pattern": ["type": "string", "minLength": 1], "path": ["type": "string", "description": "File or folder; default workspace"], "glob": ["type": "string", "description": "e.g. *.py"]], ["pattern"])),
        entry("list", "List a folder.", param(["path": ["type": "string"]])),
        entry("edit", "Replace one exact piece of text in a file. `old` must match exactly once.", param(["path": ["type": "string", "minLength": 1], "old": ["type": "string", "minLength": 1], "new": ["type": "string"]], ["path", "old", "new"])),
        entry("write", "Create or overwrite a file in the workspace.", param(["path": ["type": "string", "minLength": 1], "content": ["type": "string", "maxLength": 400000]], ["path", "content"])),
        entry("run", "Run a shell command in the workspace. Output is shortened; pipe long output through tail.", param(["command": ["type": "string", "minLength": 1, "maxLength": 4000], "timeout": ["type": "integer", "description": "Seconds, default 120"]], ["command"])),
        entry("todo", "Replace your todo list. Keep it current: it survives when older tool output is trimmed.", param(["items": ["type": "array", "maxItems": 40, "items": ["type": "object", "properties": ["text": ["type": "string"], "done": ["type": "boolean"]], "required": ["text"]]]], ["items"])),
        entry("publish", "Attach a finished workspace file to the conversation so it can be downloaded on the phone.", param(["path": ["type": "string", "minLength": 1]], ["path"])),
        entry("map", "Ask the code map of the workspace which files and functions relate to a question. Returns names with paths and line numbers. Use it before reading many files. Code only.", param(["question": ["type": "string", "minLength": 1, "maxLength": 500], "refresh": ["type": "boolean", "description": "Rebuild the map first, after large changes"]], ["question"])),
    ]
    /// The tool list sent to the model: a JSON array of `{type: "function", function: {name, description, parameters}}`.
    public static let SCHEMAS: JSONValue = .array(schemaList)

    // MARK: State

    private let root: String, home: String, denied: [String]
    private let artifacts: String, undoDir: String, owner: String
    private let limit: @Sendable () -> Int
    private let ask: Ask
    private let signal: CancelSignal?
    private let useRtk: Bool
    private let graph: String, graphDir: String
    /// How a scheduled (unattended) run is held: nil is the usual interactive rule (only risky commands ask).
    private let unattended: UnattendedPermission?
    private let lock = NSLock()
    private var todoItems: [TodoItem] = []
    private var stale = false

    public var todo: [TodoItem] { lock.lock(); defer { lock.unlock() }; return todoItems }
    /// True once this conversation has changed files, so the next map question rebuilds the map.
    public var mapStale: Bool { lock.lock(); defer { lock.unlock() }; return stale }
    private func setStale(_ value: Bool) { lock.lock(); stale = value; lock.unlock() }

    /// The tools offered to the model. `map` is offered only when a graphify program and a folder for its maps were given.
    public var schemas: JSONValue {
        guard var all = Tools.SCHEMAS.array else { return .array([]) }
        // A read-only scheduled run is not even offered the tools that change things.
        if unattended == .readOnly { all = all.filter { !Tools.changing.contains($0["function"]?["name"]?.string ?? "") } }
        if !graph.isEmpty && !graphDir.isEmpty { return .array(all) }
        return .array(all.filter { $0["function"]?["name"]?.string != "map" })
    }
    /// The tools that change files or run commands.
    static let changing: Set<String> = ["edit", "write", "run", "publish"]
    public var schemaList: [JSONValue] { schemas.array ?? [] }

    /// Finds an optional program (rtk, graphify) on PATH. Returns nil when it is not installed.
    public static func findProgram(_ name: String) -> String? { lookUpProgram(name) }

    /// graph: the graphify executable, when installed; its map of the workspace is kept under graphDir, not in the project.
    public init(workspace: String, artifacts: String, undoDir: String, home: String = NSHomeDirectory(), owner: String = "The user", deny: [String] = [], limit: @escaping @Sendable () -> Int = { 8000 }, ask: @escaping Ask = { _ in "deny" }, signal: CancelSignal? = nil, useRtk: Bool = true, graph: String = "", graphDir: String = "", unattended: UnattendedPermission? = nil) throws {
        self.unattended = unattended
        guard let realRoot = PathUtil.realpath(workspace) else { throw BlackTeamError("ENOENT: no such file or directory: \(workspace)") }
        guard let realHome = PathUtil.realpath(home) else { throw BlackTeamError("ENOENT: no such file or directory: \(home)") }
        root = realRoot
        self.home = realHome
        // Black Team's own data (settings, conversations, memory vault) is not the model's to read as files.
        denied = deny.map { PathUtil.realpath($0) ?? PathUtil.resolve(FileManager.default.currentDirectoryPath, $0) }
        self.artifacts = artifacts; self.undoDir = undoDir; self.owner = owner; self.limit = limit; self.ask = ask
        self.signal = signal; self.useRtk = useRtk; self.graph = graph; self.graphDir = graphDir
    }

    private func relative(_ file: String) -> String {
        let value = PathUtil.relative(root, file)
        return value.isEmpty ? "." : value
    }
    private func inside(_ real: String, _ base: String) -> Bool { real == base || real.hasPrefix(base + "/") }

    // MARK: Paths

    /// Resolve a model-supplied path. Reads stay inside the home folder; writes stay inside the workspace.
    private func resolve(_ input: JSONValue?, write: Bool = false) throws -> String {
        guard let text = input?.string, !text.isEmpty, !text.contains("\0") else { throw fail("Give a file path.") }
        let expanded = text.hasPrefix("~/") ? PathUtil.join(home, String(text.dropFirst(2))) : text
        let target = PathUtil.resolve(root, expanded)
        var existing = target
        while !PathUtil.exists(existing) { existing = PathUtil.dirname(existing) }
        guard let realExisting = PathUtil.realpath(existing) else { throw posixFailure(ENOENT) }
        let real = PathUtil.join(realExisting, PathUtil.relative(existing, target))
        if !(inside(real, root) || (!write && inside(real, home))) {
            throw fail("\(write ? "You can write only inside the workspace" : "That path is outside the folders you can read"). Use a path relative to the workspace, such as notes.txt or src/app.js. Call list with no path to see the workspace.")
        }
        if Tools.SECRET.test(real) { throw fail("That file holds credentials and is off limits.") }
        if denied.contains(where: { inside(real, $0) }) { throw fail("That folder is Black Team\u{2019}s private data and is off limits. Use recall for memory.") }
        return real
    }

    // JavaScript's `Math.floor(x) || fallback`, with x as a tool argument.
    private func whole(_ value: JSONValue?, _ fallback: Int) -> Int {
        var number = Double.nan
        switch value {
        case .number(let n)?: number = n
        case .string(let s)?: number = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : (Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan)
        case .bool(let b)?: number = b ? 1 : 0
        case .null?: number = 0
        default: break
        }
        guard !number.isNaN else { return fallback }
        let floored = floor(max(-1e12, min(1e12, number)))
        return floored == 0 ? fallback : Int(floored)
    }

    // MARK: Undo

    /// Every edit keeps what the file held before, so the change can be shown and undone.
    private func recordChange(file: String, before: String?, after: String) async throws -> ToolChange {
        try FileManager.default.createDirectory(atPath: undoDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = randomHex(12), name = PathUtil.relative(root, file)
        let old = "\(undoDir)/\(id).before"
        try PathUtil.writeData(old, Data((before ?? "").utf8), mode: 0o600)
        var diff = ""
        let result = await capture("diff", ["-u", "--label", "a/\(name)", "--label", "b/\(name)", old, file], timeout: 3600, maxBuffer: 8 * 1024 * 1024)
        if result.status == 1 { diff = result.stdout }
        try? FileManager.default.removeItem(atPath: old)
        let body = diff.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
        func text(_ value: String) -> String { JSONValue.string(value).text() }
        let record = "{\"root\":\(text(root)),\"file\":\(text(file)),\"existed\":\(before != nil),\"before\":\(text(before ?? "")),\"after\":\(text(sha256Hex(after)))}"
        try PathUtil.writeData("\(undoDir)/\(id).json", Data(record.utf8), mode: 0o600)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: undoDir)) ?? []).filter { $0.hasSuffix(".json") }
        let kept = entries.map { (entry: $0, at: PathUtil.stat("\(undoDir)/\($0)")?.mtimeMs ?? 0) }.sorted { $0.at > $1.at }
        for stale in kept.dropFirst(300) { try? FileManager.default.removeItem(atPath: "\(undoDir)/\(stale.entry)") }
        let shown = JSString.length(diff) > 6000 ? "\(JSString.prefix(diff, 6000))\n\u{2026} the rest of this change is not shown \u{2026}" : diff
        return ToolChange(id: id, path: name, created: before == nil, added: body.filter { $0.hasPrefix("+") }.count, removed: body.filter { $0.hasPrefix("-") }.count, diff: shown)
    }

    /// Puts a file back as it was before one edit. Refuses when the file has changed again since, so a later edit is never lost.
    public static func undoChange(_ dir: String, _ id: String?) throws -> UndoResult {
        let gone = BlackTeamError("That change is no longer available.")
        guard let id, id.count == 24, id.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { throw gone }
        let record = "\(dir)/\(id).json"
        guard let data = try? PathUtil.readData(record), let saved = try? JSONValue.parse(data),
              let savedRoot = saved["root"]?.string, let savedFile = saved["file"]?.string,
              let existed = saved["existed"]?.bool, let after = saved["after"]?.string else { throw gone }
        let before = saved["before"]?.string ?? ""
        guard let root = PathUtil.realpath(savedRoot), let folder = PathUtil.realpath(PathUtil.dirname(savedFile)) else { throw BlackTeamError("That file is no longer inside its workspace.") }
        if folder != root && !folder.hasPrefix(root + "/") { throw BlackTeamError("That file is no longer inside its workspace.") }
        guard PathUtil.exists(savedFile), let current = try? PathUtil.readText(savedFile), sha256Hex(current) == after else {
            throw BlackTeamError("The file has changed since this edit, so it was not undone. Undo the later change first.")
        }
        if existed { try PathUtil.writeData(savedFile, Data(before.utf8), mode: 0o644) } else { try FileManager.default.removeItem(atPath: savedFile) }
        try? FileManager.default.removeItem(atPath: record)
        return UndoResult(path: PathUtil.relative(root, savedFile), removed: !existed)
    }

    // MARK: Text helpers

    public static func renderTodo(_ items: [TodoItem]) -> String {
        items.isEmpty ? "(empty)" : items.map { "[\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
    }

    /// Keeps the start and the end of a long text. Limits count UTF-16 units, as JavaScript does, and never cut a pair in two.
    public static func clip(_ text: String, _ limit: Int) -> String {
        let units = Array(text.utf16)
        if units.count <= limit { return text }
        let head = Int(floor(Double(limit) * 0.6)), tail = limit - head
        var headEnd = min(head, units.count)
        if headEnd > 0 && UTF16.isLeadSurrogate(units[headEnd - 1]) { headEnd -= 1 }
        var tailStart = units.count - tail
        if tailStart > 0 && tailStart < units.count && UTF16.isTrailSurrogate(units[tailStart]) && UTF16.isLeadSurrogate(units[tailStart - 1]) { tailStart += 1 }
        return "\(String(decoding: units[0..<headEnd], as: UTF16.self))\n\u{2026} \(units.count - limit) characters left out \u{2026}\n\(String(decoding: units[tailStart...], as: UTF16.self))"
    }

    private func atomicWrite(_ file: String, _ content: String) throws {
        let temporary = "\(file).\(randomHex(6)).tmp"
        let mode = PathUtil.exists(file) ? (PathUtil.stat(file)?.mode ?? 0o644) : 0o644
        do {
            try PathUtil.writeData(temporary, Data(content.utf8), mode: mode)
            if rename(temporary, file) != 0 { throw posixFailure(errno) }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    // MARK: Tools

    private func read(_ args: [String: JSONValue]) throws -> ToolResult {
        let file = try resolve(args["path"])
        let info = try PathUtil.statThrowing(file)
        if !info.isFile { throw fail("Not a file. Use list for folders.") }
        if info.size > 5 * 1024 * 1024 { throw fail("File is over 5 MB. Use search, or run with head/tail.") }
        var all = PathUtil.splitLines(try PathUtil.readText(file))
        if all.last == "" { all.removeLast() }
        let from = max(1, whole(args["start"], 1)), count = max(1, min(whole(args["lines"], 200), 2000))
        var rows: [String] = []
        let budget = limit()
        var used = 0, last = from - 1
        var n = from
        while n <= min(all.count, from + count - 1) {
            let line = all[n - 1]
            let row = "\(n)|\(JSString.length(line) > 400 ? JSString.prefix(line, 400) + "\u{2026}" : line)"
            if used + JSString.length(row) + 1 > budget && !rows.isEmpty { break }
            rows.append(row); used += JSString.length(row) + 1; last = n
            n += 1
        }
        let more = last < all.count ? " Next: start=\(last + 1)." : ""
        return ToolResult(output: "\(rows.joined(separator: "\n"))\n(lines \(from)-\(last) of \(all.count).\(more))", log: "read \(relative(file)) \(from)-\(last) of \(all.count)")
    }

    private func search(_ args: [String: JSONValue]) async throws -> ToolResult {
        guard let pattern = args["pattern"]?.string, !pattern.isEmpty else { throw fail("Give a pattern.") }
        let target = try resolve(args["path"] ?? ".")
        let glob = args["glob"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let text = await grep(pattern, target, glob)
        // Search recurses, so every result is held to the same rules as read: no credential files, no private data.
        let lead = try! NSRegularExpression(pattern: #"^(.+?):\d+:"#)
        let allowed = { (row: String) -> Bool in
            guard let match = lead.firstMatch(in: row, range: NSRange(location: 0, length: row.utf16.count)), let range = Range(match.range(at: 1), in: row) else { return true }
            guard let real = PathUtil.realpath(PathUtil.resolve(self.root, String(row[range]))) else { return false }
            return !Tools.SECRET.test(real) && !self.denied.contains(where: { real == $0 || real.hasPrefix($0 + "/") })
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter(allowed).map { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : $0 }
        var shown: [String] = []
        let budget = limit()
        var used = 0
        for row in rows {
            if used + JSString.length(row) + 1 > budget || shown.count >= 80 { break }
            shown.append(row); used += JSString.length(row) + 1
        }
        let note = rows.count > shown.count ? "\n(\(rows.count - shown.count) more matches. Narrow the pattern or path.)" : ""
        return ToolResult(output: shown.isEmpty ? "No matches." : shown.joined(separator: "\n") + note, log: "search \(JSONValue.string(pattern).text()) in \(relative(target)) \u{2192} \(rows.count) lines")
    }

    private func list(_ args: [String: JSONValue]) throws -> ToolResult {
        let dir = try resolve(args["path"] ?? ".")
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir) } catch {
            if isMissing(error) { throw posixFailure(ENOENT) }
            throw fail(PathUtil.exists(dir) ? "ENOTDIR: not a directory, scandir '\(dir)'" : error.localizedDescription)
        }
        let locale = Locale(identifier: "en")
        let entries = names.map { (name: $0, directory: PathUtil.stat("\(dir)/\($0)", follow: false)?.isDirectory ?? false) }.sorted { a, b in
            if a.directory != b.directory { return a.directory }
            return a.name.compare(b.name, options: [], range: nil, locale: locale) == .orderedAscending
        }
        let rows = entries.prefix(200).map { entry -> String in
            if entry.directory { return "\(entry.name)/" }
            let size = PathUtil.stat("\(dir)/\(entry.name)").map { String($0.size) } ?? "?"
            return "\(entry.name)  \(size) bytes"
        }
        return ToolResult(output: (rows.isEmpty ? "(empty)" : rows.joined(separator: "\n")) + (entries.count > 200 ? "\n(\(entries.count - 200) more)" : ""), log: "list \(relative(dir)) (\(entries.count))")
    }

    /// A scheduled run at the "ask" level asks before every change to a file; nil means go ahead.
    private func confirmChange(_ verb: String, _ file: String) async -> ToolResult? {
        guard unattended == .ask else { return nil }
        let choice = await ask(ApprovalRequest(command: "\(verb) \(relative(file))", description: "Change this file in your project?"))
        if choice == "once" { return nil }
        return ToolResult(output: "\(owner) declined this change. Do not retry it; continue another way or ask.", log: "\(verb) declined: \(relative(file))", error: true)
    }

    private func edit(_ args: [String: JSONValue]) async throws -> ToolResult {
        let file = try resolve(args["path"], write: true)
        if let declined = await confirmChange("edit", file) { return declined }
        guard let old = args["old"]?.string, !old.isEmpty, let next = args["new"]?.string else { throw fail("Give old and new text.") }
        let text = try PathUtil.readText(file)
        // Occurrences are counted left to right without overlap, as split() does.
        let bytes = Data(text.utf8), needle = Data(old.utf8)
        var count = 0, first: Range<Data.Index>?
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex, let found = bytes.range(of: needle, in: cursor..<bytes.endIndex) {
            if first == nil { first = found }
            count += 1
            cursor = found.upperBound
        }
        if count == 0 { throw fail("`old` was not found. Read the lines again and copy them exactly.") }
        if count > 1 { throw fail("`old` matches \(count) places. Include more surrounding text so it matches once.") }
        var updatedBytes = bytes
        updatedBytes.replaceSubrange(first!, with: Data(next.utf8))
        let updated = String(decoding: updatedBytes, as: UTF8.self)
        try atomicWrite(file, updated)
        let change = try await recordChange(file: file, before: text, after: updated)
        setStale(true)
        let delta = "+\(change.added) \u{2212}\(change.removed) lines"
        return ToolResult(output: "Edited \(relative(file)) (\(delta)).", log: "edit \(relative(file)) (\(delta))", change: change)
    }

    private func write(_ args: [String: JSONValue]) async throws -> ToolResult {
        let file = try resolve(args["path"], write: true)
        if let declined = await confirmChange("write", file) { return declined }
        guard let content = args["content"]?.string else { throw fail("Give the file content.") }
        if JSString.length(content) > 400000 { throw fail("Content is too large for one write.") }
        try FileManager.default.createDirectory(atPath: PathUtil.dirname(file), withIntermediateDirectories: true)
        let existed = PathUtil.exists(file)
        let before = existed ? try PathUtil.readText(file) : nil
        try atomicWrite(file, content)
        let change = try await recordChange(file: file, before: before, after: content)
        setStale(true)
        let bytes = content.utf8.count
        return ToolResult(output: "\(existed ? "Overwrote" : "Created") \(relative(file)) (\(bytes) bytes).", log: "write \(relative(file)) (\(bytes) bytes)", change: change)
    }

    private func run(_ args: [String: JSONValue]) async throws -> ToolResult {
        guard let command = args["command"]?.string, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, JSString.length(command) <= 4000 else { throw fail("Give one shell command.") }
        // A scheduled run asks before every terminal command, whatever the command is. (Read-only never reaches here.)
        let alwaysAsk = unattended == .ask || unattended == .allowInProject
        if alwaysAsk || Tools.RISKY.test(command) || Tools.SECRET.test(command) || denied.contains(where: { command.contains(PathUtil.basename($0)) }) {
            let choice = await ask(ApprovalRequest(command: command, description: "Run this command on your computer?"))
            if choice != "once" { return ToolResult(output: "\(owner) declined this command. Do not retry it; continue another way or ask.", log: "run declined: \(JSString.prefix(command, 100))", error: true) }
        }
        let actual = useRtk ? await rewrite(command) : command
        if signal?.isCancelled == true { throw fail("Stopped before the command ran.") }
        let seconds = max(1, min(whole(args["timeout"], 120), 600))
        let result = await execute(command: actual, seconds: seconds)
        let status = result.timedOut ? "timed out after \(seconds)s" : "exit \(result.code)"
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = JSString.prefix(trimmed.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? "", 120)
        return ToolResult(output: "\(status)\n\(Tools.clip(trimmed.isEmpty ? "(no output)" : trimmed, limit()))", log: "run: \(JSString.prefix(command, 100)) \u{2192} \(status)\(lastLine.isEmpty ? "" : ": \(lastLine)")", error: result.timedOut || result.code != 0)
    }

    // The map is graphify's code graph of the workspace: built on first use, rebuilt after this
    // conversation edits files, after ten minutes, or on request. Queries stay within the result budget.
    private func map(_ args: [String: JSONValue]) async throws -> ToolResult {
        if graph.isEmpty || graphDir.isEmpty { throw fail("No code map tool is installed on this computer.") }
        guard let question = args["question"]?.string, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, JSString.length(question) <= 500 else { throw fail("Ask one question about the code.") }
        let dir = "\(graphDir)/\(String(sha256Hex(root).prefix(16)))", file = "\(dir)/graphify-out/graph.json"
        var age = Double.infinity
        if let info = PathUtil.stat(file) { age = Date().timeIntervalSince1970 * 1000 - info.mtimeMs }
        var note = ""
        if args["refresh"]?.bool == true || mapStale || age > 10 * 60 * 1000 {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let built = await execute(program: graph, args: ["extract", root, "--code-only", "--out", dir], seconds: 300)
            if built.timedOut || !PathUtil.exists(file) {
                throw fail("The code map could not be built\(built.timedOut ? " in five minutes" : ""): \(lastLine(built.text, 200))")
            }
            setStale(false)
            note = "Map \(age == .infinity ? "built" : "rebuilt"). "
        }
        let tokens = max(400, min(2000, Int(floor(Double(limit()) / 3.5 * 0.8))))
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = await execute(program: graph, args: ["query", trimmedQuestion, "--graph", file, "--budget", String(tokens)], seconds: 120)
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorLine = try! NSRegularExpression(pattern: "^error:", options: [.caseInsensitive, .anchorsMatchLines])
        if answer.timedOut || answer.code != 0 || errorLine.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil {
            throw fail("The code map could not answer: \(lastLine(text, 200))")
        }
        return ToolResult(output: note + Tools.clip(text, limit()), log: "map: \(JSString.prefix(trimmedQuestion, 80))")
    }

    private func lastLine(_ text: String, _ count: Int) -> String {
        let line = JSString.prefix(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? "", count)
        return line.isEmpty ? "no output" : line
    }

    private func todo(_ args: [String: JSONValue]) throws -> ToolResult {
        guard let items = args["items"]?.array, items.count <= 40 else { throw fail("Give up to 40 items.") }
        func asText(_ value: JSONValue?) -> String {
            switch value {
            case .string(let s)?: return s
            case .number(let n)?: return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .bool(let b)?: return b ? "true" : "false"
            case .array(let list)?: return list.map { asText($0) }.joined(separator: ",")
            case .object?: return "[object Object]"
            default: return ""
            }
        }
        let next = items.map { TodoItem(text: JSString.prefix(asText($0["text"]), 200), done: $0["done"]?.bool == true) }.filter { !$0.text.isEmpty }
        lock.lock(); todoItems = next; lock.unlock()
        return ToolResult(output: Tools.renderTodo(next), log: nil)
    }

    private func publish(_ args: [String: JSONValue]) throws -> ToolResult {
        let file = try resolve(args["path"], write: true)
        let info = try PathUtil.statThrowing(file)
        if !info.isFile { throw fail("Publish a regular file; zip folders first.") }
        if info.size > 250 * 1024 * 1024 { throw fail("File exceeds the 250 MB limit.") }
        let id = randomHex(16)
        let dest = "\(artifacts)/\(id)"
        try FileManager.default.copyItem(atPath: file, toPath: dest)
        chmod(dest, 0o600)
        let name = PathUtil.basename(file)
        let artifact = ToolArtifact(id: id, name: name, size: Int(info.size), sha256: sha256Hex(try PathUtil.readData(dest)))
        return ToolResult(output: "Attached \(artifact.name) (\(artifact.size) bytes) to the conversation.", log: "publish \(relative(file))", artifact: artifact)
    }

    // MARK: Processes

    // ripgrep when it is installed; plain grep otherwise, so search works on any system.
    private func grep(_ pattern: String, _ target: String, _ glob: String?) async -> String {
        func run(_ command: String, _ args: [String]) async -> (missing: Bool, text: String) {
            let result = await capture(command, args, cwd: root, timeout: 20, maxBuffer: 4 * 1024 * 1024)
            if result.missing { return (true, "") }
            let text = result.failed && result.status != 1 && result.stdout.isEmpty
                ? "search failed: \(JSString.prefix(result.stderr.isEmpty ? "Command failed: \(command)" : result.stderr, 300))"
                : result.stdout
            return (false, text)
        }
        let rg = ["-n", "-H", "--no-heading", "--color", "never", "--max-columns", "240", "--max-columns-preview", "-m", "20", "--sort", "path"] + (glob.map { ["-g", $0] } ?? []) + ["-e", pattern, "--", target]
        let plain = ["-rnIEH", "-m", "20", "--exclude-dir=.git", "--exclude-dir=node_modules"] + (glob.map { ["--include=\($0)"] } ?? []) + ["-e", pattern, "--", target]
        let first = await run("rg", rg)
        if !first.missing { return first.text }
        let fallback = await run("grep", plain)
        if fallback.missing { return "search failed: install ripgrep or grep." }
        return fallback.text.split(separator: "\n", omittingEmptySubsequences: false).map { JSString.prefix(String($0), 300) }.joined(separator: "\n")
    }

    // RTK shortens noisy command output. It is optional and fails open.
    private func rewrite(_ command: String) async -> String {
        let result = await capture("rtk", ["rewrite", command], timeout: 2, maxBuffer: 1024 * 1024)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.missing, result.status == 0 || result.status == 3, !out.isEmpty { return out }
        return command
    }

    private struct Execution { var code: Int32; var text: String; var timedOut: Bool }

    private func environment() -> [String: String] {
        var env: [String: String] = [:]
        let fixed: Set<String> = ["PATH", "HOME", "USER", "LANG", "TERM", "TMPDIR"]
        for (key, value) in currentEnvironment() {
            let locale = key.hasPrefix("LC_") && key.count > 3 && key.dropFirst(3).allSatisfy { ($0 >= "A" && $0 <= "Z") || $0 == "_" }
            if fixed.contains(key) || locale { env[key] = value }
        }
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"
        return env
    }

    // A shell command, or a program run without a shell, with the same bounded environment and the same stop handling.
    private func execute(command: String, seconds: Int) async -> Execution {
        await launch(executable: "/bin/bash", arguments: ["-c", command], seconds: seconds)
    }
    private func execute(program: String, args: [String], seconds: Int) async -> Execution {
        guard let found = lookUpProgram(program) else { return Execution(code: 127, text: "spawn \(program) ENOENT", timedOut: false) }
        return await launch(executable: found, arguments: args, seconds: seconds)
    }
    private func launch(executable: String, arguments: [String], seconds: Int) async -> Execution {
        let job = ExecJob(executable: executable, arguments: arguments, cwd: root, env: environment(), seconds: Double(seconds), signal: signal)
        let result = await job.run()
        return Execution(code: result.code ?? 1, text: String(decoding: result.combined, as: UTF8.self), timedOut: result.timedOut)
    }

    // MARK: Calling

    /// Runs one tool call by name. Failures come back as a result the model can read, never as a thrown error.
    public func call(_ name: String, _ args: JSONValue? = nil) async -> ToolResult {
        let names = ["read", "search", "list", "edit", "write", "run", "map", "todo", "publish"]
        guard names.contains(name) else { return ToolResult(output: "Unknown tool \(name). Tools: \(names.joined(separator: ", ")).", log: nil, error: true) }
        if unattended == .readOnly, Tools.changing.contains(name) {
            return ToolResult(output: "Error: this scheduled task is read-only. It can read and search, but it cannot change files or run commands.", log: nil, error: true)
        }
        // The arguments are checked against the tool's own schema first; a mismatch goes back to the model as the answer.
        if let problem = Tools.argumentProblem(name, args ?? [:]) { return ToolResult(output: problem, log: nil, error: true) }
        let arguments = args?.object ?? [:]
        do {
            switch name {
            case "read": return try read(arguments)
            case "search": return try await search(arguments)
            case "list": return try list(arguments)
            case "edit": return try await edit(arguments)
            case "write": return try await write(arguments)
            case "run": return try await run(arguments)
            case "map": return try await map(arguments)
            case "todo": return try todo(arguments)
            default: return try publish(arguments)
            }
        } catch {
            let message: String
            if isMissing(error) { message = "No such file or folder. Paths are relative to the workspace; call list with no path to see what is there." }
            else if let failure = error as? ToolFailure { message = failure.message }
            else if let known = error as? BlackTeamError { message = known.message }
            else { message = error.localizedDescription }
            return ToolResult(output: "Error: \(message)", log: nil, error: true)
        }
    }
}
