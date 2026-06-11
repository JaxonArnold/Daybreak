import Foundation
import UserNotifications
import SwiftUI
import Combine

/// Owns the alarm list, persists it, schedules the notification chain, and decides when the in-app ringing screen should take over.
@MainActor
final class AlarmStore: ObservableObject {
    /// Single shared instance — the SwiftUI scene and App Intents (Siri)
    /// must mutate the same store.
    static let shared = AlarmStore()

    @Published var alarms: [Alarm] = [] { didSet { persist() } }
    @Published var ringingAlarm: Alarm? = nil      // non-nil → full-screen RingingView
    @Published var snoozeCountThisRing = 0

    /// How long after fire time the alarm is still considered "ringing"  if the user only just opened the app. (Notifications keep firing for this window too.)
    static let ringWindow: TimeInterval = 10 * 60
    /// Notifications in the chain are spaced this far apart.
    static let chainSpacing: TimeInterval = 10
    private var chainLength: Int { min(Int(Self.ringWindow / Self.chainSpacing), 30) }

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("alarms.json")
    }()

    private init() {
        load()
        loadDismissedRing()
    }

    // MARK: - CRUD

    func upsert(_ alarm: Alarm) {
        if let i = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[i] = alarm
        } else {
            alarms.append(alarm)
        }
        sortAlarms()
        queueReschedule(alarm)
    }

    func delete(_ alarm: Alarm) {
        alarms.removeAll { $0.id == alarm.id }
        if snoozeOneShot?.0.id == alarm.id { snoozeOneShot = nil }
        cancelNotifications(for: alarm)
    }

    func toggle(_ alarm: Alarm, enabled: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].isEnabled = enabled
        if !enabled, snoozeOneShot?.0.id == alarm.id { snoozeOneShot = nil }
        queueReschedule(alarms[i])
    }

    private func sortAlarms() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    var nextAlarm: (alarm: Alarm, date: Date)? {
        alarms.compactMap { a in a.nextFireDate().map { (a, $0) } }
              .min { $0.1 < $1.1 }
    }

    // MARK: - Scheduling

    private func reschedule(_ alarm: Alarm) async {
        cancelNotifications(for: alarm)
        guard alarm.isEnabled, let fire = alarm.nextFireDate() else { return }

        let center = UNUserNotificationCenter.current()
        for i in 0..<chainLength {
            guard !Task.isCancelled else { return }   // superseded by a newer reschedule
            let content = UNMutableNotificationContent()
            content.title = "⏰ \(alarm.label)"
            content.body = i == 0 ? "Time to wake up! Open Daybreak to stop the alarm."
                                  : "Still ringing — open the app to complete your mission."
            content.interruptionLevel = .timeSensitive
            content.sound = notificationSound(for: alarm)
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

    /// Reschedule everything (call on app launch / after an alarm finishes, so repeating alarms line up their next occurrence).
    func rescheduleAll() {
        for alarm in alarms { queueReschedule(alarm) }
    }

    /// Reschedules are queued per alarm so a rapid edit/toggle can't
    /// interleave two cancel-and-add passes for the same alarm.
    private var rescheduleTasks: [UUID: Task<Void, Never>] = [:]

    private func queueReschedule(_ alarm: Alarm) {
        rescheduleTasks[alarm.id]?.cancel()
        rescheduleTasks[alarm.id] = Task { await reschedule(alarm) }
    }

    private func cancelNotifications(for alarm: Alarm) {
        var ids = (0..<chainLength).map { "\(alarm.id.uuidString)-\($0)" }
        ids += (0..<chainLength).map { "\(alarm.id.uuidString)-ringing-\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// The alarm's chosen tone if its file is bundled, else the classic tone, else the system default sound.
    private func notificationSound(for alarm: Alarm) -> UNNotificationSound {
        for tone in [alarm.tone, .classic] where bundledSoundExists(tone.fileName) {
            return UNNotificationSound(named: UNNotificationSoundName(tone.fileName))
        }
        return .default
    }

    private func bundledSoundExists(_ fileName: String) -> Bool {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext) != nil
    }

    // MARK: - Ringing takeover

    /// Called when the app becomes active or a notification is tapped.
    /// If an enabled alarm fired within the ring window, take over the screen.
    func checkForRingingAlarm() {
        guard ringingAlarm == nil else { return }
        let now = Date.now
        for alarm in alarms where alarm.isEnabled {
            guard let last = lastFireDate(of: alarm, before: now) else { continue }
            if let dismissed = dismissedRing, dismissed.id == alarm.id, dismissed.fire == last {
                continue   // this ring was already dismissed
            }
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
        AudioEngine.shared.startAlarm(song: alarm.song, tone: alarm.tone, ramp: alarm.volumeRamp)
        if alarm.vibrate { HapticEngine.shared.start() }
        if UIApplication.shared.applicationState != .active {
            Task { await postRingingNotifications(for: alarm) }
        }
    }

    /// Lock-screen breadcrumbs while the alarm audio plays in the background:
    /// silent notifications (the song is already loud) that take the user
    /// straight into the app — instead of a Now Playing card whose pause
    /// button would let them silence the alarm without doing the mission.
    private func postRingingNotifications(for alarm: Alarm) async {
        let center = UNUserNotificationCenter.current()
        for i in 0..<chainLength {
            let content = UNMutableNotificationContent()
            content.title = "⏰ \(alarm.label)"
            content.body = "Ringing now — tap to open Daybreak and complete your mission."
            content.interruptionLevel = .timeSensitive
            content.sound = nil
            content.userInfo = ["alarmID": alarm.id.uuidString]
            let trigger = i == 0 ? nil : UNTimeIntervalNotificationTrigger(
                timeInterval: Double(i) * Self.chainSpacing, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(alarm.id.uuidString)-ringing-\(i)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    // MARK: - Background ringing (the real Alarmy trick)
    //
    // Notification sounds always respect the silent switch. To ring loud on
    // a silenced phone, the app itself must be running at fire time: a
    // silent audio loop (see AudioEngine.startKeepAlive) keeps us alive in
    // the background, and this timer starts the real alarm — full-volume
    // tone or library song — the moment it's due. The notification chain
    // stays scheduled as a fallback for when iOS kills the app.

    private var fireTimer: Timer?

    /// Call when the app moves to the background.
    func enterBackground() {
        guard ringingAlarm == nil else {
            // Already ringing out loud; force-quitting now would silence it.
            startKillWarning()
            return
        }
        armFireTimer()
        if nextBackgroundFire() != nil {
            AudioEngine.shared.startKeepAlive()
            startKillWarning()
        }
    }

    /// Call when the app becomes active again.
    func enterForeground() {
        fireTimer?.invalidate()
        fireTimer = nil
        stopKillWarning()
        AudioEngine.shared.stopKeepAlive()
    }

    // MARK: - Force-quit warning
    //
    // If the user force-quits the app (or iOS kills it), the keep-alive
    // loop dies and the alarm can't ring at full volume — and we get no
    // chance to run code at that moment. So while armed in the background
    // we keep a warning notification scheduled 90 s out and push it back
    // every 45 s. App alive → it never fires. App killed → it fires.
    // (applicationWillTerminate additionally fires it immediately when
    // iOS gives us the courtesy call.)

    private static let killWarningID = "daybreak-force-quit-warning"
    private var killWarningTimer: Timer?

    func scheduleKillWarning(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Daybreak isn't running"
        content.body = "Your alarm won't be able to ring at full volume. Reopen Daybreak to re-arm it."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.killWarningID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)   // same ID = replaces pending
    }

    private func startKillWarning() {
        scheduleKillWarning(after: 90)
        killWarningTimer?.invalidate()
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleKillWarning(after: 90) }
        }
        RunLoop.main.add(timer, forMode: .common)
        killWarningTimer = timer
    }

    private func stopKillWarning() {
        killWarningTimer?.invalidate()
        killWarningTimer = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.killWarningID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.killWarningID])
    }

    private func armFireTimer() {
        fireTimer?.invalidate()
        guard let next = nextBackgroundFire() else { return }
        let timer = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.ringingAlarm == nil else { return }
                self.startRinging(next.alarm)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fireTimer = timer
    }

    /// The next thing due to ring: a regular alarm or an in-flight snooze.
    private func nextBackgroundFire() -> (alarm: Alarm, date: Date)? {
        var candidates: [(Alarm, Date)] = []
        if let next = nextAlarm { candidates.append(next) }
        if let (alarm, fire) = snoozeOneShot, fire > .now { candidates.append((alarm, fire)) }
        return candidates.min { $0.1 < $1.1 }.map { (alarm: $0.0, date: $0.1) }
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
        queueReschedule(snoozed)
    }

    /// Tracks an in-flight snooze so checkForRingingAlarm can find it.
    private var snoozeOneShot: (Alarm, Date)?

    func dismissRinging() {
        AudioEngine.shared.stop()
        HapticEngine.shared.stop()
        if let alarm = ringingAlarm {
            cancelNotifications(for: alarm)
            // Remember this ring so reopening the app while its fire time is
            // still inside the ring window doesn't start it all over again.
            if let fire = lastFireDate(of: alarm, before: .now) {
                dismissedRing = (alarm.id, fire)
            }
            // One-time alarms switch off after they ring; repeating ones
            // re-arm. Check the *stored* alarm — a snoozed copy has its
            // repeatDays stripped and must not switch off the original.
            if let i = alarms.firstIndex(where: { $0.id == alarm.id }), alarms[i].repeatDays.isEmpty {
                alarms[i].isEnabled = false
            }
        }
        snoozeOneShot = nil
        ringingAlarm = nil
        rescheduleAll()
    }

    /// The last ring the user dismissed (alarm id + fire time). Persisted so
    /// a relaunch inside the ring window doesn't replay a dismissed alarm.
    private var dismissedRing: (id: UUID, fire: Date)? {
        didSet {
            guard let dismissed = dismissedRing else { return }
            UserDefaults.standard.set(dismissed.id.uuidString, forKey: "dismissedRingID")
            UserDefaults.standard.set(dismissed.fire.timeIntervalSince1970, forKey: "dismissedRingFire")
        }
    }

    private func loadDismissedRing() {
        guard let raw = UserDefaults.standard.string(forKey: "dismissedRingID"),
              let id = UUID(uuidString: raw) else { return }
        let fire = UserDefaults.standard.double(forKey: "dismissedRingFire")
        if fire > 0 { dismissedRing = (id, Date(timeIntervalSince1970: fire)) }
    }

    private func lastFireDate(of alarm: Alarm, before now: Date) -> Date? {
        if let (snoozed, fire) = snoozeOneShot, snoozed.id == alarm.id, fire <= now {
            return fire
        }
        return alarm.lastFireDate(before: now)
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

