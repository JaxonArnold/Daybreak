import SwiftUI
import Combine

@main
struct DaybreakApp: App {
    @StateObject private var store = AlarmStore()
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
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.ringingAlarm != nil)
            .preferredColorScheme(.dark)
            .onAppear {
                let center = UNUserNotificationCenter.current()
                NotificationsManager.shared.store = store
                center.delegate = NotificationsManager.shared
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The moment the user opens the app after the notification
                // chain starts firing, take over with music + vibration.
                store.checkForRingingAlarm()
                store.rescheduleAll()
            }
        }
    }
}

