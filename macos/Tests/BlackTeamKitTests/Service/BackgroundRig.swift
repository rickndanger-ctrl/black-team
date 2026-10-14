import XCTest
@testable import BlackTeamKit

/// A background service's parts on a fake runtime and a fake Code engine, with a clock the test moves and a ticked scheduler (no timers).
final class BackgroundRig {
    let fixture: BackendFixture
    let backend: Backend
    let hooks: ServiceHooks
    let clock: Clock
    let calendar: Calendar
    let project: ProjectSummary
    var scheduler: Scheduler { hooks.scheduler! }
    var store: ScheduleStore { hooks.schedules }
    var inbox: InboxStore { hooks.inbox }
    var engine: StubEngine { fixture.engine }
    var runtime: StubRuntime { fixture.runtime }

    init(_ test: XCTestCase) throws {
        fixture = try BackendFixture(test)
        let work = fixture.files.dir + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false)
        try fixture.rewriteConfig { $0.workspace = work }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        calendar = cal
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 8))!
        let clock = Clock(start)
        self.clock = clock
        let requests = fixture.requests
        let reply: HTTPStreamFetch = { [fixture] request in try await fixture.reply(request) }
        // The same Backend the fixture makes, but on the test's clock.
        backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.engine,
            fetch: { _ in throw URLError(.cannotConnectToHost) }, stream: { request in requests.add(request); return try await reply(request) },
            contextPlanner: { messages, context, _, _, _, _ in
                PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, _ in }, now: { clock.now }, home: fixture.files.dir + "/home", keeperInterval: 3600)
        test.addTeardownBlock { [backend] in await backend.shutdown() }
        project = try backend.createProject(name: "Garden")
        hooks = ServiceHooks(backend: backend, mode: .background, now: { clock.now }, calendar: cal)
        backend.service = hooks
        try hooks.startBackgroundParts(scripts: nil, startLoops: false)
        test.addTeardownBlock { [hooks] in await hooks.stopBackgroundParts() }
    }

    /// A schedule saved now.
    @discardableResult
    func add(_ name: String = "Nightly", when: ScheduleWhen = .every(minutes: 30), kind: String = "agent", permission: UnattendedPermission = .ask,
             message: String = "Check the tests.") throws -> Schedule {
        try store.save(Schedule(name: name, project: project.id, kind: kind, message: message, when: when, permission: permission))
    }

    /// Lets the engine run and the job end, then notices that it ended.
    func finish() async {
        await backend.waitForIdle()
        await scheduler.tick()
    }

    func run(_ id: String) -> ScheduleRun? { store.get(id)?.lastRun }

    func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
