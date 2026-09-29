import Foundation
import Testing
@testable import Daybreak

// Synthetic acceleration-magnitude traces (g) at the detector's sample rate.
struct ShakeMissionTests {

    func feed(_ detector: inout ShakeDetector, seconds: Double, _ signal: (Double) -> Double) {
        let rate = ShakeDetector.sampleRate
        for i in 0..<Int(seconds * rate) {
            let t = Double(i) / rate
            detector.process(signal(t), at: t)
        }
    }

    @Test func countsEachStrokeOfAHardShake() {
        // Shaking back and forth 3 times a second peaks at both ends of
        // each swing: 6 strokes a second, 30 in five seconds.
        var detector = ShakeDetector()
        feed(&detector, seconds: 5) { t in abs(2.5 * sin(2 * .pi * 3 * t)) }
        #expect(detector.shakes == 30)
    }

    @Test func walkingIsNotShaking() {
        var detector = ShakeDetector()
        feed(&detector, seconds: 10) { t in abs(0.3 * sin(2 * .pi * 2 * t)) }
        #expect(detector.shakes == 0)
    }

    @Test func theAlarmsOwnVibrationIsNotShaking() {
        var detector = ShakeDetector()
        feed(&detector, seconds: 10) { t in abs(0.4 * sin(2 * .pi * 23 * t)) }
        #expect(detector.shakes == 0)
    }

    @Test func aSingleJoltCountsOnce() {
        // Tossing the phone onto the bed: one hard spike, not a burst.
        var detector = ShakeDetector()
        feed(&detector, seconds: 2) { t in (0.5..<0.6).contains(t) ? 3.0 : 0 }
        #expect(detector.shakes == 1)
    }
}
