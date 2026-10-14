import Foundation

// What the desktop service offers on top of the engine for the background service: the saved schedules and inbox, the settings, the
// install switch, and a few words for the status. It exists in both modes of the desktop service: in the window's own engine it only
// reads and edits the files (nothing runs on a schedule there); in the background service it also has the scheduler, the idle timer and
// the helpers. The routes (Service/ServiceRoutes.swift) and the commands talk to this.

public final class ServiceHooks: @unchecked Sendable {
    public enum Mode: String, Sendable { case window, background }

    public let mode: Mode
    let backend: Backend
    public let schedules: ScheduleStore
    public let inbox: InboxStore
    public let settings: ServiceSettingsStore
    public let manager: ServiceManager
    public let supervisor: HelperSupervisor
    public private(set) var scheduler: Scheduler?
    public private(set) var idle: IdleUnloader?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let controlLock = NSLock()
    private var heldControl: DesktopControl?
    /// What `POST /api/service/control` needs besides the session cookie. Nil (a window\u{2019}s own engine): the route does not exist.
    var controlKey: String?
    /// The control channel's actions, for a window attached over HTTP. The desktop service keeps this one current.
    var control: DesktopControl? {
        get { controlLock.lock(); defer { controlLock.unlock() }; return heldControl }
        set { controlLock.lock(); heldControl = newValue; controlLock.unlock() }
    }

    /// The schedules and inbox for a command that has its own engine open (no background service is running).
    public static func local(_ backend: Backend) -> ServiceHooks {
        if let existing = backend.locked({ backend.service }) { return existing }
        let made = ServiceHooks(backend: backend, mode: .window)
        backend.locked { backend.service = made }
        return made
    }

    init(backend: Backend, mode: Mode, manager: ServiceManager? = nil, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.backend = backend; self.mode = mode; self.now = now; self.calendar = calendar
        schedules = ScheduleStore(dataFolder: backend.dataFolder, now: now, calendar: calendar)
        inbox = InboxStore(dataFolder: backend.dataFolder)
        settings = ServiceSettingsStore(dataFolder: backend.dataFolder)
        self.manager = manager ?? ServiceManager(dataFolder: backend.dataFolder)
        supervisor = HelperSupervisor(dataFolder: backend.dataFolder)
    }

    /// Starts the parts that only the background service has.
    func startBackgroundParts(scripts: String?, startLoops: Bool = true) throws {
        let store = settings
        let scheduler = Scheduler(backend: backend, store: schedules, inbox: inbox, settings: { store.read() }, now: now, calendar: calendar)
        let idle = IdleUnloader(backend: backend, scheduler: scheduler, settings: { store.read() }, now: now)
        self.scheduler = scheduler; self.idle = idle
        if startLoops { scheduler.start(); idle.start() }
        let context = ServiceContext(dataFolder: backend.dataFolder, scripts: scripts, integrations: backend.integrations)
        for spec in ServiceHelpers.specs(for: context) { try supervisor.register(spec) }
        try supervisor.start()
    }

    func stopBackgroundParts() async {
        scheduler?.stop(); idle?.stop()
        await supervisor.stop()
    }

    /// A window (not the command) just talked to the service.
    func noteWindow() { idle?.noteWindow() }

    // MARK: Status

    /// The block added to the window's status (`status.service`).
    public func statusJSON() -> JSONValue {
        let waiting = inbox.waiting().count
        var object: [String: JSONValue] = ["mode": .string(mode.rawValue), "inbox": .number(Double(waiting))]
        if let at = idle?.unloaded {
            object["unloaded"] = true
            object["unloadedAt"] = .number(at.timeIntervalSince1970)
            object["unloadedText"] = "Model unloaded to free memory"
        } else {
            object["unloaded"] = false
        }
        if mode == .background, let next = scheduler?.nextDue() { object["nextRun"] = .number(next.timeIntervalSince1970) }
        return .object(object)
    }

    /// The full picture for Settings and `service status`.
    public func stateJSON() async -> JSONValue {
        var object = statusJSON().object ?? [:]
        object["unit"] = (await manager.state()).json
        object["settings"] = .encoded(settings.read())
        object["version"] = .string(backend.version)
        object["helpers"] = .array(supervisor.status().map(\.json))
        object["running"] = .bool(mode == .background)
        object["runsToday"] = .number(Double(schedules.runsToday()))
        object["limits"] = ["schedules": .number(Double(ScheduleStore.maxSchedules)), "runsPerDay": .number(Double(settings.read().maxRunsPerDay))]
        return .object(object)
    }

    // MARK: Schedules

    private func projectName(_ id: String?) -> String {
        guard let id else { return "" }
        return backend.locked { backend.projects.first { $0.id == id }?.name } ?? ""
    }

    public func scheduleJSON(_ schedule: Schedule) -> JSONValue {
        var object = JSONValue.encoded(schedule).object ?? [:]
        object["whenText"] = .string(schedule.when.text(calendar: calendar))
        object["whenDescription"] = .string(schedule.when.describe(calendar: calendar))
        object["projectName"] = .string(projectName(schedule.project))
        let model = schedule.model.flatMap { backend.savedModels.find($0) }
        object["modelName"] = .string(model?.name ?? "")
        object["permissionTitle"] = .string(schedule.permission.title)
        // The live state: running, waiting for an answer, queued, paused, or just scheduled.
        object["state"] = .string(scheduler?.state(of: schedule.id) ?? (schedule.enabled ? "scheduled" : (schedule.when.kind == .once && schedule.lastRun != nil ? "finished" : "paused")))
        if object["nextRun"] == nil { object["nextRun"] = .null }
        if object["lastRun"] == nil { object["lastRun"] = .null }
        return .object(object)
    }

    public func schedulesJSON() -> JSONValue {
        let models = backend.savedModels.read().map { model -> JSONValue in ["key": .string(keyOf(model)), "name": .string(model.name)] }
        let projects = backend.locked { backend.projects.map { project -> JSONValue in ["id": .string(project.id), "name": .string(project.name)] } }
        return ["schedules": .array(schedules.list().map(scheduleJSON)), "running": .bool(mode == .background),
                "limits": ["schedules": .number(Double(ScheduleStore.maxSchedules)), "runsPerDay": .number(Double(settings.read().maxRunsPerDay))],
                "runsToday": .number(Double(schedules.runsToday())), "models": .array(models), "projects": .array(projects)]
    }

    /// Adds or changes a schedule from what the screen or command sent. `when` may be the plain words or the fields.
    public func saveSchedule(_ input: [String: JSONValue]) throws -> JSONValue {
        func text(_ key: String) -> String { input[key]?.string ?? "" }
        let when: ScheduleWhen
        if let words = input["whenText"]?.string, !words.isEmpty { when = try ScheduleWhen.parse(words, now: now(), calendar: calendar) }
        else if let given = input["when"], given != .null, let decoded = try? JSONDecoder().decode(ScheduleWhen.self, from: Data(given.text().utf8)) { when = decoded }
        else { throw BlackTeamError("Choose when it runs.") }
        let project = input["project"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let model = input["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let kind = input["kind"]?.string ?? "agent"
        guard let permission = UnattendedPermission(rawValue: input["permission"]?.string ?? UnattendedPermission.ask.rawValue) else {
            throw BlackTeamError("Permission is read-only, ask or allow-in-project.")
        }
        if let project, backend.projectFolder(project) == nil { throw BlackTeamError("That project no longer exists.") }
        if let model, backend.savedModels.find(model) == nil { throw BlackTeamError("That model is not in your list.") }
        var schedule = Schedule(name: text("name"), project: project, kind: kind, message: text("message"), model: model, when: when, permission: permission,
                                enabled: input["enabled"]?.bool ?? true)
        if let id = input["id"]?.string, !id.isEmpty {
            guard let existing = schedules.get(id) else { throw BlackTeamError("That schedule no longer exists.") }
            schedule.id = existing.id
        }
        return scheduleJSON(try schedules.save(schedule))
    }

    public func previewWhen(_ words: String) throws -> JSONValue {
        let when = try ScheduleWhen.parse(words, now: now(), calendar: calendar)
        return ["when": .encoded(when), "description": .string(when.describe(calendar: calendar)),
                "next": when.next(after: now(), calendar: calendar).map { .number($0.timeIntervalSince1970) } ?? .null]
    }

    public func runSchedule(_ id: String) throws {
        guard let scheduler else {
            throw BlackTeamError("Schedules run only while Black Team is kept running in the background. Turn that on in Settings, App & data.")
        }
        try scheduler.runNow(id)
    }

    // MARK: Inbox

    public func inboxJSON() -> JSONValue {
        let items = inbox.all()
        return ["items": .array(items.map { .encoded($0) }), "waiting": .number(Double(items.filter(\.isWaiting).count))]
    }

    /// Answers a waiting question. The engine's approval is the one that decides; the inbox copy is settled with it.
    public func answer(_ id: String, approve: Bool) throws {
        guard let item = inbox.get(id), item.isWaiting else { throw BlackTeamError("That question is not waiting any more.") }
        // An organization's gate or note (Org/OrgGates.swift) is answered there, not by the engine's approval.
        if item.kind != nil { try backend.orgAnswerInbox(item, approve: approve); return }
        do { try backend.approve(id: item.id, digest: item.digest, choice: approve ? "once" : "deny") }
        catch {
            // The run it belonged to is gone or already moved on.
            _ = try? inbox.settle(id, as: "ended")
            throw BlackTeamError("That question is not waiting any more.")
        }
        _ = try? inbox.settle(id, as: approve ? "approved" : "denied")
    }
}
