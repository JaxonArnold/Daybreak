import SwiftUI
import MediaPlayer
import CoreMotion
import Combine

struct AlarmEditorView: View {
    @EnvironmentObject var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State var alarm: Alarm
    @State private var time: Date
    @State private var showingSongPicker = false
    @State private var missionKind: MissionKind
    @State private var stepCount: Double
    @State private var mathCount: Double
    @State private var motionStatus = CMPedometer.authorizationStatus()
    // Must outlive the permission request — CoreMotion cancels the callback
    // if the pedometer is deallocated while the dialog is up.
    @State private var pedometer = CMPedometer()

    enum MissionKind: String, CaseIterable, Identifiable {
        case none = "None", steps = "Steps", math = "Math"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .none:  return "hand.tap"
            case .steps: return "figure.walk"
            case .math:  return "x.squareroot"
            }
        }
    }

    init(alarm: Alarm) {
        _alarm = State(initialValue: alarm)
        var comps = DateComponents(); comps.hour = alarm.hour; comps.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: comps) ?? .now)
        switch alarm.mission {
        case .none:
            _missionKind = State(initialValue: .none)
            _stepCount = State(initialValue: 30); _mathCount = State(initialValue: 3)
        case .steps(let n):
            _missionKind = State(initialValue: .steps)
            _stepCount = State(initialValue: Double(n)); _mathCount = State(initialValue: 3)
        case .math(let n):
            _missionKind = State(initialValue: .math)
            _stepCount = State(initialValue: 30); _mathCount = State(initialValue: Double(n))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        timeSection
                        daysSection
                        soundSection
                        missionSection
                        optionsSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle(alarm.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.dawnAmber)
                }
            }
            .sheet(isPresented: $showingSongPicker) {
                MusicPicker { item in
                    if let item {
                        alarm.song = SongChoice(
                            persistentID: item.persistentID,
                            title: item.title ?? "Unknown song",
                            artist: item.artist ?? "Unknown artist"
                        )
                    }
                }
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Alarms default to the steps mission; if motion access isn't
            // granted, fall back so the selection isn't stuck on a locked tile.
            if missionKind == .steps && !stepsUsable { missionKind = .math }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Pick up a grant made in Settings while this sheet was open.
            motionStatus = CMPedometer.authorizationStatus()
        }
    }

    // MARK: - Sections

    private var timeSection: some View {
        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .card()
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Repeat", detail: alarm.repeatString)
            HStack(spacing: 8) {
                ForEach(Weekday.allCases) { day in
                    let selected = alarm.repeatDays.contains(day)
                    Button {
                        if selected { alarm.repeatDays.remove(day) }
                        else { alarm.repeatDays.insert(day) }
                    } label: {
                        Text(day.letter)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                Circle().fill(selected ? AnyShapeStyle(Theme.dawn) : AnyShapeStyle(Color.white.opacity(0.06)))
                            )
                            .foregroundStyle(selected ? Theme.ink : Theme.textDim)
                    }
                }
            }
        }
        .padding(20)
        .card()
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Wake-up song", detail: nil)
            Button { showingSongPicker = true } label: {
                HStack {
                    Image(systemName: "music.note")
                        .foregroundStyle(Theme.dawnAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.song?.title ?? "Choose from your library")
                            .foregroundStyle(.white)
                        if let song = alarm.song {
                            Text(song.artist).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            if alarm.song != nil {
                Button("Use built-in alarm tone instead") { alarm.song = nil }
                    .font(.footnote)
                    .foregroundStyle(Theme.dawnCoral)
            }

            Divider().overlay(Theme.inkBorder)

            HStack {
                Label("Notification tone", systemImage: "bell.and.waves.left.and.right")
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    Picker("Notification tone", selection: $alarm.tone) {
                        ForEach(AlarmTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(alarm.tone.displayName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.dawnAmber)
                }
            }
            Text("Plays with each notification until you open the app.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
        }
        .padding(20)
        .card()
    }

    private var missionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Wake-up mission", detail: nil)
            Text("The alarm won't stop until the mission is done.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)

            HStack(spacing: 10) {
                ForEach(MissionKind.allCases) { kind in
                    let selected = missionKind == kind
                    let locked = kind == .steps && !stepsUsable
                    Button {
                        if locked { requestMotionAccess() } else { missionKind = kind }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: locked ? "lock.fill" : kind.icon).font(.title3)
                            Text(kind.rawValue).font(.footnote.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selected ? AnyShapeStyle(Theme.dawn) : AnyShapeStyle(Color.white.opacity(0.06)))
                        )
                        .foregroundStyle(selected ? Theme.ink : Theme.textDim)
                        .opacity(locked ? 0.5 : 1)
                    }
                }
            }

            if !stepsUsable {
                if !CMPedometer.isStepCountingAvailable() {
                    Text("This device can't count steps.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textFaint)
                } else if motionStatus == .notDetermined {
                    Text("Steps needs Motion & Fitness access — tap Steps to allow.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textDim)
                } else {
                    Button("Steps needs Motion & Fitness access — open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.dawnCoral)
                }
            }

            if missionKind == .steps {
                stepperRow(value: $stepCount, range: 10...200, step: 10,
                           label: "\(Int(stepCount)) steps to dismiss")
            } else if missionKind == .math {
                stepperRow(value: $mathCount, range: 1...10, step: 1,
                           label: "\(Int(mathCount)) problem\(Int(mathCount) == 1 ? "" : "s") to dismiss")
            }
        }
        .padding(20)
        .card()
    }

    private var optionsSection: some View {
        VStack(spacing: 4) {
            optionToggle("Vibrate hard", icon: "iphone.radiowaves.left.and.right", isOn: $alarm.vibrate)
            Divider().overlay(Theme.inkBorder)
            optionToggle("Gentle volume ramp", icon: "speaker.wave.3", isOn: $alarm.volumeRamp)
            Divider().overlay(Theme.inkBorder)
            optionToggle("Allow snooze", icon: "zzz", isOn: $alarm.snoozeEnabled)
            if alarm.snoozeEnabled {
                HStack {
                    Text("Max \(alarm.maxSnoozes) snoozes · \(alarm.snoozeMinutes) min each")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Spacer()
                    Stepper("", value: $alarm.maxSnoozes, in: 1...5).labelsHidden()
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .card()
    }

    // MARK: - Helpers

    private var stepsUsable: Bool {
        CMPedometer.isStepCountingAvailable() && motionStatus == .authorized
    }

    private func requestMotionAccess() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        switch CMPedometer.authorizationStatus() {
        case .authorized:
            motionStatus = .authorized
            missionKind = .steps
        case .notDetermined:
            let now = Date()
            pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in
                DispatchQueue.main.async {
                    motionStatus = CMPedometer.authorizationStatus()
                    if motionStatus == .authorized { missionKind = .steps }
                }
            }
        default:
            // Denied earlier — iOS won't show the dialog again.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.white)
            Spacer()
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
    }

    private func optionToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon).foregroundStyle(.white)
        }
        .tint(Theme.dawnCoral)
        .padding(.vertical, 6)
    }

    private func stepperRow(value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.white)
            Slider(value: value, in: range, step: step)
                .tint(Theme.dawnCoral)
        }
    }

    private func save() {
        alarm.hour = Calendar.current.component(.hour, from: time)
        alarm.minute = Calendar.current.component(.minute, from: time)
        switch missionKind {
        case .none:  alarm.mission = .none
        case .steps: alarm.mission = .steps(count: Int(stepCount))
        case .math:  alarm.mission = .math(problems: Int(mathCount))
        }
        alarm.isEnabled = true
        store.upsert(alarm)
        dismiss()
    }
}

/// Wraps MPMediaPickerController so the user can pick any song from
/// their Apple Music / iTunes library.
struct MusicPicker: UIViewControllerRepresentable {
    var onPick: (MPMediaItem?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true
        picker.prompt = "Pick your wake-up song"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let parent: MusicPicker
        init(_ parent: MusicPicker) { self.parent = parent }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            parent.onPick(mediaItemCollection.items.first)
            parent.dismiss()
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}

