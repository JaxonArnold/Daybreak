import Foundation
import UserNotifications
import SwiftUI
import Combine

/// Owns the alarm list, persists it, schedules the notification chain,
/// and decides when the in-app ringing screen should take over.
@MainActor
final class AlarmStore: ObservableObject {
    @Published var alarms: [Alarm] = [] { didSet { persist() } }
    @Published var ringingAlarm: Alarm? = nil      // non-nil → full-screen RingingView
    @Published var snoozeCountThisRing = 0

    /// How long after fire time the alarm is still considered "ringing"
    /// if the user only just opened the app. (Notifications keep firing
    /// for this window too.)
    static let ringWindow: TimeInterval = 10 * 60
    /// Notifications in the chain are spaced this far apart.
    static let chainSpacing: TimeInterval = 30
    private var chainLength: Int { Int(Self.ringWindow / Self.chainSpacing) }   // 20

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("alarms.json")
    }()

    init() {
        load()
        Task { await requestPermission() }
    }

    // MARK: - Permissions

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - CRUD

    func upsert(_ alarm: Alarm) {
        if let i = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[i] = alarm
        } else {
            alarms.append(alarm)
        }
        sortAlarms()
        Task { await reschedule(alarm) }
    }

    func delete(_ alarm: Alarm) {
        alarms.removeAll { $0.id == alarm.id }
        cancelNotifications(for: alarm)
    }

    func toggle(_ alarm: Alarm, enabled: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].isEnabled = enabled
        let updated = alarms[i]
        Task { await reschedule(updated) }
    }

    private func sortAlarms() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    var nextAlarm: (alarm: Alarm, date: Date)? {
        alarms.compactMap { a in a.nextFireDate().map { (a, $0) } }
              .min { $0.1 < $1.1 }
    }

    // MARK: - Scheduling (the Alarmy trick)
    //
    // iOS won't let an app ring like the system Clock from the background,
    // so we schedule a *chain* of loud notifications every 30 s for 10 min.
    // They keep firing until the user opens the app — at which point the
    // app takes over with full-volume music + haptics + the mission.

    private func reschedule(_ alarm: Alarm) async {
        cancelNotifications(for: alarm)
        guard alarm.isEnabled, let fire = alarm.nextFireDate() else { return }

        let center = UNUserNotificationCenter.current()
        for i in 0..<chainLength {
            let content = UNMutableNotificationContent()
            content.title = "⏰ \(alarm.label)"
            content.body = i == 0 ? "Time to wake up! Open Daybreak to stop the alarm."
                                  : "Still ringing — open the app to complete your mission."
            content.interruptionLevel = .timeSensitive
            // Bundle a loud ≤30 s sound named "alarm.caf" (see README); falls back to default.
            content.sound = bundledSoundExists
                ? UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))
                : .default
            content.userInfo = ["alarmID": alarm.id.uuidString]

            let interval = fire.timeIntervalSinceNow + Double(i) * Self.chainSpacing
            guard interval > 0 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(alarm.id.uuidString)-\(i)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Reschedule everything (call on app launch / after an alarm finishes,
    /// so repeating alarms line up their next occurrence).
    func rescheduleAll() {
        Task {
            for alarm in alarms { await reschedule(alarm) }
        }
    }

    private func cancelNotifications(for alarm: Alarm) {
        let ids = (0..<chainLength).map { "\(alarm.id.uuidString)-\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private var bundledSoundExists: Bool {
        Bundle.main.url(forResource: "alarm", withExtension: "caf") != nil
    }

    // MARK: - Ringing takeover

    /// Called when the app becomes active or a notification is tapped.
    /// If an enabled alarm fired within the ring window, take over the screen.
    func checkForRingingAlarm() {
        guard ringingAlarm == nil else { return }
        let now = Date.now
        for alarm in alarms where alarm.isEnabled {
            guard let last = lastFireDate(of: alarm, before: now) else { continue }
            if now.timeIntervalSince(last) < Self.ringWindow {
                startRinging(alarm)
                return
            }
        }
    }

    func startRinging(_ alarm: Alarm) {
        snoozeCountThisRing = 0
        ringingAlarm = alarm
        cancelNotifications(for: alarm)
        AudioEngine.shared.startAlarm(song: alarm.song, ramp: alarm.volumeRamp)
        if alarm.vibrate { HapticEngine.shared.start() }
    }

    func snooze() {
        guard let alarm = ringingAlarm else { return }
        snoozeCountThisRing += 1
        AudioEngine.shared.stop()
        HapticEngine.shared.stop()
        ringingAlarm = nil

        // One-shot snooze chain.
        let fire = Date.now.addingTimeInterval(Double(alarm.snoozeMinutes) * 60)
        var snoozed = alarm
        snoozed.repeatDays = []
        snoozed.hour = Calendar.current.component(.hour, from: fire)
        snoozed.minute = Calendar.current.component(.minute, from: fire)
        snoozeOneShot = (snoozed, fire)
        Task { await reschedule(snoozed) }
    }

    /// Tracks an in-flight snooze so checkForRingingAlarm can find it.
    private var snoozeOneShot: (Alarm, Date)?

    func dismissRinging() {
        AudioEngine.shared.stop()
        HapticEngine.shared.stop()
        if let alarm = ringingAlarm {
            cancelNotifications(for: alarm)
            // One-time alarms switch off after they ring; repeating ones re-arm.
            if alarm.repeatDays.isEmpty, let i = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[i].isEnabled = false
            }
        }
        snoozeOneShot = nil
        ringingAlarm = nil
        rescheduleAll()
    }

    private func lastFireDate(of alarm: Alarm, before now: Date) -> Date? {
        if let (snoozed, fire) = snoozeOneShot, snoozed.id == alarm.id, fire <= now {
            return fire
        }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = alarm.hour; comps.minute = alarm.minute; comps.second = 0
        guard var candidate = cal.date(from: comps) else { return nil }
        if candidate > now {
            candidate = cal.date(byAdding: .day, value: -1, to: candidate)!
        }
        if alarm.repeatDays.isEmpty { return candidate }
        let weekday = Weekday(rawValue: cal.component(.weekday, from: candidate))!
        return alarm.repeatDays.contains(weekday) ? candidate : nil
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(alarms) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([Alarm].self, from: data) else { return }
        alarms = saved
    }
}

