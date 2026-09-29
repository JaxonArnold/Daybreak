import Foundation
import CoreMotion
import Combine

/// Counts live steps for the wake-up mission from two sources:
///
/// - **CMPedometer** — Apple's step counter. Accurate over a real walk, but
///   it reports in delayed batches (0 → 7 → 25) and tends to drop short
///   stop-start bouts and slow shuffling: a few steps, turn, a few steps,
///   which is exactly how you walk around a bedroom half-asleep.
/// - **StepDetector** — counts each step the moment it happens from the
///   accelerometer. Responsive, but easier to fool by bobbing the phone.
///
/// The detector may run at most `maxDetectorLead` steps ahead of the
/// pedometer: enough to cover its lag and forgive dropped steps, not
/// enough to finish the mission by waving the phone in bed.
@MainActor
final class StepMissionTracker: ObservableObject {
    /// Smoothed count for the UI. Never exceeds the credited count.
    @Published var steps: Int = 0
    @Published var unavailable = false

    nonisolated static let maxDetectorLead = 10

    private let pedometer = CMPedometer()
    private let motion = CMMotionManager()
    private var detector = StepDetector()
    private var pedometerSteps = 0
    private var pedometerWorking = false
    private var detectorWorking = false
    private var smoothTimer: Timer?

    /// Steps credited toward the mission. Either source may be missing
    /// (no permission, no hardware), in which case the other stands alone.
    static func creditedSteps(pedometer: Int?, detector: Int?,
                              maxLead: Int = maxDetectorLead) -> Int {
        switch (pedometer, detector) {
        case let (p?, d?): return p + min(max(d - p, 0), maxLead)
        case let (p?, nil): return p
        case let (nil, d?): return d
        case (nil, nil): return 0
        }
    }

    private var creditedSteps: Int {
        Self.creditedSteps(pedometer: pedometerWorking ? pedometerSteps : nil,
                           detector: detectorWorking ? detector.steps : nil)
    }

    func start() {
        steps = 0
        pedometerSteps = 0
        detector = StepDetector()
        startPedometer()
        startDetector()
        unavailable = !pedometerWorking && !detectorWorking
        if !unavailable { startSmoothing() }
    }

    func stop() {
        pedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
        smoothTimer?.invalidate()
        smoothTimer = nil
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometerWorking = true
        pedometer.startUpdates(from: .now) { [weak self] data, error in
            let count = error == nil ? data?.numberOfSteps.intValue : nil
            Task { @MainActor in
                guard let self else { return }
                guard let count else {
                    // e.g. Motion & Fitness access revoked — carry on with
                    // the detector alone rather than giving up.
                    self.pedometerWorking = false
                    self.unavailable = !self.detectorWorking
                    return
                }
                // Each update hops to the main actor as its own task; never
                // let a stale one lower the count.
                self.pedometerSteps = max(self.pedometerSteps, count)
            }
        }
    }

    private func startDetector() {
        guard motion.isDeviceMotionAvailable else { return }
        detectorWorking = true
        motion.deviceMotionUpdateInterval = 1 / StepDetector.sampleRate
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let sample else { return }
            // Acceleration along the up axis, so it works however the
            // phone is held.
            let g = sample.gravity, a = sample.userAcceleration
            let up = -(a.x * g.x + a.y * g.y + a.z * g.z)
            let time = sample.timestamp
            MainActor.assumeIsolated {
                self?.detector.process(up, at: time)
            }
        }
    }

    private func startSmoothing() {
        smoothTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let credited = self.creditedSteps
                guard self.steps < credited else { return }
                // Catch up faster when a pedometer batch lands, so the
                // display never trails by more than a couple of seconds.
                let gap = credited - self.steps
                self.steps += max(1, gap / 10)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        smoothTimer = timer
    }
}

/// Real-time step detection from upward acceleration (in g), sampled at
/// `sampleRate`. Classic peak detection: smooth the signal, count a step
/// when it rises above `stepThreshold`, and re-arm only once it falls back
/// below `resetThreshold`. The constants are starting points — tune them
/// on a device.
struct StepDetector {
    static let sampleRate = 50.0
    /// Upward acceleration a step's bounce must exceed.
    static let stepThreshold = 0.08
    /// The signal must drop back below this before the next step counts.
    static let resetThreshold = 0.02
    /// Fastest plausible cadence (~3.5 steps/s); closer peaks are one step.
    static let minStepInterval: TimeInterval = 0.28
    /// Slowest cadence still counted as one walk. A lone jolt with no second
    /// step inside this window (picking the phone up) isn't counted.
    static let maxStepInterval: TimeInterval = 1.6
    /// Low-pass smoothing per sample; lower is smoother.
    static let smoothing = 0.3

    private(set) var steps = 0
    private var filtered = 0.0
    private var armed = true
    private var lastStep: TimeInterval?
    private var pendingFirstStep = false

    mutating func process(_ upAcceleration: Double, at time: TimeInterval) {
        filtered += Self.smoothing * (upAcceleration - filtered)
        if filtered < Self.resetThreshold { armed = true }
        guard armed, filtered > Self.stepThreshold else { return }
        armed = false
        if let last = lastStep, time - last < Self.minStepInterval { return }

        if let last = lastStep, time - last <= Self.maxStepInterval {
            // Part of a walk — credit the bout's first step now that a
            // second one has confirmed it.
            if pendingFirstStep { steps += 1; pendingFirstStep = false }
            steps += 1
        } else {
            // First step of a new bout: hold it until the next one.
            pendingFirstStep = true
        }
        lastStep = time
    }
}
