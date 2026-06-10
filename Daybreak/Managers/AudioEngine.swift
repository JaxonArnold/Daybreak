import Foundation
import AVFoundation
import MediaPlayer

/// Plays the alarm sound at maximum volume.
/// - If the user picked a library song, it plays through
///   MPMusicPlayerController (works with Apple Music subscription tracks).
/// - Otherwise it loops a bundled tone through AVAudioPlayer.
/// The audio session uses `.playback`, so sound plays even with the
/// silent switch on.
final class AudioEngine {
    static let shared = AudioEngine()
    private init() {}

    private let musicPlayer = MPMusicPlayerController.applicationMusicPlayer
    private var tonePlayer: AVAudioPlayer?
    private var rampTimer: Timer?
    private var usingMusic = false

    func startAlarm(song: SongChoice?, ramp: Bool) {
        configureSession()
        let startVolume: Float = ramp ? 0.15 : 1.0
        setSystemVolume(startVolume)

        if let song, let item = mediaItem(for: song.persistentID) {
            usingMusic = true
            musicPlayer.setQueue(with: MPMediaItemCollection(items: [item]))
            musicPlayer.repeatMode = .one
            musicPlayer.prepareToPlay()
            musicPlayer.play()
        } else {
            usingMusic = false
            playBundledTone()
        }

        if ramp { startRamp(from: startVolume) }
    }

    func stop() {
        rampTimer?.invalidate(); rampTimer = nil
        if usingMusic { musicPlayer.stop() }
        tonePlayer?.stop(); tonePlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Internals

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback ignores the ring/silent switch; .duckOthers quiets anything else playing.
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func mediaItem(for persistentID: UInt64) -> MPMediaItem? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery()
        query.addFilterPredicate(predicate)
        return query.items?.first
    }

    private func playBundledTone() {
        // Ship any loud loopable file named "alarm.caf" (or .m4a/.wav — adjust below).
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf")
                ?? Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
            // Last resort: synthesize a beep via system sound loop.
            AudioServicesPlaySystemSound(1005)
            return
        }
        tonePlayer = try? AVAudioPlayer(contentsOf: url)
        tonePlayer?.numberOfLoops = -1
        tonePlayer?.volume = 1.0
        tonePlayer?.play()
    }

    /// Fade the *system* volume up to max over ~30 seconds so the alarm
    /// is loud but doesn't detonate instantly.
    private func startRamp(from start: Float) {
        var volume = start
        rampTimer?.invalidate()
        rampTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            volume = min(1.0, volume + 0.05)
            self?.setSystemVolume(volume)
            if volume >= 1.0 { timer.invalidate() }
        }
    }

    /// Sets the hardware output volume via MPVolumeView's slider.
    /// This is the approach widely used by shipping alarm apps; there is
    /// no public direct API for output volume.
    private func setSystemVolume(_ value: Float) {
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: .zero)
            guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                slider.value = value
            }
        }
    }
}
