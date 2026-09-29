import Foundation
import CoreMotion
import Combine

/// Counts shakes for the shake mission. Uses raw device motion, which needs
/// no permission (unlike the pedometer).
@MainActor
final class ShakeMissionTracker: ObservableObject {
    @Published var shakes = 0
    @Published var unavailable = false

    private let motion = CMMotionManager()
    private var detector = ShakeDetector()

    func start() {
        guard motion.isDeviceMotionAvailable else { unavailable = true; return }
        shakes = 0
        detector = ShakeDetector()
        motion.deviceMotionUpdateInterval = 1 / ShakeDetector.sampleRate
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let sample else { return }
            let a = sample.userAcceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let time = sample.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                self.detector.process(magnitude, at: time)
                if self.shakes != self.detector.shakes { self.shakes = self.detector.shakes }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}

/// Counts each hard stroke of a shake from the magnitude of acceleration
/// (in g). A back-and-forth shake peaks at both ends, so it counts twice —
/// the counter climbs as fast as you shake.
struct ShakeDetector {
    static let sampleRate = 50.0
    /// A stroke must exceed this — well above walking, handling the phone,
    /// or the alarm's own vibration.
    static let shakeThreshold = 1.4
    /// The signal must drop back below this before the next stroke counts.
    static let resetThreshold = 0.6
    /// Closer peaks than this are one jolt, not two strokes.
    static let minShakeInterval: TimeInterval = 0.12

    private(set) var shakes = 0
    private var armed = true
    private var lastShake: TimeInterval?

    mutating func process(_ magnitude: Double, at time: TimeInterval) {
        if magnitude < Self.resetThreshold { armed = true }
        guard armed, magnitude > Self.shakeThreshold else { return }
        armed = false
        if let last = lastShake, time - last < Self.minShakeInterval { return }
        shakes += 1
        lastShake = time
    }
}
