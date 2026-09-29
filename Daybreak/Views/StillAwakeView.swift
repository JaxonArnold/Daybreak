import SwiftUI

/// The wake-up check's in-app prompt. Invisible until the check is due,
/// then a full-screen "Still awake?" with a countdown to the re-ring.
struct StillAwakeView: View {
    @EnvironmentObject var store: AlarmStore
    let check: WakeCheck

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let secondsLeft = Int(check.deadline.timeIntervalSince(context.date).rounded(.up))
            if context.date >= check.checkAt && secondsLeft > 0 {
                ZStack {
                    Theme.nightSky.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(Theme.dawn)
                        Text("Still awake?")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("\(check.alarm.label) rings again in \(secondsLeft)s")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                            .contentTransition(.numericText())
                        Button {
                            store.confirmWakeCheck()
                        } label: {
                            Text("I'm up")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .background(Capsule().fill(Theme.dawn))
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
