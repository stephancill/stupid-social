import Foundation

/// Which reactions to the user's Apron messages the user has seen, per room. Apron has no such state (§4.7), but
/// every reaction is a logged record with a `log_id`, so a reaction is seen when its `log_id` is at or below the
/// room's `seenUpTo`, or below what the user last saw on that message. Kept on this device only.
///
/// The room's own message ids are kept too: a reaction record names only its message, and the Chats list reads
/// a page of the log that often holds reactions to older messages it doesn't include.
@MainActor
public final class ApronReactionStore {
    /// Posted on the main queue after anything changes.
    public static let didChangeNotification = Notification.Name("ApronReactionStore.didChange")

    struct Room: Codable, Equatable {
        /// Reactions logged at or before this are seen.
        var seenUpTo: Int64
        /// Message id → the newest reaction seen on it, above `seenUpTo`.
        var seenOn: [String: Int64] = [:]
        /// The user's messages in the room, newest kept.
        var ownMessages: [String] = []
    }

    private let defaults: UserDefaults
    private let key = "apronReactionsSeen"
    static let seenOnLimit = 300
    static let ownMessageLimit = 1000

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Starts tracking a room at the newest log position, so the reactions already there aren't unseen.
    public func setBaselineIfNeeded(_ logId: Int64, serverURL: URL, roomId: String) {
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        guard rooms[key] == nil else { return }
        update(key) { _ in Room(seenUpTo: logId) }
    }

    public func isSeen(logId: Int64, messageId: String, serverURL: URL, roomId: String) -> Bool {
        // A room without a baseline hasn't been shown, so it has nothing unseen yet.
        guard let room = rooms[Self.key(serverURL: serverURL, roomId: roomId)] else { return true }
        return logId <= max(room.seenUpTo, room.seenOn[messageId] ?? 0)
    }

    /// Message id → the newest reaction on it the user saw. Past `seenOnLimit` messages, the oldest fold into
    /// `seenUpTo`, which can only hide reactions older than they are.
    public func markSeen(_ newest: [String: Int64], serverURL: URL, roomId: String) {
        update(Self.key(serverURL: serverURL, roomId: roomId)) { room in
            var room = room ?? Room(seenUpTo: 0)
            room.seenOn.merge(newest) { max($0, $1) }
            if room.seenOn.count > Self.seenOnLimit {
                let dropped = room.seenOn.sorted { $0.value < $1.value }.prefix(room.seenOn.count - Self.seenOnLimit)
                for (messageId, logId) in dropped {
                    room.seenOn[messageId] = nil
                    room.seenUpTo = max(room.seenUpTo, logId)
                }
            }
            room.seenOn = room.seenOn.filter { $0.value > room.seenUpTo }
            return room
        }
    }

    public func ownMessageIds(serverURL: URL, roomId: String) -> Set<String> {
        Set(rooms[Self.key(serverURL: serverURL, roomId: roomId)]?.ownMessages ?? [])
    }

    public func addOwnMessageIds(_ ids: some Sequence<String>, serverURL: URL, roomId: String) {
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        let known = Set(rooms[key]?.ownMessages ?? [])
        let new = Set(ids).subtracting(known)
        guard !new.isEmpty, rooms[key] != nil else { return }
        update(key) { room in
            guard var room else { return nil }
            // Message ids are log ids, so the numeric order is the time order.
            room.ownMessages = Array((room.ownMessages + new).sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }.suffix(Self.ownMessageLimit))
            return room
        }
    }

    public func removeServer(_ serverURL: URL) {
        let prefix = serverURL.absoluteString + "|"
        save(rooms.filter { !$0.key.hasPrefix(prefix) })
    }

    /// The user's messages with reactions from others the user hasn't seen, oldest first. `entries` is message
    /// id → user id → that user's latest set on it; a set without emoji removed them.
    public func unseenMessageIds(
        in entries: [String: [String: (logId: Int64, emojis: [String])]],
        isOwnMessage: (String) -> Bool,
        isOwnUser: (String) -> Bool,
        serverURL: URL,
        roomId: String,
    ) -> [String] {
        guard let room = rooms[Self.key(serverURL: serverURL, roomId: roomId)] else { return [] }
        return entries.compactMap { messageId, byUser -> String? in
            guard isOwnMessage(messageId) else { return nil }
            let seen = max(room.seenUpTo, room.seenOn[messageId] ?? 0)
            let unseen = byUser.contains { userId, entry in !isOwnUser(userId) && !entry.emojis.isEmpty && entry.logId > seen }
            return unseen ? messageId : nil
        }
        .sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
    }

    // MARK: Storage

    private static func key(serverURL: URL, roomId: String) -> String {
        "\(serverURL.absoluteString)|\(roomId)"
    }

    private var rooms: [String: Room] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Room].self, from: $0) } ?? [:]
    }

    private func update(_ key: String, _ change: (Room?) -> Room?) {
        var all = rooms
        let changed = change(all[key])
        guard changed != all[key] else { return }
        all[key] = changed
        save(all)
    }

    private func save(_ all: [String: Room]) {
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ApronReactionStore.didChangeNotification, object: nil)
        }
    }
}
