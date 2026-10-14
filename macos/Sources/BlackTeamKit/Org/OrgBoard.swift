import Foundation

// Working from an Obsidian board. The organization can be linked to a board folder of ticket notes (see OrgBoardNote.swift for the format) that
// other agents (Claude Code, Codex, Hermes) work from too. While it is working, a free `ready` note becomes one of its tickets: Black Team
// claims it with an owner and a lease, runs it through the usual stages on its own branch (`org/T-7-...`), writes the stage, the role, the
// branch, a Log line per step and a link to each artifact back into the note, stops at the organization's gates, and never merges or pushes.
//
// The rules that keep it from stepping on anyone:
//   - a note held by another owner with a live lease is never touched, except for a Log line about Black Team's own work;
//   - a claim is taken only after reading the note, and given up if the note changed under it (compare-and-set), and every write goes to a
//     temporary file in the same folder and is renamed over the note, keeping the owner's file mode, so a note is never half written;
//   - only Black Team's own claims are renewed (every 30 minutes, for 2 hours) or released (on stop, pause and quit);
//   - nothing is deleted or renamed; notes without valid front matter are ignored and listed;
//   - if the folder goes away or cannot be written, Black Team stops and leaves a note in the Inbox.
// The text edits themselves are BoardNote's. This file is the link, the claim, the write-back and the loop's board step.

/// The board an organization takes tickets from: only paths and two switches, no secrets.
public struct OrgBoard: Codable, Equatable, Sendable {
    /// The board folder (it holds `Tickets/`, and Black Team makes `Artifacts/` in it).
    public var folder: String
    /// The git repository the work happens in.
    public var repo: String
    /// "Put my local models to work" is on.
    public var working: Bool = false
    /// Also take `backlog` tickets, not only `ready` ones.
    public var takeBacklog: Bool = false

    public init(folder: String, repo: String, working: Bool = false, takeBacklog: Bool = false) {
        self.folder = folder; self.repo = repo; self.working = working; self.takeBacklog = takeBacklog
    }
}

/// What the Organization page needs to show the board card.
public struct OrgBoardInfo: Codable, Equatable, Sendable {
    public var folder: String
    public var repo: String
    public var working: Bool
    public var takeBacklog: Bool
    /// The name Black Team writes as `owner` (`black-team-local@<computer>`).
    public var owner: String
    public var reachable: Bool
    public var problem: String
    /// "Working on T-7: Build", "Waiting for you on T-3", "Idle: no ready tickets".
    public var statusText: String
    /// The board tickets Black Team holds right now.
    public var holding: [String]
}

public struct OrgBoardRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var stage: String
    public var priority: String
    public var owner: String
    public var leaseUntil: String
    public var file: String
    /// free, mine or other (held by another owner with a lease that has not run out).
    public var holder: String
}

public struct OrgBoardStatus: Codable, Equatable, Sendable {
    public var info: OrgBoardInfo
    public var rows: [OrgBoardRow]
    /// Notes without usable front matter, with the reason.
    public var ignored: [String]
}

/// What working from a board keeps in memory between ticks. The closures are for tests: they stand in for a concurrent writer and a failing disk.
final class OrgBoardRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var _skew: TimeInterval = 0
    private var _host: String?
    private var _beforeRename: ((String) throws -> Void)?
    private var _scanEvery: TimeInterval = 10
    private var _lastScan: Date?
    private var _keepAlive: [String: Date] = [:]
    private var _told = Set<String>()
    let io = NSRecursiveLock()

    /// Seconds added to the clock (tests move time forward).
    var skew: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return _skew } set { lock.lock(); _skew = newValue; lock.unlock() } }
    var host: String? { get { lock.lock(); defer { lock.unlock() }; return _host } set { lock.lock(); _host = newValue; lock.unlock() } }
    /// Called with the note's path after its new text is on disk in a temporary file and before it replaces the note.
    var beforeRename: ((String) throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return _beforeRename } set { lock.lock(); _beforeRename = newValue; lock.unlock() } }
    var scanEvery: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return _scanEvery } set { lock.lock(); _scanEvery = newValue; lock.unlock() } }
    var lastScan: Date? { get { lock.lock(); defer { lock.unlock() }; return _lastScan } set { lock.lock(); _lastScan = newValue; lock.unlock() } }
    func keepAlive(_ key: String) -> Date? { lock.lock(); defer { lock.unlock() }; return _keepAlive[key] }
    func setKeepAlive(_ key: String, _ date: Date) { lock.lock(); _keepAlive[key] = date; lock.unlock() }
    /// True the first time a message is told, so the Inbox is told once.
    func tell(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _told.insert(key).inserted }
    func forget(prefix: String) { lock.lock(); _told = _told.filter { !$0.hasPrefix(prefix) }; lock.unlock() }
}

/// One note on the board as read.
struct BoardEntry {
    var file: String
    var path: String
    var data: Data
    var note: BoardNote
}

enum BoardIO {
    static let largest = 512 * 1024
    static let lease: TimeInterval = 2 * 3600
    /// A lease with less than this left is renewed (every 30 minutes of a 2 hour lease).
    static let renewBelow: TimeInterval = 90 * 60

    /// A plain file Black Team may read: not a link (a link could lead out of the folder), not large.
    static func read(_ path: String) -> Data? {
        let info = CoreFS.stat(path)
        guard info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= largest, !CoreFS.isSymlink(path) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Replaces the note if it still holds exactly `expected`. The new text goes to a hidden temporary file in the same folder with the note's
    /// own file mode, is checked against the note once more, and is renamed over it. False when the note changed meanwhile (nothing is written);
    /// a failure leaves the note as it was and removes the temporary file.
    static func commit(_ path: String, expected: Data, new: Data, beforeRename: ((String) throws -> Void)?) throws -> Bool {
        guard read(path) == expected else { return false }
        let mode = CoreFS.stat(path).mode & 0o7777
        let folder = (path as NSString).deletingLastPathComponent
        let temporary = folder + "/." + (path as NSString).lastPathComponent + "." + CoreFS.hex(6) + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw BlackTeamError("Could not write to the board folder: \(CoreFS.errnoName(errno)).") }
        var isOpen = true
        do {
            try new.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw BlackTeamError("Could not write to the board folder: \(CoreFS.errnoName(errno)).")
                    }
                    offset += written
                }
            }
            fchmod(fd, mode)
            fsync(fd); close(fd); isOpen = false
            try beforeRename?(path)
            // Someone else wrote in the meantime: back off and leave their text.
            guard read(path) == expected else { unlink(temporary); return false }
            if rename(temporary, path) != 0 { throw BlackTeamError("Could not write to the board folder: \(CoreFS.errnoName(errno)).") }
            return true
        } catch {
            if isOpen { close(fd) }
            unlink(temporary)
            throw error
        }
    }
}

extension Backend {
    // MARK: Names and time

    func orgBoardNow() -> Date { now().addingTimeInterval(orgBoardRuntime.skew) }

    /// `black-team-local@<computer>`: who Black Team writes as the owner of a ticket it holds.
    func orgBoardOwner() -> String {
        let raw = orgBoardRuntime.host ?? ProcessInfo.processInfo.hostName
        let first = raw.split(separator: ".").first.map(String.init) ?? raw
        let clean = String(first.unicodeScalars.filter { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_" })
        return "black-team-local@" + (clean.isEmpty ? "this-computer" : clean)
    }

    func orgBoardTickets(_ projectId: String) -> [OrgTicket] { orgTickets(projectId).filter { $0.boardId != nil } }

    private func tickets(_ board: OrgBoard) -> String { board.folder + "/Tickets" }
    private func artifacts(_ board: OrgBoard) -> String { board.folder + "/Artifacts" }

    // MARK: Checking a folder

    private func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    private func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private func inside(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/") }

    /// Why a board folder cannot be used, or nil. Also run on every tick, so a folder that goes away or stops being writable is noticed.
    func orgBoardReach(_ board: OrgBoard) -> String? {
        guard isDirectory(board.folder) else { return "The board folder is not there any more: \(board.folder)" }
        guard access(board.folder, R_OK | W_OK | X_OK) == 0 else { return "Black Team cannot read and write the board folder: \(board.folder)" }
        for name in ["Tickets", "Artifacts"] {
            let child = board.folder + "/" + name
            if CoreFS.isSymlink(child) {
                guard let real = realPath(child), let top = realPath(board.folder), inside(real, top) else { return "The board's \(name) folder leads outside the board folder, so Black Team will not use it." }
            }
        }
        if isDirectory(tickets(board)), access(tickets(board), R_OK | W_OK | X_OK) != 0 { return "Black Team cannot read and write the board's Tickets folder." }
        return nil
    }

    /// Checks a folder and a repository for a board and returns them as they will be stored (folder and repository as real paths).
    func orgBoardValidate(folder rawFolder: String, repo rawRepo: String?, project: Project) throws -> (folder: String, repo: String) {
        let given = EText.trim(rawFolder)
        guard given.hasPrefix("/") else { throw BlackTeamError("Choose the board folder (a full path, such as /home/you/Notes/Black Team Org/Board).") }
        guard isDirectory(given), let real = realPath(given) else { throw BlackTeamError("That board folder does not exist: \(given)") }
        if CoreFS.isSymlink(given.hasSuffix("/") ? String(given.dropLast()) : given) { throw BlackTeamError("The board folder is a link to somewhere else. Choose the folder itself.") }
        guard access(real, R_OK | W_OK | X_OK) == 0 else { throw BlackTeamError("Black Team cannot read and write that folder. Choose one you can change.") }
        let data = realPath(dataFolder) ?? dataFolder
        if inside(real, data) || inside(data, real) { throw BlackTeamError("The board cannot be inside Black Team's own data folder, or hold it.") }
        if let why = orgBoardReach(OrgBoard(folder: real, repo: "")) { throw BlackTeamError(why) }
        let repoGiven = EText.trim(rawRepo ?? "")
        let candidate = repoGiven.isEmpty ? project.workspace : repoGiven
        guard candidate.hasPrefix("/"), isDirectory(candidate), let repoReal = realPath(candidate) else { throw BlackTeamError("That repository folder does not exist: \(candidate)") }
        guard OrgGit.toplevel(repoReal) != nil else {
            throw BlackTeamError(repoGiven.isEmpty ? "\(project.name) is not a git repository, so work cannot be kept on branches. Choose a repository with --repo." : "That folder is not a git repository: \(repoReal)")
        }
        if inside(repoReal, data) { throw BlackTeamError("The repository cannot be inside Black Team's own data folder.") }
        return (real, repoReal)
    }

    // MARK: Reading the board

    func orgBoardRead(_ board: OrgBoard, file: String) -> BoardEntry? {
        guard !file.contains("/"), !file.hasPrefix(".") else { return nil }
        let path = tickets(board) + "/" + file
        guard let data = BoardIO.read(path) else { return nil }
        return BoardEntry(file: file, path: path, data: data, note: BoardNote(String(decoding: data, as: UTF8.self)))
    }

    /// Every note in `Tickets/` that has usable front matter, and the files that were left alone with the reason.
    func orgBoardScan(_ board: OrgBoard) -> (entries: [BoardEntry], ignored: [String]) {
        var entries: [BoardEntry] = [], ignored: [String] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: tickets(board))) ?? []).sorted()
        var seen = Set<String>()
        for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") && entries.count + ignored.count < 1000 {
            let path = tickets(board) + "/" + name
            if CoreFS.isSymlink(path) { ignored.append("\(name): a link, not a note"); continue }
            guard let data = BoardIO.read(path) else { ignored.append("\(name): not readable, or too large"); continue }
            let note = BoardNote(String(decoding: data, as: UTF8.self))
            guard note.valid else { ignored.append("\(name): no front matter with an id"); continue }
            guard seen.insert(note.id).inserted else { ignored.append("\(name): another note already has the id \(note.id)"); continue }
            entries.append(BoardEntry(file: name, path: path, data: data, note: note))
        }
        return (entries, ignored)
    }

    /// The candidates in the order Black Team takes them: highest priority first, then the oldest.
    func orgBoardCandidates(_ entries: [BoardEntry], board: OrgBoard, at moment: Date, skipping: Set<String>) -> [BoardEntry] {
        entries.filter { e in
            let status = e.note.status
            return (status == "ready" || (board.takeBacklog && status == "backlog")) && e.note.free(at: moment) && !skipping.contains(e.note.id)
        }.sorted { a, b in
            if a.note.rank != b.note.rank { return a.note.rank < b.note.rank }
            let da = a.note.created ?? .distantFuture, db = b.note.created ?? .distantFuture
            if da != db { return da < db }
            return a.file < b.file
        }
    }

    // MARK: Claiming, renewing, releasing

    /// A stage as the note writes it: `Intake` when the note's own stage starts with a capital, `intake` otherwise.
    static func stageWord(_ stage: String, like existing: String) -> String {
        guard existing.first?.isUppercase == true, let s = OrgStage(rawValue: stage) else { return stage }
        return s.title
    }

    private func touch(_ note: inout BoardNote, _ moment: Date) {
        let existing = note.field("updated")
        guard !existing.isEmpty else { return }
        note.set("updated", existing.count <= 10 ? String(BoardTime.stamp(moment).prefix(10)) : BoardTime.stamp(moment))
    }

    /// Takes a free note: reads it, writes the claim only if it is still exactly what was read, then reads it again to see that the claim stands.
    /// Nil when it was not free, changed meanwhile, or another owner won.
    func orgBoardClaim(_ board: OrgBoard, file: String, stage: String, text: String) -> BoardEntry? {
        orgBoardRuntime.io.lock(); defer { orgBoardRuntime.io.unlock() }
        let me = orgBoardOwner(), moment = orgBoardNow()
        guard let entry = orgBoardRead(board, file: file), entry.note.valid, entry.note.free(at: moment) else { return nil }
        var note = entry.note
        note.set("owner", me); note.set("claimed", BoardTime.stamp(moment)); note.set("lease_until", BoardTime.stamp(moment.addingTimeInterval(BoardIO.lease)))
        note.set("status", "in-progress"); note.set("stage", Self.stageWord(stage, like: note.field("stage")))
        touch(&note, moment)
        note.log(moment, who: me, text)
        guard (try? BoardIO.commit(entry.path, expected: entry.data, new: Data(note.text.utf8), beforeRename: orgBoardRuntime.beforeRename)) == true else { return nil }
        guard let after = orgBoardRead(board, file: file), after.note.owner == me else { return nil }
        orgBoardRuntime.setKeepAlive(board.folder + "|" + after.note.id, moment)
        return after
    }

    enum BoardHold { case held, free, other(String), gone }

    /// Renews Black Team's own claim when less than 90 minutes of the lease are left (every 30 minutes). Reports who holds the note.
    @discardableResult
    func orgBoardRenew(_ board: OrgBoard, file: String, force: Bool = false) -> BoardHold {
        orgBoardRuntime.io.lock(); defer { orgBoardRuntime.io.unlock() }
        let me = orgBoardOwner(), moment = orgBoardNow()
        for _ in 0..<3 {
            guard let entry = orgBoardRead(board, file: file), entry.note.valid else { return .gone }
            guard entry.note.owner == me else { return entry.note.free(at: moment) ? .free : .other(entry.note.owner) }
            if !force, let until = entry.note.leaseUntil, until.timeIntervalSince(moment) > BoardIO.renewBelow { return .held }
            var note = entry.note
            note.set("lease_until", BoardTime.stamp(moment.addingTimeInterval(BoardIO.lease)))
            if (try? BoardIO.commit(entry.path, expected: entry.data, new: Data(note.text.utf8), beforeRename: orgBoardRuntime.beforeRename)) == true {
                orgBoardRuntime.setKeepAlive(board.folder + "|" + entry.note.id, moment)
                return .held
            }
        }
        return .held
    }

    /// Gives up Black Team's own claim (stop, pause, quit) so another team can take the ticket over. A note held by someone else is not touched.
    func orgBoardRelease(_ board: OrgBoard, file: String, why: String) {
        orgBoardRuntime.io.lock(); defer { orgBoardRuntime.io.unlock() }
        let me = orgBoardOwner(), moment = orgBoardNow()
        for _ in 0..<3 {
            guard let entry = orgBoardRead(board, file: file), entry.note.valid, entry.note.owner == me else { return }
            var note = entry.note
            note.set("owner", ""); note.set("lease_until", "")
            // Work in progress goes back to the queue; a ticket waiting for the owner's decision stays in review.
            if note.status == "in-progress" { note.set("status", "ready") }
            touch(&note, moment)
            note.log(moment, who: me, "Released the ticket: \(why)")
            if (try? BoardIO.commit(entry.path, expected: entry.data, new: Data(note.text.utf8), beforeRename: orgBoardRuntime.beforeRename)) == true { return }
        }
    }

    /// Releases every board ticket Black Team holds in a project.
    func orgBoardReleaseAll(_ projectId: String, why: String) {
        guard let board = orgLoad(projectId)?.board else { return }
        for t in orgBoardTickets(projectId) where !t.finished { if let file = t.boardFile { orgBoardRelease(board, file: file, why: why) } }
    }

    // MARK: Writing back

    private static func marker(_ e: OrgEvent) -> String { e.at + "\u{1}" + e.text }

    /// What a ticket's state is called on the board.
    private func boardStatus(_ t: OrgTicket) -> String {
        switch t.state {
        case "gate": return "review"
        case "blocked", "cancelled": return "blocked"
        case "done": return "done"
        default: return "in-progress"
        }
    }

    /// Writes a ticket's progress into its note: the stage, role and branch and the status while Black Team holds it, and a Log line for every new
    /// event whoever holds it. Called after every change to a ticket that came from a board.
    func orgBoardPush(_ t: OrgTicket) {
        guard let id = t.boardId, let file = t.boardFile, let org = orgLoad(t.projectId), let board = org.board else { return }
        orgBoardRuntime.io.lock(); defer { orgBoardRuntime.io.unlock() }
        let me = orgBoardOwner(), moment = orgBoardNow()
        var start = 0
        if let mark = t.boardLogged, let at = t.history.lastIndex(where: { Self.marker($0) == mark }) { start = at + 1 }
        let fresh = Array(t.history[start...])
        let role = (t.currentRole.flatMap { org.role($0) } ?? orgStageRole(t.stage, org: org))?.name ?? ""
        for _ in 0..<3 {
            guard let entry = orgBoardRead(board, file: file), entry.note.valid, entry.note.id == id else { return }
            var note = entry.note
            let ours = note.owner == me
            if ours {
                note.set("status", boardStatus(t))
                if note.stage != t.stage.rawValue { note.set("stage", Self.stageWord(t.stage.rawValue, like: note.field("stage"))) }
                if !role.isEmpty, note.field("role") != role { note.set("role", role) }
                if let branch = t.branch, note.field("branch") != branch { note.set("branch", branch) }
                // A finished or stuck ticket is let go, so another team can pick it up.
                if t.state == "done" || t.state == "blocked" || t.state == "cancelled" { note.set("owner", ""); note.set("lease_until", "") }
            }
            for e in fresh {
                let when = BoardTime.parse(e.at) ?? moment
                var line = (e.stage.flatMap { OrgStage(rawValue: $0)?.title }.map { "\($0): " } ?? "") + e.text
                if let link = e.link { line += " [\((link as NSString).lastPathComponent)](../Artifacts/\(link))" }
                note.log(when, who: me, line)
            }
            if note.text == entry.note.text { break }
            touch(&note, moment)
            if (try? BoardIO.commit(entry.path, expected: entry.data, new: Data(note.text.utf8), beforeRename: orgBoardRuntime.beforeRename)) == true { break }
        }
        if let last = fresh.last {
            _ = try? orgTicketMutateQuiet(t.projectId, t.id) { $0.boardLogged = Self.marker(last) }
        }
    }

    // MARK: Artifacts

    /// The name an artifact has on the board.
    private func boardArtifactName(_ name: String) -> String {
        if name == "qa.md" { return "test-report.md" }
        if name.hasPrefix("qa-"), name.hasSuffix(".md") { return "test-report-" + name.dropFirst(3) }
        return name
    }

    private static let artifactMark = "<!-- written by black-team-local -->"

    /// Copies a ticket's artifact to `<board>/Artifacts/T-7/` (a Markdown file starts with a mark saying Black Team wrote it) and returns the
    /// path to link to. A file another agent already wrote there is never overwritten: Black Team's copy gets a name of its own.
    func orgBoardArtifact(_ t: OrgTicket, name: String, text: String) -> String? {
        guard let id = t.boardId, let board = orgLoad(t.projectId)?.board, orgBoardReach(board) == nil else { return nil }
        let root = artifacts(board), dir = root + "/" + id
        guard BoardNote.validID(id) else { return nil }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let real = realPath(dir), let top = realPath(board.folder), inside(real, top) else { return nil }
            let markdown = name.hasSuffix(".md")
            var target = boardArtifactName(name)
            let body = markdown ? Self.artifactMark + "\n" + text : text
            if let existing = BoardIO.read(dir + "/" + target) {
                let ours = markdown && String(decoding: existing.prefix(Self.artifactMark.utf8.count), as: UTF8.self) == Self.artifactMark
                if !ours {
                    let ext = (target as NSString).pathExtension
                    target = ((target as NSString).deletingPathExtension) + "-black-team." + ext
                }
            }
            let path = dir + "/" + target
            let temporary = dir + "/." + target + "." + CoreFS.hex(6) + ".tmp"
            try CoreFS.writeAtomic(path, Data(body.utf8), temporary: temporary)
            return id + "/" + target
        } catch { return nil }
    }

    /// Puts a stage's artifact on the board and says so in the note's Log, with a link. The diff also gets a short summary file.
    func orgBoardShare(_ t: OrgTicket, stage: OrgStage, name: String, title: String, text: String) {
        func record(_ shown: String, link: String) {
            _ = try? orgTicketMutate(t.projectId, t.id) { x in
                orgEvent(&x, stage: stage, "Saved \(shown).")
                x.history[x.history.count - 1].link = link
            }
        }
        if let link = orgBoardArtifact(t, name: name, text: text) { record(title, link: link) }
        if name.hasPrefix("diff"), name.hasSuffix(".patch"), let base = t.base, let root = orgMirrorRoot(t) {
            let stat = OrgGit.stat(root, base: base)
            let summary = "# Changes for \(t.label)\n\nBranch: `\(t.branch ?? "")`\n\n" + (stat.isEmpty ? "No files were changed." : "```\n\(stat)\n```") + "\n\nNothing is merged or pushed; merging the branch is up to you.\n"
            if let link = orgBoardArtifact(t, name: "diff-summary.md", text: summary) { record("the summary of the changes", link: link) }
        }
    }

    // MARK: The links Black Team makes

    private func orgBoardRequire(_ projectId: String) throws -> (org: Organization, board: OrgBoard, project: Project) {
        let project = try roomProject(projectId)
        let org = try orgRequire(projectId)
        guard let board = org.board else { throw BlackTeamError("\(project.name) is not linked to a board. Link one first.") }
        return (org, board, project)
    }

    /// Links the project's organization to a board folder and a repository (making the organization first when the project has none, with every
    /// role on the local model in use). Nothing is started.
    @discardableResult
    public func orgLink(projectId: String, folder: String, repo: String? = nil, takeBacklog: Bool = false) throws -> OrgState {
        let project = try roomProject(projectId)
        let checked = try orgBoardValidate(folder: folder, repo: repo, project: project)
        if orgLoad(projectId) == nil { try orgCreate(projectId: projectId, template: "software") }
        if let running = orgLoad(projectId)?.board, running.working { throw BlackTeamError("Stop working for the board before you change the link.") }
        try orgMutate(projectId) { $0.board = OrgBoard(folder: checked.folder, repo: checked.repo, working: false, takeBacklog: takeBacklog) }
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func orgBoardOptions(projectId: String, takeBacklog: Bool) throws -> OrgState {
        _ = try orgBoardRequire(projectId)
        try orgMutate(projectId) { $0.board?.takeBacklog = takeBacklog }
        return try orgState(projectId: projectId)
    }

    /// Takes the link away. Stops working first; tickets already taken from the board stay in the organization but no longer write to it.
    @discardableResult
    public func orgUnlink(projectId: String) throws -> OrgState {
        let (_, board, _) = try orgBoardRequire(projectId)
        if board.working { _ = try orgWork(projectId: projectId, on: false) }
        try orgMutate(projectId) { $0.board = nil }
        for t in orgBoardTickets(projectId) where !t.finished {
            _ = try? orgTicketMutateQuiet(projectId, t.id) { x in x.boardId = nil; x.boardFile = nil; x.boardLogged = nil; orgEvent(&x, "The board was unlinked, so this ticket stays here only.") }
        }
        return try orgState(projectId: projectId)
    }

    /// "Put my local models to work" on or off. On: the agreement is checked as for any start (all-local needs no yes; a paid role needs
    /// `confirmPaid`), and the organization starts taking tickets from the board. Off: the work stops, and every claim is given up.
    @discardableResult
    public func orgWork(projectId: String, on: Bool, confirmPaid: Bool = false) throws -> OrgState {
        let (org, board, project) = try orgBoardRequire(projectId)
        if on {
            if let why = orgBoardReach(board) { throw BlackTeamError(why) }
            guard OrgGit.toplevel(board.repo) != nil else { throw BlackTeamError("The repository is not there any more: \(board.repo)") }
            let agreement = orgAgreementBuild(org, project: project)
            if let first = agreement.problems.first { throw BlackTeamError(first) }
            if agreement.leavesThisMac && !confirmPaid {
                throw BlackTeamError("Some roles use a paid service, so work for the board needs your yes first. " + agreement.text)
            }
            orgBoardRuntime.forget(prefix: projectId)
            try orgMutate(projectId) { $0.board?.working = true }
            try orgStart(projectId: projectId, digest: agreement.digest)
        } else {
            try orgMutate(projectId) { o in o.board?.working = false; o.running = false; o.paused = false; o.pausedReason = "" }
            if let c = orgRuntime.current, c.project == projectId { orgRuntime.stopRequested = true; cancel() }
            orgBoardReleaseAll(projectId, why: "Black Team stopped working for the board.")
        }
        return try orgState(projectId: projectId)
    }

    // MARK: Showing it

    func orgBoardStatusText(_ org: Organization, board: OrgBoard, problem: String?) -> String {
        if let problem { return problem }
        if !board.working { return "Not working. Press Start working to put your local models to work." }
        if org.paused { return "Paused: " + (org.pausedReason.isEmpty ? "waiting for you" : org.pausedReason) }
        let mine = orgBoardTickets(org.projectId).filter { !$0.finished }
        if let c = orgRuntime.current, c.project == org.projectId, let t = mine.first(where: { $0.id == c.ticket }) { return "Working on \(t.label): \(t.stage.title)" }
        if let t = mine.first(where: { $0.state == "gate" }) { return "Waiting for you on \(t.label)" }
        if let t = mine.first(where: { $0.state == "running" || $0.state == "ready" }) { return "Next: \(t.label), \(t.stage.title)" }
        if let t = mine.first(where: { $0.state == "blocked" }) { return "\(t.label) is stuck: \(t.note)" }
        return "Idle: no ready tickets"
    }

    func orgBoardInfo(_ org: Organization) -> OrgBoardInfo? {
        guard let board = org.board else { return nil }
        let problem = orgBoardReach(board)
        return OrgBoardInfo(folder: board.folder, repo: board.repo, working: board.working, takeBacklog: board.takeBacklog, owner: orgBoardOwner(), reachable: problem == nil,
                            problem: problem ?? "", statusText: orgBoardStatusText(org, board: board, problem: problem), holding: orgBoardTickets(org.projectId).filter { !$0.finished }.map(\.label))
    }

    /// What the board holds and who owns what.
    public func orgBoardStatus(projectId: String) throws -> OrgBoardStatus {
        let (org, board, _) = try orgBoardRequire(projectId)
        let info = orgBoardInfo(org)!
        if info.reachable == false { return OrgBoardStatus(info: info, rows: [], ignored: []) }
        let scan = orgBoardScan(board)
        let me = orgBoardOwner(), moment = orgBoardNow()
        let rows = scan.entries.map { e -> OrgBoardRow in
            let n = e.note
            let holder = n.free(at: moment) ? "free" : (n.owner == me ? "mine" : "other")
            return OrgBoardRow(id: n.id, title: n.title, status: n.status, stage: n.stage, priority: n.priority, owner: n.owner, leaseUntil: n.field("lease_until"), file: e.file, holder: holder)
        }.sorted { a, b in
            let order = ["in-progress": 0, "review": 1, "ready": 2, "blocked": 3, "backlog": 4, "done": 5]
            if a.status != b.status { return (order[a.status] ?? 6) < (order[b.status] ?? 6) }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
        return OrgBoardStatus(info: info, rows: rows, ignored: scan.ignored)
    }
}
