import Foundation

/// The puzzle the user must complete before the alarm will stop.
enum Mission: Codable, Equatable, Hashable {
    case none
    case steps(count: Int)          // walk N steps (pedometer)
    case math(problems: Int)        // solve N arithmetic problems

    var label: String {
        switch self {
        case .none:               return "None — tap to dismiss"
        case .steps(let n):       return "Walk \(n) steps"
        case .math(let n):        return "Solve \(n) math problems"
        }
    }

    var shortLabel: String {
        switch self {
        case .none:         return "Off"
        case .steps(let n): return "\(n) steps"
        case .math(let n):  return "\(n) math"
        }
    }
}

/// A song chosen from the user's Apple Music / iTunes library.
struct SongChoice: Codable, Equatable, Hashable {
    var persistentID: UInt64        // MPMediaItem persistent ID
    var title: String
    var artist: String
}

enum Weekday: Int, Codable, CaseIterable, Identifiable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var id: Int { rawValue }
    var letter: String { ["S", "M", "T", "W", "T", "F", "S"][rawValue - 1] }
    var name: String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][rawValue - 1]
    }
    static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Alarm: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour: Int = 7
    var minute: Int = 0
    var label: String = "Alarm"
    var isEnabled: Bool = true
    var repeatDays: Set<Weekday> = []           // empty = one-time
    var song: SongChoice? = nil                 // nil = built-in alarm tone
    var mission: Mission = .steps(count: 30)
    var vibrate: Bool = true
    var volumeRamp: Bool = true                 // fade in over ~30 s instead of instant blast
    var snoozeEnabled: Bool = true
    var snoozeMinutes: Int = 5
    var maxSnoozes: Int = 3

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? .now
        return f.string(from: date)
    }

    var repeatString: String {
        if repeatDays.isEmpty { return "Once" }
        if repeatDays.count == 7 { return "Every day" }
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        if repeatDays == weekdays { return "Weekdays" }
        if repeatDays == [.saturday, .sunday] { return "Weekends" }
        return repeatDays.sorted().map(\.letter).joined(separator: " ")
    }

    /// The next date this alarm should fire, from `reference`.
    func nextFireDate(after reference: Date = .now) -> Date? {
        guard isEnabled else { return nil }
        let cal = Calendar.current
        if repeatDays.isEmpty {
            var comps = cal.dateComponents([.year, .month, .day], from: reference)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard let today = cal.date(from: comps) else { return nil }
            return today > reference ? today : cal.date(byAdding: .day, value: 1, to: today)
        }
        // Repeating: find the soonest matching weekday.
        var best: Date?
        for day in repeatDays {
            var comps = DateComponents()
            comps.weekday = day.rawValue; comps.hour = hour; comps.minute = minute; comps.second = 0
            if let date = cal.nextDate(after: reference, matching: comps, matchingPolicy: .nextTime),
               best == nil || date < best! {
                best = date
            }
        }
        return best
    }
}
