import SwiftUI
import Combine

struct AlarmListView: View {
    @EnvironmentObject var store: AlarmStore
    @State private var editingAlarm: Alarm?
    @State private var showingNew = false
    @State private var showingQuick = false
    @State private var now = Date.now
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.nightSky.ignoresSafeArea()

                List {
                    Group {
                        NextAlarmCard(now: now)
                        ForEach(store.alarms) { alarm in
                            AlarmRow(alarm: alarm) { editingAlarm = alarm }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.delete(alarm)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        if store.alarms.isEmpty {
                            emptyState
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 100, for: .scrollContent)
            }
            .navigationTitle("Daybreak")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingQuick = true } label: {
                        Image(systemName: "timer")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.dawnAmber)
                    }
                    .accessibilityLabel("Quick alarm")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.dawnAmber)
                    }
                    .accessibilityLabel("Add alarm")
                }
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditorView(alarm: alarm)
            }
            .sheet(isPresented: $showingNew) {
                AlarmEditorView(alarm: Alarm())
            }
            .sheet(isPresented: $showingQuick) {
                QuickAlarmView()
                    .presentationDetents([.medium])
                    .presentationBackground(Theme.ink)
            }
            .sheet(isPresented: Binding(
                get: { !didCompleteOnboarding },
                set: { didCompleteOnboarding = !$0 }
            )) {
                OnboardingView()
                    .environmentObject(store)
                    .interactiveDismissDisabled()
            }
            .onReceive(tick) { now = $0 }
        }
        .tint(Theme.dawnAmber)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.dawn)
            Text("No alarms yet")
                .font(.headline)
            Text("Tap + to set your first wake-up.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// The signature element: a sunrise arc that fills as your alarm approaches.
struct NextAlarmCard: View {
    @EnvironmentObject var store: AlarmStore
    let now: Date

    var body: some View {
        Group {
            if let next = store.nextAlarm {
                VStack(spacing: 14) {
                    SunriseArc(progress: arcProgress(for: next.date))
                        .frame(height: 90)
                    VStack(spacing: 4) {
                        Text(countdown(to: next.date))
                            .font(Theme.clock(30))
                            .foregroundStyle(.white)
                        Text("until \(next.alarm.label.lowercased()) · \(next.alarm.timeString)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .card()
            }
        }
    }

    /// Arc fills over the final 12 hours before the alarm.
    private func arcProgress(for date: Date) -> Double {
        let remaining = date.timeIntervalSince(now)
        let window: TimeInterval = 12 * 3600
        return max(0, min(1, 1 - remaining / window))
    }

    private func countdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

struct SunriseArc: View {
    let progress: Double   // 0 = night, 1 = alarm time

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Horizon line
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 8))
                    p.addLine(to: CGPoint(x: w, y: h - 8))
                }
                .stroke(Theme.inkBorder, lineWidth: 1)

                // The arc track + filled portion
                arcPath(in: geo.size).stroke(Theme.inkBorder, style: .init(lineWidth: 3, lineCap: .round))
                arcPath(in: geo.size)
                    .trim(from: 0, to: progress)
                    .stroke(Theme.dawn, style: .init(lineWidth: 3, lineCap: .round))

                // The sun, riding the arc
                let angle = Double.pi * (1 - progress)
                let r = (w - 40) / 2
                let cx = w / 2 + r * cos(angle)
                let cy = (h - 8) - r * sin(angle) * (h - 24) / r
                Circle()
                    .fill(Theme.dawn)
                    .frame(width: 16, height: 16)
                    .shadow(color: Theme.dawnAmber.opacity(0.8), radius: 8)
                    .position(x: cx, y: max(8, cy))
            }
        }
    }

    private func arcPath(in size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 20, y: size.height - 8))
            p.addQuadCurve(
                to: CGPoint(x: size.width - 20, y: size.height - 8),
                control: CGPoint(x: size.width / 2, y: -size.height * 0.6)
            )
        }
    }
}

struct AlarmRow: View {
    @EnvironmentObject var store: AlarmStore
    let alarm: Alarm
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(alarm.timeString)
                        .font(Theme.clock(36))
                        .foregroundStyle(alarm.isEnabled ? .white : Theme.textFaint)
                    HStack(spacing: 6) {
                        Text(alarm.label)
                        Text("·")
                        Text(alarm.repeatString)
                        if alarm.mission != .none {
                            Text("·")
                            Label(alarm.mission.shortLabel, systemImage: "figure.walk")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(alarm.isEnabled ? Theme.textDim : Theme.textFaint)
                    if let song = alarm.song {
                        Label("\(song.title) — \(song.artist)", systemImage: "music.note")
                            .font(.footnote)
                            .foregroundStyle(alarm.isEnabled ? Theme.dawnAmber.opacity(0.9) : Theme.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { alarm.isEnabled },
                    set: { store.toggle(alarm, enabled: $0) }
                ))
                .labelsHidden()
                .tint(Theme.dawnCoral)
                .sensoryFeedback(.selection, trigger: alarm.isEnabled)
            }
            .padding(20)
            .card()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { store.delete(alarm) } label: {
                Label("Delete alarm", systemImage: "trash")
            }
        }
    }
}

