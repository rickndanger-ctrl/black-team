import Foundation

/// Small file-system helpers shared by the Core files.
enum CoreFS {
    static func errnoName(_ code: Int32) -> String {
        switch code {
        case ENOENT: return "ENOENT"
        case EACCES: return "EACCES"
        case EPERM: return "EPERM"
        case ENOTDIR: return "ENOTDIR"
        case EISDIR: return "EISDIR"
        case ELOOP: return "ELOOP"
        case EIO: return "EIO"
        case ENOSPC: return "ENOSPC"
        case EEXIST: return "EEXIST"
        default: return String(cString: strerror(code))
        }
    }

    /// stat() follows symbolic links, as Node's statSync does.
    static func stat(_ path: String) -> (mode: mode_t, size: Int, error: Int32) {
        var info = CStat()
        if fstatat(AT_FDCWD, path, &info, 0) != 0 { return (0, 0, errno) }
        return (info.st_mode, Int(info.st_size), 0)
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = CStat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    static func hex(_ count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Writes beside the target, flushes, then renames over it, so a crash never leaves half a file.
    static func writeAtomic(_ file: String, _ data: Data, temporary: String, syncDirectory: Bool = false) throws {
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw BlackTeamError("Could not save \((file as NSString).lastPathComponent): \(errnoName(errno)).") }
        var isOpen = true
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw BlackTeamError("Could not save \((file as NSString).lastPathComponent): \(errnoName(errno)).")
                    }
                    offset += written
                }
            }
            fsync(fd); close(fd); isOpen = false
            if rename(temporary, file) != 0 {
                throw BlackTeamError("Could not save \((file as NSString).lastPathComponent): \(errnoName(errno)).")
            }
            if syncDirectory {
                let dirfd = open((file as NSString).deletingLastPathComponent, O_RDONLY)
                if dirfd >= 0 { fsync(dirfd); close(dirfd) }
            }
        } catch {
            if isOpen { close(fd) }
            unlink(temporary)
            throw error
        }
        unlink(temporary)
    }
}

/// Creates a folder only the user can open, and refuses one that is a symbolic link.
public func privateDirectory(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if CoreFS.isSymlink(dir) { throw BlackTeamError("Private storage must not be a symbolic link.") }
    chmod(dir, 0o700)
}

/// Atomic, private (0600) JSON write. A symbolic link at `file` is replaced, never followed.
public func writeJSON<T: Encodable>(_ file: String, _ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try CoreFS.writeAtomic(file, data, temporary: "\(file).\(CoreFS.hex(10)).tmp")
}

private func historyHex(_ text: String, count: Int, dashes: Bool) -> Bool {
    guard text.utf8.count == count else { return false }
    return text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || (dashes && $0 == 45) }
}

private func parsesAsDate(_ text: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
        formatter.formatOptions = options
        if formatter.date(from: text) != nil { return true }
    }
    return false
}

/// One line of the conversation list.
public struct ThreadSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var updated: String
    public var kind: String
    public var project: String?
    /// "local" (nothing in it may leave this Mac) or "cloud" (it has been sent to `provider`).
    public var privacy: String = "local"
    public var provider: String = ""

    public init(id: String, title: String, updated: String, kind: String, project: String? = nil, privacy: String = "local", provider: String = "") {
        self.id = id; self.title = title; self.updated = updated; self.kind = kind; self.project = project; self.privacy = privacy; self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case id, title, updated, kind, project, privacy, provider }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title); updated = try c.decode(String.self, forKey: .updated)
        kind = try c.decode(String.self, forKey: .kind); project = try c.decodeIfPresent(String.self, forKey: .project)
        privacy = try c.decodeIfPresent(String.self, forKey: .privacy) ?? "local"; provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
    }
}

/// Saved conversations. A conversation is loose JSON (`JSONValue`) because messages carry
/// fields that belong to the engine (tool calls, artifacts, the model name).
public final class History: @unchecked Sendable {
    /// Conversation ids and request ids are 36 characters of lowercase hex and dashes.
    public static func validID(_ text: String) -> Bool { historyHex(text, count: 36, dashes: true) }

    public let dir: String
    private var rows: [String: JSONValue] = [:]
    private var requestIndex: [String: JSONValue] = [:]
    private let lock = NSLock()

    public init(stateDir: String) throws {
        try privateDirectory(stateDir)
        dir = stateDir + "/conversations"
        try privateDirectory(dir)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            guard name.hasSuffix(".json"), History.validID(String(name.dropLast(5))) else { continue }
            let id = String(name.dropLast(5))
            let file = dir + "/" + name
            if CoreFS.isSymlink(file) { throw BlackTeamError("Conversation files must not be symbolic links.") }
            if CoreFS.stat(file).size > 8 * 1024 * 1024 { throw BlackTeamError("Conversation exceeds the supported storage size.") }
            guard let data = FileManager.default.contents(atPath: file), var thread = try? JSONValue.parse(data) else {
                throw BlackTeamError("A saved conversation is damaged. Restore it from your backup before opening Black Team.")
            }
            if !validThread(thread, id) {
                throw BlackTeamError("A saved conversation has an unsupported format. Restore it from your backup before opening Black Team.")
            }
            var changed = false
            var object = thread.object!
            var messages = object["messages"]!.array!
            for index in messages.indices where messages[index]["state"]?.string == "writing" {
                var message = messages[index].object!
                message["state"] = "interrupted"
                messages[index] = .object(message); changed = true
            }
            var requests = object["requests"]!.array!
            for index in requests.indices {
                var request = requests[index].object!
                if request["state"]?.string == "running" { request["state"] = "interrupted"; changed = true }
                requests[index] = .object(request)
                var indexed = request; indexed["threadId"] = .string(id)
                requestIndex[request["id"]!.string!] = .object(indexed)
            }
            object["messages"] = .array(messages); object["requests"] = .array(requests)
            thread = .object(object)
            rows[id] = thread
            if changed { try save(thread) }
        }
    }

    public func list() -> [ThreadSummary] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.map { thread in
            ThreadSummary(id: thread["id"]?.string ?? "", title: thread["title"]?.string ?? "", updated: thread["updated"]?.string ?? "",
                          kind: { let kind = thread["kind"]?.string ?? ""; return kind.isEmpty ? "chat" : kind }(),
                          project: { let project = thread["project"]?.string ?? ""; return project.isEmpty ? nil : project }(),
                          privacy: thread["privacy"]?.string == "cloud" ? "cloud" : "local", provider: thread["provider"]?.string ?? "")
        }.sorted { $0.updated > $1.updated }
    }

    public func get(_ id: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return rows[id] }

    /// Every saved conversation, for searches across all of them.
    public var threads: [JSONValue] { lock.lock(); defer { lock.unlock() }; return Array(rows.values) }

    /// The saved request with this id, with the id of its conversation as `threadId`.
    public func request(_ id: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return requestIndex[id] }

    public func save(_ thread: JSONValue) throws {
        guard let id = thread["id"]?.string, History.validID(id) else { throw BlackTeamError("This conversation has no valid id.") }
        try writeJSON(dir + "/" + id + ".json", thread)
        lock.lock(); rows[id] = thread; lock.unlock()
    }

    /// A new, empty conversation titled from the first message (not saved until `save`).
    public func create(_ message: String) -> JSONValue {
        let spaced = message.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // The title is 72 UTF-16 units, as in the Linux app, without splitting a character.
        var title = "", units = 0
        for scalar in spaced.unicodeScalars {
            if units + scalar.utf16.count > 72 { break }
            title.unicodeScalars.append(scalar); units += scalar.utf16.count
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["id": .string(UUID().uuidString.lowercased()), "title": .string(title), "updated": .string(formatter.string(from: Date())),
                "messages": [], "requests": []]
    }

    /// Records a request in the thread (replacing one with the same id) and in the request index.
    public func remember(_ thread: inout JSONValue, _ request: JSONValue) {
        var object = thread.object ?? [:]
        var requests = object["requests"]?.array ?? []
        if let at = requests.firstIndex(where: { $0["id"] == request["id"] }) { requests[at] = request } else { requests.append(request) }
        object["requests"] = .array(requests)
        thread = .object(object)
        if let id = request["id"]?.string, var indexed = request.object {
            indexed["threadId"] = thread["id"] ?? .null
            lock.lock(); requestIndex[id] = .object(indexed); lock.unlock()
        }
    }
}

/// Whether a saved conversation has the shape and limits the app wrote it with.
public func validThread(_ thread: JSONValue, _ id: String) -> Bool {
    guard let t = thread.object, t["id"]?.string == id, let title = t["title"]?.string, title.utf16.count <= 200,
          let updated = t["updated"]?.string, parsesAsDate(updated),
          let messages = t["messages"]?.array, messages.count <= 1002, let requests = t["requests"]?.array else { return false }
    let messageStates: Set<String> = ["done", "writing", "interrupted", "error"]
    let requestStates: Set<String> = ["running", "done", "interrupted", "error"]
    for m in messages {
        guard let object = m.object, let mid = object["id"]?.string, History.validID(mid),
              let role = object["role"]?.string, role == "user" || role == "assistant",
              let content = object["content"]?.string, content.utf16.count <= 270000,
              let state = object["state"]?.string, messageStates.contains(state) else { return false }
    }
    for r in requests {
        guard let object = r.object, let rid = object["id"]?.string, History.validID(rid),
              let hash = object["hash"]?.string, historyHex(hash, count: 64, dashes: false),
              let state = object["state"]?.string, requestStates.contains(state) else { return false }
    }
    return true
}
