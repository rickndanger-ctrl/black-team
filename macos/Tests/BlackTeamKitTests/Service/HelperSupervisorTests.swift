import XCTest
#if canImport(Glibc)
import Glibc
#endif
@testable import BlackTeamKit

/// The supervised-process facility, with a trivial fake helper (a small script, run directly and never through a shell by the supervisor).
final class HelperSupervisorTests: XCTestCase {
    final class Delays: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [TimeInterval] = []
        func add(_ value: TimeInterval) { lock.lock(); all.append(value); lock.unlock() }
        var list: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return all }
    }

    func folder() throws -> String {
        let made = (PathUtil.realpath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bt-helper-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: made) }
        return made
    }

    func script(_ dir: String, _ name: String, _ body: String) throws -> String {
        let path = dir + "/" + name
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func wait(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testAHelperThatKeepsEndingIsRestartedWithAGrowingWaitUpToACap() async throws {
        let dir = try folder(), delays = Delays()
        let fake = try script(dir, "fake", "echo \"started $$\" >> \"$1\"\necho oops\nexit 3")
        let supervisor = HelperSupervisor(dataFolder: dir, sleep: { delays.add($0) }, poll: 0.01, grace: 1)
        try supervisor.register(HelperSpec(id: "fake", name: "Fake helper", executable: fake, arguments: [dir + "/starts"], initialBackoff: 2, maxBackoff: 10, stableAfter: 3600))
        try supervisor.start()
        try await wait("five restarts") { (supervisor.status().first?.restarts ?? 0) >= 5 }
        await supervisor.stop()
        XCTAssertEqual(Array(delays.list.prefix(5)), [2, 4, 8, 10, 10])
        let status = try XCTUnwrap(supervisor.status().first)
        XCTAssertEqual(status.state, "stopped")
        XCTAssertNil(status.pid)
        XCTAssertEqual(status.lastExit, "It ended with status 3.")
        let starts = try String(contentsOfFile: dir + "/starts", encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThanOrEqual(starts.count, 5)
        // Stopped means stopped: nothing starts again.
        let count = starts.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try String(contentsOfFile: dir + "/starts", encoding: .utf8).split(separator: "\n").count, count)
        // Its output is in a log that can be read back.
        XCTAssertTrue(supervisor.tail("fake").contains("oops"))
    }

    func testAHelperThatRanLongEnoughStartsOverWithTheShortWait() async throws {
        let dir = try folder(), delays = Delays()
        let fake = try script(dir, "fake", "exit 1")
        let supervisor = HelperSupervisor(dataFolder: dir, sleep: { delays.add($0) }, poll: 0.01, grace: 1)
        // Every run counts as long enough, so the wait never grows.
        try supervisor.register(HelperSpec(id: "steady", name: "Steady", executable: fake, initialBackoff: 2, maxBackoff: 60, stableAfter: 0))
        try supervisor.start()
        try await wait("three restarts") { (supervisor.status().first?.restarts ?? 0) >= 3 }
        await supervisor.stop()
        XCTAssertTrue(delays.list.prefix(3).allSatisfy { $0 == 2 }, "\(delays.list)")
    }

    func testStoppingTheSupervisorEndsARunningHelperAndAKillsOneThatIgnoresBeingAsked() async throws {
        let dir = try folder()
        let polite = try script(dir, "polite", "exec sleep 60")
        let stubborn = try script(dir, "stubborn", "trap '' TERM\nwhile true; do sleep 1; done")
        let supervisor = HelperSupervisor(dataFolder: dir, poll: 0.01, grace: 0.5)
        try supervisor.register(HelperSpec(id: "polite", name: "Polite", executable: polite))
        try supervisor.register(HelperSpec(id: "stubborn", name: "Stubborn", executable: stubborn))
        try supervisor.start()
        try await wait("both running") { supervisor.status().allSatisfy { $0.state == "running" && $0.pid != nil } }
        let pids = supervisor.status().compactMap(\.pid)
        XCTAssertEqual(pids.count, 2)
        for pid in pids { XCTAssertTrue(alive(pid)) }
        await supervisor.stop()
        // Both are gone (a child that has ended may linger as a zombie until it is collected; the supervisor waited for them).
        for pid in pids { XCTAssertFalse(alive(pid), "process \(pid) should be gone") }
        XCTAssertTrue(supervisor.status().allSatisfy { $0.state == "stopped" })
    }

    func testAHelperThatStopsAnsweringItsHealthCheckIsRestarted() async throws {
        let dir = try folder()
        let fake = try script(dir, "fake", "echo up >> \"$1\"\nexec sleep 60")
        let supervisor = HelperSupervisor(dataFolder: dir, sleep: { _ in }, poll: 0.01, grace: 1)
        try supervisor.register(HelperSpec(id: "sick", name: "Sick", executable: fake, arguments: [dir + "/ups"], health: { false }, healthEvery: 0.02, healthFailures: 2, initialBackoff: 0))
        try supervisor.start()
        try await wait("a restart") { (supervisor.status().first?.restarts ?? 0) >= 1 }
        await supervisor.stop()
        XCTAssertEqual(supervisor.status().first?.lastExit, "It stopped answering and was restarted.")
        XCTAssertGreaterThanOrEqual(try String(contentsOfFile: dir + "/ups", encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testAHealthyHelperIsLeftAlone() async throws {
        let dir = try folder()
        let fake = try script(dir, "fake", "exec sleep 60")
        let supervisor = HelperSupervisor(dataFolder: dir, sleep: { _ in }, poll: 0.01, grace: 1)
        try supervisor.register(HelperSpec(id: "well", name: "Well", executable: fake, health: { true }, healthEvery: 0.02, healthFailures: 1))
        try supervisor.start()
        try await wait("running") { supervisor.status().first?.state == "running" }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(supervisor.status().first?.restarts, 0)
        await supervisor.stop()
    }

    func testTheRuntimeFolderAndLogsArePrivateAndRegistrationIsChecked() async throws {
        let dir = try folder()
        let fake = try script(dir, "fake", "echo hello")
        let supervisor = HelperSupervisor(dataFolder: dir, sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000_000) }, poll: 0.01, grace: 0.2)
        try supervisor.register(HelperSpec(id: "quiet", name: "Quiet", executable: fake))
        XCTAssertThrowsError(try supervisor.register(HelperSpec(id: "quiet", name: "Again", executable: fake)))
        XCTAssertThrowsError(try supervisor.register(HelperSpec(id: "Bad Id", name: "x", executable: fake)))
        XCTAssertThrowsError(try supervisor.register(HelperSpec(id: "relative", name: "x", executable: "bin/tool")))
        try supervisor.start()
        try await wait("the log") { supervisor.tail("quiet").contains("hello") }
        var info = stat()
        XCTAssertEqual(stat(dir + "/run", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(stat(dir + "/run/quiet.log", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        await supervisor.stop()
    }

    func testTheServiceStartsRegisteredHelpersWithItAndStopsThemWithIt() async throws {
        let rig = try BackgroundRig(self)
        let dir = try folder()
        let fake = try script(dir, "fake", "exec sleep 60")
        try rig.hooks.supervisor.register(HelperSpec(id: "gateway", name: "Gateway", executable: fake))
        try await wait("the helper") { rig.hooks.supervisor.status().first?.state == "running" }
        let pid = try XCTUnwrap(rig.hooks.supervisor.status().first?.pid)
        XCTAssertEqual(rig.hooks.statusJSON()["mode"]?.string, "background")
        await rig.hooks.stopBackgroundParts()
        XCTAssertFalse(alive(pid))
    }
}
