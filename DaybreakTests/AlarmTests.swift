import Foundation
import Testing
@testable import Daybreak

// All date tests pin the calendar to America/New_York so results don't
// depend on the machine running them — and so the DST cases are real.
//
// Anchor dates (worth knowing when reading assertions):
//   Wed Jun 10 2026 — plain summer weekday
//   Sun Mar  8 2026 — US DST begins, 2:00 → 3:00 (an hour vanishes)
//   Sun Nov  1 2026 — US DST ends,   2:00 → 1:00 (an hour repeats)
struct AlarmTests {

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func alarm(_ hour: Int, _ minute: Int, repeats: Set<Weekday> = [], enabled: Bool = true) -> Alarm {
        var a = Alarm()
        a.hour = hour; a.minute = minute
        a.repeatDays = repeats; a.isEnabled = enabled
        return a
    }

    // MARK: - nextFireDate, one-time alarms

    @Test func oneTimeLaterTodayFiresToday() {
        let next = alarm(8, 0).nextFireDate(after: date(2026, 6, 10, 6, 0), calendar: cal)
        #expect(next == date(2026, 6, 10, 8, 0))
    }

    @Test func oneTimeEarlierTodayFiresTomorrow() {
        let next = alarm(8, 0).nextFireDate(after: date(2026, 6, 10, 9, 30), calendar: cal)
        #expect(next == date(2026, 6, 11, 8, 0))
    }

    @Test func oneTimeAtExactAlarmTimeFiresTomorrow() {
        // At 8:00:00 sharp the moment has arrived, not passed —
        // scheduling must look to tomorrow, not "now".
        let next = alarm(8, 0).nextFireDate(after: date(2026, 6, 10, 8, 0), calendar: cal)
        #expect(next == date(2026, 6, 11, 8, 0))
    }

    @Test func oneTimeSecondsAfterAlarmTimeFiresTomorrow() {
        let next = alarm(8, 0).nextFireDate(after: date(2026, 6, 10, 8, 0, 30), calendar: cal)
        #expect(next == date(2026, 6, 11, 8, 0))
    }

    @Test func disabledAlarmNeverFires() {
        let next = alarm(8, 0, enabled: false).nextFireDate(after: date(2026, 6, 10, 6, 0), calendar: cal)
        #expect(next == nil)
    }

    // MARK: - nextFireDate, repeating alarms

    @Test func repeatingSameDayLaterTimeFiresToday() {
        // Jun 10 2026 is a Wednesday.
        let next = alarm(8, 0, repeats: [.wednesday]).nextFireDate(after: date(2026, 6, 10, 6, 0), calendar: cal)
        #expect(next == date(2026, 6, 10, 8, 0))
    }

    @Test func repeatingSameDayEarlierTimeFiresNextWeek() {
        let next = alarm(8, 0, repeats: [.wednesday]).nextFireDate(after: date(2026, 6, 10, 9, 0), calendar: cal)
        #expect(next == date(2026, 6, 17, 8, 0))
    }

    @Test func repeatingPicksSoonestOfSeveralDays() {
        // From a Wednesday evening, Mon+Fri should pick Friday.
        let next = alarm(8, 0, repeats: [.monday, .friday]).nextFireDate(after: date(2026, 6, 10, 20, 0), calendar: cal)
        #expect(next == date(2026, 6, 12, 8, 0))
    }

    @Test func repeatingEveryDayFiresTomorrowAfterTodaysTime() {
        let all = Set(Weekday.allCases)
        let next = alarm(8, 0, repeats: all).nextFireDate(after: date(2026, 6, 10, 9, 0), calendar: cal)
        #expect(next == date(2026, 6, 11, 8, 0))
    }

    // MARK: - nextFireDate across DST transitions

    @Test func springForwardKeepsWallClockTime() throws {
        // 11 pm the night clocks jump forward. 7:00 wall time is only
        // 7 real hours away (2:00–3:00 doesn't exist).
        let ref = date(2026, 3, 7, 23, 0)
        let next = try #require(alarm(7, 0).nextFireDate(after: ref, calendar: cal))
        #expect(next == date(2026, 3, 8, 7, 0))
        let seconds = Int(next.timeIntervalSince(ref))
        #expect(seconds == 7 * 3600)
    }

    @Test func fallBackKeepsWallClockTime() throws {
        // 11 pm the night clocks fall back. 7:00 wall time is
        // 9 real hours away (1:00–2:00 happens twice).
        let ref = date(2026, 10, 31, 23, 0)
        let next = try #require(alarm(7, 0).nextFireDate(after: ref, calendar: cal))
        #expect(next == date(2026, 11, 1, 7, 0))
        let seconds = Int(next.timeIntervalSince(ref))
        #expect(seconds == 9 * 3600)
    }

    @Test func repeatingAcrossSpringForwardKeepsWallClockTime() {
        // Mar 8 2026 is a Sunday.
        let ref = date(2026, 3, 7, 23, 0)
        let next = alarm(7, 0, repeats: [.sunday]).nextFireDate(after: ref, calendar: cal)
        #expect(next == date(2026, 3, 8, 7, 0))
    }

    // MARK: - lastFireDate (drives the "take over the screen" check)

    @Test func lastFireEarlierTodayIsToday() {
        let last = alarm(7, 0).lastFireDate(before: date(2026, 6, 10, 7, 5), calendar: cal)
        #expect(last == date(2026, 6, 10, 7, 0))
    }

    @Test func lastFireNotYetTodayIsYesterday() {
        let last = alarm(7, 0).lastFireDate(before: date(2026, 6, 10, 6, 55), calendar: cal)
        #expect(last == date(2026, 6, 9, 7, 0))
    }

    @Test func lastFireAtExactAlarmTimeIsNow() {
        let last = alarm(7, 0).lastFireDate(before: date(2026, 6, 10, 7, 0), calendar: cal)
        #expect(last == date(2026, 6, 10, 7, 0))
    }

    @Test func repeatingLastFireOnWrongWeekdayIsNil() {
        // Monday-only alarm queried on a Wednesday morning after 7:00:
        // the most recent candidate (Wed 7:00) isn't a Monday.
        let last = alarm(7, 0, repeats: [.monday]).lastFireDate(before: date(2026, 6, 10, 7, 5), calendar: cal)
        #expect(last == nil)
    }

    @Test func repeatingLastFireOnMatchingWeekdayIsFound() {
        let last = alarm(7, 0, repeats: [.wednesday]).lastFireDate(before: date(2026, 6, 10, 7, 5), calendar: cal)
        #expect(last == date(2026, 6, 10, 7, 0))
    }

    // MARK: - Persistence & migration

    @Test func legacyJSONWithoutToneDecodesAsClassic() throws {
        // Alarms saved before the tone field existed must still load —
        // a decode failure here silently wipes every saved alarm.
        let legacy = """
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","hour":6,"minute":30,
         "label":"Work","isEnabled":true,"repeatDays":[2,3],
         "mission":{"steps":{"count":40}},"vibrate":true,"volumeRamp":false,
         "snoozeEnabled":true,"snoozeMinutes":5,"maxSnoozes":3}
        """
        let decoded = try JSONDecoder().decode(Alarm.self, from: Data(legacy.utf8))
        #expect(decoded.tone == .classic)
        #expect(decoded.hour == 6)
        #expect(decoded.minute == 30)
        #expect(decoded.mission == .steps(count: 40))
        #expect(decoded.repeatDays == [.monday, .tuesday])
        #expect(decoded.song == nil)
    }

    @Test func alarmRoundTripsThroughCodable() throws {
        var original = alarm(22, 45, repeats: [.saturday, .sunday])
        original.label = "Weekend"
        original.tone = .pulse
        original.mission = .math(problems: 5)
        original.song = SongChoice(persistentID: 42, title: "Song", artist: "Artist")
        original.snoozeMinutes = 10

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Alarm.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Display helpers

    @Test func repeatStringNamesCommonPatterns() {
        #expect(alarm(7, 0).repeatString == "Once")
        #expect(alarm(7, 0, repeats: Set(Weekday.allCases)).repeatString == "Every day")
        #expect(alarm(7, 0, repeats: [.monday, .tuesday, .wednesday, .thursday, .friday]).repeatString == "Weekdays")
        #expect(alarm(7, 0, repeats: [.saturday, .sunday]).repeatString == "Weekends")
        #expect(alarm(7, 0, repeats: [.monday, .wednesday]).repeatString == "M W")
    }

    @Test func toneFileNamesFollowConvention() {
        #expect(AlarmTone.classic.fileName == "alarm.caf")
        // Every non-classic tone must follow "alarm-<tone>.caf".
        for tone in AlarmTone.allCases where tone != .classic {
            #expect(tone.fileName == "alarm-\(tone.rawValue).caf")
        }
    }
}
