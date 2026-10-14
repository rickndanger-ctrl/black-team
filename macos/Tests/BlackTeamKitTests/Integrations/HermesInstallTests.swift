import XCTest
@testable import BlackTeamKit

// Installing Hermes Agent: the pinned archive, its checksum, the path-safety rules, and the steps after unpacking, with a fake network
// and a fake command runner. Nothing real is downloaded or run.

/// Writes a prepared archive instead of downloading, and remembers what was asked.
final class ArchiveDownloader: FileDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [DownloadRequest] = []
    let archive: URL
    var failure: Error?
    init(archive: URL) { self.archive = archive }
    var requests: [DownloadRequest] { lock.withLock { asked } }
    func download(_ request: DownloadRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> URL {
        lock.withLock { asked.append(request) }
        if let failure { throw failure }
        progress?(DownloadProgress(bytesReceived: 5, totalBytes: 10, bytesPerSecond: 1))
        try? FileManager.default.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: request.destination)
        try FileManager.default.copyItem(at: archive, to: request.destination)
        return request.destination
    }
    func cancel() {}
}

/// Records the commands and lets a test decide how each ends. Makes the file a real `venv` command would make.
final class RecordingRunner: SetupCommandRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String]; var environment: [String: String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var pythonVersion = "3.14"
    var failOn: String?
    var failure: Error?
    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int32, tail: String) {
        lock.withLock { recorded.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        if arguments.first == "-c" { return (0, pythonVersion) }
        if let failure { throw failure }
        if let failOn, arguments.contains(failOn) { return (1, "error: no matching distribution") }
        // `uv venv <dir>` and `python -m venv <dir>` make <dir>/bin/python.
        if let index = arguments.firstIndex(of: "venv"), let folder = arguments.last, index == 0 || arguments[index - 1] == "-m" {
            try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder + "/bin/python", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        onLine("+ openai==2.24.0")
        onLine("+ rich==14.3.3")
        return (0, "")
    }
}

/// A minimal tar (ustar) writer, so a test can make archives that `tar -c` itself would refuse to make.
struct TarEntry {
    var name: String
    var content = ""
    var link: String?
    var directory = false
}

func makeTarGz(_ entries: [TarEntry], at url: URL) throws {
    func field(_ text: String, _ length: Int) -> [UInt8] { Array((text.utf8 + [UInt8](repeating: 0, count: length)).prefix(length)) }
    func octal(_ value: Int, _ length: Int) -> [UInt8] { field(String(value, radix: 8).leftPad(length - 1), length) }
    var tar = Data()
    for entry in entries {
        let body = Array(entry.content.utf8)
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int) { header.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put(field(entry.name, 100), at: 0)
        put(octal(entry.directory ? 0o755 : 0o644, 8), at: 100)
        put(octal(0, 8), at: 108); put(octal(0, 8), at: 116)
        put(octal(entry.link == nil && !entry.directory ? body.count : 0, 12), at: 124)
        put(octal(0, 12), at: 136)
        put([UInt8](repeating: 0x20, count: 8), at: 148)
        put([entry.link != nil ? UInt8(ascii: "2") : entry.directory ? UInt8(ascii: "5") : UInt8(ascii: "0")], at: 156)
        put(field(entry.link ?? "", 100), at: 157)
        put(Array("ustar".utf8) + [0, 0x30, 0x30], at: 257)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(field(String(sum, radix: 8).leftPad(6), 6) + [0, 0x20], at: 148)
        tar.append(contentsOf: header)
        if entry.link == nil, !entry.directory {
            tar.append(contentsOf: body)
            tar.append(contentsOf: [UInt8](repeating: 0, count: (512 - body.count % 512) % 512))
        }
    }
    tar.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    let raw = url.deletingPathExtension().appendingPathExtension("tar")
    try tar.write(to: raw)
    try? FileManager.default.removeItem(at: url)
    let (status, output) = try RuntimeInstaller.run("/usr/bin/env", ["sh", "-c", "gzip -c '\(raw.path)' > '\(url.path)'"], timeout: 30)
    XCTAssertEqual(status, 0, output)
    try? FileManager.default.removeItem(at: raw)
}

extension String {
    fileprivate func leftPad(_ length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

final class HermesInstallTests: XCTestCase {
    private let commit = "0123456789abcdef0123456789abcdef01234567"
    private var top: String { "hermes-agent-" + commit }

    private func archive(_ dir: String, extra: [TarEntry] = [], good: Bool = true) throws -> (url: URL, sha: String) {
        var entries = [TarEntry(name: top + "/", directory: true)]
        if good {
            entries += [TarEntry(name: top + "/hermes_bootstrap.py", content: "# bootstrap\n"), TarEntry(name: top + "/cli.py", content: "# cli\n"),
                        TarEntry(name: top + "/pyproject.toml", content: "[project]\nname = \"hermes-agent\"\n"),
                        TarEntry(name: top + "/bin/", directory: true), TarEntry(name: top + "/bin/run", link: "../cli.py")]
        }
        let url = URL(fileURLWithPath: dir + "/fixture-\(UUID().uuidString.prefix(6)).tar.gz")
        try makeTarGz(entries + extra, at: url)
        return (url, try Downloader.sha256(of: url))
    }

    private func installer(_ dir: String, archive made: (url: URL, sha: String), tooling: HermesTooling = HermesTooling(uv: "/fake/uv", python: "/fake/python3"),
                           runner: SetupCommandRunning = RecordingRunner(), sha: String? = nil) -> (HermesInstaller, ArchiveDownloader) {
        let downloader = ArchiveDownloader(archive: made.url)
        let pinned = HermesArchive(commit: commit, url: URL(string: "https://github.com/NousResearch/hermes-agent/archive/\(commit).tar.gz")!,
                                   sha256: sha ?? made.sha, bytes: 1)
        return (HermesInstaller(dataFolder: dir + "/data", archive: pinned, downloader: downloader, runner: runner, tooling: tooling, home: dir + "/home", environment: ["PATH": "/usr/bin"]), downloader)
    }

    // MARK: The pin

    func testThePinnedArchiveIsFixedAndFetchedFromGitHubOnly() {
        let pin = HermesArchive.pinned
        XCTAssertEqual(pin.commit, "158fd638da1629c8e62caf9ade1515d162def8ab")
        XCTAssertEqual(pin.url.absoluteString, "https://github.com/NousResearch/hermes-agent/archive/158fd638da1629c8e62caf9ade1515d162def8ab.tar.gz")
        XCTAssertEqual(pin.sha256.count, 64)
        XCTAssertTrue(pin.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(pin.topFolder, "hermes-agent-158fd638da1629c8e62caf9ade1515d162def8ab")
        // The archive redirects to codeload.github.com, and only that is allowed on top of the starting host.
        XCTAssertEqual(DownloadHosts.githubArchive, ["codeload.github.com"])
        XCTAssertTrue(DownloadHosts.host("codeload.github.com", matches: DownloadHosts.githubArchive))
        XCTAssertFalse(DownloadHosts.host("objects.githubusercontent.com", matches: DownloadHosts.githubArchive))
        XCTAssertFalse(DownloadHosts.host("evil.example", matches: DownloadHosts.githubArchive))
        // Model downloads did not get wider.
        XCTAssertEqual(DownloadHosts.huggingFace, ["huggingface.co", "hf.co"])
        XCTAssertEqual(DownloadHosts.github, ["github.com", "githubusercontent.com"])
    }

    // MARK: Checksum and path safety

    func testAnArchiveThatDoesNotMatchItsChecksumIsRefused() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        let (install, downloader) = installer(dir, archive: try archive(dir), runner: runner, sha: String(repeating: "a", count: 64))
        do { _ = try await install.install(); XCTFail("should be refused") }
        catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("did not match its checksum") == true, "\(error)") }
        XCTAssertEqual(downloader.requests.count, 1)
        XCTAssertEqual(downloader.requests.first?.expectedSHA256, String(repeating: "a", count: 64), "the real downloader checks it too")
        XCTAssertEqual(downloader.requests.first?.allowedHostSuffixes, ["codeload.github.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: HermesInstaller.sourceFolder(dataFolder: dir + "/data")), "nothing was unpacked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/hermes/downloads/hermes-\(commit).tar.gz"), "the bad file was deleted")
        XCTAssertTrue(runner.calls.isEmpty, "nothing was run")
    }

    func testUnsafePathsInTheArchiveAreRefusedAndNothingIsWrittenOutside() async throws {
        let cases: [(String, [TarEntry])] = [
            ("parent folder", [TarEntry(name: top + "/../../escaped.txt", content: "x")]),
            ("absolute path", [TarEntry(name: "/tmp/black-team-escaped-\(UUID().uuidString)", content: "x")]),
            ("another top folder", [TarEntry(name: "somewhere-else/file", content: "x")]),
            ("link to an absolute path", [TarEntry(name: top + "/evil", link: "/etc")]),
            ("link out of the folder", [TarEntry(name: top + "/evil", link: "../../../../etc")]),
            ("link out through a folder", [TarEntry(name: top + "/sub/", directory: true), TarEntry(name: top + "/sub/evil", link: "../../..")]),
        ]
        for (label, extra) in cases {
            let dir = makeTemporaryFolder(self)
            let (install, _) = installer(dir, archive: try archive(dir, extra: extra))
            do { _ = try await install.install(); XCTFail("\(label) should be refused") }
            catch {
                let message = (error as? BlackTeamError)?.message ?? "\(error)"
                XCTAssertTrue(message.contains("outside its own folder") || message.contains("points outside"), "\(label): \(message)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/hermes/hermes-agent"), "\(label): nothing was installed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/escaped.txt"), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/hermes/escaped.txt"), label)
        }
    }

    func testNamesAreCheckedBeforeAnythingIsUnpacked() {
        XCTAssertNoThrow(try HermesArchiveReader.validate(names: [top, top + "/a/b.py", top + "/a..b/c"], top: top))
        for bad in ["/abs", top + "/../x", "../" + top, "other/x", top + "/a/../../x", "x\u{1}y", "\\windows"] {
            XCTAssertThrowsError(try HermesArchiveReader.validate(names: [top, bad], top: top), bad)
        }
        XCTAssertThrowsError(try HermesArchiveReader.validate(names: [], top: top))
    }

    func testAnArchiveWithoutHermesInItIsRefused() async throws {
        let dir = makeTemporaryFolder(self)
        let (install, _) = installer(dir, archive: try archive(dir, good: false))
        do { _ = try await install.install(); XCTFail("should be refused") }
        catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("did not contain the files") == true, "\(error)") }
    }

    // MARK: Installing

    func testInstallWithUvUnpacksAndBuildsAnEnvironmentInsideBlackTeamsFolder() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        let (install, downloader) = installer(dir, archive: try archive(dir), runner: runner)
        let events = EventBox()
        let found = try await install.install { events.add($0) }
        let source = dir + "/data/hermes/hermes-agent"
        XCTAssertEqual(found.source, source)
        XCTAssertEqual(found.python, source + "/venv/bin/python")
        XCTAssertNotNil(inspectHermes(source: source), "inspectHermes accepts the folder")
        XCTAssertEqual(install.installed(), found)
        XCTAssertEqual(downloader.requests.count, 1)
        XCTAssertEqual(runner.calls.map(\.executable), ["/fake/uv", "/fake/uv"])
        XCTAssertEqual(runner.calls[0].arguments, ["venv", "--python", "3.14", source + "/venv"])
        XCTAssertEqual(runner.calls[1].arguments, ["pip", "install", "--python", source + "/venv/bin/python", "-e", source + "[all]"])
        // Every cache and home the tools use is inside Black Team's folder, never the person's own.
        for call in runner.calls {
            for key in ["HERMES_HOME", "HERMES_RUNTIME_DIR", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "PIP_CACHE_DIR"] {
                XCTAssertTrue(call.environment[key]?.hasPrefix(dir + "/data/hermes/") == true, "\(key) = \(call.environment[key] ?? "nil")")
            }
        }
        // The link in the archive stayed a link inside the folder.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source + "/bin/run"), "../cli.py")
        XCTAssertEqual(mode(dir + "/data/hermes"), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/data/hermes/downloads"), "the 80 MB archive is not kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/home/.hermes"), "the person's own Hermes folder is not touched")
        XCTAssertEqual(events.names.first, "checking")
        XCTAssertTrue(events.names.contains("downloading"))
        XCTAssertTrue(events.names.contains("unpacking") && events.names.contains("creating") && events.names.contains("packages"))
        XCTAssertEqual(events.names.last, "done")
    }

    func testInstallWithPipUsesVenvAndPip() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        let (install, _) = installer(dir, archive: try archive(dir), tooling: HermesTooling(uv: "", python: "/fake/python3.14"), runner: runner)
        _ = try await install.install()
        let source = dir + "/data/hermes/hermes-agent"
        XCTAssertEqual(runner.calls.map(\.arguments.first), ["-c", "-m", "-m"])
        XCTAssertEqual(runner.calls[1].arguments, ["-m", "venv", source + "/venv"])
        XCTAssertEqual(runner.calls[2].executable, source + "/venv/bin/python")
        XCTAssertEqual(runner.calls[2].arguments, ["-m", "pip", "install", "-e", source + "[all]"])
    }

    func testAnOldPythonWithoutUvIsExplained() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        runner.pythonVersion = "3.12"
        let (install, _) = installer(dir, archive: try archive(dir), tooling: HermesTooling(uv: "", python: "/fake/python3"), runner: runner)
        do { _ = try await install.install(); XCTFail("should be refused") }
        catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("needs Python 3.14, and this computer's Python is 3.12") == true, "\(error)") }
        XCTAssertNil(inspectHermes(source: dir + "/data/hermes/hermes-agent/") , "no usable install was left")
    }

    func testNoPythonAndNoUvFailsBeforeDownloadingAnything() async throws {
        let dir = makeTemporaryFolder(self)
        let (install, downloader) = installer(dir, archive: try archive(dir), tooling: HermesTooling())
        do { _ = try await install.install(); XCTFail("should be refused") }
        catch { XCTAssertEqual((error as? BlackTeamError)?.message, HermesTooling.missingMessage) }
        XCTAssertTrue(downloader.requests.isEmpty)
    }

    func testAFailedInstallCanBeRetriedWithoutDownloadingAgain() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        runner.failOn = "pip"
        let (install, downloader) = installer(dir, archive: try archive(dir), runner: runner)
        do { _ = try await install.install(); XCTFail("should fail") }
        catch {
            let message = (error as? BlackTeamError)?.message ?? ""
            XCTAssertTrue(message.contains("Could not install Hermes's Python packages") && message.contains("no matching distribution"), message)
        }
        XCTAssertNil(install.installed(), "not ready yet")
        XCTAssertTrue(CoreFS.exists(dir + "/data/hermes/hermes-agent/hermes_bootstrap.py"), "the unpacked source is kept")
        runner.failOn = nil
        let found = try await install.install()
        XCTAssertEqual(downloader.requests.count, 1, "the second try reused the unpacked source")
        XCTAssertEqual(install.installed(), found)
    }

    func testStoppingTheInstallStops() async throws {
        let dir = makeTemporaryFolder(self)
        let runner = RecordingRunner()
        runner.failure = CancellationError()
        let (install, _) = installer(dir, archive: try archive(dir), runner: runner)
        do { _ = try await install.install(); XCTFail("should stop") } catch is CancellationError {}
        XCTAssertNil(install.installed())
    }

    func testToolingIsFoundWithoutRunningAnything() throws {
        let dir = makeTemporaryFolder(self)
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        let marker = dir + "/ran"
        for name in ["uv", "python3.14", "python3"] {
            try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: dir + "/bin/" + name, atomically: true, encoding: .utf8)
            chmod(dir + "/bin/" + name, 0o755)
        }
        let found = findHermesTooling(home: dir + "/home", env: ["PATH": dir + "/bin"])
        XCTAssertEqual(found.uv, dir + "/bin/uv")
        XCTAssertEqual(found.python, dir + "/bin/python3.14", "python3.14 is preferred to python3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "finding does not run")
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ event: HermesInstallEvent) {
        let name: String
        switch event {
        case .checking: name = "checking"
        case .downloading: name = "downloading"
        case .verifying: name = "verifying"
        case .unpacking: name = "unpacking"
        case .creatingEnvironment: name = "creating"
        case .installingPackages: name = "packages"
        case .done: name = "done"
        }
        lock.withLock { all.append(name) }
    }
    var names: [String] { lock.withLock { all } }
}
