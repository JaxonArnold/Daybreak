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
                        permRow(icon: "bell.fill", title: "Allow Notifications", granted: notificationsGranted) {
                            Task { await requestNotifications() }
                        }
                        permRow(icon: "figure.walk", title: "Motion & Fitness", granted: motionGranted) {
                            requestMotion()
                        }
                        permRow(icon: "music.note", title: "Media Library", granted: mediaGranted) {
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
                    .disabled(!(notificationsGranted && motionGranted))
                    .opacity((notificationsGranted && motionGranted) ? 1 : 0.6)
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func permRow(icon: String, title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.dawnAmber)
            Text(title).foregroundStyle(.white)
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
        // If the device can't count steps, allow continue so the app remains usable.
        guard CMPedometer.isStepCountingAvailable() else {
            motionGranted = true
            return
        }
        let pedometer = CMPedometer()
        let now = Date()
        pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, error in
            DispatchQueue.main.async {
                motionGranted = (error == nil)
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
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { notificationsGranted = granted }
        } catch {
            await MainActor.run { notificationsGranted = false }
        }
    }
}

