import XCTest
@testable import BlackTeamKit

/// Scheduled work: catch-up, no overlap, one model slot, caps, approvals with nobody there, and the idle unload.
final class SchedulerTests: XCTestCase {
    func testADueScheduleRunsAsANormalConversationInItsProject() async throws {
        let rig = try BackgroundRig(self)
        rig.engine.action = { ref, _ in ref.updateLast { $0["content"] = "All 12 tests pass.\nNothing changed." } }
        let schedule = try rig.add("Test check")
        rig.clock.advance(31 * 60)
        await rig.scheduler.tick()
        try await rig.waitFor("the run to start") { rig.run(schedule.id) != nil }
        await rig.finish()
        let last = try XCTUnwrap(rig.run(schedule.id))
        XCTAssertEqual(last.state, "done")
        XCTAssertEqual(last.note, "All 12 tests pass.")
        let threadId = try XCTUnwrap(last.threadId)
        let thread = try XCTUnwrap(rig.backend.history.get(threadId))
        XCTAssertEqual(thread["project"]?.string, rig.project.id)
        XCTAssertEqual(thread["kind"]?.string, "agent")
        XCTAssertEqual(thread["title"]?.string, "Test check \u{00B7} Oct 13, 08:31")
        XCTAssertEqual(thread["messages"]?.array?.first?["content"]?.string, "Check the tests.")
        // The run was Code in the project's folder, with the usual rules (no unattended limits were asked for beyond "ask").
        XCTAssertEqual(rig.engine.runs.first?.workspace, rig.project.workspace)
        XCTAssertEqual(rig.store.runsToday(), 1)
        XCTAssertNil(rig.scheduler.state(of: schedule.id))
        XCTAssertTrue(rig.store.get(schedule.id)!.nextRun! > rig.clock.now.timeIntervalSince1970)
    }

    func testAChatScheduleRunsAsChatWithNoToolLimits() async throws {
        let rig = try BackgroundRig(self)
        let schedule = try rig.add("Digest", kind: "chat", message: "Summarise yesterday.")
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        await rig.finish()
        let last = try XCTUnwrap(rig.run(schedule.id))
        XCTAssertEqual(last.state, "done", last.note)
        XCTAssertEqual(rig.backend.history.get(try XCTUnwrap(last.threadId))?["kind"]?.string, "chat")
        XCTAssertEqual(rig.engine.runs.count, 0)
    }

    func testARunMissedWhileTheComputerWasOffRunsOnceNotOncePerMissedTime() async throws {
        let rig = try BackgroundRig(self)
        let schedule = try rig.add("Frequent", when: .every(minutes: 30))
        // Off for ten hours: twenty runs were missed.
        rig.clock.advance(10 * 3600)
        await rig.scheduler.tick()
        await rig.finish()
        await rig.scheduler.tick()
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 1)
        XCTAssertEqual(rig.store.runsToday(), 1)
        let next = try XCTUnwrap(rig.store.get(schedule.id)?.nextRun)
        XCTAssertEqual(next, rig.clock.now.timeIntervalSince1970 + 30 * 60, accuracy: 1)
        // A daily one missed for three days is the same.
        let daily = try rig.add("Daily", when: .daily(hour: 9, minute: 0))
        rig.clock.advance(3 * 24 * 3600)
        await rig.scheduler.tick()
        await rig.finish()
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 3, "one for each schedule that was due: the 30-minute one and the daily one")
        XCTAssertEqual(rig.run(daily.id)?.state, "done")
    }

    func testAOnceThatWasMissedRunsOnStartAndIsThenFinished() async throws {
        let rig = try BackgroundRig(self)
        let at = rig.clock.now.addingTimeInterval(3600)
        let schedule = try rig.add("One time", when: .once(at: at))
        rig.clock.advance(5 * 3600)
        await rig.scheduler.tick()
        await rig.finish()
        XCTAssertEqual(rig.engine.runs.count, 1)
        let after = try XCTUnwrap(rig.store.get(schedule.id))
        XCTAssertNil(after.nextRun)
        XCTAssertFalse(after.enabled)
        let state = rig.hooks.scheduleJSON(after)["state"]?.string
        XCTAssertEqual(state, "finished")
        rig.clock.advance(24 * 3600)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 1)
    }

    func testAScheduleNeverOverlapsItself() async throws {
        let rig = try BackgroundRig(self)
        let gate = BackendGate()
        rig.engine.action = { ref, _ in await gate.wait(); ref.updateLast { $0["content"] = "Done." } }
        let schedule = try rig.add("Slow", when: .every(minutes: 5))
        rig.clock.advance(6 * 60)
        await rig.scheduler.tick()
        try await rig.waitFor("the run to start") { rig.engine.runs.count == 1 }
        XCTAssertEqual(rig.scheduler.state(of: schedule.id), "running")
        // It comes due again while it is still going: that one is skipped, nothing starts beside it, nothing queues behind it.
        rig.clock.advance(6 * 60)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 1)
        XCTAssertEqual(rig.run(schedule.id)?.state, "running", "the run that is going keeps its record")
        XCTAssertThrowsError(try rig.scheduler.runNow(schedule.id)) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "That schedule is already running.") }
        await gate.open()
        await rig.finish()
        XCTAssertEqual(rig.run(schedule.id)?.state, "done")
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 1)
        XCTAssertFalse(rig.scheduler.hasWork)
    }

    func testARunWaitsItsTurnBehindARunningJobAndOthersWaitBehindIt() async throws {
        let rig = try BackgroundRig(self)
        let gate = BackendGate()
        rig.engine.action = { ref, _ in await gate.wait(); ref.updateLast { $0["content"] = "Done." } }
        // A person's own job holds the one model slot.
        _ = try rig.backend.submit(message: "My own task", kind: "agent", mode: "balanced", requestId: newID())
        try await rig.waitFor("the job to start") { rig.engine.runs.count == 1 }
        let first = try rig.add("First"), second = try rig.add("Second")
        rig.clock.advance(31 * 60)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.scheduler.state(of: first.id), "queued")
        XCTAssertEqual(rig.scheduler.state(of: second.id), "queued")
        XCTAssertEqual(rig.engine.runs.count, 1, "nothing starts while the slot is busy")
        XCTAssertTrue(rig.scheduler.hasWork)
        await gate.open()
        await rig.backend.waitForIdle()
        // The slot is free: the first queued run starts, and the second waits for it.
        await rig.scheduler.tick()
        try await rig.waitFor("the first run") { rig.engine.runs.count == 2 }
        XCTAssertEqual(rig.run(first.id)?.state, "running")
        XCTAssertEqual(rig.scheduler.state(of: second.id), "queued")
        await rig.finish()
        await rig.scheduler.tick()
        try await rig.waitFor("the second run") { rig.engine.runs.count == 3 }
        await rig.finish()
        XCTAssertEqual(rig.run(first.id)?.state, "done")
        XCTAssertEqual(rig.run(second.id)?.state, "done")
    }

    func testTheDailyLimitSkipsRunsAndSaysSo() async throws {
        let rig = try BackgroundRig(self)
        try rig.hooks.settings.save(ServiceSettings(idleMinutes: 10, approvalHours: 24, maxRunsPerDay: 2))
        let schedule = try rig.add("Busy")
        for _ in 0..<2 {
            try rig.scheduler.runNow(schedule.id)
            await rig.scheduler.tick()
            await rig.finish()
            XCTAssertEqual(rig.run(schedule.id)?.state, "done")
        }
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 2)
        XCTAssertEqual(rig.run(schedule.id)?.state, "skipped")
        XCTAssertEqual(rig.run(schedule.id)?.note, "Skipped: the limit of 2 scheduled runs a day was reached.")
        // Tomorrow it counts from zero again.
        rig.clock.advance(24 * 3600)
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        await rig.finish()
        XCTAssertEqual(rig.engine.runs.count, 3)
    }

    func testAPausedScheduleDoesNotRunByItselfButRunNowStillWorks() async throws {
        let rig = try BackgroundRig(self)
        let schedule = try rig.add("Pausable")
        _ = try rig.store.setEnabled(schedule.id, false)
        rig.clock.advance(2 * 3600)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 0)
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        await rig.finish()
        XCTAssertEqual(rig.engine.runs.count, 1)
        XCTAssertFalse(rig.store.get(schedule.id)!.enabled, "running it by hand does not resume it")
        XCTAssertThrowsError(try rig.scheduler.runNow("nope")) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "That schedule no longer exists.") }
    }

    func testARunWhoseProjectWasRemovedSaysWhatIsWrongInsteadOfRunning() async throws {
        let rig = try BackgroundRig(self)
        var schedule = try rig.add("Orphan")
        schedule = try rig.store.change(schedule.id) { item, _ in item.project = newID() }
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        XCTAssertEqual(rig.engine.runs.count, 0)
        XCTAssertEqual(rig.run(schedule.id)?.state, "error")
        XCTAssertTrue(rig.run(schedule.id)?.note.contains("no longer exists") == true)
    }

    func testAScheduleThatNamesAnotherModelSwitchesToItFirst() async throws {
        let rig = try BackgroundRig(self)
        // Two saved models; the schedule names the second.
        let config = try rig.backend.configStore.read()
        var other = ModelConfig(source: "server", endpoint: "http://127.0.0.1:5555/v1", id: "a-custom-model", apiKey: "private-server-credential", name: "Second model")
        other.context = config.model.context
        let key = try rig.backend.savedModels.remember(other)
        let schedule = try rig.hooks.saveSchedule(["name": "Other model", "message": "Hi", "kind": "chat", "whenText": "every 30 minutes", "model": .string(key)])
        try rig.scheduler.runNow(try XCTUnwrap(schedule["id"]?.string))
        await rig.scheduler.tick()
        await rig.finish()
        XCTAssertEqual(try rig.backend.configStore.read().model.name, "Second model")
    }

    // MARK: Approvals with nobody there

    /// A Code run that asks one question and waits for it, like the engine does.
    func askingEngine(_ rig: BackgroundRig, id: String = "ask-1", expires: Double = 0, then: @escaping @Sendable (ThreadRef, String) -> Void) {
        rig.engine.action = { ref, job in
            let choice: String = await withCheckedContinuation { continuation in
                job.present(PendingApproval(id: id, digest: "digest-1", command: "rm -rf build", description: "Run this command on your computer?",
                                            expires: Int64(expires == 0 ? (Date().timeIntervalSince1970 + 86400) * 1000 : expires * 1000))) { answer in
                    guard answer.id == id, answer.digest == "digest-1", ["once", "deny"].contains(answer.choice) else { throw BlackTeamError("No matching active approval.") }
                    job.withdraw()
                    continuation.resume(returning: answer.choice)
                }
            }
            then(ref, choice)
        }
    }

    func testAQuestionWaitsInTheInboxAndTheRunStaysWaitingUntilSomeoneAnswers() async throws {
        let rig = try BackgroundRig(self)
        askingEngine(rig) { ref, choice in ref.updateLast { $0["content"] = choice == "once" ? "Cleaned the build folder." : "Left it alone." } }
        let schedule = try rig.add("Cleanup")
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        try await rig.waitFor("the question") { rig.backend.status_job?.approval != nil }
        await rig.scheduler.tick()
        // Not failed, not going on: waiting, with the question saved.
        XCTAssertEqual(rig.run(schedule.id)?.state, "waiting")
        XCTAssertEqual(rig.scheduler.state(of: schedule.id), "waiting")
        let waiting = rig.inbox.waiting()
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.command, "rm -rf build")
        XCTAssertEqual(waiting.first?.question, "Run this command on your computer?")
        XCTAssertEqual(waiting.first?.scheduleName, "Cleanup")
        XCTAssertEqual(waiting.first?.threadId, rig.run(schedule.id)?.threadId)
        XCTAssertEqual(rig.hooks.statusJSON()["inbox"]?.int, 1, "the window's badge")
        // The same question is on the job, where the phone's approval card reads it.
        XCTAssertEqual(rig.backend.status_job?.approval?.id, "ask-1")
        // The inbox is read the same on a second look: nothing is added twice.
        await rig.scheduler.tick()
        XCTAssertEqual(rig.inbox.all().count, 1)
        // Approving from the inbox lets that step run and the run carry on.
        try rig.hooks.answer("ask-1", approve: true)
        XCTAssertEqual(rig.inbox.get("ask-1")?.state, "approved")
        await rig.finish()
        XCTAssertEqual(rig.run(schedule.id)?.state, "done")
        XCTAssertEqual(rig.run(schedule.id)?.note, "Cleaned the build folder.")
        XCTAssertTrue(rig.inbox.waiting().isEmpty)
        // Answering a second time is refused plainly.
        XCTAssertThrowsError(try rig.hooks.answer("ask-1", approve: true)) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "That question is not waiting any more.") }
    }

    func testDenyingFromTheInboxRefusesThatStep() async throws {
        let rig = try BackgroundRig(self)
        askingEngine(rig) { ref, choice in ref.updateLast { $0["content"] = choice == "once" ? "Cleaned." : "Left it alone." } }
        let schedule = try rig.add("Cleanup")
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        try await rig.waitFor("the question") { rig.backend.status_job?.approval != nil }
        await rig.scheduler.tick()
        try rig.hooks.answer("ask-1", approve: false)
        XCTAssertEqual(rig.inbox.get("ask-1")?.state, "denied")
        await rig.finish()
        XCTAssertEqual(rig.run(schedule.id)?.note, "Left it alone.")
    }

    func testAnAnswerFromThePhonesApprovalCardSettlesTheInboxToo() async throws {
        let rig = try BackgroundRig(self)
        askingEngine(rig) { ref, _ in ref.updateLast { $0["content"] = "Done." } }
        let schedule = try rig.add("Cleanup")
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        try await rig.waitFor("the question") { rig.backend.status_job?.approval != nil }
        await rig.scheduler.tick()
        // The phone answers through the engine's own approval.
        try rig.backend.approve(id: "ask-1", digest: "digest-1", choice: "once")
        await rig.scheduler.tick()
        XCTAssertTrue(rig.inbox.waiting().isEmpty)
        XCTAssertEqual(rig.inbox.get("ask-1")?.state, "answered")
        await rig.finish()
        XCTAssertEqual(rig.run(schedule.id)?.state, "done")
    }

    func testAQuestionNobodyAnswersEndsTheRunAsNotApprovedAndTheInboxSaysItRanOut() async throws {
        let rig = try BackgroundRig(self)
        rig.engine.action = { _, job in
            job.present(PendingApproval(id: "ask-2", digest: "d", command: "git push", description: "Run this command on your computer?", expires: 0)) { _ in }
            // The engine's own timer ran out (Engine/Engine.swift): it ends the turn with this message.
            job.withdraw()
            throw BlackTeamError(Engine.notApprovedMessage)
        }
        let schedule = try rig.add("Push")
        try rig.scheduler.runNow(schedule.id)
        await rig.scheduler.tick()
        try await rig.waitFor("the run to end") { rig.backend.status_job?.state == "error" }
        await rig.scheduler.tick()
        XCTAssertEqual(rig.run(schedule.id)?.state, "not-approved")
        XCTAssertEqual(rig.run(schedule.id)?.note, Engine.notApprovedMessage)
        XCTAssertTrue(rig.inbox.waiting().isEmpty)
        XCTAssertNil(rig.scheduler.state(of: schedule.id))
    }

    func testARunThatWasWaitingWhenTheServiceStoppedIsMarkedInterruptedAndItsQuestionEnded() async throws {
        let rig = try BackgroundRig(self)
        let schedule = try rig.add("Interrupted")
        _ = try rig.store.change(schedule.id) { item, _ in item.lastRun = ScheduleRun(at: 1, state: "waiting", note: "Waiting for your answer.") }
        try rig.inbox.add(InboxItem(id: "old", scheduleId: schedule.id, scheduleName: "Interrupted", threadId: nil, project: nil, command: "rm x", question: "Run?", digest: "d",
                                    created: 1, expires: 2, state: "waiting", answered: nil))
        let fresh = Scheduler(backend: rig.backend, store: rig.store, inbox: rig.inbox, settings: { ServiceSettings() }, now: { rig.clock.now }, calendar: rig.calendar)
        await fresh.tick()
        XCTAssertEqual(rig.run(schedule.id)?.state, "interrupted")
        XCTAssertEqual(rig.inbox.get("old")?.state, "ended")
    }

    // MARK: Idle

    func testTheModelIsUnloadedAfterTheIdleTimeAndStartedAgainOnDemand() async throws {
        let rig = try BackgroundRig(self)
        rig.runtime.state = .ready
        rig.runtime.stopAction = { [runtime = rig.runtime] in runtime.state = .off }
        rig.runtime.startAction = { [runtime = rig.runtime] in runtime.state = .ready; return "http://127.0.0.1:5555/v1" }
        let idle = try XCTUnwrap(rig.hooks.idle)
        let began = rig.clock.now
        _ = began
        var stopped = await idle.tick()
        XCTAssertFalse(stopped)
        rig.clock.advance(9 * 60)
        stopped = await idle.tick()
        XCTAssertFalse(stopped, "nine minutes is not ten")
        rig.clock.advance(61)
        stopped = await idle.tick()
        XCTAssertTrue(stopped)
        XCTAssertEqual(rig.runtime.stops, [false])
        XCTAssertNotNil(idle.unloaded)
        let status = rig.hooks.statusJSON()
        XCTAssertEqual(status["unloaded"]?.bool, true)
        XCTAssertEqual(status["unloadedText"]?.string, "Model unloaded to free memory")
        // The next message starts it again, with nothing else to do.
        let before = rig.runtime.starts
        _ = try rig.backend.submit(message: "Hello again", kind: "chat", mode: "balanced", requestId: newID())
        await rig.backend.waitForIdle()
        XCTAssertEqual(rig.runtime.starts, before + 1)
        _ = await idle.tick()
        XCTAssertNil(idle.unloaded)
        XCTAssertEqual(rig.hooks.statusJSON()["unloaded"]?.bool, false)
    }

    func testTheModelIsNeverUnloadedWhileAJobRunsOrAWindowIsOpenOrWorkIsWaiting() async throws {
        let rig = try BackgroundRig(self)
        rig.runtime.state = .ready
        let idle = try XCTUnwrap(rig.hooks.idle)
        let gate = BackendGate()
        rig.engine.action = { ref, _ in await gate.wait(); ref.updateLast { $0["content"] = "Done." } }
        _ = try rig.backend.submit(message: "A long task", kind: "agent", mode: "balanced", requestId: newID())
        try await rig.waitFor("the job") { rig.engine.runs.count == 1 }
        rig.clock.advance(3 * 3600)
        var stopped = await idle.tick()
        XCTAssertFalse(stopped, "a job is running")
        XCTAssertTrue(rig.runtime.stops.isEmpty)
        await gate.open()
        await rig.backend.waitForIdle()
        // The job just ended: the idle clock starts from its end.
        stopped = await idle.tick()
        XCTAssertFalse(stopped)
        rig.backend.locked { rig.backend.lastActivity = rig.clock.now }
        rig.clock.advance(11 * 60)
        // A window that talked to the service a few seconds ago is open.
        idle.noteWindow()
        stopped = await idle.tick()
        XCTAssertFalse(stopped, "a window is attached")
        rig.clock.advance(IdleUnloader.windowGrace + 1)
        // A scheduled run is waiting for its turn.
        let schedule = try rig.add("Soon")
        try rig.scheduler.runNow(schedule.id)
        rig.clock.advance(11 * 60)
        rig.backend.locked { rig.backend.lastActivity = rig.clock.now.addingTimeInterval(-3600) }
        stopped = await idle.tick()
        XCTAssertFalse(stopped, "work is lined up")
        await rig.scheduler.tick()
        await rig.finish()
        rig.clock.advance(11 * 60)
        stopped = await idle.tick()
        XCTAssertTrue(stopped, "now it is idle")
    }

    func testAnIdleTimeOfZeroNeverUnloadsAndTheSettingsAreChecked() async throws {
        let rig = try BackgroundRig(self)
        try rig.hooks.settings.save(ServiceSettings(idleMinutes: 0, approvalHours: 24, maxRunsPerDay: 24))
        rig.runtime.state = .ready
        let idle = try XCTUnwrap(rig.hooks.idle)
        rig.clock.advance(24 * 3600)
        let stopped = await idle.tick()
        XCTAssertFalse(stopped)
        XCTAssertThrowsError(try rig.hooks.settings.save(ServiceSettings(idleMinutes: -1)))
        XCTAssertThrowsError(try rig.hooks.settings.save(ServiceSettings(approvalHours: 0)))
        XCTAssertThrowsError(try rig.hooks.settings.save(ServiceSettings(maxRunsPerDay: 500)))
        XCTAssertEqual(rig.hooks.settings.read().idleMinutes, 0)
    }
}

extension Backend {
    /// The latest job, however it ended.
    var status_job: JobSnapshot? { locked { job?.snapshot } }
}
