import Foundation

/// A copy of a workspace folder taken before each subscription-agent run, so the run can be undone.
///
/// The archive is `<data>/agent-snapshots/<thread id>/<run id>.tar` (private). It holds the files of the folder, leaving out
/// the folders that are rebuilt or are not the person's work (`.git`, `node_modules`, `.build`, `build`, `dist`, `DerivedData`).
/// A folder that is too large is not archived at all; the run goes ahead and its message says so.
public struct AgentSnapshots: Sendable {
    public static let excludedFolders: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData"]
    public static let maxBytes: Int64 = 200 * 1024 * 1024
    public static let maxFiles = 20_000
    /// The newest snapshots kept per conversation.
    public static let keepPerConversation = 5

    public enum Outcome: Equatable, Sendable {
        case saved(files: Int)
        /// Not archived, with the reason for the person.
        case skipped(String)
    }

    /// What a rollback changed: files written back from the snapshot, and files the task created that were removed.
    public struct Restored: Equatable, Sendable {
        public var restored: [String]
        public var removed: [String]
    }

    let root: String

    public init(dataFolder: String) {
        root = dataFolder + "/agent-snapshots"
    }

    private func conversationFolder(_ threadId: String) -> String { root + "/" + threadId }
    private func archivePath(_ threadId: String, _ runId: String) -> String { conversationFolder(threadId) + "/" + runId + ".tar" }

    /// Whether a snapshot exists for this run.
    public func exists(threadId: String, runId: String) -> Bool {
        History.validID(threadId) && History.validID(runId) && FileManager.default.fileExists(atPath: archivePath(threadId, runId))
    }

    /// Archives the workspace as it is now, before the run. Keeps only the newest snapshots of the conversation.
    public func take(threadId: String, runId: String, workspace: String) throws -> Outcome {
        guard History.validID(threadId), History.validID(runId) else { throw BlackTeamError("This task cannot be saved for rollback.") }
        let scan = try Self.scan(workspace)
        if scan.bytes > Self.maxBytes {
            return .skipped("This task was not saved for rollback: the project folder is larger than 200 MB.")
        }
        if scan.files.count > Self.maxFiles {
            return .skipped("This task was not saved for rollback: the project folder has more than 20,000 files.")
        }
        let folder = conversationFolder(threadId)
        try privateDirectory(root)
        try privateDirectory(folder)
        let final = archivePath(threadId, runId)
        let partial = final + ".partial"
        let list = folder + "/." + runId + ".list"
        // Each file is listed by name, NUL-separated, so no name is read as an option and no folder is walked twice.
        let names = scan.files.map(\.path).joined(separator: "\0") + (scan.files.isEmpty ? "" : "\0")
        guard FileManager.default.createFile(atPath: list, contents: Data(names.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw BlackTeamError("The project could not be saved for rollback.")
        }
        defer { try? FileManager.default.removeItem(atPath: list) }
        // The file is created private before tar writes into it, so the archive is never readable by others.
        try? FileManager.default.removeItem(atPath: partial)
        guard FileManager.default.createFile(atPath: partial, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BlackTeamError("The project could not be saved for rollback.")
        }
        let status = try runTar(["--null", "-c", "-f", partial, "-C", workspace, "-T", list])
        guard status == 0 else {
            try? FileManager.default.removeItem(atPath: partial)
            throw BlackTeamError("The project could not be saved for rollback.")
        }
        try? FileManager.default.removeItem(atPath: final)
        try FileManager.default.moveItem(atPath: partial, toPath: final)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: final)
        prune(folder)
        return .saved(files: scan.files.count)
    }

    /// Puts the folder back as it was before the run: files that changed are written back from the archive, and files the run
    /// created that are not in the archive are removed. Folders are listed, never deleted. Nothing outside the folder is touched.
    public func restore(threadId: String, runId: String, workspace: String) throws -> Restored {
        guard exists(threadId: threadId, runId: runId) else {
            throw BlackTeamError("There is no saved state for this task. Only the newest \(Self.keepPerConversation) tasks in a conversation can be rolled back.")
        }
        let work = root + "/.restore-" + randomHex(8)
        try privateDirectory(work)
        defer { try? FileManager.default.removeItem(atPath: work) }
        guard try runTar(["-x", "-f", archivePath(threadId, runId), "-C", work]) == 0 else {
            throw BlackTeamError("The saved state for this task could not be read.")
        }
        let saved = try Self.scan(work).files
        let savedPaths = Set(saved.map(\.path))
        let current = try Self.scan(workspace).files
        let fm = FileManager.default
        var removed: [String] = []
        for file in current where !savedPaths.contains(file.path) {
            try fm.removeItem(atPath: workspace + "/" + file.path)
            removed.append(file.path)
        }
        var restored: [String] = []
        for file in saved {
            let source = work + "/" + file.path, target = workspace + "/" + file.path
            if file.isLink {
                let destination = try fm.destinationOfSymbolicLink(atPath: source)
                if (try? fm.destinationOfSymbolicLink(atPath: target)) == destination { continue }
                try? fm.removeItem(atPath: target)
                try Self.ensureParent(target)
                try fm.createSymbolicLink(atPath: target, withDestinationPath: destination)
                restored.append(file.path)
                continue
            }
            if fm.fileExists(atPath: target), fm.contentsEqual(atPath: source, andPath: target) { continue }
            try? fm.removeItem(atPath: target)
            try Self.ensureParent(target)
            try fm.copyItem(atPath: source, toPath: target)
            restored.append(file.path)
        }
        return Restored(restored: restored.sorted(), removed: removed.sorted())
    }

    /// Keeps the newest archives of a conversation and removes the rest.
    private func prune(_ folder: String) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".tar") }
        let dated = names.map { name -> (String, Date) in
            let date = (try? fm.attributesOfItem(atPath: folder + "/" + name)[.modificationDate] as? Date) ?? .distantPast
            return (name, date ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in dated.dropFirst(Self.keepPerConversation) { try? fm.removeItem(atPath: folder + "/" + name) }
    }

    private static func ensureParent(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    struct Entry: Equatable {
        var path: String
        var bytes: Int64
        var isLink: Bool
    }

    struct Scan {
        var files: [Entry]
        var bytes: Int64
    }

    /// The files and links of a folder, relative to it, leaving out the excluded folders wherever they are.
    static func scan(_ folder: String) throws -> Scan {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: []) else {
            throw BlackTeamError("The project folder could not be read.")
        }
        var files: [Entry] = []
        var bytes: Int64 = 0
        let prefix = base.standardizedFileURL.path + "/"
        while let url = walker.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true, !(values.isSymbolicLink ?? false) {
                if excludedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let isLink = values.isSymbolicLink ?? false
            let size = isLink ? 0 : Int64(values.fileSize ?? 0)
            files.append(Entry(path: path, bytes: size, isLink: isLink))
            bytes += size
        }
        return Scan(files: files.sorted { $0.path < $1.path }, bytes: bytes)
    }

    /// Runs the system archiver with no shell, and returns its exit status.
    private func runTar(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw BlackTeamError("The project could not be saved for rollback.") }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
