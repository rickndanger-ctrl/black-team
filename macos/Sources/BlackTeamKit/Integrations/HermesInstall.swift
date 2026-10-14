import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Installs Hermes Agent (github.com/NousResearch/hermes-agent, MIT) into Black Team's own data folder, when the person approves it
// in the setup plan. It never touches ~/.hermes or a Hermes the person installed themselves.
//
//   <data>/hermes/hermes-agent    the source, from a pinned GitHub source archive, with its venv/ inside
//   <data>/hermes/cache, python   uv's and pip's caches and a Python uv fetched (nothing is written to the user's own caches)
//   <data>/hermes/home            HERMES_HOME while installing
//   <data>/hermes/install.json    which commit is unpacked, and whether the install finished
//
// A conversation's own Hermes profile lives in <data>/hermes/<thread id>, beside these.

/// One GitHub source archive of Hermes Agent: what it is, where it comes from and the SHA-256 it must have.
public struct HermesArchive: Equatable, Sendable {
    public var commit: String
    public var url: URL
    public var sha256: String
    public var bytes: Int64

    public init(commit: String, url: URL, sha256: String, bytes: Int64) {
        self.commit = commit; self.url = url; self.sha256 = sha256; self.bytes = bytes
    }

    /// GitHub names the single top-level folder of a source archive `<repo>-<commit>`.
    public var topFolder: String { "hermes-agent-" + commit }

    /// The commit the adapter (scripts/agent-runner.py) was written against, checked on 2026-10-13: it exists upstream
    /// (2026-10-03, MIT licence), its source archive has the files `inspectHermes` looks for (hermes_bootstrap.py, cli.py,
    /// pyproject.toml) and everything agent-runner.py imports loads from a virtual environment built from it.
    /// The archive is GitHub's generated one, fetched over HTTPS from github.com (redirected to codeload.github.com).
    public static let pinned = HermesArchive(
        commit: "158fd638da1629c8e62caf9ade1515d162def8ab",
        url: URL(string: "https://github.com/NousResearch/hermes-agent/archive/158fd638da1629c8e62caf9ade1515d162def8ab.tar.gz")!,
        sha256: "f8c7bbf18b01421b025adc873b83928d34f986971bfaaa475d4356aa727c7757",
        bytes: 78_826_789)
}

/// What is on this computer to build Hermes's Python environment with. Only found, never run.
public struct HermesTooling: Equatable, Sendable {
    /// `uv`, which can also fetch the Python it needs; empty when not found.
    public var uv: String
    /// `python3.14`, else `python3`, else `python`; empty when none was found.
    public var python: String
    public init(uv: String = "", python: String = "") { self.uv = uv; self.python = python }

    public var isAvailable: Bool { !uv.isEmpty || !python.isEmpty }

    /// What to tell a person who has neither.
    public static let missingMessage = "Hermes Agent needs Python 3.14, and no Python was found on this computer. Install Python 3.14 (your system's package manager has it) or the uv tool (docs.astral.sh/uv), then try again."
}

/// Looks for uv and Python on the command path, the way the rest of discovery does, without running anything.
public func findHermesTooling(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment) -> HermesTooling {
    let dirs = harnessSearchPaths(home: home, env: env) + ["/usr/bin", "/bin"]
    let python = ["python3.14", "python3", "python"].map { findExecutable($0, in: dirs) }.first { !$0.isEmpty } ?? ""
    return HermesTooling(uv: findExecutable("uv", in: dirs), python: python)
}

public enum HermesInstallEvent: Sendable, Equatable {
    case checking
    case downloading(DownloadProgress)
    case verifying
    case unpacking
    case creatingEnvironment
    /// Python packages arrive one by one; `count` is how many have been named so far.
    case installingPackages(count: Int)
    case done(HermesInstall)
}

/// What the setup plan needs from an installer, so tests can use a fake.
public protocol HermesInstalling: Sendable {
    func install(progress: (@Sendable (HermesInstallEvent) -> Void)?) async throws -> HermesInstall
    func cancel()
}

/// Runs a program to completion with its output, stopping it if the task is cancelled. Tests replace it so nothing real runs.
public protocol SetupCommandRunning: Sendable {
    /// `onLine` sees each line of output as it arrives. Returns the exit status and the last lines of output.
    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int32, tail: String)
}

private final class RunningProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var tailLines: [String] = []
    private var partial = ""
    private var stopped = false
    var tail: String { lock.lock(); defer { lock.unlock() }; return tailLines.joined(separator: "\n") }
    var wasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func feed(_ data: Data, onLine: @Sendable (String) -> Void) {
        var lines: [String] = []
        lock.lock()
        partial += String(decoding: data, as: UTF8.self)
        while let end = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(partial[..<end]).trimmingCharacters(in: .whitespaces)
            partial = String(partial[partial.index(after: end)...])
            if !line.isEmpty { lines.append(line); tailLines.append(line); if tailLines.count > 20 { tailLines.removeFirst() } }
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}

public struct SystemCommandRunner: SetupCommandRunning {
    /// A step that has not finished by then is stopped.
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 20 * 60) { self.timeout = timeout }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int32, tail: String) {
        let running = RunningProcess()
        let process = running.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { running.feed(data, onLine: onLine) }
        }
        let timer = DispatchWorkItem { running.stop() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: BlackTeamError("\((executable as NSString).lastPathComponent) could not be started: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        } onCancel: { running.stop() }
        timer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { running.feed(rest + Data("\n".utf8), onLine: onLine) }
        if Task.isCancelled { throw CancellationError() }
        return (status, running.tail)
    }
}

private final class PackageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// The marker `install.json` in the Hermes folder.
struct HermesInstallRecord: Codable, Equatable {
    var commit: String
    var sha256: String
    /// "unpacked" once the source is in place, "ready" once its Python environment is built.
    var state: String
}

public final class HermesInstaller: HermesInstalling, @unchecked Sendable {
    public let dataFolder: String
    private let downloader: FileDownloading
    private let runner: SetupCommandRunning
    private let archive: HermesArchive
    private let toolingOverride: HermesTooling?
    private let home: String
    private let environment: [String: String]

    /// `downloader`, `runner` and `tooling` are injectable for tests.
    public init(dataFolder: String, archive: HermesArchive = .pinned, downloader: FileDownloading = Downloader(),
                runner: SetupCommandRunning = SystemCommandRunner(), tooling: HermesTooling? = nil,
                home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.dataFolder = dataFolder; self.archive = archive; self.downloader = downloader; self.runner = runner
        self.toolingOverride = tooling; self.home = home; self.environment = environment
    }

    public static func root(dataFolder: String) -> String { dataFolder + "/hermes" }
    /// Where the source lands, so discovery and the connect step can look there.
    public static func sourceFolder(dataFolder: String) -> String { root(dataFolder: dataFolder) + "/hermes-agent" }
    /// The tool store Hermes uses for this install (see HermesRunner); kept apart from the person's own `~/.hermes/tools`.
    public static func toolStore(dataFolder: String) -> String { root(dataFolder: dataFolder) + "/tools" }

    private var root: String { Self.root(dataFolder: dataFolder) }
    private var source: String { Self.sourceFolder(dataFolder: dataFolder) }
    private var recordFile: String { root + "/install.json" }

    /// The install in Black Team's folder if it is complete, else nil.
    public func installed() -> HermesInstall? {
        guard let record = readRecord(), record.state == "ready" else { return nil }
        return inspectHermes(source: source)
    }

    public func cancel() { downloader.cancel() }

    private func readRecord() -> HermesInstallRecord? {
        FileManager.default.contents(atPath: recordFile).flatMap { try? JSONDecoder().decode(HermesInstallRecord.self, from: $0) }
    }

    private func writeRecord(_ state: String) throws {
        let record = HermesInstallRecord(commit: archive.commit, sha256: archive.sha256, state: state)
        try CoreFS.writeAtomic(recordFile, try JSONEncoder().encode(record), temporary: recordFile + ".\(CoreFS.hex(10)).tmp")
    }

    private func buildEnvironment() -> [String: String] {
        var env = localEnvironment(environment)
        env["PATH"] = (harnessSearchPaths(home: home, env: environment) + ["/usr/bin", "/bin"]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        // Everything the tools write stays in Black Team's folder.
        env["HERMES_HOME"] = root + "/home"
        env["HERMES_RUNTIME_DIR"] = Self.toolStore(dataFolder: dataFolder)
        env["UV_CACHE_DIR"] = root + "/cache/uv"
        env["UV_PYTHON_INSTALL_DIR"] = root + "/python"
        env["PIP_CACHE_DIR"] = root + "/cache/pip"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["UV_NO_PROGRESS"] = "1"
        env["NO_COLOR"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        return env
    }

    /// Downloads, checks and unpacks the pinned source if it is not already in place, then builds its Python environment.
    /// A failed run leaves what is finished (the download keeps its progress; an unpacked source is reused), so trying again resumes.
    @discardableResult
    public func install(progress: (@Sendable (HermesInstallEvent) -> Void)? = nil) async throws -> HermesInstall {
        progress?(.checking)
        let tooling = toolingOverride ?? findHermesTooling(home: home, env: environment)
        // Fail before downloading 80 MB that cannot be used.
        guard tooling.isAvailable else { throw BlackTeamError(HermesTooling.missingMessage) }
        let fm = FileManager.default
        try privateDirectory(root)
        let env = buildEnvironment()

        let record = readRecord()
        let unpacked = record?.commit == archive.commit && inspectSource(source)
        if !unpacked {
            let downloads = root + "/downloads"
            let staging = root + "/.staging"
            let file = URL(fileURLWithPath: downloads + "/hermes-\(archive.commit).tar.gz")
            defer { try? fm.removeItem(atPath: staging) }
            _ = try await downloader.download(
                DownloadRequest(url: archive.url, destination: file, expectedSHA256: archive.sha256, expectedSize: archive.bytes,
                                allowedHostSuffixes: DownloadHosts.githubArchive),
                progress: { progress?(.downloading($0)) })
            progress?(.verifying)
            // The downloader checks the hash too; this is the check that holds whatever downloader was used.
            let actual = try await Task.detached(priority: .utility) { try Downloader.sha256(of: file) }.value
            guard actual == archive.sha256.lowercased() else {
                try? fm.removeItem(at: file)
                throw BlackTeamError("The Hermes Agent download did not match its checksum, so it was deleted and nothing was installed. Please try again; if it keeps happening the download may have been tampered with.")
            }
            progress?(.unpacking)
            try? fm.removeItem(atPath: staging)
            try privateDirectory(staging)
            let top = try await HermesArchiveReader.unpack(archive: file, into: staging, top: archive.topFolder)
            try? fm.removeItem(atPath: source)
            guard rename(top, source) == 0 else { throw BlackTeamError("Could not put Hermes Agent in place: \(String(cString: strerror(errno))).") }
            try writeRecord("unpacked")
            try? fm.removeItem(atPath: downloads)
        }
        if Task.isCancelled { throw CancellationError() }

        progress?(.creatingEnvironment)
        try? fm.removeItem(atPath: source + "/venv")   // a half-built one from an earlier try
        let venvPython = source + "/venv/bin/python"
        let target = source + "[all]"
        let packages = PackageCounter()
        let onLine: @Sendable (String) -> Void = { line in
            if line.hasPrefix("+ ") || line.hasPrefix("Collecting ") { progress?(.installingPackages(count: packages.next())) }
        }
        if !tooling.uv.isEmpty {
            try await step(tooling.uv, ["venv", "--python", "3.14", source + "/venv"], env, "create Hermes's Python environment", onLine: { _ in })
            progress?(.installingPackages(count: 0))
            try await step(tooling.uv, ["pip", "install", "--python", venvPython, "-e", target], env, "install Hermes's Python packages", onLine: onLine)
        } else {
            let version = try await runner.run(tooling.python, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], environment: env, directory: nil, onLine: { _ in })
            let found = version.tail.split(separator: "\n").last.map(String.init) ?? ""
            guard version.status == 0, found == "3.14" else {
                throw BlackTeamError(version.status == 0
                    ? "Hermes Agent needs Python 3.14, and this computer's Python is \(found). Install Python 3.14, or the uv tool (docs.astral.sh/uv), which can fetch it, then try again."
                    : "Python could not be started to set up Hermes Agent. Install Python 3.14, or the uv tool (docs.astral.sh/uv), then try again.")
            }
            try await step(tooling.python, ["-m", "venv", source + "/venv"], env, "create Hermes's Python environment", onLine: { _ in },
                           hint: "On some systems this needs the python3-venv package.")
            progress?(.installingPackages(count: 0))
            try await step(venvPython, ["-m", "pip", "install", "-e", target], env, "install Hermes's Python packages", onLine: onLine)
        }

        guard let found = inspectHermes(source: source) else {
            throw BlackTeamError("Hermes Agent was installed but its Python environment could not be found. Try again.")
        }
        try writeRecord("ready")
        progress?(.done(found))
        return found
    }

    private func inspectSource(_ folder: String) -> Bool {
        ["hermes_bootstrap.py", "cli.py"].allSatisfy { CoreFS.exists(folder + "/" + $0) }
    }

    private func step(_ executable: String, _ arguments: [String], _ env: [String: String], _ what: String,
                      onLine: @escaping @Sendable (String) -> Void, hint: String = "") async throws {
        let result = try await runner.run(executable, arguments, environment: env, directory: source, onLine: onLine)
        if result.status != 0 {
            let detail = result.tail.isEmpty ? "" : " " + String(result.tail.suffix(400))
            throw BlackTeamError("Could not \(what) (exit code \(result.status)).\(detail)\(hint.isEmpty ? "" : " " + hint) Check your internet connection and try again.")
        }
    }
}

/// Unpacks a GitHub source archive with the same care as the llama.cpp installer: nothing may land outside the folder it is
/// unpacked into. Names are checked before anything is written and links are checked after.
enum HermesArchiveReader {
    /// Throws unless every name is a relative path inside `top`, with no `..`, no control characters and no absolute path.
    static func validate(names: [String], top: String) throws {
        let refusal = BlackTeamError("The Hermes Agent download contains files outside its own folder, so it was not installed.")
        guard !names.isEmpty, names.count < 500_000 else { throw BlackTeamError("The Hermes Agent download is empty or unreadable, so it was not installed.") }
        for name in names {
            if name.hasPrefix("/") || name.hasPrefix("\\") || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { throw refusal }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.contains("..") { throw refusal }
            if parts.first != top { throw refusal }
        }
    }

    /// Throws unless every item under `folder` is a file, a folder or a link that stays inside `folder`.
    static func checkLinks(in folder: String) throws {
        let refusal = BlackTeamError("The Hermes Agent download contains a link that points outside its own folder, so it was not installed.")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(atPath: folder) else { return }
        for case let relative as String in walker {
            let path = folder + "/" + relative
            guard let attributes = try? fm.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else { continue }
            switch type {
            case .typeRegular, .typeDirectory: continue
            case .typeSymbolicLink:
                guard let target = try? fm.destinationOfSymbolicLink(atPath: path), !target.hasPrefix("/") else { throw refusal }
                let resolved = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).appendingPathComponent(target).standardized.path
                let inside = resolved == root || resolved.hasPrefix(root + "/") || resolved.hasPrefix(folder + "/") || resolved == folder
                if !inside { throw refusal }
            default: throw refusal   // devices, pipes and sockets have no place in a source archive
            }
        }
    }

    /// Lists, checks, unpacks into `staging` and checks links. Returns the unpacked top folder.
    static func unpack(archive: URL, into staging: String, top: String) async throws -> String {
        let listing = try await Task.detached { try RuntimeInstaller.run("/usr/bin/env", ["tar", "-tzf", archive.path], timeout: 300) }.value
        if listing.0 != 0 { throw BlackTeamError("Could not read the Hermes Agent download. \(listing.1.suffix(300))") }
        try validate(names: listing.1.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }, top: top)
        let extracted = try await Task.detached { try RuntimeInstaller.run("/usr/bin/env", ["tar", "-xzf", archive.path, "-C", staging, "--no-same-owner"], timeout: 600) }.value
        if extracted.0 != 0 { throw BlackTeamError("Could not unpack the Hermes Agent download. \(extracted.1.suffix(300))") }
        let folder = staging + "/" + top
        guard CoreFS.exists(folder + "/hermes_bootstrap.py"), CoreFS.exists(folder + "/cli.py") else {
            throw BlackTeamError("The Hermes Agent download did not contain the files Black Team needs, so it was not installed.")
        }
        try checkLinks(in: staging)
        return folder
    }
}
