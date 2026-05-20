import AppKit

// Three distinct system sounds — one per lifecycle event.
// All respect System Preferences volume and mute.
enum SoundPlayer {

    // App detected in Trash — attention-getting, like an incoming alert
    static func playDetected() {
        guard let s = NSSound(named: "Ping") else { return }
        s.volume = 1.5
        s.play()
    }

    // Scan finished — softer, "results are ready"
    static func playScanComplete() {
        guard let s = NSSound(named: "Pop") else { return }
        s.volume = 1.5
        s.play()
    }

    // Cleanup done — prominent success chime
    static func playCleanupComplete() {
        guard let s = NSSound(named: "Glass") else { return }
        s.volume = 1.5
        s.play()
    }
}
