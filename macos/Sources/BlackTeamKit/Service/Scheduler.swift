import Foundation

// The scheduler: in the background service, finds the schedules that are due and runs each as a normal conversation in its project
// (it shows in the window, on the phone and in history). One local model slot means one run at a time: a run that comes due while
// another job is going waits its turn. A schedule never overlaps itself, a run missed while the computer was off runs once when the
// service starts (not once per missed time), and a day's runs are capped. The engine's own step and time budgets apply to every run.
//
// A Code run that reaches a step needing an answer does not fail and does not go on: the engine holds it (the usual approval, Engine/Engine.swift),
// and the scheduler copies the question into the inbox. The answer comes from the inbox, the phone's approval card or the command; if
// nobody answers in time the engine ends the run and the scheduler records "not approved".

extension Backend {
    /// The snapshot of the job with this id, while it is still the latest job.
    func jobSnapshot(id: String) -> JobSnapshot? { locked { job?.id == id ? job?.snapshot : nil } }
    /// Something else holds the one model slot: a response, or an optimizing run.
    var modelSlotBusy: Bool { isBusy || tuneState.running }
}

public final class Scheduler: @unchecked Sendable {
    struct Active: Sendable {
        var scheduleId: String
        var requestId: String
        var threadId: String
        var started: Double
    }

    private let backend: Backend
    public let store: ScheduleStore
    public let inbox: InboxStore
    private let settings: @Sendable () -> ServiceSettings
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var queue: [String] = []
    private var active: Active?
    private var loop: Task<Void, Never>?
    private var recovered = false
    /// The last time the scheduler finished or started a run (the idle timer reads it).
    private var lastWork: Date

    public init(backend: Backend, store: ScheduleStore, inbox: InboxStore, settings: @escaping @Sendable () -> ServiceSettings,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.backend = backend; self.store = store; self.inbox = inbox; self.settings = settings; self.now = now; self.calendar = calendar
        lastWork = now()
    }

    // MARK: Running the loop

    /// Checks every few seconds until `stop()`.
    public func start(every seconds: TimeInterval = 5) {
        lock.lock(); defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    public func stop() {
        lock.lock(); let task = loop; loop = nil; lock.unlock()
        task?.cancel()
    }

    // MARK: State for the screens and the idle timer

    /// "running", "waiting" (for an answer), "queued" or nil.
    public func state(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if active?.scheduleId == id { return store.get(id)?.lastRun?.state == "waiting" ? "waiting" : "running" }
        return queue.contains(id) ? "queued" : nil
    }

    /// Work is going or lined up: the model must not be unloaded.
    public var hasWork: Bool { lock.lock(); defer { lock.unlock() }; return active != nil || !queue.isEmpty }

    /// A run is due soon: within this many seconds.
    public func nextDue() -> Date? {
        store.list().filter(\.enabled).compactMap { $0.nextRun.map { Date(timeIntervalSince1970: $0) } }.min()
    }

    public var lastWorkAt: Date { lock.lock(); defer { lock.unlock() }; return lastWork }

    // MARK: Asking for a run

    /// "Run now": queues this schedule at once, paused or not. A schedule that is already running or waiting is not queued twice.
    public func runNow(_ id: String) throws {
        guard store.get(id) != nil else { throw BlackTeamError("That schedule no longer exists.") }
        lock.lock(); defer { lock.unlock() }
        if active?.scheduleId == id { throw BlackTeamError("That schedule is already running.") }
        if queue.contains(id) { throw BlackTeamError("That schedule is already waiting for its turn.") }
        queue.append(id)
    }

    // MARK: One pass

    public func tick() async {
        recoverOnce()
        await watchActive()
        enqueueDue()
        await startNext()
    }

    /// Runs that were going when the service last stopped did not finish: say so, and settle their questions.
    private func recoverOnce() {
        lock.lock(); let first = !recovered; recovered = true; lock.unlock()
        guard first else { return }
        for schedule in store.list() where schedule.lastRun?.isOpen == true {
            _ = try? store.change(schedule.id) { item, _ in
                item.lastRun?.state = "interrupted"
                item.lastRun?.note = "Black Team stopped before this run finished."
                item.lastRun?.finished = self.now().timeIntervalSince1970
            }
        }
        try? inbox.settleAll(as: "ended", at: now())
    }

    /// Schedules whose time has come join the queue. The next time is worked out from now, so a run missed for a day (or a hundred
    /// times) runs once.
    private func enqueueDue() {
        let moment = now()
        for schedule in store.list() where schedule.enabled {
            guard let due = schedule.nextRun, Date(timeIntervalSince1970: due) <= moment else { continue }
            _ = try? store.change(schedule.id) { item, _ in
                item.nextRun = item.when.next(after: moment, calendar: self.calendar)?.timeIntervalSince1970
                // A once that has run is finished.
                if item.nextRun == nil { item.enabled = false }
            }
            lock.lock()
            // A schedule that is still running or waiting is skipped, not queued behind itself.
            let overlapping = active?.scheduleId == schedule.id || queue.contains(schedule.id)
            if !overlapping { queue.append(schedule.id) }
            lock.unlock()
            if overlapping { noteSkipped(schedule.id, "Skipped: the last run was still going.") }
        }
    }

    private func noteSkipped(_ id: String, _ note: String) {
        _ = try? store.change(id) { item, _ in
            // Never overwrite the run that is going.
            if item.lastRun?.isOpen == true { return }
            item.lastRun = ScheduleRun(at: self.now().timeIntervalSince1970, state: "skipped", note: note, finished: self.now().timeIntervalSince1970)
        }
    }

    // MARK: Starting

    private func startNext() async {
        while true {
            guard let id = lock.withLock({ active == nil ? queue.first : nil }) else { return }
            // One local model slot: wait while a response (or optimizing) holds it.
            if backend.modelSlotBusy { return }
            lock.withLock { _ = queue.removeFirst() }
            guard let schedule = store.get(id) else { continue }
            let outcome = await begin(schedule)
            if outcome == .wait {
                // Something else took the slot between the check and the send: keep its place at the front.
                lock.withLock { queue.insert(id, at: 0) }
                return
            }
        }
    }

    private enum Begin { case started, ended, wait }

    private func fail(_ schedule: Schedule, state: String = "error", _ note: String) {
        let moment = now().timeIntervalSince1970
        _ = try? store.change(schedule.id) { item, _ in item.lastRun = ScheduleRun(at: moment, state: state, note: note, finished: moment) }
    }

    private func begin(_ schedule: Schedule) async -> Begin {
        let limit = settings().maxRunsPerDay
        if store.runsToday() >= limit {
            fail(schedule, state: "skipped", "Skipped: the limit of \(limit) scheduled runs a day was reached.")
            return .ended
        }
        if let project = schedule.project, backend.projectFolder(project) == nil {
            fail(schedule, "The project for this schedule no longer exists. Edit the schedule to choose another.")
            return .ended
        }
        // A named model is switched to first (the one in use otherwise). It stays the model in use afterwards.
        if let model = schedule.model, let config = try? backend.configStore.read(), keyOf(config.model) != model {
            do { _ = try await backend.switchTo(key: model) }
            catch {
                let text = messageOf(error)
                if text.contains("Wait for the current response") { return .wait }
                fail(schedule, text)
                return .ended
            }
        }
        let requestId = UUID().uuidString.lowercased()
        let policy = schedule.kind == "agent" ? UnattendedPolicy(permission: schedule.permission, approvalSeconds: settings().approvalHours * 3600) : nil
        do {
            let result = try backend.submit(message: schedule.message, kind: schedule.kind, mode: "balanced", requestId: requestId, threadId: nil,
                                            project: schedule.project, from: .mac, unattended: policy)
            let moment = now()
            try? store.countRun()
            let title = "\(schedule.name) \u{00B7} \(Self.stamp(moment, calendar))"
            try? backend.renameThread(result.threadId, title: String(title.prefix(120)))
            _ = try? store.change(schedule.id) { item, _ in
                item.lastRun = ScheduleRun(at: moment.timeIntervalSince1970, state: "running", threadId: result.threadId, note: "Started.")
            }
            lock.withLock { active = Active(scheduleId: schedule.id, requestId: requestId, threadId: result.threadId, started: moment.timeIntervalSince1970); lastWork = moment }
            return .started
        } catch {
            let text = messageOf(error)
            if text.hasPrefix("A response is already running") || text.hasPrefix("Black Team is optimizing") { return .wait }
            fail(schedule, text)
            return .ended
        }
    }

    static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[max(0, min(11, (c.month ?? 1) - 1))]) \(c.day ?? 1), \(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
    }

    // MARK: Watching the run that is going

    private func watchActive() async {
        guard let current = lock.withLock({ active }) else { return }
        if let snapshot = backend.jobSnapshot(id: current.requestId) {
            if snapshot.state == "running" {
                updateWaiting(current, snapshot)
                return
            }
            finish(current, state: snapshot.state)
            return
        }
        // The job is no longer the latest one: read how the request ended from the saved conversation.
        finish(current, state: backend.history.request(current.requestId)?["state"]?.string ?? "interrupted")
    }

    /// A question from the run shows in the inbox; once it is gone (answered, or run out) the run is "running" again.
    private func updateWaiting(_ current: Active, _ snapshot: JobSnapshot) {
        guard let schedule = store.get(current.scheduleId) else { return }
        if let ask = snapshot.approval {
            let item = InboxItem(id: ask.id, scheduleId: schedule.id, scheduleName: schedule.name, threadId: current.threadId, project: schedule.project,
                                 command: ask.command, question: ask.description, digest: ask.digest, created: now().timeIntervalSince1970,
                                 expires: Double(ask.expires) / 1000, state: "waiting", answered: nil)
            try? inbox.add(item)
            if schedule.lastRun?.state != "waiting" {
                _ = try? store.change(schedule.id) { item, _ in item.lastRun?.state = "waiting"; item.lastRun?.note = "Waiting for your answer." }
            }
        } else if schedule.lastRun?.state == "waiting" {
            // Whatever answered it (the inbox, the phone, the command) has settled it; if nobody did, the run is still going.
            try? inbox.settleAll(scheduleId: schedule.id, as: "answered", at: now())
            _ = try? store.change(schedule.id) { item, _ in item.lastRun?.state = "running"; item.lastRun?.note = "Running." }
        }
    }

    private func finish(_ current: Active, state: String) {
        let moment = now()
        var outcome = "done", note = "Finished."
        let reply = backend.history.get(current.threadId)?["messages"]?.array?.last
        let error = reply?["error"]?.string
        switch state {
        case "done":
            let text = reply?["content"]?.string ?? ""
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            note = first.isEmpty ? "Finished." : String(first.prefix(200))
        case "interrupted":
            outcome = "stopped"; note = "Stopped before it finished."
        default:
            if error == Engine.notApprovedMessage { outcome = "not-approved"; note = Engine.notApprovedMessage }
            else { outcome = "error"; note = String((error ?? "The run did not finish.").prefix(300)) }
        }
        // A question that was never answered ran out; any other still waiting ended with the run.
        try? inbox.settleAll(scheduleId: current.scheduleId, as: outcome == "not-approved" ? "expired" : "ended", at: moment)
        let name = store.get(current.scheduleId)?.name ?? "Scheduled run"
        // The run's own save came after the title was first set, so it is set again now that the conversation is final.
        try? backend.renameThread(current.threadId, title: String("\(name) \u{00B7} \(Self.stamp(Date(timeIntervalSince1970: current.started), calendar))".prefix(120)))
        _ = try? store.change(current.scheduleId) { item, _ in
            item.lastRun = ScheduleRun(at: current.started, state: outcome, threadId: current.threadId, note: note, finished: moment.timeIntervalSince1970)
        }
        lock.lock(); active = nil; lastWork = moment; lock.unlock()
    }
}

extension Backend {
    /// The folder of a project, if the project still exists.
    func projectFolder(_ id: String) -> String? { locked { projects.first { $0.id == id }?.workspace } }
}
