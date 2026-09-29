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
        pendingWakeCheck = UserDefaults.standard.data(forKey: Self.wakeCheckKey)
            .flatMap { try? JSONDecoder().decode(WakeCheck.self, from: $0) }
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
        if pendingWakeCheck?.alarm.id == alarm.id { endWakeCheck() }
        cancelNotifications(for: alarm)
        FailsafeAlarm.cancel(alarm.id)
    }

    func toggle(_ alarm: Alarm, enabled: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].isEnabled = enabled
        if !enabled, snoozeOneShot?.0.id == alarm.id { snoozeOneShot = nil }
        if !enabled, pendingWakeCheck?.alarm.id == alarm.id { endWakeCheck() }
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
        // Keep the AlarmKit failsafe in lockstep with the notification chain.
        await FailsafeAlarm.sync(alarm)
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
        for alarm in alarms { queueReschedule(pendingOneShot(for: alarm.id) ?? alarm) }
    }

    /// A snooze or wake-check re-ring waiting on this alarm. It's scheduled
    /// in the alarm's place — they share notification and backup-alarm IDs,
    /// so scheduling the regular next occurrence would wipe it out.
    private func pendingOneShot(for id: UUID) -> Alarm? {
        if let (snoozed, fire) = snoozeOneShot, snoozed.id == id, fire > .now { return snoozed }
        if let check = pendingWakeCheck, check.alarm.id == id, check.deadline > .now { return check.rering }
        return nil
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
        // The app was closed mid-ring (force-quit, crash): pick up where it
        // left off, mission and all.
        if let interrupted = interruptedRing() {
            startRinging(interrupted)
            return
        }
        let now = Date.now
        // A missed wake-up check rings again — unless it's long past, in
        // which case they're clearly up now: wrap it up.
        if let check = pendingWakeCheck, check.deadline <= now {
            if now.timeIntervalSince(check.deadline) < Self.ringWindow {
                startRinging(check.alarm)
                return
            }
            endWakeCheck()
            finishOccurrence(of: check.alarm)
        }
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
        // Nothing is ringing — clear anything an interrupted ring left
        // behind (its rescue notifications and backup alarm).
        stopHeartbeat()
        removeSpentQuickAlarms()
    }

    func startRinging(_ alarm: Alarm) {
        // Snoozes count per occurrence, so a snooze's ring — or a ring
        // resumed after a force-quit — carries on the count.
        if let ledger = snoozeLedger, ledger.alarmID == alarm.id,
           ledger.occurrence == occurrence(of: alarm) {
            snoozeCountThisRing = ledger.used
        } else {
            snoozeCountThisRing = 0
        }
        ringingAlarm = alarm
        // Ringing again because a wake-up check was missed: that check is over.
        if pendingWakeCheck?.alarm.id == alarm.id { endWakeCheck() }
        // The app is ringing out loud, so this occurrence's notification
        // chain and backup alarm aren't needed — the heartbeat keeps a
        // rescue armed instead, in case the app is closed mid-ring.
        // Dismissing re-arms the next occurrence via rescheduleAll.
        cancelNotifications(for: alarm)
        FailsafeAlarm.cancel(alarm.id)
        AudioEngine.shared.startAlarm(song: alarm.song, tone: alarm.tone, ramp: alarm.volumeRamp)
        if alarm.vibrate { HapticEngine.shared.start() }
        startHeartbeat(for: alarm)
    }

    // MARK: - Ringing heartbeat (closing the app doesn't stop the alarm)
    //
    // While ringing, the app itself makes the noise — so if it's force-quit,
    // nothing else would. A heartbeat every `chainSpacing` seconds:
    //  - keeps a loud notification chain and an AlarmKit alarm scheduled
    //    `rescueLead` seconds ahead, pushing both back each beat. App alive
    //    → they never fire. App closed → loud notifications every 10 s plus
    //    a system alarm that breaks through silent mode and Focus.
    //  - posts the silent "tap to open" lock-screen breadcrumb while the app
    //    is in the background. Posted live rather than pre-scheduled, so they
    //    stop with the app instead of doubling up with the loud chain.
    //  - records that we're still ringing, so reopening the app after a
    //    force-quit goes straight back to the ringing screen.

    /// How far ahead of now the rescue is kept while ringing.
    static let rescueLead: TimeInterval = 30

    private static let rescueNowID = "daybreak-rescue-now"
    private static let ringingAlarmKey = "ringingAlarm"
    private static let ringingHeartbeatKey = "ringingHeartbeat"

    private var heartbeatTimer: Timer?
    private var breadcrumbCount = 0
    /// Rescue scheduling runs as a chain of tasks so a push-back can never
    /// land after a cancel — that would fire a stray alarm after dismissal.
    private var rescueTask: Task<Void, Never>?

    private static func rescueID(_ i: Int) -> String { "daybreak-rescue-\(i)" }

    private var rescueIDs: [String] {
        [Self.rescueNowID] + (0..<chainLength).map(Self.rescueID)
    }

    private func startHeartbeat(for alarm: Alarm) {
        heartbeatTimer?.invalidate()
        breadcrumbCount = 0
        if let data = try? JSONEncoder().encode(alarm) {
            UserDefaults.standard.set(data, forKey: Self.ringingAlarmKey)
        }
        // Resuming after a force-quit: clear the rescue notifications that
        // got us here.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: rescueIDs)
        beat(alarm)
        let timer = Timer(timeInterval: Self.chainSpacing, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let alarm = self.ringingAlarm { self.beat(alarm) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func beat(_ alarm: Alarm) {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.ringingHeartbeatKey)
        let previous = rescueTask
        rescueTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await scheduleRescue(for: alarm)
        }
        if UIApplication.shared.applicationState != .active {
            postBreadcrumb(for: alarm)
        }
    }

    /// Stops the heartbeat and removes the rescue. Safe to call when idle.
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        UserDefaults.standard.removeObject(forKey: Self.ringingAlarmKey)
        UserDefaults.standard.removeObject(forKey: Self.ringingHeartbeatKey)
        let ids = rescueIDs
        let previous = rescueTask
        previous?.cancel()
        rescueTask = Task {
            await previous?.value   // let an in-flight push-back finish first
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            FailsafeAlarm.cancel(FailsafeAlarm.rescueID)
        }
    }

    private func scheduleRescue(for alarm: Alarm) async {
        let center = UNUserNotificationCenter.current()
        let content = rescueContent(for: alarm)
        for i in 0..<chainLength {
            guard !Task.isCancelled else { return }
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Self.rescueLead + Double(i) * Self.chainSpacing, repeats: false)
            // Same IDs every beat, so each add replaces the pending one.
            let request = UNNotificationRequest(identifier: Self.rescueID(i), content: content, trigger: trigger)
            try? await center.add(request)
        }
        guard !Task.isCancelled else { return }
        await FailsafeAlarm.scheduleRescue(for: alarm, at: .now.addingTimeInterval(Self.rescueLead))
    }

    private func rescueContent(for alarm: Alarm) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(alarm.label)"
        content.body = "Your alarm is still going — open Daybreak to finish your mission."
        content.interruptionLevel = .timeSensitive
        content.sound = notificationSound(for: alarm)
        content.userInfo = ["alarmID": alarm.id.uuidString]
        return content
    }

    /// The app is being closed mid-ring (swiped away): sound the first loud
    /// notification right away instead of waiting for the rescue chain.
    func ringingWillTerminate() {
        guard let alarm = ringingAlarm else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Self.rescueNowID,
                                            content: rescueContent(for: alarm), trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Lock-screen breadcrumb while the alarm plays in the background: a
    /// silent notification (the song is already loud) that takes the user
    /// straight into the app — instead of a Now Playing card whose pause
    /// button would let them silence the alarm without doing the mission.
    private func postBreadcrumb(for alarm: Alarm) {
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(alarm.label)"
        content.body = "Ringing now — tap to open Daybreak and complete your mission."
        content.interruptionLevel = .timeSensitive
        content.sound = nil
        content.userInfo = ["alarmID": alarm.id.uuidString]
        // IDs cycle within the set cancelNotifications(for:) cleans up.
        let id = "\(alarm.id.uuidString)-ringing-\(breadcrumbCount % chainLength)"
        breadcrumbCount += 1
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A ring cut short by the app closing (force-quit, crash) whose last
    /// heartbeat was within `ringWindow`, for an alarm that's still on.
    private func interruptedRing() -> Alarm? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.ringingAlarmKey),
              let alarm = try? JSONDecoder().decode(Alarm.self, from: data),
              alarms.contains(where: { $0.id == alarm.id && $0.isEnabled }) else { return nil }
        let lastBeat = Date(timeIntervalSince1970: defaults.double(forKey: Self.ringingHeartbeatKey))
        return Date.now.timeIntervalSince(lastBeat) < Self.ringWindow ? alarm : nil
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
        // Already ringing out loud — the ringing heartbeat covers a force-quit.
        guard ringingAlarm == nil else { return }
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
        if let check = pendingWakeCheck, check.deadline > .now { candidates.append((check.alarm, check.deadline)) }
        return candidates.min { $0.1 < $1.1 }.map { (alarm: $0.0, date: $0.1) }
    }

    func snooze() {
        guard let alarm = ringingAlarm,
              alarm.snoozeEnabled, snoozeCountThisRing < alarm.maxSnoozes else { return }
        snoozeCountThisRing += 1
        if let occurrence = occurrence(of: alarm) {
            snoozeLedger = SnoozeLedger(alarmID: alarm.id, occurrence: occurrence,
                                        used: snoozeCountThisRing)
        }
        AudioEngine.shared.stop()
        HapticEngine.shared.stop()
        ringingAlarm = nil
        stopHeartbeat()

        // One-shot snooze chain.
        let fire = Date.now.addingTimeInterval(Double(alarm.snoozeMinutes) * 60)
        var snoozed = alarm
        snoozed.repeatDays = []
        snoozed.hour = Calendar.current.component(.hour, from: fire)
        snoozed.minute = Calendar.current.component(.minute, from: fire)
        if snoozed.isQuick { snoozed.quickFireDate = fire }
        snoozeOneShot = (snoozed, fire)
        queueReschedule(snoozed)
    }

    /// Tracks an in-flight snooze so checkForRingingAlarm can find it.
    private var snoozeOneShot: (Alarm, Date)?

    /// Snoozes used on one occurrence of an alarm (its id + scheduled time).
    /// Tied to the occurrence rather than reset on every ring, so a snooze's
    /// ring continues the count — and persisted, so closing the app can't
    /// reset the limit.
    private struct SnoozeLedger: Codable {
        var alarmID: UUID
        var occurrence: Date
        var used: Int
    }

    private static let snoozeLedgerKey = "snoozeLedger"

    private var snoozeLedger: SnoozeLedger? {
        get {
            UserDefaults.standard.data(forKey: Self.snoozeLedgerKey)
                .flatMap { try? JSONDecoder().decode(SnoozeLedger.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.snoozeLedgerKey)
        }
    }

    /// The scheduled occurrence a ring belongs to. Uses the stored alarm: a
    /// snoozed copy carries the snooze time, but its ring still belongs to
    /// the original occurrence.
    private func occurrence(of alarm: Alarm) -> Date? {
        let stored = alarms.first { $0.id == alarm.id } ?? alarm
        return stored.lastFireDate(before: .now)
    }

    func dismissRinging() {
        AudioEngine.shared.stop()
        HapticEngine.shared.stop()
        stopHeartbeat()
        if let alarm = ringingAlarm {
            cancelNotifications(for: alarm)
            // Remember this occurrence so reopening the app inside the ring
            // window doesn't start it all over again.
            if let fire = occurrence(of: alarm) {
                dismissedRing = (alarm.id, fire)
            }
            // Check the *stored* alarm — a snoozed copy has its repeatDays
            // stripped and must not switch off the original. Quick alarms are
            // one-and-done; with a wake-up check, the occurrence isn't over
            // until it's answered.
            if let stored = alarms.first(where: { $0.id == alarm.id }) {
                if stored.isQuick {
                    delete(stored)
                } else if stored.wakeUpCheck {
                    startWakeCheck(for: stored)
                } else {
                    finishOccurrence(of: stored)
                }
            }
        }
        snoozeOneShot = nil
        ringingAlarm = nil
        rescheduleAll()
    }

    /// An occurrence is over: one-time alarms switch off and stay in the
    /// list; repeating ones simply re-arm.
    private func finishOccurrence(of alarm: Alarm) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }),
              alarms[i].repeatDays.isEmpty else { return }
        alarms[i].isEnabled = false
    }

    // MARK: - Wake-up check
    //
    // `wakeCheckDelay` after an alarm with a wake-up check is stopped, a
    // notification (and an in-app prompt, see StillAwakeView) asks "Still
    // awake?". No answer within `wakeCheckWindow` and the alarm rings again,
    // mission and all. The re-ring is a one-shot at the deadline, riding the
    // same machinery as a snooze: the fire timer, notification chain, and
    // backup alarm — so it happens even if the app has been closed.

    static let wakeCheckDelay: TimeInterval = 5 * 60
    static let wakeCheckWindow: TimeInterval = 90
    static let wakeCheckID = "daybreak-wake-check"
    private static let wakeCheckKey = "pendingWakeCheck"

    @Published private(set) var pendingWakeCheck: WakeCheck? {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(pendingWakeCheck), forKey: Self.wakeCheckKey)
        }
    }

    private func startWakeCheck(for alarm: Alarm) {
        let checkAt = Date.now.addingTimeInterval(Self.wakeCheckDelay)
        pendingWakeCheck = WakeCheck(alarm: alarm, checkAt: checkAt,
                                     deadline: checkAt.addingTimeInterval(Self.wakeCheckWindow))
        let content = UNMutableNotificationContent()
        content.title = "☀️ Still awake?"
        content.body = "Tap within \(Int(Self.wakeCheckWindow)) seconds, or \(alarm.label) rings again."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.wakeCheckDelay, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.wakeCheckID, content: content, trigger: trigger))
    }

    /// "I'm up" — from the prompt, or by tapping the check notification.
    func confirmWakeCheck() {
        guard let check = pendingWakeCheck, Date.now < check.deadline else { return }
        endWakeCheck()
        finishOccurrence(of: check.alarm)
        rescheduleAll()   // drops the re-ring for the next regular occurrence
    }

    private func endWakeCheck() {
        pendingWakeCheck = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.wakeCheckID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.wakeCheckID])
    }

    /// Catches a quick alarm that went off but was never dismissed (the app
    /// was closed mid-ring): it can't ring again, so tidy it away. The hour
    /// of grace outlasts any run of snoozes.
    private func removeSpentQuickAlarms() {
        let cutoff = Date.now.addingTimeInterval(-60 * 60)
        for alarm in alarms {
            guard let fire = alarm.quickFireDate, fire < cutoff,
                  ringingAlarm?.id != alarm.id, snoozeOneShot?.0.id != alarm.id else { continue }
            delete(alarm)
        }
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


/// A pending wake-up check: ask at `checkAt`, ring `alarm` again at
/// `deadline` if nobody answers.
struct WakeCheck: Codable, Equatable {
    var alarm: Alarm
    var checkAt: Date
    var deadline: Date

    /// What rings if the check is missed: the alarm as a one-shot at the
    /// exact deadline (`quickFireDate` means "ring once, at this moment").
    var rering: Alarm {
        var copy = alarm
        copy.repeatDays = []
        copy.hour = Calendar.current.component(.hour, from: deadline)
        copy.minute = Calendar.current.component(.minute, from: deadline)
        copy.quickFireDate = deadline
        return copy
    }
}
