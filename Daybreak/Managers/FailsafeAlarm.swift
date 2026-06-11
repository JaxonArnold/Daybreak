import AlarmKit
import AppIntents
import SwiftUI

/// System-level failsafe via AlarmKit (iOS 26): a parallel alarm that
/// breaks through Focus and the silent switch even if the app has been
/// force-quit. It's scheduled 60 s after the real fire time — when the app
/// is alive it rings first and cancels this before it fires; when the app
/// is dead, the system alarm cuts through where the notification chain
/// can't. Shares the alarm's UUID, so cancel/re-sync is one call.
enum FailsafeAlarm {
    struct Metadata: AlarmMetadata {}

    /// How long the in-app alarm gets to ring (and cancel us) first.
    static let graceWindow: TimeInterval = 60

    /// Cancel and, if the alarm is enabled, re-schedule the failsafe for
    /// its next occurrence. Mirrors the notification-chain lifecycle.
    static func sync(_ alarm: Alarm) async {
        cancel(alarm.id)
        guard alarm.isEnabled, let fire = alarm.nextFireDate() else { return }
        guard await ensureAuthorized() else { return }

        let alert = AlarmPresentation.Alert(
            title: "\(alarm.label) — open Daybreak",
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(text: "Open Daybreak", textColor: .white, systemImageName: "sun.horizon.fill"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<Metadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: Metadata(),
            tintColor: Theme.dawnAmber
        )
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(fire.addingTimeInterval(graceWindow)),
            attributes: attributes,
            secondaryIntent: OpenDaybreakIntent()
        )
        _ = try? await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
    }

    static func cancel(_ id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }

    /// Asks for AlarmKit authorization the first time a failsafe is
    /// scheduled — i.e. when the user saves their first alarm, which is
    /// the moment the request makes sense to them.
    private static func ensureAuthorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default:
            return false
        }
    }
}

/// The "Open Daybreak" button on the system alarm — brings the app up so
/// the ringing screen and mission take over.
struct OpenDaybreakIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Daybreak"
    static let isDiscoverable: Bool = false
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmStore.shared.checkForRingingAlarm()
        return .result()
    }
}
