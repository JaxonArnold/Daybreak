import SwiftUI
import Combine

/// Timer-style alarm: stack +1/+5/+10/+15/+30 min and +1 hour taps into a
/// running total, then set a one-time alarm that far from now.
struct QuickAlarmView: View {
    @EnvironmentObject var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var totalMinutes = 0
    @State private var now = Date.now
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Just under a day — past that, an hour/minute alarm can't represent
    /// the intended fire date.
    private static let maxMinutes = 23 * 60 + 59

    private let increments: [(label: String, minutes: Int)] = [
        ("+1 min", 1), ("+5 min", 5), ("+10 min", 10),
        ("+15 min", 15), ("+30 min", 30), ("+1 hour", 60),
    ]

    /// The alarm model stores hour/minute only, so quick alarms count from
    /// the next whole minute — the alarm may ring slightly late, never early.
    static func fireDate(adding minutes: Int, from now: Date, calendar cal: Calendar = .current) -> Date {
        let floor = cal.dateInterval(of: .minute, for: now)?.start ?? now
        let base = floor == now ? now : floor.addingTimeInterval(60)
        return base.addingTimeInterval(Double(minutes) * 60)
    }

    private var fireDate: Date {
        Self.fireDate(adding: totalMinutes, from: now)
    }

    private var totalString: String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m) min"
    }

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Quick alarm")
                    .font(.headline)
                    .foregroundStyle(.white)

                VStack(spacing: 6) {
                    Text(totalString)
                        .font(Theme.clock(56, weight: .bold))
                        .foregroundStyle(totalMinutes == 0 ? Theme.textFaint : .white)
                        .contentTransition(.numericText())
                    Text(totalMinutes == 0
                         ? "Tap below to add time"
                         : "Rings at \(fireDate.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(increments, id: \.minutes) { increment in
                        Button {
                            withAnimation(.snappy) {
                                totalMinutes = min(totalMinutes + increment.minutes, Self.maxMinutes)
                            }
                        } label: {
                            Text(increment.label)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                                .foregroundStyle(Theme.dawnAmber)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy) { totalMinutes = 0 }
                    } label: {
                        Text("Reset")
                            .font(.subheadline.weight(.medium))
                            .frame(width: 90)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .foregroundStyle(Theme.textDim)
                    }
                    .disabled(totalMinutes == 0)

                    Button {
                        start()
                    } label: {
                        Text("Set alarm")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Capsule().fill(Theme.dawn))
                    }
                    .disabled(totalMinutes == 0)
                    .opacity(totalMinutes == 0 ? 0.5 : 1)
                }
            }
            .padding(24)
        }
        .onReceive(tick) { now = $0 }
        .sensoryFeedback(.increase, trigger: totalMinutes)
        .preferredColorScheme(.dark)
    }

    private func start() {
        let cal = Calendar.current
        var alarm = Alarm()
        alarm.label = "Quick alarm"
        alarm.mission = .none          // it's a nap timer, not a wake-up fight
        alarm.hour = cal.component(.hour, from: fireDate)
        alarm.minute = cal.component(.minute, from: fireDate)
        store.upsert(alarm)
        dismiss()
    }
}
