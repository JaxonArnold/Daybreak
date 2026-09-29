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
    @State private var shakeCount: Double
    @State private var memoryRounds: Double
    @State private var typingPhrases: Double
    @State private var scanCode: String?
    @State private var photoReference: PhotoReference?
    @State private var showingCodeScanner = false
    @State private var showingPhotoCamera = false
    @State private var processingPhoto = false
    @State private var photoFailed = false
    @State private var cameraDenied = false
    @State private var motionStatus = CMPedometer.authorizationStatus()
    // Must outlive the permission request — CoreMotion cancels the callback
    // if the pedometer is deallocated while the dialog is up.
    @State private var pedometer = CMPedometer()

    enum MissionKind: String, CaseIterable, Identifiable {
        case none = "None", steps = "Steps", math = "Math", shake = "Shake"
        case scan = "Scan", memory = "Memory", typing = "Typing", photo = "Photo"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .none:   return "hand.tap"
            case .steps:  return "figure.walk"
            case .math:   return "x.squareroot"
            case .shake:  return "hand.wave"
            case .scan:   return "qrcode.viewfinder"
            case .memory: return "square.grid.3x3"
            case .typing: return "keyboard"
            case .photo:  return "camera.viewfinder"
            }
        }
    }

    init(alarm: Alarm) {
        _alarm = State(initialValue: alarm)
        var comps = DateComponents(); comps.hour = alarm.hour; comps.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: comps) ?? .now)
        var kind = MissionKind.none
        var steps = 30.0, math = 3.0, shakes = 50.0, rounds = 3.0, phrases = 2.0
        var code: String?
        var photo: PhotoReference?
        switch alarm.mission {
        case .none:                 break
        case .steps(let n):         kind = .steps; steps = Double(n)
        case .math(let n):          kind = .math; math = Double(n)
        case .shake(let n):         kind = .shake; shakes = Double(n)
        case .scan(let saved):      kind = .scan; code = saved
        case .memory(let n):        kind = .memory; rounds = Double(n)
        case .typing(let n):        kind = .typing; phrases = Double(n)
        case .photo(let saved):     kind = .photo; photo = saved
        }
        _missionKind = State(initialValue: kind)
        _stepCount = State(initialValue: steps)
        _mathCount = State(initialValue: math)
        _shakeCount = State(initialValue: shakes)
        _memoryRounds = State(initialValue: rounds)
        _typingPhrases = State(initialValue: phrases)
        _scanCode = State(initialValue: code)
        _photoReference = State(initialValue: photo)
    }

    /// The scan and photo missions need something registered before saving.
    private var canSave: Bool {
        switch missionKind {
        case .scan:  return scanCode != nil
        case .photo: return photoReference != nil
        default:     return true
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
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.4)
                }
            }
            .sheet(isPresented: $showingCodeScanner) {
                RegisterCodeView { scanCode = $0 }
            }
            .fullScreenCover(isPresented: $showingPhotoCamera) {
                CameraPicker { image in
                    showingPhotoCamera = false
                    if let image { registerPhoto(image) }
                }
                .ignoresSafeArea()
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
        .onChange(of: alarm.tone) { _, tone in
            AudioEngine.shared.preview(tone)
        }
        .sensoryFeedback(.selection, trigger: alarm.repeatDays)
        .sensoryFeedback(.selection, trigger: missionKind)
        .sensoryFeedback(.selection, trigger: alarm.tone)
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
                    .accessibilityLabel(day.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
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
                        ForEach(AlarmTone.allCases.filter(\.isBundled)) { tone in
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(MissionKind.allCases) { kind in
                    let selected = missionKind == kind
                    let locked = (kind == .steps && !stepsUsable)
                        || (kind == .scan && !CodeScanner.isSupported)
                        || (kind == .photo && !CameraPicker.isAvailable)
                    Button {
                        if !locked { missionKind = kind }
                        else if kind == .steps { requestMotionAccess() }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: locked ? "lock.fill" : kind.icon).font(.title3)
                                .frame(height: 26)   // symbols differ in height; keep tiles even
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

            if !CodeScanner.isSupported || !CameraPicker.isAvailable {
                Text(CameraPicker.isAvailable ? "This device can't scan codes."
                     : "This device's camera isn't available for Scan or Photo.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
            }

            switch missionKind {
            case .steps:
                stepperRow(value: $stepCount, range: 10...200, step: 10,
                           label: "\(Int(stepCount)) steps to dismiss")
            case .math:
                stepperRow(value: $mathCount, range: 1...10, step: 1,
                           label: "\(Int(mathCount)) problem\(Int(mathCount) == 1 ? "" : "s") to dismiss")
            case .shake:
                stepperRow(value: $shakeCount, range: 20...150, step: 10,
                           label: "\(Int(shakeCount)) shakes to dismiss")
            case .scan:
                scanSetup
            case .memory:
                stepperRow(value: $memoryRounds, range: 1...6, step: 1,
                           label: "\(Int(memoryRounds)) round\(Int(memoryRounds) == 1 ? "" : "s") · patterns of \(MemoryRound.length(forRound: 1)) to \(MemoryRound.length(forRound: Int(memoryRounds))) tiles")
            case .typing:
                stepperRow(value: $typingPhrases, range: 1...5, step: 1,
                           label: "\(Int(typingPhrases)) phrase\(Int(typingPhrases) == 1 ? "" : "s") to retype")
            case .photo:
                photoSetup
            case .none:
                EmptyView()
            }
        }
        .padding(20)
        .card()
    }

    private var scanSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let scanCode {
                Label("Code registered", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(scanCode)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Text(scanCode == nil
                 ? "Scan a QR code or barcode on something away from your bed — toothpaste, a coffee bag, a label on the bathroom mirror. You'll scan it again to stop the alarm."
                 : "Keep it somewhere you have to get up to reach.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
            Button(scanCode == nil ? "Scan a code" : "Scan a different code") { registerCode() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.dawnAmber)
            if cameraDenied {
                Button("Camera access is off — open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.dawnCoral)
            }
        }
    }

    private var photoSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let photoReference, let thumbnail = UIImage(data: photoReference.thumbnail) {
                HStack(spacing: 12) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Spot registered", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Text("Keep it somewhere you have to get up to reach.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            } else {
                Text("Take a photo of a spot away from your bed — the bathroom sink, the coffee maker. You'll photograph it again, from about the same place, to stop the alarm.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
            }
            if processingPhoto {
                ProgressView().tint(Theme.dawnAmber)
            } else {
                Button(photoReference == nil ? "Take a photo" : "Take a different photo") { takePhoto() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.dawnAmber)
            }
            if photoFailed {
                Text("Couldn't process that photo. Try again.")
                    .font(.footnote)
                    .foregroundStyle(Theme.dawnCoral)
            }
            if cameraDenied {
                Button("Camera access is off — open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.dawnCoral)
            }
        }
    }

    private func takePhoto() {
        Task {
            if await CameraAccess.request() {
                cameraDenied = false
                showingPhotoCamera = true
            } else {
                cameraDenied = true
            }
        }
    }

    private func registerPhoto(_ image: UIImage) {
        processingPhoto = true
        photoFailed = false
        Task {
            if let reference = await PhotoMatcher.makeReference(from: image) {
                photoReference = reference
            } else {
                photoFailed = true
            }
            processingPhoto = false
        }
    }

    private func registerCode() {
        Task {
            if await CameraAccess.request() {
                cameraDenied = false
                showingCodeScanner = true
            } else {
                cameraDenied = true
            }
        }
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
            // Quick alarms are naps — they delete themselves once stopped.
            if !alarm.isQuick {
                Divider().overlay(Theme.inkBorder)
                optionToggle("Wake-up check", icon: "checkmark.seal", isOn: $alarm.wakeUpCheck)
                if alarm.wakeUpCheck {
                    Text("\(Int(AlarmStore.wakeCheckDelay / 60)) minutes after you stop the alarm, you'll be asked if you're still up. No answer within \(Int(AlarmStore.wakeCheckWindow)) seconds and it rings again.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
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
        case .shake: alarm.mission = .shake(count: Int(shakeCount))
        case .scan:  alarm.mission = scanCode.map { .scan(code: $0) } ?? .none
        case .memory: alarm.mission = .memory(rounds: Int(memoryRounds))
        case .typing: alarm.mission = .typing(phrases: Int(typingPhrases))
        case .photo: alarm.mission = photoReference.map { .photo(reference: $0) } ?? .none
        }
        alarm.isEnabled = true
        // A quick alarm keeps deleting itself after it rings, at the edited
        // time — unless it's been given repeat days, making it a regular one.
        if alarm.isQuick {
            alarm.quickFireDate = nil
            if alarm.repeatDays.isEmpty { alarm.quickFireDate = alarm.nextFireDate() }
        }
        store.upsert(alarm)
        dismiss()
    }
}

/// Full-screen scanner for registering the scan mission's code — the first
/// code it sees is the one.
struct RegisterCodeView: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = false

    var body: some View {
        NavigationStack {
            CodeScanner { code in
                guard !picked else { return }
                picked = true
                onPick(code)
                dismiss()
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Point at a QR code or barcode")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
            .navigationTitle("Register a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: picked)
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

