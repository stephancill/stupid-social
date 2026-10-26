import Foundation

/// Read cursors for Apron rooms: how far the user has read each room, as a `message_id` (§4.6).
///
/// Servers that keep read cursors for a stable identity are the source of truth; their cursors are cached
/// here as they arrive. Otherwise (guests, servers without cursors) the cursor is kept on the device and
/// synced through iCloud Key-Value storage. Cursors only move forward, so local and remote dictionaries
/// merge with a per-key `max`, like `StorySeenSync`.
public final class ApronReadStore: NSObject {
    /// Posted on the main queue after any cursor changes, locally or from another device.
    public static let didChangeNotification = Notification.Name("ApronReadStore.didChange")

    private let defaults: UserDefaults
    private let kvStore: NSUbiquitousKeyValueStore
    private let localKey = "apronReadCursors"
    private let cloudKey = "com.stupid.apron.readcursors"
    private let serverKey = "apronServerReadCursors"
    private let ownUsersKey = "apronOwnUserIds"
    private let ownUsersCloudKey = "com.stupid.apron.ownusers"

    public init(defaults: UserDefaults = .standard, kvStore: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.kvStore = kvStore
        super.init()
        kvStore.synchronize()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
        )
        _ = mergeRemote()
    }

    /// The server's cursor when it keeps one, otherwise the device/iCloud cursor.
    public func cursor(serverURL: URL, roomId: String) -> Int64? {
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        return serverCursors[key] ?? localCursors[key]
    }

    /// Records the server's cursor as the truth for this room, even when it is behind the local one.
    public func setServerCursor(_ messageId: Int64, serverURL: URL, roomId: String) {
        var cursors = serverCursors
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        guard cursors[key] != messageId else { return }
        cursors[key] = messageId
        defaults.set(cursors.mapValues(NSNumber.init(value:)), forKey: serverKey)
        postChange()
    }

    /// Advances the cursor; it never moves back (§4.6). `serverTracksCursors` keeps it with the server's cache.
    public func markRead(_ messageId: Int64, serverURL: URL, roomId: String, serverTracksCursors: Bool) {
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        if serverTracksCursors {
            guard (serverCursors[key] ?? 0) < messageId else { return }
            setServerCursor(messageId, serverURL: serverURL, roomId: roomId)
            return
        }
        var cursors = localCursors
        guard (cursors[key] ?? 0) < messageId else { return }
        cursors[key] = messageId
        saveLocal(cursors)
        postChange()
    }

    /// Starts tracking a room the user has never read at its latest message, so joining doesn't flood it as unread.
    public func setBaselineIfNeeded(_ messageId: Int64, serverURL: URL, roomId: String) {
        guard cursor(serverURL: serverURL, roomId: roomId) == nil else { return }
        markRead(messageId, serverURL: serverURL, roomId: roomId, serverTracksCursors: false)
    }

    /// Every `user_id` the user has had on a server. Guests get a new one per connection, and their own
    /// earlier messages should never count as unread.
    public func ownUserIds(serverURL: URL) -> Set<String> {
        Set((defaults.dictionary(forKey: ownUsersKey)?[serverURL.absoluteString] as? [String]) ?? [])
    }

    /// Synced through iCloud, so messages sent from the user's other devices count as their own there too.
    public func addOwnUserId(_ userId: String, serverURL: URL) {
        var all = ownUsers
        var ids = all[serverURL.absoluteString] ?? []
        guard ids.insert(userId).inserted else { return }
        all[serverURL.absoluteString] = ids
        saveOwnUsers(all)
    }

    public func removeServer(_ serverURL: URL) {
        let prefix = serverURL.absoluteString + "|"
        saveLocal(localCursors.filter { !$0.key.hasPrefix(prefix) })
        defaults.set(serverCursors.filter { !$0.key.hasPrefix(prefix) }.mapValues(NSNumber.init(value:)), forKey: serverKey)
        var all = ownUsers
        all[serverURL.absoluteString] = nil
        saveOwnUsers(all)
        postChange()
    }

    // MARK: Storage

    private static func key(serverURL: URL, roomId: String) -> String {
        "\(serverURL.absoluteString)|\(roomId)"
    }

    private var ownUsers: [String: Set<String>] {
        Self.decodeOwnUsers(defaults.dictionary(forKey: ownUsersKey))
    }

    private static func decodeOwnUsers(_ dictionary: [String: Any]?) -> [String: Set<String>] {
        (dictionary ?? [:]).compactMapValues { ($0 as? [String]).map(Set.init) }
    }

    private func saveOwnUsers(_ all: [String: Set<String>]) {
        let plist = all.mapValues { Array($0).sorted() }
        defaults.set(plist, forKey: ownUsersKey)
        kvStore.set(plist, forKey: ownUsersCloudKey)
        kvStore.synchronize()
    }

    private var localCursors: [String: Int64] {
        Self.decode(defaults.dictionary(forKey: localKey))
    }

    private var serverCursors: [String: Int64] {
        Self.decode(defaults.dictionary(forKey: serverKey))
    }

    private static func decode(_ dictionary: [String: Any]?) -> [String: Int64] {
        (dictionary ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    private func saveLocal(_ cursors: [String: Int64]) {
        let plist = cursors.mapValues(NSNumber.init(value:))
        defaults.set(plist, forKey: localKey)
        kvStore.set(plist, forKey: cloudKey)
        kvStore.synchronize()
    }

    @objc private func remoteDidChange() {
        if mergeRemote() {
            postChange()
        }
    }

    /// Merges iCloud cursors into local storage with a per-room `max`, and own user IDs as a union, and writes
    /// the results back.
    private func mergeRemote() -> Bool {
        var changed = false
        let local = localCursors
        let merged = local.merging(Self.decode(kvStore.dictionary(forKey: cloudKey))) { max($0, $1) }
        if merged != local {
            saveLocal(merged)
            changed = true
        }
        let localUsers = ownUsers
        let remoteUsers = Self.decodeOwnUsers(kvStore.dictionary(forKey: ownUsersCloudKey))
        let mergedUsers = localUsers.merging(remoteUsers) { $0.union($1) }
        if mergedUsers != localUsers || mergedUsers != remoteUsers {
            saveOwnUsers(mergedUsers)
            changed = changed || mergedUsers != localUsers
        }
        return changed
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ApronReadStore.didChangeNotification, object: nil)
        }
    }
}
