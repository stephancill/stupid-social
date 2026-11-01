import Foundation

/// Coordinates Spotify/GitHub story "seen" timestamps across the user's Apple
/// devices using iCloud Key-Value storage (`NSUbiquitousKeyValueStore`).
///
/// Seen timestamps per actor are monotonic (they only ever advance), so it is
/// safe to merge local and remote dictionaries with a per-actor `max` at both
/// ends and write the merged result back to both ends. That makes the otherwise
/// last-writer-wins iCloud KV sync converge even when two devices briefly push
/// stale dictionaries.
///
/// Local `UserDefaults` stays the fast read path so the story bar renders
/// instantly and the feature degrades gracefully (local-only) when iCloud is
/// not configured. The same dictionaries are also written to
/// `NSUbiquitousKeyValueStore`; remote changes are observed, merged into local
/// storage, and surfaced via `didChangeNotification`.
public final class StorySeenSync: NSObject {
    /// Posted (on the main queue) after a remote iCloud change merged new seen
    /// timestamps into the local stores. Observers should re-derive display
    /// state from the seen stores.
    public static let didChangeNotification = Notification.Name("StorySeenSync.didChange")

    private let kvStore: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let spotifyLocalKey: String
    private let githubLocalKey: String
    private let spotifyCloudKey: String
    private let githubCloudKey: String

    public init(
        defaults: UserDefaults = .standard,
        kvStore: NSUbiquitousKeyValueStore = .default,
        spotifyLocalKey: String = "spotifyActivitySeenTimestamps",
        githubLocalKey: String = "githubActivitySeenTimestamps",
        spotifyCloudKey: String = "com.stupid.storyseen.spotify",
        githubCloudKey: String = "com.stupid.storyseen.github",
    ) {
        self.defaults = defaults
        self.kvStore = kvStore
        self.spotifyLocalKey = spotifyLocalKey
        self.githubLocalKey = githubLocalKey
        self.spotifyCloudKey = spotifyCloudKey
        self.githubCloudKey = githubCloudKey
        super.init()

        kvStore.synchronize()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
        )
        // Bootstrap any previous remote state before the UI first reads it.
        _ = mergeRemote(kvKey: spotifyCloudKey, localKey: spotifyLocalKey)
        _ = mergeRemote(kvKey: githubCloudKey, localKey: githubLocalKey)
    }

    /// Mirrors the current local Spotify seen dictionary into iCloud.
    public func pushSpotifySeen() {
        push(localKey: spotifyLocalKey, cloudKey: spotifyCloudKey)
    }

    /// Mirrors the current local GitHub seen dictionary into iCloud.
    public func pushGitHubSeen() {
        push(localKey: githubLocalKey, cloudKey: githubCloudKey)
    }

    /// The element-wise `max` merge used to converge local and remote seen
    /// timestamps. Pure and dependency-free for testability.
    public static func merged(_ local: [String: Double], _ remote: [String: Double]) -> [String: Double] {
        local.merging(remote) { max($0, $1) }
    }

    private func push(localKey: String, cloudKey: String) {
        let dict = defaults.dictionary(forKey: localKey) as? [String: Double] ?? [:]
        kvStore.set(dict, forKey: cloudKey)
        kvStore.synchronize()
    }

    @objc private func remoteDidChange(_: Notification) {
        let didChange = mergeRemote(kvKey: spotifyCloudKey, localKey: spotifyLocalKey)
            || mergeRemote(kvKey: githubCloudKey, localKey: githubLocalKey)
        guard didChange else { return }
        NotificationCenter.default.post(name: StorySeenSync.didChangeNotification, object: self)
    }

    /// Merges the remote dictionary into local defaults (and back to iCloud) so
    /// non-local seen timestamps win. Returns whether anything changed.
    private func mergeRemote(kvKey: String, localKey: String) -> Bool {
        let local = defaults.dictionary(forKey: localKey) as? [String: Double] ?? [:]
        let remote = kvStore.dictionary(forKey: kvKey) as? [String: Double] ?? [:]
        let merged = StorySeenSync.merged(local, remote)
        guard merged != local else { return false }
        defaults.set(merged, forKey: localKey)
        kvStore.set(merged, forKey: kvKey)
        kvStore.synchronize()
        return true
    }
}
