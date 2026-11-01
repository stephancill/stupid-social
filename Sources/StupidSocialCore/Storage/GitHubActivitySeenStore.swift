import Foundation

public struct GitHubActivitySeenStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "githubActivitySeenTimestamps") {
        self.defaults = defaults
        self.key = key
    }

    public func isSeen(actorId: String, activityTimestamp: Date) -> Bool {
        timestamps[actorId].map { activityTimestamp.timeIntervalSince1970 <= $0 } ?? false
    }

    public func seenTimestamp(actorId: String) -> Double {
        timestamps[actorId] ?? 0
    }

    public func markSeen(actorId: String, activityTimestamp: Date) {
        var values = timestamps
        values[actorId] = max(values[actorId] ?? 0, activityTimestamp.timeIntervalSince1970)
        defaults.set(values, forKey: key)
    }

    private var timestamps: [String: Double] {
        defaults.dictionary(forKey: key)?.compactMapValues { value in
            (value as? NSNumber)?.doubleValue
        } ?? [:]
    }
}
