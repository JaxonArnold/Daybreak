import Foundation
import CoreMotion
import Combine

/// Counts live steps for the wake-up mission using the iPhone's pedometer.
///
/// CoreMotion delivers steps in coalesced batches (0 → 7 → 25) with a
/// few seconds of latency — there's no per-step callback. `steps` is a
/// smoothed count that rolls toward the real total one step at a time, so
/// the mission ring fills like it's counting every stride.
@MainActor
final class StepMissionTracker: ObservableObject {
    /// Smoothed count for the UI. Never exceeds the real count.
    @Published var steps: Int = 0
    @Published var unavailable = false

    /// Raw batched total from CoreMotion.
    private var actualSteps = 0

    private let pedometer = CMPedometer()
    private var startDate: Date?
    private var smoothTimer: Timer?

    var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    func start() {
        guard isAvailable else { unavailable = true; return }
        steps = 0
        actualSteps = 0
        startDate = .now
        pedometer.startUpdates(from: startDate!) { [weak self] data, error in
            guard let data, error == nil else {
                Task { @MainActor in self?.unavailable = true }
                return
            }
            Task { @MainActor in
                self?.actualSteps = data.numberOfSteps.intValue
            }
        }
        startSmoothing()
    }

    private func startSmoothing() {
        smoothTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.steps < self.actualSteps else { return }
                // Catch up faster when a big batch lands, so the display
                // never trails reality by more than a couple of seconds.
                let gap = self.actualSteps - self.steps
                self.steps += max(1, gap / 10)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        smoothTimer = timer
    }

    func stop() {
        pedometer.stopUpdates()
        smoothTimer?.invalidate()
        smoothTimer = nil
    }
}

