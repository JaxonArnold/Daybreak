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
        // Auto-Lock would otherwise darken the screen partway through a
        // mission (30 s by default) — right as you're walking with it.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private func missionView(for alarm: Alarm) -> some View {
        switch alarm.mission {
        case .steps(let count):
            StepMissionView(target: count) { store.dismissRinging() }
        case .math(let problems):
            MathMissionView(target: problems) { store.dismissRinging() }
        case .shake(let count):
            ShakeMissionView(target: count) { store.dismissRinging() }
        case .scan(let code):
            ScanMissionView(code: code) { store.dismissRinging() }
        case .memory(let rounds):
            MemoryMissionView(rounds: rounds) { store.dismissRinging() }
        case .typing(let phrases):
            TypingMissionView(count: phrases) { store.dismissRinging() }
        case .photo(let reference):
            PhotoMissionView(reference: reference) { store.dismissRinging() }
        case .none:
            EmptyView()
        }
    }
}

/// Soft amber glow that breathes behind the clock.
struct PulsingGlow: View {
    @State private var pulse = false
    var body: some View {
        // An overlay on a clear, screen-sized layer: the glow is wider than
        // the screen, and laid out directly it would widen the ringing view
        // (pushing its buttons off the edges).
        Color.clear
            .overlay {
                // A radial gradient rather than a blurred circle: the same soft
                // glow with no offscreen blur to re-render each frame — or to clip.
                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: Theme.dawnCoral.opacity(0.18), location: 0),
                        .init(color: Theme.dawnCoral.opacity(0.12), location: 0.45),
                        .init(color: .clear, location: 1),
                    ], center: .center, startRadius: 0, endRadius: 270))
                    .frame(width: 540, height: 540)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)
            }
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
        Group {
            if tracker.unavailable {
                FallbackMathMission(
                    reason: "Step counting isn't available — check Motion & Fitness in Settings. Solve these instead.",
                    onComplete: onComplete)
            } else {
                VStack(spacing: 20) {
                    MissionProgressRing(count: tracker.steps, target: target, unit: "steps")

                    Text("Get up and walk. Phone in hand!")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)

                    if tracker.steps == 0 {
                        Text("First steps can take a few seconds to register.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            // The haptic pattern thumps once a second — noise right in the
            // walking band that the step sensors have to see through. The
            // alarm audio keeps playing; you're already up.
            HapticEngine.shared.stop()
            tracker.start()
        }
        .onDisappear { tracker.stop() }
        .onChange(of: tracker.steps) { _, steps in
            if steps >= target {
                tracker.stop()
                onComplete()
            }
        }
    }
}

/// Progress ring shared by the counting missions (steps, shakes).
struct MissionProgressRing: View {
    let count: Int
    let target: Int
    let unit: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle()
                .trim(from: 0, to: min(1, Double(count) / Double(target)))
                .stroke(Theme.dawn, style: .init(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: count)
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(Theme.clock(52, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("of \(target) \(unit)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(width: 200, height: 200)
    }
}

/// When a mission can't run (no sensor, no camera), fall back to math —
/// never trap the user with a ringing alarm, never skip the mission.
struct FallbackMathMission: View {
    let reason: String
    var problems = 5
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Theme.dawnCoral)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            MathMissionView(target: problems, onComplete: onComplete)
        }
    }
}

// MARK: - Shake mission

struct ShakeMissionView: View {
    let target: Int
    let onComplete: () -> Void
    @StateObject private var tracker = ShakeMissionTracker()

    var body: some View {
        Group {
            if tracker.unavailable {
                FallbackMathMission(reason: "This device can't detect shaking. Solve these instead.",
                                    onComplete: onComplete)
            } else {
                VStack(spacing: 20) {
                    MissionProgressRing(count: tracker.shakes, target: target, unit: "shakes")
                    Text("Shake your phone hard!")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
        .onChange(of: tracker.shakes) { _, shakes in
            if shakes >= target {
                tracker.stop()
                onComplete()
            }
        }
    }
}

// MARK: - Scan mission

struct ScanMissionView: View {
    let code: String
    let onComplete: () -> Void

    /// Lost the item, or can't find the code? After this long, math is on
    /// offer — a way out that still takes effort.
    private static let fallbackDelay: Duration = .seconds(60)

    @State private var cameraReady: Bool?      // nil while checking permission
    @State private var wrongScans = 0
    @State private var showWrongCode = false
    @State private var offerFallback = false
    @State private var usingFallback = false
    @State private var completed = false

    var body: some View {
        Group {
            if cameraReady == false {
                FallbackMathMission(reason: "The camera isn't available. Solve these instead.",
                                    onComplete: onComplete)
            } else if usingFallback {
                FallbackMathMission(reason: "Solve these to stop the alarm.", onComplete: onComplete)
            } else {
                VStack(spacing: 16) {
                    Group {
                        if cameraReady == true {
                            CodeScanner(onScan: check)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 280, height: 280)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Text(showWrongCode ? "That's not your code" : "Go scan the code you registered.")
                        .font(.subheadline.weight(showWrongCode ? .semibold : .regular))
                        .foregroundStyle(showWrongCode ? Theme.dawnCoral : Theme.textDim)

                    if offerFallback {
                        Button("Can't find it? Solve 5 problems instead") { usingFallback = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.dawnAmber)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .sensoryFeedback(.error, trigger: wrongScans)
        .sensoryFeedback(.success, trigger: completed)
        .task {
            cameraReady = CodeScanner.isSupported ? await CameraAccess.request() : false
            try? await Task.sleep(for: Self.fallbackDelay)
            withAnimation { offerFallback = true }
        }
    }

    private func check(_ payload: String) {
        guard !completed else { return }
        if payload == code {
            completed = true
            onComplete()
        } else {
            wrongScans += 1
            showWrongCode = true
            let attempt = wrongScans
            Task {
                try? await Task.sleep(for: .seconds(2))
                if wrongScans == attempt { showWrongCode = false }
            }
        }
    }
}

// MARK: - Memory mission

struct MemoryMissionView: View {
    let rounds: Int
    let onComplete: () -> Void

    @State private var round = 1
    @State private var game = MemoryRound.random(length: MemoryRound.length(forRound: 1))
    @State private var watching = true
    @State private var lit: Int?
    @State private var playback = 0      // bump to (re)play the pattern
    @State private var misses = 0

    var body: some View {
        VStack(spacing: 18) {
            Text("Round \(round) of \(rounds)")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            Text(watching ? "Watch the pattern" : "Now repeat it")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 12), count: 3), spacing: 12) {
                ForEach(0..<MemoryRound.tileCount, id: \.self) { tile in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(lit == tile ? AnyShapeStyle(Theme.dawn) : AnyShapeStyle(Color.white.opacity(0.08)))
                        .frame(width: 72, height: 72)
                        .contentShape(Rectangle())
                        .onTapGesture { tap(tile) }
                }
            }
            .allowsHitTesting(!watching)
        }
        .padding(.bottom, 40)
        .sensoryFeedback(.error, trigger: misses)
        .task(id: playback) { await playPattern() }
    }

    private func playPattern() async {
        watching = true
        lit = nil
        try? await Task.sleep(for: .milliseconds(700))
        for tile in game.sequence {
            guard !Task.isCancelled else { return }
            lit = tile
            try? await Task.sleep(for: .milliseconds(500))
            lit = nil
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return }
        watching = false
    }

    private func tap(_ tile: Int) {
        lit = tile
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if lit == tile { lit = nil }
        }
        switch game.tap(tile) {
        case .correct:
            break
        case .wrong:
            misses += 1
            playback += 1        // watch it again
        case .complete where round == rounds:
            onComplete()
        case .complete:
            round += 1
            game = .random(length: MemoryRound.length(forRound: round))
            playback += 1
        }
    }
}

// MARK: - Typing mission

struct TypingMissionView: View {
    let onComplete: () -> Void

    @State private var phrases: [String]
    @State private var index = 0
    @State private var input = ""
    @FocusState private var focused: Bool

    init(count: Int, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _phrases = State(initialValue: TypingMission.randomPhrases(count))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Phrase \(index + 1) of \(phrases.count)")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            Text(phrases[index])
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            TextField("Type it here", text: $input, axis: .vertical)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                .padding(.horizontal, 32)
                .focused($focused)
            Text("Capitals and punctuation don't matter.")
                .font(.footnote)
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.bottom, 40)
        .onAppear { focused = true }
        .onChange(of: input) { _, text in
            guard TypingMission.matches(text, phrases[index]) else { return }
            if index + 1 == phrases.count {
                onComplete()
            } else {
                index += 1
                input = ""
            }
        }
    }
}

// MARK: - Photo mission

struct PhotoMissionView: View {
    let reference: PhotoReference
    let onComplete: () -> Void

    /// Same safety valve as the scan mission.
    private static let fallbackDelay: Duration = .seconds(60)

    @State private var cameraReady: Bool?
    @State private var showingCamera = false
    @State private var checking = false
    @State private var feedback: String?
    @State private var misses = 0
    @State private var offerFallback = false
    @State private var usingFallback = false
    @State private var completed = false

    var body: some View {
        Group {
            if cameraReady == false {
                FallbackMathMission(reason: "The camera isn't available. Solve these instead.",
                                    onComplete: onComplete)
            } else if usingFallback {
                FallbackMathMission(reason: "Solve these to stop the alarm.", onComplete: onComplete)
            } else {
                VStack(spacing: 14) {
                    if let thumbnail = UIImage(data: reference.thumbnail) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    Text(feedback ?? "Go take a photo of this spot.")
                        .font(.subheadline.weight(feedback == nil ? .regular : .semibold))
                        .foregroundStyle(feedback == nil ? Theme.textDim : Theme.dawnCoral)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        showingCamera = true
                    } label: {
                        Text(checking ? "Checking…" : "Take photo")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Capsule().fill(Theme.dawn))
                    }
                    .disabled(checking || cameraReady != true)
                    .padding(.horizontal, 60)
                    if offerFallback {
                        Button("Can't match it? Solve 5 problems instead") { usingFallback = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.dawnAmber)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                showingCamera = false
                if let image { check(image) }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.error, trigger: misses)
        .sensoryFeedback(.success, trigger: completed)
        .task {
            cameraReady = CameraPicker.isAvailable ? await CameraAccess.request() : false
            try? await Task.sleep(for: Self.fallbackDelay)
            withAnimation { offerFallback = true }
        }
    }

    private func check(_ image: UIImage) {
        checking = true
        feedback = nil
        Task {
            let distance = await PhotoMatcher.distance(from: image, to: reference)
            checking = false
            guard !completed else { return }
            if let distance, distance < PhotoMatcher.matchThreshold {
                completed = true
                onComplete()
                return
            }
            misses += 1
            guard let distance else {
                feedback = "Couldn't check that photo. Try again."
                return
            }
            feedback = "Not a match — stand where you took the first photo and try again."
            #if DEBUG
            feedback! += String(format: " (score %.2f, needs under %.2f)", distance, PhotoMatcher.matchThreshold)
            #endif
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

