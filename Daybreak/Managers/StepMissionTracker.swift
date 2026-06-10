import Foundation
import CoreMotion
import Combine

/// Counts live steps for the wake-up mission using the iPhone's pedometer.
@MainActor
final class StepMissionTracker: ObservableObject {
    @Published var steps: Int = 0
    @Published var unavailable = false

    private let pedometer = CMPedometer()
    private var startDate: Date?

    var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    func start() {
        guard isAvailable else { unavailable = true; return }
        steps = 0
        startDate = .now
        pedometer.startUpdates(from: startDate!) { [weak self] data, error in
            guard let data, error == nil else {
                Task { @MainActor in self?.unavailable = true }
                return
            }
            Task { @MainActor in
                self?.steps = data.numberOfSteps.intValue
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }
}

