import XCTest
@testable import BlackTeamKit

// Stop pressed before Claude Code or Codex has actually launched. The run must end as interrupted, never hang or crash.
final class AgentStopBeforeLaunchTests: XCTestCase {
    func idle(_ backend: Backend, seconds: Double = 15) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await backend.waitForIdle(); return true }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func testStopRightAfterStartingEndsTheRunAsInterruptedAndTheToolNeverRuns() async throws {
        for service in AgentService.allCases {
            let fixture = try BackendFixture(self)
            let agents = FakeAgentLauncher(lines: claudeRecordedLines.map { (.stdout, $0) })
            agents.holdUntilStopped = true
            let backend = try Backend(
                dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine, memory: nil,
                fetch: { _ in throw URLError(.cannotConnectToHost) }, stream: { _ in throw URLError(.cannotConnectToHost) },
                contextPlanner: nil, discover: { noTools }, terminal: { _, _ in }, home: fixture.files.dir + "/home", keeperInterval: 3600, agents: agents)
            fixture.backends.append(backend)
            addTeardownBlock { await backend.shutdown() }
            let project = try backend.createProject(name: "Stop \(service.engine)")
            _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true)
            let result = try backend.submitAgentTask(service: service, message: "long task", requestId: newID(), project: project.id)
            backend.cancel()
            let finished = await idle(backend)
            XCTAssertTrue(finished, "the run did not end after Stop for \(service.engine)")
            guard finished else { return }
            let thread = try XCTUnwrap(backend.history.get(result.threadId))
            XCTAssertEqual(thread["messages"]?.array?.last?["state"], "interrupted")
            XCTAssertFalse(backend.isBusy)
            XCTAssertTrue(agents.commands.isEmpty, "the tool was started although Stop came first")
        }
    }

    func testTheRealLauncherGivenAStopThatCameFirstDoesNotRunTheTool() async throws {
        let signal = CancelSignal()
        signal.cancel()
        let started = Date()
        let exit = await ProcessAgentLauncher().run(
            AgentCommand(executable: "/bin/sh", arguments: ["-c", "sleep 30; echo never"], workspace: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin"]),
            timeout: 120, signal: signal) { _, _ in }
        XCTAssertTrue(exit.cancelled || exit.status == nil, "\(exit)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}
