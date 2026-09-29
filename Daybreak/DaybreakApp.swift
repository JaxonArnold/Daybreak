import SwiftUI
import Combine

final class AppDelegate: NSObject, UIApplicationDelegate {
    // Set up before launch finishes, so tapping a notification that
    // launched the app (a "Still awake?" check, say) reaches the delegate.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationsManager.shared.store = AlarmStore.shared
        UNUserNotificationCenter.current().delegate = NotificationsManager.shared
        return true
    }

    // A force-quit of an app that's running in the background (our silent
    // keep-alive loop keeps us running) lands here — fire the warning right
    // away instead of waiting for the dead man's switch.
    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated {
            let store = AlarmStore.shared
            if store.ringingAlarm != nil {
                // Swiped away mid-ring: the alarm keeps going.
                store.ringingWillTerminate()
            } else if store.alarms.contains(where: { $0.isEnabled }) {
                store.scheduleKillWarning(after: 1)
            }
        }
    }
}

@main
struct DaybreakApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AlarmStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                AlarmListView()
                    .environmentObject(store)

                if store.ringingAlarm != nil {
                    RingingView()
                        .environmentObject(store)
                        .transition(.opacity)
                        .zIndex(1)
                } else if let check = store.pendingWakeCheck {
                    StillAwakeView(check: check)
                        .environmentObject(store)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.ringingAlarm != nil)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // The moment the user opens the app after the notification
                // chain starts firing, take over with music + vibration.
                store.enterForeground()
                store.checkForRingingAlarm()
                store.rescheduleAll()
            case .background:
                // Stay alive on a silent audio loop so the alarm can ring
                // at full volume even if the phone is on silent.
                store.enterBackground()
            default:
                break
            }
        }
    }
}

