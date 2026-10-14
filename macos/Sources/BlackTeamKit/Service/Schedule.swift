import Foundation

// Scheduled work: what a schedule is, the plain shapes of "when" a person can pick (no cron syntax), the arithmetic that finds the next
// run, and the file the schedules live in. Running them is Service/Scheduler.swift.

/// When a schedule runs. Four shapes: every N minutes or hours, every day at a time, weekdays at a time, or once at a time.
public struct ScheduleWhen: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case every, daily, weekdays, once }
    public var kind: Kind
    /// For `every`: the gap in minutes.
    public var minutes: Int?
    /// For `daily` and `weekdays`: the time of day, on this computer's clock.
    public var hour: Int?
    public var minute: Int?
    /// For `once`: the moment, in seconds since 1970.
    public var at: Double?

    public static let shortestGap = 5, longestGap = 7 * 24 * 60

    public init(kind: Kind, minutes: Int? = nil, hour: Int? = nil, minute: Int? = nil, at: Double? = nil) {
        self.kind = kind; self.minutes = minutes; self.hour = hour; self.minute = minute; self.at = at
    }

    public static func every(minutes: Int) -> ScheduleWhen { ScheduleWhen(kind: .every, minutes: minutes) }
    public static func daily(hour: Int, minute: Int) -> ScheduleWhen { ScheduleWhen(kind: .daily, hour: hour, minute: minute) }
    public static func weekdays(hour: Int, minute: Int) -> ScheduleWhen { ScheduleWhen(kind: .weekdays, hour: hour, minute: minute) }
    public static func once(at date: Date) -> ScheduleWhen { ScheduleWhen(kind: .once, at: date.timeIntervalSince1970) }

    /// Whether the fields are in range for the kind.
    public func validate() throws {
        switch kind {
        case .every:
            guard let minutes, minutes >= Self.shortestGap, minutes <= Self.longestGap else {
                throw BlackTeamError("Choose a gap of at least \(Self.shortestGap) minutes and at most 7 days.")
            }
        case .daily, .weekdays:
            guard let hour, let minute, (0...23).contains(hour), (0...59).contains(minute) else { throw BlackTeamError("Choose a time of day.") }
        case .once:
            guard let at, at.isFinite, at > 0 else { throw BlackTeamError("Choose the date and time.") }
        }
    }

    /// The next moment after `date` this schedule is due. Nil: never again (a once that has passed).
    /// Times of day follow the calendar's clock, so a daily 09:00 stays 09:00 across a clock change; a time that does not exist that
    /// day (the hour skipped in spring) runs at the next time that does.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .every:
            guard let minutes else { return nil }
            return date.addingTimeInterval(Double(minutes) * 60)
        case .once:
            guard let at else { return nil }
            let moment = Date(timeIntervalSince1970: at)
            return moment > date ? moment : nil
        case .daily, .weekdays:
            guard let hour, let minute else { return nil }
            let target = DateComponents(hour: hour, minute: minute, second: 0)
            var from = date
            // Today's time has passed when the clock on the wall already reads it. Going by the wall clock (not by elapsed time) keeps a
            // time that happens twice (the hour that repeats in autumn) to one run a day.
            let wall = calendar.dateComponents([.hour, .minute], from: date)
            if (wall.hour ?? 0, wall.minute ?? 0) >= (hour, minute),
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) {
                from = tomorrow.addingTimeInterval(-1)
            }
            // A week of days is always enough to find a weekday.
            for _ in 0..<9 {
                guard let candidate = calendar.nextDate(after: from, matching: target, matchingPolicy: .nextTime, direction: .forward) else { return nil }
                if kind == .daily || !calendar.isDateInWeekend(candidate) { return candidate }
                from = candidate
            }
            return nil
        }
    }

    // MARK: Words

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(String(format: "%02d", minute)) \(hour < 12 ? "am" : "pm")"
    }

    /// For people: "Every 30 minutes", "Every day at 9:30 am", "Weekdays at 5:00 pm", "Once on 2026-10-14 at 9:30 am".
    public func describe(calendar: Calendar = .current) -> String {
        switch kind {
        case .every:
            let minutes = minutes ?? 0
            if minutes % 60 == 0 { let hours = minutes / 60; return hours == 1 ? "Every hour" : "Every \(hours) hours" }
            return "Every \(minutes) minutes"
        case .daily: return "Every day at \(Self.clock(hour ?? 0, minute ?? 0))"
        case .weekdays: return "Weekdays at \(Self.clock(hour ?? 0, minute ?? 0))"
        case .once:
            let date = Date(timeIntervalSince1970: at ?? 0)
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return "Once on \(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)) at \(Self.clock(c.hour ?? 0, c.minute ?? 0))"
        }
    }

    /// The typed form `parse` reads back: "every 30 minutes", "daily at 09:30", "weekdays at 17:00", "once at 2026-10-14 09:30".
    public func text(calendar: Calendar = .current) -> String {
        func hm(_ h: Int?, _ m: Int?) -> String { String(format: "%02d:%02d", h ?? 0, m ?? 0) }
        switch kind {
        case .every:
            let minutes = minutes ?? 0
            return minutes % 60 == 0 ? "every \(minutes / 60) hours" : "every \(minutes) minutes"
        case .daily: return "daily at \(hm(hour, minute))"
        case .weekdays: return "weekdays at \(hm(hour, minute))"
        case .once:
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: at ?? 0))
            return "once at " + String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        }
    }

    // MARK: Reading what a person typed

    private static let help = "Say when like this: every 30 minutes, every 2 hours, daily at 9:30, weekdays at 17:00, or once at 2026-10-14 09:30."

    /// A time of day: "9", "9am", "9:30", "9:30 pm", "17:00".
    static func parseTime(_ given: String) -> (hour: Int, minute: Int)? {
        var text = given.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) { meridiem = suffix; text = String(text.dropLast(2)) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(minute) else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        return (0...23).contains(hour) ? (hour, minute) : nil
    }

    private static func sameDay(_ a: DateComponents, _ b: DateComponents) -> Bool { a.year == b.year && a.month == b.month && a.day == b.day }

    /// Reads one of the four plain shapes. `now` and `calendar` place "today", "tomorrow" and a date without a year.
    public static func parse(_ given: String, now: Date = Date(), calendar: Calendar = .current) throws -> ScheduleWhen {
        let words = given.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { throw BlackTeamError(help) }
        func failure() -> BlackTeamError { BlackTeamError(help) }
        // "every N minutes|hours", "every hour", "every minute" is too often.
        if words[0] == "every" {
            let rest = Array(words.dropFirst())
            if rest.first == "day" || rest.first == "weekday" || rest.first == "weekdays" {
                return try parse((rest.first == "day" ? "daily" : "weekdays") + " " + rest.dropFirst().joined(separator: " "), now: now, calendar: calendar)
            }
            var count = 1
            var unit = rest.first ?? ""
            if let first = rest.first, let number = Int(first) { count = number; unit = rest.count > 1 ? rest[1] : "" }
            guard rest.count == (Int(rest.first ?? "") != nil ? 2 : 1) else { throw failure() }
            let minutes: Int
            switch unit {
            case "minute", "minutes", "min", "mins": minutes = count
            case "hour", "hours", "hr", "hrs": minutes = count * 60
            default: throw failure()
            }
            let result = ScheduleWhen.every(minutes: minutes)
            try result.validate()
            return result
        }
        let timeWords = words.dropFirst().filter { $0 != "at" && $0 != "@" }
        if words[0] == "daily" || words[0] == "weekdays" {
            guard timeWords.count >= 1, timeWords.count <= 2, let time = parseTime(timeWords.joined(separator: " ")) else { throw failure() }
            return words[0] == "daily" ? .daily(hour: time.hour, minute: time.minute) : .weekdays(hour: time.hour, minute: time.minute)
        }
        if words[0] == "once" {
            var rest = Array(words.dropFirst()).filter { $0 != "on" && $0 != "at" && $0 != "@" }
            var day: DateComponents?
            if let first = rest.first {
                if first == "today" { day = calendar.dateComponents([.year, .month, .day], from: now); rest.removeFirst() }
                else if first == "tomorrow", let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) { day = calendar.dateComponents([.year, .month, .day], from: tomorrow); rest.removeFirst() }
                else {
                    let pieces = first.split(separator: "-").map(String.init)
                    if pieces.count == 3, pieces[0].count == 4, let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]) {
                        day = DateComponents(year: y, month: m, day: d); rest.removeFirst()
                    }
                }
            }
            guard let day, !rest.isEmpty, rest.count <= 2, let time = parseTime(rest.joined(separator: " ")) else { throw failure() }
            var parts = day
            parts.hour = time.hour; parts.minute = time.minute; parts.second = 0
            guard let date = calendar.date(from: parts), sameDay(calendar.dateComponents([.year, .month, .day], from: date), day) else {
                throw BlackTeamError("That date does not exist.")
            }
            guard date > now else { throw BlackTeamError("That time has already passed.") }
            return .once(at: date)
        }
        throw failure()
    }
}

/// What the last run of a schedule did.
public struct ScheduleRun: Codable, Equatable, Sendable {
    public var at: Double
    /// "running", "waiting" (needs an answer), "done", "error", "not-approved", "stopped", "interrupted" or "skipped".
    public var state: String
    public var threadId: String?
    /// One plain sentence: how it ended, or the first line of its answer.
    public var note: String
    public var finished: Double?
    public init(at: Double, state: String, threadId: String? = nil, note: String = "", finished: Double? = nil) {
        self.at = at; self.state = state; self.threadId = threadId; self.note = note; self.finished = finished
    }
    public var isOpen: Bool { state == "running" || state == "waiting" }
}

public struct Schedule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The project's id; nil runs in the general workspace.
    public var project: String?
    /// "chat" or "agent" (Code).
    public var kind: String
    public var message: String
    /// A saved model's key; nil uses the model in use when it runs.
    public var model: String?
    public var when: ScheduleWhen
    public var permission: UnattendedPermission
    /// Paused schedules do not run by themselves; "run now" still works.
    public var enabled: Bool
    public var created: Double
    public var nextRun: Double?
    public var lastRun: ScheduleRun?

    public init(id: String = UUID().uuidString.lowercased(), name: String, project: String? = nil, kind: String = "agent", message: String, model: String? = nil,
                when: ScheduleWhen, permission: UnattendedPermission = .ask, enabled: Bool = true, created: Double = Date().timeIntervalSince1970,
                nextRun: Double? = nil, lastRun: ScheduleRun? = nil) {
        self.id = id; self.name = name; self.project = project; self.kind = kind; self.message = message; self.model = model; self.when = when
        self.permission = permission; self.enabled = enabled; self.created = created; self.nextRun = nextRun; self.lastRun = lastRun
    }
}

/// The saved schedules and how many runs have started today. `<data>/schedules.json`, private, written atomically. The file is read
/// afresh for every call, so the window, the command and the service always agree.
public final class ScheduleStore: @unchecked Sendable {
    public static let maxSchedules = 20
    public static let maxMessage = 16000
    public let file: String
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    private struct Saved: Codable {
        var schedules: [Schedule] = []
        /// The local day ("2026-10-13") `runsToday` counts.
        var day: String = ""
        var runsToday: Int = 0
    }

    public init(dataFolder: String, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        file = dataFolder + "/schedules.json"
        self.now = now; self.calendar = calendar
    }

    private func read() -> Saved {
        guard let data = FileManager.default.contents(atPath: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    private func write(_ saved: Saved) throws {
        try privateDirectory((file as NSString).deletingLastPathComponent)
        try writeJSON(file, saved)
    }

    private func dayKey() -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func list() -> [Schedule] { lock.lock(); defer { lock.unlock() }; return read().schedules }

    public func get(_ id: String) -> Schedule? { list().first { $0.id == id } }

    /// Runs started so far today (this computer's day).
    public func runsToday() -> Int {
        lock.lock(); defer { lock.unlock() }
        let saved = read()
        return saved.day == dayKey() ? saved.runsToday : 0
    }

    /// Counts one more run started today.
    public func countRun() throws {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        if saved.day != dayKey() { saved.day = dayKey(); saved.runsToday = 0 }
        saved.runsToday += 1
        try write(saved)
    }

    /// Checks a schedule's own fields (not the project or model, which the caller knows about).
    public static func validate(_ schedule: Schedule) throws {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 60 { throw BlackTeamError("Give the schedule a name of up to 60 characters.") }
        let message = schedule.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || message.count > maxMessage { throw BlackTeamError("Enter a message of up to 16,000 characters.") }
        if !["chat", "agent"].contains(schedule.kind) { throw BlackTeamError("Choose Chat or Code.") }
        if let project = schedule.project, !History.validID(project) { throw BlackTeamError("Invalid project.") }
        try schedule.when.validate()
    }

    /// Adds a schedule (its next run is worked out now) or replaces the one with the same id.
    @discardableResult
    public func save(_ given: Schedule) throws -> Schedule {
        try Self.validate(given)
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        var schedule = given
        schedule.name = given.name.trimmingCharacters(in: .whitespacesAndNewlines)
        schedule.message = given.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = saved.schedules.firstIndex(where: { $0.id == schedule.id }) {
            // Editing keeps what the runs have recorded; a changed time is worked out again.
            let old = saved.schedules[index]
            schedule.created = old.created; schedule.lastRun = old.lastRun
            schedule.nextRun = schedule.enabled ? (schedule.when == old.when && old.enabled ? old.nextRun : schedule.when.next(after: now(), calendar: calendar)?.timeIntervalSince1970) : nil
            saved.schedules[index] = schedule
        } else {
            if saved.schedules.count >= Self.maxSchedules { throw BlackTeamError("You can keep up to \(Self.maxSchedules) schedules. Remove one to add another.") }
            schedule.created = now().timeIntervalSince1970
            schedule.nextRun = schedule.enabled ? schedule.when.next(after: now(), calendar: calendar)?.timeIntervalSince1970 : nil
            schedule.lastRun = nil
            saved.schedules.append(schedule)
        }
        try write(saved)
        return schedule
    }

    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        guard saved.schedules.contains(where: { $0.id == id }) else { throw BlackTeamError("That schedule no longer exists.") }
        saved.schedules.removeAll { $0.id == id }
        try write(saved)
    }

    /// Pauses or resumes. Resuming works out the next run from now: time that passed while paused is not caught up.
    @discardableResult
    public func setEnabled(_ id: String, _ enabled: Bool) throws -> Schedule {
        try change(id) { schedule, store in
            schedule.enabled = enabled
            schedule.nextRun = enabled ? schedule.when.next(after: store.now(), calendar: store.calendar)?.timeIntervalSince1970 : nil
        }
    }

    /// Changes one schedule under the lock (used by the scheduler to record runs and set the next one).
    @discardableResult
    public func change(_ id: String, _ update: (inout Schedule, ScheduleStore) -> Void) throws -> Schedule {
        lock.lock(); defer { lock.unlock() }
        var saved = read()
        guard let index = saved.schedules.firstIndex(where: { $0.id == id }) else { throw BlackTeamError("That schedule no longer exists.") }
        update(&saved.schedules[index], self)
        try write(saved)
        return saved.schedules[index]
    }
}
