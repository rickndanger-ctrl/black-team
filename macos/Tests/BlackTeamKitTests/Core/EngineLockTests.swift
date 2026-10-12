import XCTest
@testable import BlackTeamKit

final class EngineLockTests: XCTestCase {
    var folder = ""
    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "bt-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: folder) }

    /// Process ids this test treats as running.
    final class Alive: @unchecked Sendable {
        var pids: Set<Int32> = []
    }

    func make(_ program: String, pid: Int32, alive: Alive) -> EngineLock {
        EngineLock(dataFolder: folder, program: program, pid: pid, alive: { alive.pids.contains($0) })
    }

    func testFirstTakesItAndTheFileIsPrivate() throws {
        let alive = Alive(); alive.pids = [100]
        let lock = make("the Black Team app", pid: 100, alive: alive)
        XCTAssertTrue(lock.acquire())
        XCTAssertTrue(lock.isHeld)
        let mode = (try FileManager.default.attributesOfItem(atPath: folder + "/engine.lock")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let saved = try JSONDecoder().decode(EngineLock.Holder.self, from: Data(contentsOf: URL(fileURLWithPath: folder + "/engine.lock")))
        XCTAssertEqual(saved.pid, 100); XCTAssertEqual(saved.program, "the Black Team app"); XCTAssertGreaterThan(saved.started, 0)
        XCTAssertNil(lock.refusalForLocalModel())
        XCTAssertNil(lock.noticeOnce())
    }

    func testSecondTakerStartsButIsToldAndRefusedALocalModel() {
        let alive = Alive(); alive.pids = [100, 200]
        let first = make("the Black Team app", pid: 100, alive: alive)
        let second = make("the black-team command", pid: 200, alive: alive)
        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
        XCTAssertEqual(second.noticeOnce(), "Black Team is also open in the Black Team app. Only one of them can run your local model at a time.")
        XCTAssertNil(second.noticeOnce(), "said once")
        XCTAssertEqual(second.refusalForLocalModel(),
                       "Your local model is in use by the Black Team app. Stop it there, or use a cloud model or a subscription agent here.")
        XCTAssertNil(first.refusalForLocalModel())
    }

    func testStaleLockIsTakenOver() {
        let alive = Alive(); alive.pids = [100, 200]
        let first = make("the Black Team app", pid: 100, alive: alive)
        let second = make("the black-team command", pid: 200, alive: alive)
        XCTAssertTrue(first.acquire())
        alive.pids = [200]                              // the app was killed; its lock file is left behind
        XCTAssertNil(second.otherHolder())
        XCTAssertNil(second.noticeOnce())
        XCTAssertNil(second.refusalForLocalModel())
        XCTAssertTrue(second.isHeld)
    }

    func testDamagedLockFileIsStale() throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: folder + "/engine.lock"))
        let alive = Alive(); alive.pids = [200]
        let lock = make("the black-team command", pid: 200, alive: alive)
        XCTAssertTrue(lock.acquire())
    }

    func testReleaseOnShutdownLetsTheOtherTakeOver() {
        let alive = Alive(); alive.pids = [100, 200]
        let first = make("the Black Team app", pid: 100, alive: alive)
        let second = make("the black-team command", pid: 200, alive: alive)
        first.acquire()
        XCTAssertNotNil(second.refusalForLocalModel())
        first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/engine.lock"))
        XCTAssertNil(second.refusalForLocalModel())     // the refused one can now start its model
        XCTAssertTrue(second.isHeld)
    }

    func testReleaseNeverRemovesSomeoneElsesLock() {
        let alive = Alive(); alive.pids = [100, 200]
        let first = make("a", pid: 100, alive: alive)
        let second = make("b", pid: 200, alive: alive)
        first.acquire()
        second.release()                                // never held it
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/engine.lock"))
    }

    func testBackendTakesAndReleasesTheLockAndRefusesSecondLocalStart() async throws {
        let alive = Alive()
        _ = alive
        let a = try Backend(dataFolder: folder, program: "the Black Team app")
        XCTAssertTrue(a.engineLock.isHeld)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/engine.lock"))
        await a.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/engine.lock"))
    }

    func testRealProcessTableDecidesLiveness() {
        XCTAssertTrue(EngineLock.processExists(getpid()))
        XCTAssertFalse(EngineLock.processExists(0))
        XCTAssertFalse(EngineLock.processExists(Int32.max))
    }
}
