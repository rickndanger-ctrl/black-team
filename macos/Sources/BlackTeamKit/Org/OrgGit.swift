import Foundation

// The git side of an organization: each ticket's engineering work happens on its own branch in its own worktree, so the person's branch and
// working folder are never touched. Black Team runs `git` with a fixed argument list (never through a shell) and reads only what it prints.

enum OrgGit {
    struct Result { var status: Int32; var output: String; var ok: Bool { status == 0 } }

    /// A branch name Black Team made itself: letters, digits and dashes under `black-team/`.
    static func branchName(number: Int, title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) { slug.unicodeScalars.append(scalar) }
            else if !slug.hasSuffix("-") { slug += "-" }
            if slug.count >= 32 { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "black-team/t\(number)" + (slug.isEmpty ? "" : "-" + slug)
    }

    static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 120) -> Result {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: 127, output: "git could not be started.") }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func line(_ arguments: [String], in directory: String) -> String? {
        let r = run(arguments, in: directory)
        let text = EText.trim(r.output)
        return r.ok && !text.isEmpty ? text : nil
    }

    /// The top folder of the repository this folder is in, or nil when it is not in one.
    static func toplevel(_ directory: String) -> String? { line(["rev-parse", "--show-toplevel"], in: directory) }
    /// The folder's path inside the repository, with a trailing slash ("" at the top).
    static func prefix(_ directory: String) -> String { line(["rev-parse", "--show-prefix"], in: directory) ?? "" }
    static func head(_ directory: String) -> String? { line(["rev-parse", "--verify", "HEAD"], in: directory) }
    static func currentBranch(_ directory: String) -> String? { line(["symbolic-ref", "--short", "-q", "HEAD"], in: directory) }

    /// Makes the ticket's branch from `base` and a worktree for it. Nothing in the person's checkout changes.
    static func addWorktree(repo: String, path: String, branch: String, base: String) throws {
        let r = run(["worktree", "add", "-q", "-b", branch, path, base], in: repo)
        if !r.ok { throw BlackTeamError("The branch for this ticket could not be made: \(EText.prefix(EText.trim(r.output), 200))") }
    }

    /// Commits everything in the worktree as Black Team. True when something was committed. Hooks are skipped and no identity is needed.
    @discardableResult
    static func commitAll(_ directory: String, message: String) -> Bool {
        guard run(["add", "-A"], in: directory).ok else { return false }
        let pending = run(["status", "--porcelain"], in: directory)
        if !pending.ok || EText.trim(pending.output).isEmpty { return false }
        let r = run(["-c", "user.name=Black Team", "-c", "user.email=black-team@localhost", "-c", "commit.gpgsign=false",
                     "commit", "-q", "--no-verify", "-m", message], in: directory)
        return r.ok
    }

    static func diff(_ directory: String, base: String) -> String { run(["diff", "--no-color", "\(base)..HEAD"], in: directory).output }
    static func stat(_ directory: String, base: String) -> String { EText.trim(run(["diff", "--stat", "--no-color", "\(base)..HEAD"], in: directory).output) }
    static func files(_ directory: String, base: String) -> [String] {
        run(["diff", "--name-only", "\(base)..HEAD"], in: directory).output.split(separator: "\n").map(String.init)
    }
    static func log(_ directory: String, base: String) -> String { EText.trim(run(["log", "--oneline", "--no-color", "\(base)..HEAD"], in: directory).output) }

    /// Adds a line to the repository's local exclude file (`.git/info/exclude`), so Black Team's folder never shows in the person's `git status`.
    static func exclude(repo: String, pattern: String) {
        guard let path = line(["rev-parse", "--git-path", "info/exclude"], in: repo) else { return }
        let file = path.hasPrefix("/") ? path : repo + "/" + path
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        if current.split(separator: "\n").contains(where: { $0 == Substring(pattern) }) { return }
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }

    static func removeWorktree(repo: String, path: String) {
        _ = run(["worktree", "remove", "--force", path], in: repo)
    }
}
