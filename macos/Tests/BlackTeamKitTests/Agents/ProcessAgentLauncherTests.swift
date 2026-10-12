import XCTest
@testable import BlackTeamKit

// The real launcher, with ordinary programs standing in for a tool (no subscription is used).
final class ProcessAgentLauncherTests: XCTestCase {
    func testLinesAndExitStatusArrive() async throws {
        let folder = NSTemporaryDirectory()
        let collected = LineCollector()
        let exit = await ProcessAgentLauncher().run(
            AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo one; echo two >&2; exit 3"], workspace: folder, environment: ["PATH": "/usr/bin:/bin"]),
            timeout: 30, signal: CancelSignal()) { stream, line in collected.add(stream, line) }
        XCTAssertEqual(exit.status, 3)
        XCTAssertFalse(exit.timedOut); XCTAssertFalse(exit.cancelled)
        XCTAssertEqual(collected.lines(.stdout), ["one"])
        XCTAssertEqual(collected.lines(.stderr), ["two"])
    }

    func testStopKillsTheToolAndItsChildren() async throws {
        let signal = CancelSignal()
        let started = Date()
        let task = Task {
            await ProcessAgentLauncher().run(
                AgentCommand(executable: "/bin/sh", arguments: ["-c", "sleep 60 & sleep 60; echo never"], workspace: NSTemporaryDirectory(),
                             environment: ["PATH": "/usr/bin:/bin"]),
                timeout: 120, signal: signal) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        signal.cancel()
        let exit = await task.value
        XCTAssertTrue(exit.cancelled || exit.status == nil, "\(exit)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testMissingWorkspaceIsAStartError() async {
        let exit = await ProcessAgentLauncher().run(
            AgentCommand(executable: "/bin/sh", arguments: ["-c", "true"], workspace: "/no/such/folder/here", environment: ["PATH": "/usr/bin:/bin"]),
            timeout: 10, signal: CancelSignal()) { _, _ in }
        XCTAssertNotNil(exit.spawnError)
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(AgentStream, String)] = []
    func add(_ stream: AgentStream, _ line: String) { lock.lock(); items.append((stream, line)); lock.unlock() }
    func lines(_ stream: AgentStream) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.0 == stream }.map(\.1)
    }
}
