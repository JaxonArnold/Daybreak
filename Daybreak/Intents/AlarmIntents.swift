import AppIntents
import CoreMotion
import UIKit

// Siri / Shortcuts support. These run inside the app process — iOS launches
// the app in the background if it isn't running — so they talk straight to
// AlarmStore.shared.

// MARK: - Alarm entity (lets Siri ask "which alarm?")

nonisolated struct AlarmEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Alarm"
    static let defaultQuery = AlarmEntityQuery()

    let id: UUID
    let timeString: String
    let label: String

    @MainActor
    init(_ alarm: Alarm) {
        id = alarm.id
        timeString = alarm.timeString
        label = alarm.label
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(timeString)", subtitle: "\(label)")
    }
}

nonisolated struct AlarmEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AlarmEntity] {
        AlarmStore.shared.alarms.filter { identifiers.contains($0.id) }.map(AlarmEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AlarmEntity] {
        AlarmStore.shared.alarms.map(AlarmEntity.init)
    }
}

// MARK: - Intents

struct SetAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Set an Alarm"
    static let description = IntentDescription("Creates a new Daybreak alarm.")

    @Parameter(title: "Time")
    var time: Date

    @Parameter(title: "Label", default: "Alarm")
    var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Set an alarm for \(\.$time)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cal = Calendar.current
        var alarm = Alarm()
        alarm.hour = cal.component(.hour, from: time)
        alarm.minute = cal.component(.minute, from: time)
        alarm.label = label
        // The default steps mission needs motion access; an alarm created
        // by voice mustn't land on a mission the user can't complete.
        if !(CMPedometer.isStepCountingAvailable()
             && CMPedometer.authorizationStatus() == .authorized) {
            alarm.mission = .math(problems: 3)
        }
        AlarmStore.shared.upsert(alarm)
        rearmBackgroundProtection()
        return .result(dialog: "Alarm set for \(alarm.timeString).")
    }
}

nonisolated struct NextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Alarm"
    static let description = IntentDescription("Tells you when your next Daybreak alarm rings.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let next = AlarmStore.shared.nextAlarm else {
            return .result(dialog: "You don't have any alarms turned on.")
        }
        let when = next.date.formatted(.relative(presentation: .named))
        return .result(dialog: "\(next.alarm.label) rings at \(next.alarm.timeString), \(when).")
    }
}

struct TurnOffAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off an Alarm"
    static let description = IntentDescription("Disables a Daybreak alarm without deleting it.")

    @Parameter(title: "Alarm")
    var alarm: AlarmEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off \(\.$alarm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stored = AlarmStore.shared.alarms.first(where: { $0.id == alarm.id }) else {
            return .result(dialog: "That alarm no longer exists.")
        }
        AlarmStore.shared.toggle(stored, enabled: false)
        rearmBackgroundProtection()
        return .result(dialog: "Turned off the \(stored.timeString) alarm.")
    }
}

struct TurnOnAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On an Alarm"
    static let description = IntentDescription("Re-enables a Daybreak alarm.")

    @Parameter(title: "Alarm")
    var alarm: AlarmEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Turn on \(\.$alarm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stored = AlarmStore.shared.alarms.first(where: { $0.id == alarm.id }) else {
            return .result(dialog: "That alarm no longer exists.")
        }
        AlarmStore.shared.toggle(stored, enabled: true)
        rearmBackgroundProtection()
        return .result(dialog: "The \(stored.timeString) alarm is on.")
    }
}

/// After Siri changes alarms while the app sits in the background, re-arm
/// the keep-alive loop and fire timer so the new state rings reliably —
/// the scenePhase handler only runs on real foreground/background moves.
@MainActor
private func rearmBackgroundProtection() {
    if UIApplication.shared.applicationState != .active {
        AlarmStore.shared.enterBackground()
    }
}

// MARK: - Siri phrases

nonisolated struct DaybreakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetAlarmIntent(),
            phrases: [
                "Set a \(.applicationName) alarm",
                "Set an alarm in \(.applicationName)",
                "Wake me up with \(.applicationName)",
            ],
            shortTitle: "Set Alarm",
            systemImageName: "alarm"
        )
        AppShortcut(
            intent: NextAlarmIntent(),
            phrases: [
                "When's my next \(.applicationName) alarm",
                "What's my next \(.applicationName) alarm",
            ],
            shortTitle: "Next Alarm",
            systemImageName: "sun.horizon"
        )
        AppShortcut(
            intent: TurnOffAlarmIntent(),
            phrases: [
                "Turn off a \(.applicationName) alarm",
                "Disable a \(.applicationName) alarm",
            ],
            shortTitle: "Turn Off Alarm",
            systemImageName: "alarm.slash"
        )
        AppShortcut(
            intent: TurnOnAlarmIntent(),
            phrases: [
                "Turn on a \(.applicationName) alarm",
                "Enable a \(.applicationName) alarm",
            ],
            shortTitle: "Turn On Alarm",
            systemImageName: "alarm.fill"
        )
    }
}
