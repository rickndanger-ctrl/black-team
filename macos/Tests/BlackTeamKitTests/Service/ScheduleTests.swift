import XCTest
@testable import BlackTeamKit

/// The plain shapes of "when", the arithmetic that finds the next run (with an injected clock and time zone), and the schedule file.
final class ScheduleTests: XCTestCase {
    func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// A moment on the calendar's wall clock.
    func date(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    func wall(_ calendar: Calendar, _ date: Date?) -> String {
        guard let date else { return "never" }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    // MARK: Reading what a person types

    func testTheFourPlainShapesAreRead() throws {
        let cal = calendar(), now = date(cal, 2026, 10, 13, 12)
        XCTAssertEqual(try ScheduleWhen.parse("every 30 minutes", now: now, calendar: cal), .every(minutes: 30))
        XCTAssertEqual(try ScheduleWhen.parse("Every 2 hours", now: now, calendar: cal), .every(minutes: 120))
        XCTAssertEqual(try ScheduleWhen.parse("every hour", now: now, calendar: cal), .every(minutes: 60))
        XCTAssertEqual(try ScheduleWhen.parse("daily at 9:30", now: now, calendar: cal), .daily(hour: 9, minute: 30))
        XCTAssertEqual(try ScheduleWhen.parse("every day at 9am", now: now, calendar: cal), .daily(hour: 9, minute: 0))
        XCTAssertEqual(try ScheduleWhen.parse("daily 5:05 PM", now: now, calendar: cal), .daily(hour: 17, minute: 5))
        XCTAssertEqual(try ScheduleWhen.parse("weekdays at 17:00", now: now, calendar: cal), .weekdays(hour: 17, minute: 0))
        XCTAssertEqual(try ScheduleWhen.parse("every weekday at 12am", now: now, calendar: cal), .weekdays(hour: 0, minute: 0))
        XCTAssertEqual(try ScheduleWhen.parse("once at 2026-10-14 09:30", now: now, calendar: cal), .once(at: date(cal, 2026, 10, 14, 9, 30)))
        XCTAssertEqual(try ScheduleWhen.parse("once tomorrow at 7am", now: now, calendar: cal), .once(at: date(cal, 2026, 10, 14, 7)))
        XCTAssertEqual(try ScheduleWhen.parse("once today at 3pm", now: now, calendar: cal), .once(at: date(cal, 2026, 10, 13, 15)))
    }

    func testWhatCannotBeReadSaysHowToSayIt() {
        let cal = calendar(), now = date(cal, 2026, 10, 13, 12)
        for bad in ["", "*/5 * * * *", "every 2 fortnights", "daily at 25:00", "daily at 9:75", "weekdays", "once", "once at 2026-02-30 09:00", "every banana"] {
            XCTAssertThrowsError(try ScheduleWhen.parse(bad, now: now, calendar: cal), bad) { error in
                XCTAssertTrue((error as? BlackTeamError)?.message.contains("every 30 minutes") == true || (error as? BlackTeamError)?.message.contains("does not exist") == true, bad)
            }
        }
        // Too often, too rare, and in the past.
        XCTAssertThrowsError(try ScheduleWhen.parse("every 1 minutes", now: now, calendar: cal))
        XCTAssertThrowsError(try ScheduleWhen.parse("every 200 hours", now: now, calendar: cal))
        XCTAssertThrowsError(try ScheduleWhen.parse("once at 2026-10-13 11:00", now: now, calendar: cal)) { XCTAssertEqual(($0 as? BlackTeamError)?.message, "That time has already passed.") }
    }

    func testTheTypedFormRoundTripsAndTheWordsAreForPeople() throws {
        let cal = calendar(), now = date(cal, 2026, 10, 13, 12)
        for words in ["every 30 minutes", "every 2 hours", "daily at 09:30", "weekdays at 17:00", "once at 2026-10-14 09:30"] {
            let parsed = try ScheduleWhen.parse(words, now: now, calendar: cal)
            XCTAssertEqual(parsed.text(calendar: cal), words)
        }
        XCTAssertEqual(ScheduleWhen.every(minutes: 90).describe(calendar: cal), "Every 90 minutes")
        XCTAssertEqual(ScheduleWhen.every(minutes: 60).describe(calendar: cal), "Every hour")
        XCTAssertEqual(ScheduleWhen.daily(hour: 9, minute: 30).describe(calendar: cal), "Every day at 9:30 am")
        XCTAssertEqual(ScheduleWhen.weekdays(hour: 17, minute: 0).describe(calendar: cal), "Weekdays at 5:00 pm")
        XCTAssertEqual(ScheduleWhen.daily(hour: 0, minute: 5).describe(calendar: cal), "Every day at 12:05 am")
    }

    // MARK: The next run

    func testEveryNMinutesCountsFromTheMomentGiven() {
        let cal = calendar(), start = date(cal, 2026, 10, 13, 23, 50)
        XCTAssertEqual(wall(cal, ScheduleWhen.every(minutes: 30).next(after: start, calendar: cal)), "2026-10-14 00:20")
    }

    func testDailyRunsTodayIfTheTimeIsAheadAndTomorrowIfItHasPassed_AcrossMidnightAndMonthEnds() {
        let cal = calendar()
        let nine = ScheduleWhen.daily(hour: 9, minute: 0)
        XCTAssertEqual(wall(cal, nine.next(after: date(cal, 2026, 10, 13, 8, 59), calendar: cal)), "2026-10-13 09:00")
        XCTAssertEqual(wall(cal, nine.next(after: date(cal, 2026, 10, 13, 9, 0), calendar: cal)), "2026-10-14 09:00")
        XCTAssertEqual(wall(cal, nine.next(after: date(cal, 2026, 10, 13, 9, 0, 5), calendar: cal)), "2026-10-14 09:00")
        // Just before midnight, a 00:05 schedule is tomorrow's; a 23:59 one is still tonight's.
        XCTAssertEqual(wall(cal, ScheduleWhen.daily(hour: 0, minute: 5).next(after: date(cal, 2026, 10, 31, 23, 59), calendar: cal)), "2026-11-01 00:05")
        XCTAssertEqual(wall(cal, ScheduleWhen.daily(hour: 23, minute: 59).next(after: date(cal, 2026, 10, 31, 23, 58), calendar: cal)), "2026-10-31 23:59")
        XCTAssertEqual(wall(cal, ScheduleWhen.daily(hour: 0, minute: 0).next(after: date(cal, 2026, 12, 31, 23, 59, 59), calendar: cal)), "2027-01-01 00:00")
    }

    func testWeekdaysSkipTheWeekend() {
        let cal = calendar()
        let evening = ScheduleWhen.weekdays(hour: 17, minute: 0)
        // 2026-10-16 is a Friday.
        XCTAssertEqual(wall(cal, evening.next(after: date(cal, 2026, 10, 16, 12), calendar: cal)), "2026-10-16 17:00")
        XCTAssertEqual(wall(cal, evening.next(after: date(cal, 2026, 10, 16, 17, 1), calendar: cal)), "2026-10-19 17:00")
        XCTAssertEqual(wall(cal, evening.next(after: date(cal, 2026, 10, 17, 9), calendar: cal)), "2026-10-19 17:00")
        XCTAssertEqual(wall(cal, evening.next(after: date(cal, 2026, 10, 18, 23, 59), calendar: cal)), "2026-10-19 17:00")
    }

    func testOnceHasNoNextRunAfterItsTime() {
        let cal = calendar(), moment = date(cal, 2026, 10, 14, 9, 30)
        let once = ScheduleWhen.once(at: moment)
        XCTAssertEqual(once.next(after: moment.addingTimeInterval(-1), calendar: cal), moment)
        XCTAssertNil(once.next(after: moment, calendar: cal))
    }

    func testAClockChangeKeepsTheWallClockTimeAndNeverRunsTwiceADay() {
        let cal = calendar("America/New_York")
        // Spring: 2026-03-08, the clock jumps from 02:00 to 03:00. A 02:30 schedule runs once, at the first moment that exists, and
        // the day after is 02:30 again.
        let night = ScheduleWhen.daily(hour: 2, minute: 30)
        let springRun = night.next(after: date(cal, 2026, 3, 7, 12), calendar: cal)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: springRun!), DateComponents(year: 2026, month: 3, day: 8))
        XCTAssertTrue((springRun!.timeIntervalSince(date(cal, 2026, 3, 8, 3, 0)) >= 0) && springRun!.timeIntervalSince(date(cal, 2026, 3, 8, 3, 31)) < 0, wall(cal, springRun))
        XCTAssertEqual(wall(cal, night.next(after: springRun!.addingTimeInterval(1), calendar: cal)), "2026-03-09 02:30")
        // An ordinary 09:00 stays 09:00 on the wall across the change (a 23-hour day).
        let nine = ScheduleWhen.daily(hour: 9, minute: 0)
        XCTAssertEqual(wall(cal, nine.next(after: date(cal, 2026, 3, 7, 9, 0, 1), calendar: cal)), "2026-03-08 09:00")
        XCTAssertEqual(nine.next(after: date(cal, 2026, 3, 7, 9, 0, 1), calendar: cal)!.timeIntervalSince(date(cal, 2026, 3, 7, 9)), 23 * 3600)
        // Autumn: 2026-11-01, 01:30 happens twice. A 01:30 schedule runs at the first one only.
        let early = ScheduleWhen.daily(hour: 1, minute: 30)
        let first = early.next(after: date(cal, 2026, 11, 1, 0, 10), calendar: cal)!
        XCTAssertEqual(wall(cal, first), "2026-11-01 01:30")
        XCTAssertEqual(wall(cal, early.next(after: first.addingTimeInterval(1), calendar: cal)), "2026-11-02 01:30")
        // Even if the first one was missed and the service starts in the repeated hour.
        let secondHour = first.addingTimeInterval(3600 + 5)
        XCTAssertEqual(wall(cal, early.next(after: secondHour, calendar: cal)), "2026-11-02 01:30")
        // The day the clocks go back is 25 hours long: 09:00 to 09:00 across it is 25 hours, and the day after is 24.
        XCTAssertEqual(nine.next(after: date(cal, 2026, 10, 31, 9, 0, 1), calendar: cal)!.timeIntervalSince(date(cal, 2026, 10, 31, 9)), 25 * 3600)
        XCTAssertEqual(nine.next(after: date(cal, 2026, 11, 1, 9, 0, 1), calendar: cal)!.timeIntervalSince(date(cal, 2026, 11, 1, 9)), 24 * 3600)
    }

    // MARK: The file

    func store(_ clock: Clock, calendar: Calendar? = nil) throws -> (ScheduleStore, String) {
        let folder = NSTemporaryDirectory() + "bt-sched-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        return (ScheduleStore(dataFolder: folder, now: { clock.now }, calendar: calendar ?? self.calendar()), folder)
    }

    func draft(_ name: String = "Morning check", when: ScheduleWhen = .daily(hour: 9, minute: 0)) -> Schedule {
        Schedule(name: name, kind: "agent", message: "Look at the failing tests and say what changed.", when: when)
    }

    func testASavedScheduleIsPrivateAndKnowsItsNextRun() throws {
        let cal = calendar(), clock = Clock(date(cal, 2026, 10, 13, 8))
        let (store, folder) = try store(clock)
        let saved = try store.save(draft())
        XCTAssertEqual(wall(cal, saved.nextRun.map { Date(timeIntervalSince1970: $0) }), "2026-10-13 09:00")
        XCTAssertEqual(store.list().map(\.name), ["Morning check"])
        var info = stat()
        XCTAssertEqual(stat(folder + "/schedules.json", &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testPausingClearsTheNextRunAndResumingStartsFromNowWithoutCatchingUp() throws {
        let cal = calendar(), clock = Clock(date(cal, 2026, 10, 13, 8))
        let (store, _) = try store(clock)
        let saved = try store.save(draft())
        let paused = try store.setEnabled(saved.id, false)
        XCTAssertNil(paused.nextRun)
        XCTAssertFalse(paused.enabled)
        clock.now = date(cal, 2026, 10, 15, 12)
        let resumed = try store.setEnabled(saved.id, true)
        XCTAssertEqual(wall(cal, resumed.nextRun.map { Date(timeIntervalSince1970: $0) }), "2026-10-16 09:00")
    }

    func testEditingKeepsTheRecordOfRunsAndWorksOutTheNewTime() throws {
        let cal = calendar(), clock = Clock(date(cal, 2026, 10, 13, 8))
        let (store, _) = try store(clock)
        let saved = try store.save(draft())
        _ = try store.change(saved.id) { item, _ in item.lastRun = ScheduleRun(at: 1, state: "done", note: "ok") }
        var edit = saved
        edit.when = .daily(hour: 18, minute: 0); edit.name = "Evening check"
        let changed = try store.save(edit)
        XCTAssertEqual(changed.lastRun?.state, "done")
        XCTAssertEqual(wall(cal, changed.nextRun.map { Date(timeIntervalSince1970: $0) }), "2026-10-13 18:00")
        XCTAssertEqual(store.list().count, 1)
    }

    func testTheNumberOfSchedulesIsCappedAndFieldsAreChecked() throws {
        let cal = calendar(), clock = Clock(date(cal, 2026, 10, 13, 8))
        let (store, _) = try store(clock)
        for index in 0..<ScheduleStore.maxSchedules { try store.save(draft("Schedule \(index)")) }
        XCTAssertThrowsError(try store.save(draft("One too many"))) { XCTAssertTrue(($0 as? BlackTeamError)?.message.contains("up to 20 schedules") == true) }
        XCTAssertThrowsError(try store.save(Schedule(name: " ", message: "x", when: .daily(hour: 9, minute: 0))))
        XCTAssertThrowsError(try store.save(Schedule(name: "a", message: "", when: .daily(hour: 9, minute: 0))))
        XCTAssertThrowsError(try store.save(Schedule(name: "a", kind: "poem", message: "x", when: .daily(hour: 9, minute: 0))))
        XCTAssertThrowsError(try store.save(Schedule(name: "a", message: String(repeating: "x", count: 16001), when: .daily(hour: 9, minute: 0))))
        XCTAssertThrowsError(try store.save(Schedule(name: "a", message: "x", when: .every(minutes: 2))))
        XCTAssertEqual(store.list().count, ScheduleStore.maxSchedules)
    }

    func testRunsAreCountedPerDay() throws {
        let cal = calendar(), clock = Clock(date(cal, 2026, 10, 13, 23, 0))
        let (store, _) = try store(clock)
        try store.countRun(); try store.countRun()
        XCTAssertEqual(store.runsToday(), 2)
        clock.now = date(cal, 2026, 10, 14, 0, 1)
        XCTAssertEqual(store.runsToday(), 0)
        try store.countRun()
        XCTAssertEqual(store.runsToday(), 1)
    }
}

/// A clock a test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
