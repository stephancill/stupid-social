import Foundation

/// Which reactions to the user's Apron messages the user has seen. Apron has no such state (§4.7), but every
/// reaction is a logged record with a `log_id`, so a reaction is seen when its `log_id` is at or below its room's
/// baseline (the room's newest log position when it was first shown here) or what the user last saw on that
/// message.
///
/// Only reactions to the user's newest `messageLimit` messages, across every room, can be unseen, so what the
/// user saw is at most one mark per such message. Those marks sync to the user's other devices through iCloud
/// Key-Value storage; they only move forward, so devices merge them with a `max`. Baselines and the list of the
/// user's messages are kept on each device: a reaction record names only its message, and the Chats list reads a
/// page of the log that often holds reactions to older messages it doesn't include.
@MainActor
public final class ApronReactionStore {
    /// Posted on the main queue after anything changes.
    public static let didChangeNotification = Notification.Name("ApronReactionStore.didChange")
    /// Posted on the main queue for each room whose seen reactions another device moved, with `serverURL` (URL)
    /// and `roomId` (String) in `userInfo`.
    public static let remoteDidChangeNotification = Notification.Name("ApronReactionStore.remoteDidChange")

    struct State: Codable, Equatable {
        /// Room key → reactions logged at or before this are seen.
        var baselines: [String: Int64] = [:]
        /// The user's newest messages in tracked rooms, as message keys, oldest first.
        var ownMessages: [String] = []
        /// Message key → the newest reaction on it the user saw.
        var seen: [String: Int64] = [:]
    }

    /// A mark in iCloud is about 70 bytes of JSON (`"<server>|<room>|<message>":<log id>`), so 1000 take at most
    /// about 70 KB of the 1 MB every synced setting shares.
    static let messageLimit = 1000
    /// Reactions older than this are never unseen, however long the user stayed away.
    static let unseenWindow: TimeInterval = 3 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let kvStore: NSUbiquitousKeyValueStore
    private let key = "apronReactionState"
    private let cloudKey = "com.stupid.apron.reactionmarks"
    private var remoteObserver: NSObjectProtocol?
    /// Read once: every chat refresh and Chats row reads it, and it holds thousands of entries.
    private var cachedState: State?

    public init(defaults: UserDefaults = .standard, kvStore: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.kvStore = kvStore
        kvStore.synchronize()
        remoteObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeRemote() }
        }
        mergeRemote()
    }

    /// Starts tracking a room at the newest log position, so the reactions already there aren't unseen.
    public func setBaselineIfNeeded(_ logId: Int64, serverURL: URL, roomId: String) {
        let room = Self.roomKey(serverURL: serverURL, roomId: roomId)
        guard state.baselines[room] == nil else { return }
        update { $0.baselines[room] = logId }
    }

    /// Message id → the newest reaction on it the user saw.
    public func markSeen(_ newest: [String: Int64], serverURL: URL, roomId: String) {
        let room = Self.roomKey(serverURL: serverURL, roomId: roomId)
        update { state in
            state.seen.merge(newest.map { (Self.messageKey(room: room, messageId: $0.key), $0.value) }) { max($0, $1) }
            state.seen = Self.newest(state.seen)
        }
    }

    /// The room's messages among the user's newest `messageLimit`.
    public func ownMessageIds(serverURL: URL, roomId: String) -> Set<String> {
        let prefix = Self.roomKey(serverURL: serverURL, roomId: roomId) + "|"
        return Set(state.ownMessages.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// Only for rooms with a baseline, which are the ones shown here.
    public func addOwnMessageIds(_ ids: some Sequence<String>, serverURL: URL, roomId: String) {
        let room = Self.roomKey(serverURL: serverURL, roomId: roomId)
        let current = state
        guard current.baselines[room] != nil else { return }
        let new = Set(ids.map { Self.messageKey(room: room, messageId: $0) }).subtracting(current.ownMessages)
        guard !new.isEmpty else { return }
        update { state in
            state.ownMessages = Array((state.ownMessages + new).sorted { Self.order($0) < Self.order($1) }.suffix(Self.messageLimit))
        }
    }

    public func removeServer(_ serverURL: URL) {
        let prefix = serverURL.absoluteString + "|"
        update { state in
            state.baselines = state.baselines.filter { !$0.key.hasPrefix(prefix) }
            state.ownMessages.removeAll { $0.hasPrefix(prefix) }
            state.seen = state.seen.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    /// The user's messages, among their newest `messageLimit`, with reactions from others in the last
    /// `unseenWindow` the user hasn't seen, oldest first. `entries` is message id → user id → that user's latest set on it; a set without emoji
    /// removed them.
    public func unseenMessageIds(
        in entries: [String: [String: (logId: Int64, emojis: [String])]],
        isOwnMessage: (String) -> Bool,
        isOwnUser: (String) -> Bool,
        serverURL: URL,
        roomId: String,
        now: Date = Date(),
    ) -> [String] {
        let room = Self.roomKey(serverURL: serverURL, roomId: roomId)
        let state = state
        // A room without a baseline hasn't been shown, so it has nothing unseen yet.
        guard let baseline = state.baselines[room] else { return [] }
        // `log_id`s are Unix milliseconds (§2.1).
        let since = Int64((now.timeIntervalSince1970 - Self.unseenWindow) * 1000)
        let eligible = ownMessageIds(serverURL: serverURL, roomId: roomId)
        return entries.compactMap { messageId, byUser -> String? in
            guard eligible.contains(messageId), isOwnMessage(messageId) else { return nil }
            let seen = max(baseline, since, state.seen[Self.messageKey(room: room, messageId: messageId)] ?? 0)
            let unseen = byUser.contains { userId, entry in !isOwnUser(userId) && !entry.emojis.isEmpty && entry.logId > seen }
            return unseen ? messageId : nil
        }
        .sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
    }

    // MARK: Keys

    private static func roomKey(serverURL: URL, roomId: String) -> String {
        "\(serverURL.absoluteString)|\(roomId)"
    }

    /// Message ids have no `|`, so the room is everything before the last one.
    private static func messageKey(room: String, messageId: String) -> String {
        "\(room)|\(messageId)"
    }

    private static func room(ofMessageKey key: String) -> String {
        key.lastIndex(of: "|").map { String(key[..<$0]) } ?? key
    }

    /// Message ids are log ids, Unix milliseconds on every server (§2.1), so they order messages in time across
    /// servers.
    private static func order(_ messageKey: String) -> Int64 {
        messageKey.split(separator: "|").last.flatMap { Int64($0) } ?? 0
    }

    /// The marks on the newest `messageLimit` messages. Marks are only made on the user's messages, so these
    /// cover every message that can still have unseen reactions.
    private static func newest(_ seen: [String: Int64]) -> [String: Int64] {
        guard seen.count > messageLimit else { return seen }
        return Dictionary(uniqueKeysWithValues: seen.sorted { order($0.key) > order($1.key) }.prefix(messageLimit).map { ($0.key, $0.value) })
    }

    // MARK: Storage

    private var state: State {
        if let cachedState {
            return cachedState
        }
        let loaded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        cachedState = loaded
        return loaded
    }

    private func update(_ change: (inout State) -> Void) {
        let current = state
        var changed = current
        change(&changed)
        guard changed != current else { return }
        save(changed)
    }

    private func save(_ state: State) {
        cachedState = state
        defaults.set(try? JSONEncoder().encode(state), forKey: key)
        saveRemote(state.seen)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ApronReactionStore.didChangeNotification, object: nil)
        }
    }

    // MARK: iCloud

    private var remoteSeen: [String: Int64] {
        kvStore.data(forKey: cloudKey).flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]
    }

    private func saveRemote(_ seen: [String: Int64]) {
        guard seen != remoteSeen else { return }
        kvStore.set(try? JSONEncoder().encode(seen), forKey: cloudKey)
        kvStore.synchronize()
    }

    /// Merges what other devices saw, and writes the result back so iCloud holds this device's marks too.
    private func mergeRemote() {
        var state = state
        let local = state.seen
        state.seen = Self.newest(local.merging(remoteSeen) { max($0, $1) })
        guard state.seen != local else {
            saveRemote(local)
            return
        }
        save(state)
        let rooms = Set(state.seen.filter { local[$0.key] != $0.value }.keys.map(Self.room(ofMessageKey:)))
        for room in rooms {
            guard let separator = room.firstIndex(of: "|"), let serverURL = URL(string: String(room[..<separator])) else { continue }
            let roomId = String(room[room.index(after: separator)...])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: ApronReactionStore.remoteDidChangeNotification, object: nil, userInfo: ["serverURL": serverURL, "roomId": roomId])
            }
        }
    }
}
