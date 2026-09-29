import Foundation
import Testing
@testable import Daybreak

// Synthetic accelerometer traces at the detector's sample rate. A walk is
// modeled as one upward bounce per step — a sine at the step cadence.
struct StepMissionTests {

    /// Feeds `seconds` of `signal(t)` into the detector, starting at `start`.
    func feed(_ detector: inout StepDetector, from start: Double = 0,
              seconds: Double, _ signal: (Double) -> Double) {
        let rate = StepDetector.sampleRate
        for i in 0..<Int(seconds * rate) {
            let t = Double(i) / rate
            detector.process(signal(t), at: start + t)
        }
    }

    func walk(stepsPerSecond cadence: Double, amplitude: Double) -> (Double) -> Double {
        { t in amplitude * sin(2 * .pi * cadence * t) }
    }

    // MARK: - StepDetector

    @Test func countsEveryStepOfASteadyWalk() {
        var detector = StepDetector()
        feed(&detector, seconds: 10, walk(stepsPerSecond: 2, amplitude: 0.25))
        #expect(detector.steps == 20)
    }

    @Test func countsASlowGentleShuffle() {
        var detector = StepDetector()
        feed(&detector, seconds: 10, walk(stepsPerSecond: 1, amplitude: 0.12))
        #expect(detector.steps == 10)
    }

    @Test func countsShortStopStartBouts() {
        // Three steps, stand still for three seconds, three more — the
        // bedroom pattern CMPedometer tends to drop.
        var detector = StepDetector()
        let steps = walk(stepsPerSecond: 2, amplitude: 0.25)
        feed(&detector, from: 0, seconds: 1.5, steps)
        feed(&detector, from: 1.5, seconds: 3) { _ in 0 }
        feed(&detector, from: 4.5, seconds: 1.5, steps)
        #expect(detector.steps == 6)
    }

    @Test func ignoresAPhoneLyingStill() {
        var detector = StepDetector()
        feed(&detector, seconds: 10) { t in 0.01 * sin(2 * .pi * 7 * t) }
        #expect(detector.steps == 0)
    }

    @Test func ignoresASingleJolt() {
        // Picking the phone up: one sharp bump with no follow-up step.
        var detector = StepDetector()
        feed(&detector, seconds: 5) { t in (1.0..<1.1).contains(t) ? 0.5 : 0 }
        #expect(detector.steps == 0)
    }

    // MARK: - Combining the two counters

    @Test func detectorFillsInThePedometersLag() {
        #expect(StepMissionTracker.creditedSteps(pedometer: 5, detector: 12) == 12)
    }

    @Test func detectorLeadIsCapped() {
        // Waving the phone in bed: the detector sees "steps" the pedometer
        // doesn't. Only maxDetectorLead of them count.
        let credited = StepMissionTracker.creditedSteps(pedometer: 0, detector: 40)
        #expect(credited == StepMissionTracker.maxDetectorLead)
    }

    @Test func pedometerWinsWhenItsAhead() {
        #expect(StepMissionTracker.creditedSteps(pedometer: 25, detector: 20) == 25)
    }

    @Test func eitherCounterCanStandAlone() {
        #expect(StepMissionTracker.creditedSteps(pedometer: nil, detector: 40) == 40)
        #expect(StepMissionTracker.creditedSteps(pedometer: 30, detector: nil) == 30)
        #expect(StepMissionTracker.creditedSteps(pedometer: nil, detector: nil) == 0)
    }
}
