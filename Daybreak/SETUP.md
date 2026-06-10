// Daybreak setup

// This project needs a couple of one-time steps in Xcode for the best alarm experience.

// 1) Add the custom alarm sound

// 1. Drag your loud, loop-friendly sound file named `alarm.caf` into the project navigator (any group is fine). If you only have `.m4a` or `.wav`, rename it to `alarm.caf` or adjust code/sound name accordingly.
// 2. In the add dialog, check "Copy items if needed" and ensure your app target is selected under "Add to targets".
// 3. Confirm the file appears under Build Phases > Copy Bundle Resources for your app target.

// The app uses this file in two places:
// - Notification sound: `AlarmStore` schedules notifications with `UNNotificationSound(named: "alarm.caf")`.
// - In-app ringing: `AudioEngine` loads `alarm.caf` from the bundle and loops it via `AVAudioPlayer` when no library song is chosen.

// Note: iOS notification sounds must be ≤ 30 seconds.

// 2) Info.plist privacy strings

// Add the following keys to your app's Info.plist with friendly messages:
// - Privacy - Motion Usage Description (`NSMotionUsageDescription`): "Daybreak uses motion data to count your steps for wake-up missions."
// - Privacy - Media Library Usage Description (`NSAppleMusicUsageDescription`): "Daybreak accesses your music library so you can pick a wake-up song."

// No explicit key is required for notifications, but the app will request permission on first run.

// 3) Capabilities

// - Background Modes are not required for notifications; the app uses a notification chain to wake you.
// - Ensure Audio, AirPlay, and Picture in Picture capability is enabled if you want to be explicit about audio playback in background (optional for this design since notifications handle the wake-up).

// 4) Testing checklist

// - Launch the app and complete onboarding to grant permissions.
// - Create a one-time alarm a few minutes ahead and lock the device. You should receive a series of notifications every 30 seconds.
// - Tap a notification — the app should take over with the ringing screen.
// - Try snooze; then verify the one-shot snooze notification fires at the expected time.
// - Test both built-in tone and a library song.
