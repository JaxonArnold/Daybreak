import Foundation
import UserNotifications

final class NotificationsManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsManager()
    private override init() { super.init() }

    weak var store: AlarmStore?

    // Called when the user taps a notification or performs an action.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.store?.checkForRingingAlarm()
        }
        completionHandler()
    }

    // Show banners and play sound even if the app is foregrounded —
    // unless the ringing screen has already taken over.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            // An alarm notification arriving while the app is open means
            // it's fire time — take over the screen, don't just banner.
            self?.store?.checkForRingingAlarm()
            if self?.store?.ringingAlarm != nil {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound])
            }
        }
    }
}
