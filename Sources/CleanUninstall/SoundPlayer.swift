import AppKit

// Three distinct system sounds — one per lifecycle event.
// All respect System Preferences volume and mute.
enum SoundPlayer {

    // App detected in Trash — attention-getting, like an incoming alert
    static func playDetected() {
        NSSound(named: "Ping")?.play()
    }

    // Scan finished — softer, "results are ready"
    static func playScanComplete() {
        NSSound(named: "Pop")?.play()
    }

    // Cleanup done — prominent success chime
    static func playCleanupComplete() {
        NSSound(named: "Glass")?.play()
    }
}
