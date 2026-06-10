import Foundation
import CoreHaptics
import AudioToolbox

/// Drives a relentless, heavy vibration while the alarm rings.
/// Uses Core Haptics where available; falls back to the classic
/// system vibration on older devices.
final class HapticEngine {
    static let shared = HapticEngine()
    private init() {}

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var fallbackTimer: Timer?

    func start() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            startFallback()
            return
        }
        do {
            engine = try CHHapticEngine()
            engine?.playsHapticsOnly = true
            // If the system stops the engine (audio interruption etc.), restart.
            engine?.resetHandler = { [weak self] in self?.restart() }
            engine?.stoppedHandler = { [weak self] _ in self?.restart() }
            try engine?.start()

            // One second of maximum-intensity buzz with a hard transient
            // "thump" at the start — looped forever.
            let thump = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                ],
                relativeTime: 0
            )
            let buzz = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                ],
                relativeTime: 0.05,
                duration: 0.95
            )
            let pattern = try CHHapticPattern(events: [thump, buzz], parameters: [])
            player = try engine?.makeAdvancedPlayer(with: pattern)
            player?.loopEnabled = true
            try player?.start(atTime: 0)
        } catch {
            startFallback()
        }
    }

    func stop() {
        try? player?.stop(atTime: 0)
        player = nil
        engine?.stop()
        engine = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func restart() {
        try? engine?.start()
        try? player?.start(atTime: 0)
    }

    private func startFallback() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        fallbackTimer?.fire()
    }
}
