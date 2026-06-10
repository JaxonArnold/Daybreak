import SwiftUI
import Combine

/// Full-screen takeover while the alarm rings. The music and haptics
/// keep going until the mission is finished (or a snooze is spent).
struct RingingView: View {
    @EnvironmentObject var store: AlarmStore
    @State private var missionActive = false
    @State private var now = Date.now
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Slow-breathing dawn background so the screen itself feels awake.
            Theme.nightSky.ignoresSafeArea()
            PulsingGlow()

            if let alarm = store.ringingAlarm {
                VStack(spacing: 0) {
                    Spacer()

                    Text(now, format: .dateTime.hour().minute())
                        .font(Theme.clock(76, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())

                    Text(alarm.label)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textDim)
                        .padding(.top, 4)

                    if let song = alarm.song {
                        Label("\(song.title) — \(song.artist)", systemImage: "music.note")
                            .font(.subheadline)
                            .foregroundStyle(Theme.dawnAmber)
                            .padding(.top, 16)
                            .lineLimit(1)
                            .padding(.horizontal, 32)
                    }

                    Spacer()

                    if missionActive {
                        missionView(for: alarm)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        VStack(spacing: 14) {
                            Button {
                                if alarm.mission == .none {
                                    store.dismissRinging()
                                } else {
                                    withAnimation(.spring) { missionActive = true }
                                }
                            } label: {
                                Text(alarm.mission == .none ? "Stop" : "Start mission · \(alarm.mission.shortLabel)")
                                    .font(.headline)
                                    .foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .background(Capsule().fill(Theme.dawn))
                            }

                            if alarm.snoozeEnabled && store.snoozeCountThisRing < alarm.maxSnoozes {
                                Button {
                                    store.snooze()
                                } label: {
                                    Text("Snooze \(alarm.snoozeMinutes) min · \(alarm.maxSnoozes - store.snoozeCountThisRing) left")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textDim)
                                        .frame(height: 44)
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .statusBarHidden()
    }

    @ViewBuilder
    private func missionView(for alarm: Alarm) -> some View {
        switch alarm.mission {
        case .steps(let count):
            StepMissionView(target: count) { store.dismissRinging() }
        case .math(let problems):
            MathMissionView(target: problems) { store.dismissRinging() }
        case .none:
            EmptyView()
        }
    }
}

/// Soft amber glow that breathes behind the clock.
struct PulsingGlow: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Theme.dawnCoral.opacity(0.18))
            .frame(width: 380, height: 380)
            .blur(radius: 80)
            .scaleEffect(pulse ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}

// MARK: - Step mission

struct StepMissionView: View {
    let target: Int
    let onComplete: () -> Void
    @StateObject private var tracker = StepMissionTracker()

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, Double(tracker.steps) / Double(target)))
                    .stroke(Theme.dawn, style: .init(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: tracker.steps)
                VStack(spacing: 2) {
                    Text("\(tracker.steps)")
                        .font(Theme.clock(52, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("of \(target) steps")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(width: 200, height: 200)

            Text("Get up and walk. Phone in hand!")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)

            if tracker.unavailable {
                VStack(spacing: 10) {
                    Text("Step counting isn't available — check Motion & Fitness permission in Settings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dawnCoral)
                        .multilineTextAlignment(.center)
                    Button("Dismiss alarm anyway") { onComplete() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.dawnAmber)
                }
                .padding(.horizontal, 32)
            }
        }
        .padding(.bottom, 50)
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
        .onChange(of: tracker.steps) { _, steps in
            if steps >= target {
                tracker.stop()
                onComplete()
            }
        }
    }
}

// MARK: - Math mission

struct MathMissionView: View {
    let target: Int
    let onComplete: () -> Void

    @State private var solved = 0
    @State private var a = Int.random(in: 1...49)
    @State private var b = Int.random(in: 1...9)
    @State private var c = Int.random(in: 1...9)
    @State private var answer = ""
    @State private var shake = false
    @FocusState private var focused: Bool

    private var correct: Int { a + b * c }

    var body: some View {
        VStack(spacing: 18) {
            Text("Problem \(solved + 1) of \(target)")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)

            Text("\(a) + \(b) × \(c)")
                .font(Theme.clock(44, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: shake ? -8 : 0)
                .animation(shake ? .default.repeatCount(3).speed(4) : .default, value: shake)

            TextField("Answer", text: $answer)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.clock(30))
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                .padding(.horizontal, 60)
                .focused($focused)

            Button {
                check()
            } label: {
                Text("Check")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().fill(Theme.dawn))
            }
            .padding(.horizontal, 60)
        }
        .padding(.bottom, 40)
        .onAppear { focused = true }
    }

    private func check() {
        guard Int(answer) == correct else {
            shake = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = false }
            answer = ""
            return
        }
        solved += 1
        if solved >= target {
            onComplete()
        } else {
            a = Int.random(in: 12...49); b = Int.random(in: 12...49); c = Int.random(in: 2...9)
            answer = ""
        }
    }
}

