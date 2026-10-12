import Foundation

public enum MacArchitecture: String, Sendable, Codable {
    case arm64, x64

    public static var current: MacArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x64
        #endif
    }
    /// Mach-O cputype for this architecture.
    var cpuType: UInt32 { self == .arm64 ? 0x0100000C : 0x01000007 }
}

/// A downloadable llama.cpp build for one architecture.
public struct RuntimeAsset: Codable, Sendable, Equatable {
    public var name: String
    public var size: Int64?
    public var url: URL
    /// From the "digest" GitHub publishes for each asset ("sha256:…").
    public var sha256: String?
    public init(name: String, size: Int64?, url: URL, sha256: String?) {
        self.name = name; self.size = size; self.url = url; self.sha256 = sha256
    }
}

public struct RuntimeRelease: Sendable, Equatable {
    public var tag: String
    public var asset: RuntimeAsset
    public init(tag: String, asset: RuntimeAsset) { self.tag = tag; self.asset = asset }
}

/// What `<data>/runtime/current.json` says.
public struct InstalledRuntime: Codable, Sendable, Equatable {
    public var tag: String
    /// Absolute path of `llama-server`, with its dylibs beside it.
    public var executable: String
    public var architecture: MacArchitecture
    public var installedAt: String
    /// Kept on disk until the next install, so a bad update can be rolled back by hand.
    public var previousTag: String?
    public var versionOutput: String?
}

public enum RuntimeInstallEvent: Sendable {
    case checking
    case downloading(DownloadProgress)
    case extracting
    case verifying
    case done(InstalledRuntime)
}

public typealias RuntimeFetcher = @Sendable (URL) async throws -> Data

/// Installs the official llama.cpp macOS build into `<dataFolder>/runtime/<tag>/`.
public final class RuntimeInstaller: @unchecked Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")!
    /// GitHub's "latest" is not reliable for llama.cpp: today it points at a stray "v0.6.0" release with no
    /// binaries, and the real bNNNN builds are all marked pre-release. So the recent list is the fallback.
    public static let listURL = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30")!

    public let dataFolder: URL
    private let architecture: MacArchitecture
    private let fetch: RuntimeFetcher
    private let downloader: FileDownloading
    private let versionTimeout: TimeInterval

    /// `fetch`, `downloader` and `architecture` are injectable for tests.
    public init(dataFolder: URL, architecture: MacArchitecture = .current, fetch: RuntimeFetcher? = nil,
                downloader: FileDownloading = Downloader(), versionTimeout: TimeInterval = 20) {
        self.dataFolder = dataFolder
        self.architecture = architecture
        self.fetch = fetch ?? RuntimeInstaller.githubFetch
        self.downloader = downloader
        self.versionTimeout = versionTimeout
    }

    public var runtimeFolder: URL { dataFolder.appendingPathComponent("runtime", isDirectory: true) }
    private var currentFile: URL { runtimeFolder.appendingPathComponent("current.json") }

    public func cancel() { downloader.cancel() }

    // MARK: Reading

    /// What is installed, or nil when nothing usable is (no record, or the program is gone).
    public func installedRuntime() -> InstalledRuntime? {
        guard let data = try? Data(contentsOf: currentFile),
              let runtime = try? JSONDecoder().decode(InstalledRuntime.self, from: data),
              FileManager.default.isExecutableFile(atPath: runtime.executable) else { return nil }
        return runtime
    }

    /// The newest llama.cpp build with a macOS package for this Mac.
    public func latestAvailable() async throws -> RuntimeRelease {
        var firstError: Error?
        for url in [RuntimeInstaller.latestURL, RuntimeInstaller.listURL] {
            do {
                let data = try await fetch(url)
                if let release = RuntimeInstaller.selectRelease(from: data, architecture: architecture) { return release }
            } catch { firstError = firstError ?? error }
        }
        if let firstError, firstError is BlackTeamError { throw firstError }
        throw BlackTeamError("Could not find a llama.cpp download for this Mac. Check your internet connection and try again.")
    }

    /// A newer build than the installed one, or nil.
    public func updateAvailable() async throws -> RuntimeRelease? {
        let latest = try await latestAvailable()
        guard let installed = installedRuntime() else { return latest }
        return RuntimeInstaller.buildNumber(latest.tag) > RuntimeInstaller.buildNumber(installed.tag) ? latest : nil
    }

    // MARK: Installing

    @discardableResult
    public func install(_ chosen: RuntimeRelease? = nil, force: Bool = false,
                        progress: (@Sendable (RuntimeInstallEvent) -> Void)? = nil) async throws -> InstalledRuntime {
        progress?(.checking)
        let release: RuntimeRelease
        if let chosen { release = chosen } else { release = try await latestAvailable() }
        let previous = installedRuntime()
        if !force, let previous, previous.tag == release.tag { progress?(.done(previous)); return previous }

        let fm = FileManager.default
        try fm.createDirectory(at: runtimeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let downloads = runtimeFolder.appendingPathComponent("downloads", isDirectory: true)
        let staging = runtimeFolder.appendingPathComponent(".staging-\(release.tag)", isDirectory: true)
        let final = runtimeFolder.appendingPathComponent(release.tag, isDirectory: true)
        defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: downloads) }

        let archive = downloads.appendingPathComponent(release.asset.name)
        _ = try await downloader.download(
            DownloadRequest(url: release.asset.url, destination: archive, expectedSHA256: release.asset.sha256,
                            expectedSize: release.asset.size, allowedHostSuffixes: DownloadHosts.github),
            progress: { progress?(.downloading($0)) })

        progress?(.extracting)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await RuntimeInstaller.extract(archive: archive, into: staging)
        guard let found = RuntimeInstaller.findServer(in: staging) else {
            throw BlackTeamError("The llama.cpp download did not contain llama-server, so it was not installed.")
        }
        let relative = found

        // The old copy of this tag (a failed or forced install) goes; the currently installed other tag stays.
        try? fm.removeItem(at: final)
        // rename(2) moves the whole folder in one step.
        if rename(staging.path, final.path) != 0 {
            throw BlackTeamError("Could not put llama.cpp in place: \(String(cString: strerror(errno))).")
        }

        progress?(.verifying)
        let executable = final.appendingPathComponent(relative)
        do {
            RuntimeInstaller.clearQuarantine(at: final)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try RuntimeInstaller.verifyMachO(executable, architecture: architecture)
            let output = try await RuntimeInstaller.runVersion(executable: executable, timeout: versionTimeout)
            let installed = InstalledRuntime(tag: release.tag, executable: executable.path, architecture: architecture,
                                             installedAt: ISO8601DateFormatter().string(from: Date()),
                                             previousTag: previous?.tag == release.tag ? nil : previous?.tag,
                                             versionOutput: output)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let json = try encoder.encode(installed)
            let temp = runtimeFolder.appendingPathComponent("current.json.tmp")
            try json.write(to: temp, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if fm.fileExists(atPath: currentFile.path) { _ = try fm.replaceItemAt(currentFile, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: currentFile) }
            prune(keeping: [installed.tag, installed.previousTag].compactMap { $0 })
            progress?(.done(installed))
            return installed
        } catch {
            try? fm.removeItem(at: final)   // the previous version and current.json are untouched
            throw error
        }
    }

    private func prune(keeping tags: [String]) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: runtimeFolder, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("b"), name.dropFirst().allSatisfy(\.isNumber), !tags.contains(name) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Pure helpers (public for tests)

    public static func buildNumber(_ tag: String) -> Int {
        guard tag.hasPrefix("b"), let n = Int(tag.dropFirst()) else { return -1 }
        return n
    }

    /// Picks the macOS package for `architecture` from a GitHub release (one object) or a list of them.
    /// In a list the highest bNNNN tag that has the package wins; drafts and non-bNNNN tags are skipped.
    public static func selectRelease(from data: Data, architecture: MacArchitecture) -> RuntimeRelease? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        let releases: [JSONValue] = json.array ?? [json]
        var best: RuntimeRelease?
        for release in releases {
            guard release["draft"]?.bool != true, let tag = release["tag_name"]?.string, buildNumber(tag) >= 0,
                  let asset = selectAsset(from: release["assets"]?.array ?? [], architecture: architecture) else { continue }
            if best == nil || buildNumber(tag) > buildNumber(best!.tag) { best = RuntimeRelease(tag: tag, asset: asset) }
        }
        return best
    }

    /// The plain build, not variants: `llama-bNNNN-bin-macos-arm64.tar.gz` (or `.zip`).
    public static func selectAsset(from assets: [JSONValue], architecture: MacArchitecture) -> RuntimeAsset? {
        let stem = "-bin-macos-\(architecture.rawValue)"
        var candidates: [(rank: Int, asset: RuntimeAsset)] = []
        for item in assets {
            guard let name = item["name"]?.string, name.hasPrefix("llama-"), let link = item["browser_download_url"]?.string,
                  let url = URL(string: link) else { continue }
            let rank: Int
            if name.hasSuffix(stem + ".tar.gz") { rank = 0 }
            else if name.hasSuffix(stem + ".zip") { rank = 1 }
            else { continue }
            var digest = item["digest"]?.string
            if let value = digest, value.hasPrefix("sha256:") { digest = String(value.dropFirst(7)) } else { digest = nil }
            candidates.append((rank, RuntimeAsset(name: name, size: item["size"]?.double.map { Int64($0) }, url: url, sha256: digest)))
        }
        return candidates.min { $0.rank < $1.rank }?.asset
    }

    /// Unpacks a .tar.gz with /usr/bin/tar or a .zip with /usr/bin/ditto.
    static func extract(archive: URL, into folder: URL) async throws {
        let name = archive.lastPathComponent
        let command: (String, [String])
        if name.hasSuffix(".zip") { command = ("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) }
        else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { command = ("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path]) }
        else { throw BlackTeamError("Unknown llama.cpp package type: \(name).") }
        let (status, output) = try await Task.detached { try RuntimeInstaller.run(command.0, command.1, timeout: 300) }.value
        if status != 0 { throw BlackTeamError("Could not unpack the llama.cpp download. \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    /// Path, relative to `folder`, of the first regular `llama-server` file (links followed), shallowest first.
    static func findServer(in folder: URL) -> String? {
        let root = folder.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return nil }
        var hits: [String] = []
        for case let relative as String in walker where (relative as NSString).lastPathComponent == "llama-server" {
            let full = folder.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            // A link must not point outside the unpacked folder.
            if full.resolvingSymlinksInPath().path.hasPrefix(root + "/") { hits.append(relative) }
        }
        return hits.min { $0.split(separator: "/").count < $1.split(separator: "/").count }
    }

    /// Throws unless the file is a Mach-O (or universal) program that contains `architecture`.
    public static func verifyMachO(_ file: URL, architecture: MacArchitecture) throws {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 4096), head.count >= 8 else {
            throw BlackTeamError("llama-server could not be read.")
        }
        try? handle.close()
        func be32(_ at: Int) -> UInt32 { head[at..<at+4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ at: Int) -> UInt32 { head[at..<at+4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let magic = be32(0)
        var types: [UInt32] = []
        if magic == 0xCFFAEDFE { types = [le32(4)] }                        // 64-bit little-endian Mach-O
        else if magic == 0xCAFEBABE {                                       // universal (big-endian header)
            let count = Int(be32(4))
            for i in 0..<min(count, 8) where 8 + i * 20 + 4 <= head.count { types.append(be32(8 + i * 20)) }
        }
        guard !types.isEmpty else { throw BlackTeamError("The downloaded llama-server is not a Mac program.") }
        guard types.contains(architecture.cpuType) else {
            throw BlackTeamError("The downloaded llama-server is for a different kind of Mac (not \(architecture == .arm64 ? "Apple silicon" : "Intel")).")
        }
    }

    /// Removes the download-quarantine flag from everything under `folder`, so macOS does not block
    /// the program. Files fetched by this app are not flagged anyway; this covers archives that carry it.
    @discardableResult
    public static func clearQuarantine(at folder: URL) -> Int {
        var cleared = 0
        func clear(_ path: String) { if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 { cleared += 1 } }
        clear(folder.path)
        if let walker = FileManager.default.enumerator(atPath: folder.path) {
            for case let relative as String in walker { clear(folder.path + "/" + relative) }
        }
        return cleared
    }

    /// Runs `llama-server --version` and returns what it prints. Fails if it will not start in time.
    static func runVersion(executable: URL, timeout: TimeInterval) async throws -> String {
        let (status, output): (Int32, String)
        do {
            (status, output) = try await Task.detached { try run(executable.path, ["--version"], timeout: timeout, directory: executable.deletingLastPathComponent()) }.value
        } catch let error as BlackTeamError { throw error }
        catch { throw BlackTeamError("llama-server could not be started: \(error.localizedDescription)") }
        guard status == 0 else {
            throw BlackTeamError("llama-server did not start (exit code \(status)). macOS may be blocking it. \(output.suffix(300))")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a program, collecting stdout and stderr together, with a time limit.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval, directory: URL? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        var collected = Data()
        let reader = DispatchQueue(label: "black-team.run.reader")
        let readDone = DispatchSemaphore(value: 0)
        try process.run()
        reader.async { collected = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 3)
            throw BlackTeamError("\((path as NSString).lastPathComponent) did not respond within \(Int(timeout)) seconds.")
        }
        _ = readDone.wait(timeout: .now() + 5)
        return (process.terminationStatus, String(decoding: collected, as: UTF8.self))
    }

    static let githubFetch: RuntimeFetcher = { url in
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BlackTeam", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BlackTeamError("GitHub sent an unexpected reply.") }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw BlackTeamError("GitHub is limiting requests right now. Please try again in a few minutes.")
        }
        guard http.statusCode == 200 else { throw BlackTeamError("Could not check GitHub for llama.cpp (HTTP \(http.statusCode)).") }
        return data
    }
}
