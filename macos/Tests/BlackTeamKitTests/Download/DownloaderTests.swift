import XCTest
import CryptoKit
@testable import BlackTeamKit

final class DownloaderTests: XCTestCase {
    var folder: URL!
    let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) })
    let url = URL(string: "https://example.test/file.bin")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bt-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var destination: URL { folder.appendingPathComponent("out/file.bin") }
    var part: URL { URL(fileURLWithPath: destination.path + ".part") }
    func downloader(space: Int64? = nil) -> Downloader {
        Downloader(configuration: StubServer.configuration(), freeSpace: { _ in space ?? Int64.max })
    }
    func request(sha: String? = nil, size: Int64? = nil, hosts: [String] = []) -> DownloadRequest {
        DownloadRequest(url: url, destination: destination, expectedSHA256: sha, expectedSize: size, allowedHostSuffixes: hosts)
    }
    func ranged(_ req: URLRequest) -> Reply {
        let total = body.count
        if let header = req.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="),
           let start = Int(header.dropFirst(6).replacingOccurrences(of: "-", with: "")) {
            if start >= total {
                return .data(status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data())
            }
            return .data(status: 206, headers: ["Content-Range": "bytes \(start)-\(total - 1)/\(total)"], body: Data(body.suffix(from: start)))
        }
        return .data(status: 200, body: body)
    }
    typealias Reply = StubServer.Reply

    func testFreshDownloadVerifiesAndMovesIntoPlace() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        let seen = Box<[DownloadProgress]>([])
        let result = try await downloader().download(request(sha: sha(body), size: Int64(body.count))) { p in seen.update { $0.append(p) } }
        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let mode = (try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let last = try XCTUnwrap(seen.value.last)
        XCTAssertEqual(last.bytesReceived, Int64(body.count))
        XCTAssertEqual(last.totalBytes, Int64(body.count))
        XCTAssertEqual(last.fraction, 1)
    }

    func testResumesWithRangeRequest() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.prefix(70_000).write(to: part)
        StubServer.reset { self.ranged($0) }
        _ = try await downloader().download(request(sha: sha(body), size: Int64(body.count)))
        XCTAssertEqual(StubServer.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=70000-")
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 5_000).write(to: part)   // junk that must not survive
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        _ = try await downloader().download(request(sha: sha(body)))
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func test416WithCompletePartFinishes() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: part)
        StubServer.reset { self.ranged($0) }   // no expected size, so the request goes out and gets 416
        _ = try await downloader().download(request(sha: sha(body)))
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func test416WithUselessPartStartsAgain() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (body + Data(repeating: 1, count: 10)).write(to: part)   // longer than the real file
        StubServer.reset { self.ranged($0) }
        _ = try await downloader().download(request(sha: sha(body)))
        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(StubServer.requests.count, 2)
    }

    func testHashMismatchDeletesFileAndSaysSo() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        do {
            _ = try await downloader().download(request(sha: String(repeating: "0", count: 64)))
            XCTFail("expected an error")
        } catch let error as BlackTeamError {
            XCTAssertTrue(error.message.contains("did not match its checksum"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testWrongSizeIsRejected() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        do {
            _ = try await downloader().download(request(size: Int64(body.count) + 5))
            XCTFail("expected an error")
        } catch let error as BlackTeamError {
            XCTAssertTrue(error.message.contains("size"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelKeepsPartFileAndResumeCompletes() async throws {
        let sent = 40_000
        StubServer.reset { req in
            req.value(forHTTPHeaderField: "Range") == nil
                ? .stall(headers: [:], body: self.body, sent: sent)
                : self.ranged(req)
        }
        let worker = downloader()
        let task = Task { try await worker.download(self.request(sha: self.sha(self.body))) }
        for _ in 0..<100 where Downloader.fileSize(part) < Int64(sent) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(Downloader.fileSize(part), Int64(sent))
        worker.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(Downloader.fileSize(part), Int64(sent))

        _ = try await downloader().download(request(sha: sha(body)))
        XCTAssertEqual(StubServer.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=\(sent)-")
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testRedirectToUnknownHostIsRefused() async throws {
        StubServer.reset { req in
            req.url?.host == "example.test" ? .redirect(to: URL(string: "https://evil.example/x")!) : .data(status: 200, body: self.body)
        }
        do {
            _ = try await downloader().download(request(hosts: DownloadHosts.huggingFace))
            XCTFail("expected an error")
        } catch let error as BlackTeamError {
            XCTAssertTrue(error.message.contains("evil.example"), error.message)
        }
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRedirectToHttpIsRefused() async throws {
        StubServer.reset { req in
            req.url?.host == "example.test" ? .redirect(to: URL(string: "http://cdn.hf.co/x")!) : .data(status: 200, body: self.body)
        }
        do { _ = try await downloader().download(request(hosts: DownloadHosts.huggingFace)); XCTFail("expected an error") }
        catch is BlackTeamError {}
    }

    func testRedirectToAllowedCdnWorks() async throws {
        StubServer.reset { req in
            req.url?.host == "example.test" ? .redirect(to: URL(string: "https://us.aws.cdn.hf.co/blob")!) : .data(status: 200, body: self.body)
        }
        _ = try await downloader().download(request(sha: sha(body), hosts: DownloadHosts.huggingFace))
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testHostSuffixMatchingRespectsDotBoundary() {
        XCTAssertTrue(DownloadHosts.host("cas-bridge.xethub.hf.co", matches: DownloadHosts.huggingFace))
        XCTAssertTrue(DownloadHosts.host("release-assets.githubusercontent.com", matches: DownloadHosts.github))
        XCTAssertTrue(DownloadHosts.host("objects.githubusercontent.com", matches: DownloadHosts.github))
        XCTAssertFalse(DownloadHosts.host("evilhf.co", matches: DownloadHosts.huggingFace))
        XCTAssertFalse(DownloadHosts.host("hf.co.evil.example", matches: DownloadHosts.huggingFace))
    }

    func testNonHttpsIsRefused() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        let insecure = DownloadRequest(url: URL(string: "http://example.test/f")!, destination: destination)
        do { _ = try await downloader().download(insecure); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("https")) }
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testInsufficientSpaceFailsBeforeDownloading() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        do { _ = try await downloader(space: 1_000).download(request(size: Int64(body.count))); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("Not enough free disk space"), error.message) }
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testInsufficientSpaceWithUnknownSizeIsCaughtFromContentLength() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        do { _ = try await downloader(space: 1_000).download(request()); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("Not enough free disk space"), error.message) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testHttpErrorGivesClearMessage() async throws {
        StubServer.reset { _ in .data(status: 404, body: Data("no".utf8)) }
        do { _ = try await downloader().download(request()); XCTFail("expected an error") }
        catch let error as BlackTeamError { XCTAssertTrue(error.message.contains("404"), error.message) }
    }

    func testEventsStreamEndsWithFinished() async throws {
        StubServer.reset { _ in .data(status: 200, body: self.body) }
        var finished: URL?
        var progressCount = 0
        for try await event in downloader().events(for: request(sha: sha(body))) {
            switch event { case .progress: progressCount += 1; case .finished(let url): finished = url }
        }
        XCTAssertEqual(finished, destination)
        XCTAssertGreaterThan(progressCount, 0)
    }

    func testStreamedHashMatchesCryptoKit() throws {
        try body.write(to: folder.appendingPathComponent("h.bin"))
        XCTAssertEqual(try Downloader.sha256(of: folder.appendingPathComponent("h.bin")), sha(body))
    }
}

/// Small thread-safe holder for values touched from progress callbacks.
final class Box<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
