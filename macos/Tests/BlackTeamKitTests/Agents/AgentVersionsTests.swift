import XCTest
@testable import BlackTeamKit

/// Counts the registry requests a check makes.
final class FetchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class AgentVersionsTests: XCTestCase {
    func httpStatus(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func registry(_ body: String, status: Int = 200) -> HTTPFetch {
        { request in (Data(body.utf8), self.httpStatus(request.url!, status)) }
    }

    func testVersionIsTakenFromTheToolsOwnOutput() {
        XCTAssertEqual(AgentVersions.parseVersion("codex-cli 0.162.1"), "0.162.1")
        XCTAssertEqual(AgentVersions.parseVersion("2.1.289 (Claude Code)"), "2.1.289")
        XCTAssertNil(AgentVersions.parseVersion("no version here"))
    }

    func testInstalledVersionRunsTheToolsVersionCommand() async throws {
        let dir = NSTemporaryDirectory() + "bt-version-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/codex"
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\necho 'codex-cli 0.162.1'\n".utf8), attributes: [.posixPermissions: 0o755])
        let installed = await AgentVersions.installedVersion(service: .codex, executable: path)
        XCTAssertEqual(installed, "0.162.1")
        let missing = await AgentVersions.installedVersion(service: .codex, executable: dir + "/absent")
        XCTAssertNil(missing)
    }

    func testNewerIsNumericAndFalseWhenUnknownOrEqual() {
        XCTAssertTrue(AgentVersions.isNewer("0.163.0", than: "0.162.1"))
        XCTAssertTrue(AgentVersions.isNewer("2.1.289", than: "2.1.99"))
        XCTAssertFalse(AgentVersions.isNewer("2.1.99", than: "2.1.289"))
        XCTAssertFalse(AgentVersions.isNewer("0.162.1", than: "0.162.1"))
        XCTAssertFalse(AgentVersions.isNewer(nil, than: "0.162.1"))
        XCTAssertFalse(AgentVersions.isNewer("0.163.0", than: nil))
        XCTAssertTrue(AgentVersions.isNewer("0.163.0", than: "0.162.1"))
    }

    func testStatusReportsAnUpdateOnlyWhenBothVersionsAreKnown() {
        XCTAssertTrue(AgentUpdateStatus(installed: "0.162.1", latest: "0.163.0").updateAvailable)
        XCTAssertFalse(AgentUpdateStatus(installed: "0.163.0", latest: "0.163.0").updateAvailable)
        XCTAssertFalse(AgentUpdateStatus(installed: nil, latest: "0.163.0").updateAvailable)
    }

    func testLatestVersionIsReadFromTheRegistryBody() async {
        let codex = await AgentVersions.latestVersion(service: .codex, fetch: registry(#"{"name":"@openai/codex","version":"0.163.0"}"#))
        XCTAssertEqual(codex, "0.163.0")
        let claude = await AgentVersions.latestVersion(service: .claudeCode, fetch: registry(#"{"version":"2.1.289"}"#))
        XCTAssertEqual(claude, "2.1.289")
    }

    func testLatestVersionIsUnknownOnAnyFailure() async {
        let url = AgentVersions.registryURL(.codex)
        XCTAssertEqual(AgentVersions.registryURL(.claudeCode).absoluteString, "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")
        XCTAssertEqual(url.absoluteString, "https://registry.npmjs.org/@openai/codex/latest")
        let failed: HTTPFetch = { _ in throw URLError(.notConnectedToInternet) }
        let failedValue = await AgentVersions.latestVersion(service: .codex, fetch: failed)
        XCTAssertNil(failedValue)
        let badJSON = await AgentVersions.latestVersion(service: .codex, fetch: registry("<html>"))
        XCTAssertNil(badJSON)
        let redirect = await AgentVersions.latestVersion(service: .codex, fetch: registry("", status: 302))
        XCTAssertNil(redirect)
        let big: HTTPFetch = { request in (Data(repeating: 32, count: AgentVersions.registryLimit + 1), self.httpStatus(request.url!, 200)) }
        let bigValue = await AgentVersions.latestVersion(service: .codex, fetch: big)
        XCTAssertNil(bigValue)
    }

    func testLatestIsKeptForTwelveHoursAndAcrossLaunches() async throws {
        let folder = NSTemporaryDirectory() + "bt-versions-" + UUID().uuidString
        try privateDirectory(folder)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let count = FetchCount()
        let fetch: HTTPFetch = { request in
            count.add()
            return (Data(#"{"version":"0.163.0"}"#.utf8), self.httpStatus(request.url!, 200))
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AgentVersionStore(dataFolder: folder)
        let first = await store.latest(service: .codex, now: start, fetch: fetch)
        XCTAssertEqual(first, "0.163.0")
        XCTAssertEqual(count.value, 1)
        let again = await store.latest(service: .codex, now: start.addingTimeInterval(3600), fetch: fetch)
        XCTAssertEqual(again, "0.163.0")
        XCTAssertEqual(count.value, 1, "a second call within 12 hours makes no request")
        // A relaunch reads the saved check instead of asking the registry again.
        let relaunched = AgentVersionStore(dataFolder: folder)
        let afterRelaunch = await relaunched.latest(service: .codex, now: start.addingTimeInterval(11 * 3600), fetch: fetch)
        XCTAssertEqual(afterRelaunch, "0.163.0")
        XCTAssertEqual(count.value, 1)
        let later = await store.latest(service: .codex, now: start.addingTimeInterval(13 * 3600), fetch: fetch)
        XCTAssertEqual(later, "0.163.0")
        XCTAssertEqual(count.value, 2, "after 12 hours the registry is asked again")
    }
}
