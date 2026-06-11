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
    private var keepAlivePlayer: AVAudioPlayer?
    private var rampTimer: Timer?
    private var usingMusic = false

    func startAlarm(song: SongChoice?, tone: AlarmTone, ramp: Bool) {
        stopKeepAlive()
        configureSession()
        let startVolume: Float = ramp ? 0.15 : 1.0
        setSystemVolume(startVolume)

        if let song, let item = mediaItem(for: song.persistentID) {
            if let assetURL = item.assetURL {
                // DRM-free track: play it ourselves through AVAudioPlayer.
                // No Now Playing session → no pause button on the lock screen.
                usingMusic = false
                tonePlayer = try? AVAudioPlayer(contentsOf: assetURL)
                tonePlayer?.numberOfLoops = -1
                tonePlayer?.volume = 1.0
                if tonePlayer?.play() != true { playBundledTone(tone) }
            } else {
                // Apple Music (DRM) track: only MPMusicPlayerController can
                // play it, and that puts a player on the lock screen. Disable
                // its remote commands and re-start playback if it's paused.
                usingMusic = true
                setRemoteCommands(enabled: false)
                musicPlayer.setQueue(with: MPMediaItemCollection(items: [item]))
                musicPlayer.repeatMode = .one
                musicPlayer.prepareToPlay()
                musicPlayer.play()
                startMusicWatchdog(fallbackTone: tone)
            }
        } else {
            usingMusic = false
            playBundledTone(tone)
        }

        if ramp { startRamp(from: startVolume) }
    }

    /// While ringing with a DRM track, re-start playback whenever it stops —
    /// the lock-screen pause button must not silence the alarm. This also
    /// covers applicationMusicPlayer failing to start from the background:
    /// if playback won't stick after a few attempts, blast the bundled tone
    /// instead (AVAudioPlayer has no lock-screen controls at all).
    private var musicWatchdog: Timer?

    private func startMusicWatchdog(fallbackTone: AlarmTone) {
        musicWatchdog?.invalidate()
        var stalledTicks = 0
        musicWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, self.usingMusic else { timer.invalidate(); return }
            if self.musicPlayer.playbackState == .playing {
                stalledTicks = 0
            } else {
                stalledTicks += 1
                self.musicPlayer.play()
                if stalledTicks >= 3 {
                    timer.invalidate()
                    self.usingMusic = false
                    self.musicPlayer.stop()
                    self.playBundledTone(fallbackTone)
                }
            }
        }
    }

    /// The alarm must not be controllable from the lock screen.
    private func setRemoteCommands(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        [center.pauseCommand, center.playCommand, center.stopCommand,
         center.togglePlayPauseCommand, center.nextTrackCommand,
         center.previousTrackCommand, center.changePlaybackPositionCommand]
            .forEach { $0.isEnabled = enabled }
    }

    // MARK: - Background keep-alive
    //
    // iOS suspends backgrounded apps, and a suspended app can't start audio
    // at alarm time. Looping a silent file (with the "audio" background
    // mode) keeps the app running so AlarmStore's fire timer can take over
    // with full-volume sound — even with the silent switch on.

    /// Begin looping silence. Uses .mixWithOthers so it never interrupts
    /// whatever the user is listening to.
    func startKeepAlive() {
        guard keepAlivePlayer?.isPlaying != true else { return }
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        keepAlivePlayer = try? AVAudioPlayer(contentsOf: url)
        keepAlivePlayer?.numberOfLoops = -1
        keepAlivePlayer?.volume = 0
        keepAlivePlayer?.play()
    }

    func stopKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    func stop() {
        rampTimer?.invalidate(); rampTimer = nil
        musicWatchdog?.invalidate(); musicWatchdog = nil
        setRemoteCommands(enabled: true)
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

    private func playBundledTone(_ tone: AlarmTone) {
        let name = (tone.fileName as NSString).deletingPathExtension
        let ext = (tone.fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: "alarm", withExtension: "caf") else {
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
    /// The view is created once — the ramp calls this every 1.5 s and
    /// building a UIKit view hierarchy each tick is wasteful.
    private lazy var volumeView = MPVolumeView(frame: .zero)

    private func setSystemVolume(_ value: Float) {
        DispatchQueue.main.async { [self] in
            guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                slider.value = value
            }
        }
    }

    // MARK: - Tone preview (editor)

    private var previewPlayer: AVAudioPlayer?

    /// Play a few seconds of a tone so the user can hear what they picked.
    func preview(_ tone: AlarmTone) {
        let name = (tone.fileName as NSString).deletingPathExtension
        let ext = (tone.fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        previewPlayer = try? AVAudioPlayer(contentsOf: url)
        previewPlayer?.play()
        let player = previewPlayer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.previewPlayer === player else { return }
            player?.stop()
            self.previewPlayer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
