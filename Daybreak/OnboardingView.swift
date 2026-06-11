import SwiftUI
import UserNotifications
import CoreMotion
import MediaPlayer

struct OnboardingView: View {
    @EnvironmentObject var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var notificationsGranted = false
    @State private var motionGranted = false
    @State private var mediaGranted = false

    // Must outlive requestMotion(): CoreMotion cancels the permission
    // callback if the pedometer is deallocated while the dialog is up.
    @State private var pedometer = CMPedometer()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.ink.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Welcome to Daybreak")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("We need a few permissions so your alarms can ring reliably and missions can work.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        permRow(icon: "bell.fill", title: "Allow Notifications",
                                note: "Required — alarms can't ring without it",
                                granted: notificationsGranted) {
                            Task { await requestNotifications() }
                        }
                        permRow(icon: "figure.walk", title: "Motion & Fitness",
                                note: "Optional — for the steps mission",
                                granted: motionGranted) {
                            requestMotion()
                        }
                        permRow(icon: "music.note", title: "Media Library",
                                note: "Optional — for wake-up songs",
                                granted: mediaGranted) {
                            requestMedia()
                        }
                    }
                    .padding(20)
                    .card()

                    Button {
                        dismiss()
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Capsule().fill(Theme.dawn))
                    }
                    .padding(.horizontal, 24)
                    .disabled(!notificationsGranted)
                    .opacity(notificationsGranted ? 1 : 0.6)
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .task { await refreshGrantedStates() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Pick up changes made in Settings, or a permission dialog
                // resolving while this sheet is up.
                Task { await refreshGrantedStates() }
            }
        }
    }

    /// Reflect permissions that are already granted, so the Continue button
    /// isn't blocked behind requests that would never show a dialog again.
    private func refreshGrantedStates() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = settings.authorizationStatus == .authorized
                            || settings.authorizationStatus == .provisional

        if CMPedometer.isStepCountingAvailable() {
            motionGranted = CMPedometer.authorizationStatus() == .authorized
        } else {
            motionGranted = true
        }

        mediaGranted = MPMediaLibrary.authorizationStatus() == .authorized
    }

    private func permRow(icon: String, title: String, note: String,
                         granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.dawnAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.white)
                Text(note).font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.dawnAmber)
            }
        }
    }

    // MARK: Requests

    private func requestMotion() {
        // If the device can't count steps, mark granted so the row settles.
        guard CMPedometer.isStepCountingAvailable() else {
            motionGranted = true
            return
        }
        switch CMPedometer.authorizationStatus() {
        case .authorized:
            motionGranted = true
        case .notDetermined:
            let now = Date()
            pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in
                // The query can error ("no data") even when access was just
                // granted — the authorization status is the real answer.
                DispatchQueue.main.async {
                    motionGranted = CMPedometer.authorizationStatus() == .authorized
                }
            }
        default:
            // Denied earlier — iOS won't show the dialog again.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func requestMedia() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async { mediaGranted = (status == .authorized) }
        }
    }

    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .denied {
            // Denied earlier — iOS won't show the dialog again.
            await MainActor.run {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { notificationsGranted = granted }
        } catch {
            await MainActor.run { notificationsGranted = false }
        }
    }
}

