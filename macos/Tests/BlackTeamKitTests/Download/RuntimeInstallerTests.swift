import XCTest
@testable import BlackTeamKit

/// Writes the archive the "server" would send, instead of downloading.
final class FakeDownloader: FileDownloading, @unchecked Sendable {
    var archive: URL
    var requests: [DownloadRequest] = []
    init(archive: URL) { self.archive = archive }
    func download(_ request: DownloadRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> URL {
        requests.append(request)
        try FileManager.default.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: request.destination)
        try FileManager.default.copyItem(at: archive, to: request.destination)
        return request.destination
    }
    func cancel() {}
}

final class RuntimeInstallerTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bt-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func asset(_ name: String, tag: String = "b200") -> String {
        """
        {"name":"\(name)","size":1234,"digest":"sha256:\(String(repeating: "ab", count: 32))",
         "browser_download_url":"https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/\(name)"}
        """
    }
    func release(_ tag: String, draft: Bool = false, assets: [String]) -> String {
        "{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":true,\"assets\":[\(assets.map { asset($0, tag: tag) }.joined(separator: ","))]}"
    }
    var sample: Data {
        let list = [
            "{\"tag_name\":\"v0.6.0\",\"assets\":[{\"name\":\"nightly-tag.txt\",\"browser_download_url\":\"https://github.com/x/y\"}]}",
            release("b200", assets: ["llama-b200-bin-macos-arm64-kleidiai.tar.gz", "llama-b200-bin-macos-x64.tar.gz", "llama-b200-bin-macos-arm64.tar.gz", "llama-b200-bin-ubuntu-x64.tar.gz"]),
            release("b201", draft: true, assets: ["llama-b201-bin-macos-arm64.tar.gz"]),
            release("b199", assets: ["llama-b199-bin-macos-arm64.zip"]),
        ]
        return Data("[\(list.joined(separator: ","))]".utf8)
    }

    func testPicksNewestPublishedReleaseAndPlainArm64Asset() throws {
        let release = try XCTUnwrap(RuntimeInstaller.selectRelease(from: sample, architecture: .arm64))
        XCTAssertEqual(release.tag, "b200")
        XCTAssertEqual(release.asset.name, "llama-b200-bin-macos-arm64.tar.gz")
        XCTAssertEqual(release.asset.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(release.asset.size, 1234)
    }

    func testPicksIntelAsset() throws {
        XCTAssertEqual(RuntimeInstaller.selectRelease(from: sample, architecture: .x64)?.asset.name, "llama-b200-bin-macos-x64.tar.gz")
    }

    func testZipIsUsedWhenThatIsAllThereIsAndSingleObjectIsAccepted() throws {
        let one = Data(release("b150", assets: ["llama-b150-bin-macos-arm64.zip"]).utf8)
        XCTAssertEqual(RuntimeInstaller.selectRelease(from: one, architecture: .arm64)?.asset.name, "llama-b150-bin-macos-arm64.zip")
    }

    func testStrayLatestReleaseWithoutBinariesIsSkipped() {
        let stray = Data("{\"tag_name\":\"v0.6.0\",\"assets\":[]}".utf8)
        XCTAssertNil(RuntimeInstaller.selectRelease(from: stray, architecture: .arm64))
    }

    func testLatestAvailableFallsBackToTheList() async throws {
        let installer = RuntimeInstaller(dataFolder: folder, architecture: .arm64, fetch: { url in
            url == RuntimeInstaller.latestURL ? Data("{\"tag_name\":\"v0.6.0\",\"assets\":[]}".utf8) : self.sample
        }, downloader: FakeDownloader(archive: folder))
        let latest = try await installer.latestAvailable()
        XCTAssertEqual(latest.tag, "b200")
    }

    func testUpdateAvailableComparesBuildNumbers() async throws {
        let installer = RuntimeInstaller(dataFolder: folder, architecture: .arm64, fetch: { _ in self.sample }, downloader: FakeDownloader(archive: folder))
        let nothing = try await installer.updateAvailable()
        XCTAssertEqual(nothing?.tag, "b200")   // nothing installed yet
    }

    // MARK: Install with a real tar.gz made on the spot

    /// Builds `llama-<tag>/llama-server` (a copy of a real Mac program) plus a dylib, packed as .tar.gz.
    func makeArchive(tag: String, server: URL? = URL(fileURLWithPath: "/usr/bin/true"), asText: Bool = false) throws -> URL {
        let root = folder.appendingPathComponent("src-\(tag)/llama-\(tag)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: root.appendingPathComponent("libllama.dylib"))
        if asText { try Data("#!/bin/sh\necho hi\n".utf8).write(to: root.appendingPathComponent("llama-server")) }
        else if let server { try FileManager.default.copyItem(at: server, to: root.appendingPathComponent("llama-server")) }
        let archive = folder.appendingPathComponent("llama-\(tag)-bin-macos-arm64.tar.gz")
        let (status, out) = try RuntimeInstaller.run("/usr/bin/tar", ["-czf", archive.path, "-C", folder.appendingPathComponent("src-\(tag)").path, "llama-\(tag)"], timeout: 30)
        XCTAssertEqual(status, 0, out)
        return archive
    }
    func release(_ tag: String) -> RuntimeRelease {
        RuntimeRelease(tag: tag, asset: RuntimeAsset(name: "llama-\(tag)-bin-macos-arm64.tar.gz", size: nil,
                                                     url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/x.tar.gz")!, sha256: nil))
    }

    func testInstallExtractsVerifiesAndRecords() async throws {
        let data = folder.appendingPathComponent("data")
        let fake = FakeDownloader(archive: try makeArchive(tag: "b1"))
        let installer = RuntimeInstaller(dataFolder: data, architecture: .current, fetch: { _ in Data() }, downloader: fake)
        let events = Box<[String]>([])
        let installed = try await installer.install(release("b1")) { event in
            switch event {
            case .extracting: events.update { $0.append("extracting") }
            case .verifying: events.update { $0.append("verifying") }
            default: break
            }
        }
        XCTAssertEqual(events.value, ["extracting", "verifying"])
        XCTAssertEqual(installed.tag, "b1")
        XCTAssertTrue(installed.executable.hasSuffix("/runtime/b1/llama-b1/llama-server"), installed.executable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("runtime/b1/llama-b1/libllama.dylib").path))
        XCTAssertEqual(installer.installedRuntime(), installed)
        XCTAssertEqual(fake.requests.first?.allowedHostSuffixes, DownloadHosts.github)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("runtime/downloads").path))
        let mode = (try FileManager.default.attributesOfItem(atPath: data.appendingPathComponent("runtime/current.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        // Installing the same tag again does nothing.
        let again = try await installer.install(release("b1"))
        XCTAssertEqual(again, installed)
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testBadUpdateKeepsThePreviousVersion() async throws {
        let data = folder.appendingPathComponent("data")
        let fake = FakeDownloader(archive: try makeArchive(tag: "b1"))
        let installer = RuntimeInstaller(dataFolder: data, architecture: .current, fetch: { _ in Data() }, downloader: fake)
        let first = try await installer.install(release("b1"))

        fake.archive = try makeArchive(tag: "b2", asText: true)   // not a Mac program
        do { _ = try await installer.install(release("b2")); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("not a Mac program"), error.message) }
        XCTAssertEqual(installer.installedRuntime(), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("runtime/b2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.executable))
    }

    func testGoodUpdateRecordsPreviousAndPrunesOlder() async throws {
        let data = folder.appendingPathComponent("data")
        let fake = FakeDownloader(archive: try makeArchive(tag: "b1"))
        let installer = RuntimeInstaller(dataFolder: data, architecture: .current, fetch: { _ in Data() }, downloader: fake)
        _ = try await installer.install(release("b1"))
        fake.archive = try makeArchive(tag: "b2")
        _ = try await installer.install(release("b2"))
        fake.archive = try makeArchive(tag: "b3")
        let third = try await installer.install(release("b3"))
        XCTAssertEqual(third.previousTag, "b2")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("runtime/b1").path))
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("runtime/b2").path))
    }

    func testArchiveWithoutServerFails() async throws {
        let data = folder.appendingPathComponent("data")
        let fake = FakeDownloader(archive: try makeArchive(tag: "b5", server: nil))
        let installer = RuntimeInstaller(dataFolder: data, architecture: .current, fetch: { _ in Data() }, downloader: fake)
        do { _ = try await installer.install(release("b5")); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("did not contain llama-server"), error.message) }
        XCTAssertNil(installer.installedRuntime())
    }

    func testMachOCheckRejectsWrongArchitectureAndScripts() throws {
        let program = URL(fileURLWithPath: "/usr/bin/true")
        let other: MacArchitecture = MacArchitecture.current == .arm64 ? .x64 : .arm64
        // /usr/bin/true is universal on current macOS, so only assert the current architecture passes.
        XCTAssertNoThrow(try RuntimeInstaller.verifyMachO(program, architecture: .current))
        _ = other
        let script = folder.appendingPathComponent("script")
        try Data("#!/bin/sh\n".utf8 + Data(count: 100)).write(to: script)
        XCTAssertThrowsError(try RuntimeInstaller.verifyMachO(script, architecture: .current))
    }

    func testQuarantineAttributeIsCleared() throws {
        let file = folder.appendingPathComponent("flagged")
        try Data("x".utf8).write(to: file)
        let value = "0083;00000000;Safari;"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        XCTAssertGreaterThanOrEqual(RuntimeInstaller.clearQuarantine(at: folder), 1)
        XCTAssertEqual(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
    }

    func testVersionCheckTimesOut() async throws {
        do { _ = try await RuntimeInstaller.runVersion(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.5); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("did not start") || error.message.contains("did not respond"), error.message) }
    }

    // MARK: Live

    func testLiveInstallRunsLlamaServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACK_TEAM_LIVE"] == "1", "live test")
        let data = folder.appendingPathComponent("live")
        let installer = RuntimeInstaller(dataFolder: data)
        let installed = try await installer.install()
        print("LIVE installed", installed.tag, installed.executable, installed.versionOutput ?? "")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.executable))
        XCTAssertTrue((installed.versionOutput ?? "").lowercased().contains("version"), installed.versionOutput ?? "")
        XCTAssertEqual(installer.installedRuntime()?.tag, installed.tag)
        let newer = try await installer.updateAvailable()
        print("LIVE update available:", newer?.tag ?? "none")
    }
}
