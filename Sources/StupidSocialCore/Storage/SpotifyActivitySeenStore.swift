import Foundation

public struct SpotifyActivitySeenStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "spotifyActivitySeenTimestamps") {
        self.defaults = defaults
        self.key = key
    }

    public func isSeen(userURI: String, activityTimestamp: Date) -> Bool {
        seenTimestamp(for: userURI) >= activityTimestamp.timeIntervalSince1970
    }

    public func markSeen(userURI: String, activityTimestamp: Date) {
        var timestamps = seenTimestamps()
        timestamps[userURI] = max(timestamps[userURI] ?? 0, activityTimestamp.timeIntervalSince1970)
        defaults.set(timestamps, forKey: key)
    }

    private func seenTimestamp(for userURI: String) -> Double {
        seenTimestamps()[userURI] ?? 0
    }

    private func seenTimestamps() -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
