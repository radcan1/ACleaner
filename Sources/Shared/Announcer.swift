import AppKit

/// Central VoiceOver announcement helper. Replaces the three near-identical
/// private `announce()` implementations that existed in AppState, UpdateEngine,
/// and RootView.
enum Announcer {
    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }

    // MARK: - Throttled progress announcements
    //
    // Long scans update their status text many times a second. Announcing
    // every update would spam VoiceOver; announcing nothing leaves the user
    // in silence until the scan ends. `announceThrottled` allows at most one
    // announcement per `minInterval` seconds per `key`, so a scan loop can
    // call it freely at every status update.
    @MainActor private static var lastAnnounced: [String: Date] = [:]

    @MainActor
    static func announceThrottled(
        _ message: String,
        key: String,
        minInterval: TimeInterval = 4,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        let now = Date()
        if let last = lastAnnounced[key], now.timeIntervalSince(last) < minInterval { return }
        lastAnnounced[key] = now
        announce(message, priority: priority)
    }
}
