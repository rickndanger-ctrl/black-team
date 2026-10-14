import Foundation

// The inbox: things that wait for a person. Today that is a question from a scheduled Code run ("Run this command on your computer?").
// The run itself waits in the engine (the usual approval machinery, Engine/Engine.swift); the inbox is the saved copy of the question so
// it can be shown in the window, on the phone and in `black-team inbox`, and survives a look at it from another screen.

public struct InboxItem: Codable, Equatable, Sendable {
    public var id: String
    /// The engine's own approval id: answering means answering that one.
    public var scheduleId: String
    public var scheduleName: String
    public var threadId: String?
    public var project: String?
    /// What it wants to do, with secrets already removed by the engine.
    public var command: String
    public var question: String
    public var digest: String
    public var created: Double
    /// When the question runs out, in seconds since 1970.
    public var expires: Double
    /// "waiting", "approved", "denied", "answered" (answered somewhere else, such as the phone), "expired" (nobody answered in time) or
    /// "ended" (the run stopped before an answer).
    public var state: String
    public var answered: Double?

    public var isWaiting: Bool { state == "waiting" }
}

/// `<data>/inbox.json`: private, atomic, the newest first, and the settled ones trimmed to the last 50.
public final class InboxStore: @unchecked Sendable {
    public static let keep = 50
    public let file: String
    private let lock = NSLock()

    private struct Saved: Codable { var items: [InboxItem] = [] }

    public init(dataFolder: String) { file = dataFolder + "/inbox.json" }

    private func read() -> Saved {
        guard let data = FileManager.default.contents(atPath: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    private func write(_ saved: Saved) throws {
        var saved = saved
        let waiting = saved.items.filter(\.isWaiting)
        let settled = saved.items.filter { !$0.isWaiting }.prefix(Self.keep)
        saved.items = (waiting + settled).sorted { $0.created > $1.created }
        try privateDirectory((file as NSString).deletingLastPathComponent)
        try writeJSON(file, saved)
    }

    public func all() -> [InboxItem] { lock.lock(); defer { lock.unlock() }; return read().items }
    public func waiting() -> [InboxItem] { all().filter(\.isWaiting) }
    public func get(_ id: String) -> InboxItem? { all().first { $0.id == id } }

    /// Saves a new question (a second call with the same id changes nothing).
    public func add(_ item: InboxItem) throws {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        if saved.items.contains(where: { $0.id == item.id }) { return }
        saved.items.append(item)
        try write(saved)
    }

    /// Settles a waiting question. Returns false when it was not waiting.
    @discardableResult
    public func settle(_ id: String, as state: String, at date: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        guard let index = saved.items.firstIndex(where: { $0.id == id && $0.isWaiting }) else { return false }
        saved.items[index].state = state
        saved.items[index].answered = date.timeIntervalSince1970
        try write(saved)
        return true
    }

    /// Settles every question still waiting for this schedule's run (or for all, when `scheduleId` is nil).
    public func settleAll(scheduleId: String? = nil, as state: String, at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        var changed = false
        for index in saved.items.indices where saved.items[index].isWaiting && (scheduleId == nil || saved.items[index].scheduleId == scheduleId) {
            saved.items[index].state = state
            saved.items[index].answered = date.timeIntervalSince1970
            changed = true
        }
        if changed { try write(saved) }
    }
}

/// How the background service behaves. `<data>/service-settings.json`.
public struct ServiceSettings: Codable, Equatable, Sendable {
    /// Minutes with no job, conversation or open window after which the model is stopped to free memory. 0: never.
    public var idleMinutes = 10
    /// Hours a question from a scheduled run waits for an answer before the run ends as "not approved".
    public var approvalHours = 24
    /// The most scheduled runs that may start in one day.
    public var maxRunsPerDay = 24

    public init(idleMinutes: Int = 10, approvalHours: Int = 24, maxRunsPerDay: Int = 24) {
        self.idleMinutes = idleMinutes; self.approvalHours = approvalHours; self.maxRunsPerDay = maxRunsPerDay
    }

    public func validate() throws {
        if !(0...1440).contains(idleMinutes) { throw BlackTeamError("Choose an idle time from 0 (never) to 1440 minutes.") }
        if !(1...168).contains(approvalHours) { throw BlackTeamError("Choose how long a question waits, from 1 to 168 hours.") }
        if !(1...200).contains(maxRunsPerDay) { throw BlackTeamError("Choose a daily limit from 1 to 200 runs.") }
    }
}

public final class ServiceSettingsStore: @unchecked Sendable {
    public let file: String
    public init(dataFolder: String) { file = dataFolder + "/service-settings.json" }

    public func read() -> ServiceSettings {
        guard let data = FileManager.default.contents(atPath: file), let saved = try? JSONDecoder().decode(ServiceSettings.self, from: data),
              (try? saved.validate()) != nil else { return ServiceSettings() }
        return saved
    }

    @discardableResult
    public func save(_ settings: ServiceSettings) throws -> ServiceSettings {
        try settings.validate()
        try privateDirectory((file as NSString).deletingLastPathComponent)
        try writeJSON(file, settings)
        return settings
    }
}
