import Foundation
import StupidChatKit

/// Chats the user archived in the app, for networks without an archive of their own (Instagram, Bluesky,
/// LinkedIn, Spotify, Discord, Apron), by Chats row id (`<account id>|<chat>`). Kept in `UserDefaults` and synced
/// across the user's devices through iCloud Key-Value storage.
///
/// Each chat keeps its latest change and when it was made, so two devices merge by taking the later change per
/// chat; an unarchive is kept as a change too (for `unarchiveRetention`), so it reaches devices that still have
/// the chat archived rather than being undone by them.
@MainActor
public final class ChatArchiveStore: ChatLocalArchive {
    /// Posted on the main queue after the archived chats change, here or on another device.
    public static let didChangeNotification = Notification.Name("ChatArchiveStore.didChange")

    struct Change: Codable, Equatable {
        var archived: Bool
        /// Seconds since 1970.
        var at: Double
    }

    /// An entry is about 80 bytes of JSON, so this many take at most about 160 KB of the 1 MB every synced
    /// setting shares.
    static let changeLimit = 2000
    static let unarchiveRetention: TimeInterval = 90 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let kvStore: NSUbiquitousKeyValueStore
    private let now: () -> Date
    private let key = "chatArchiveChanges"
    private let cloudKey = "com.stupid.chats.archive"
    private var remoteObserver: NSObjectProtocol?
    private var changes: [String: Change]

    public init(defaults: UserDefaults = .standard, kvStore: NSUbiquitousKeyValueStore = .default, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.kvStore = kvStore
        self.now = now
        changes = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Change].self, from: $0) } ?? [:]
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

    public var didChange: Notification.Name {
        Self.didChangeNotification
    }

    public func isArchived(_ chatId: String) -> Bool {
        changes[chatId]?.archived == true
    }

    public func setArchived(_ archived: Bool, chatId: String) {
        guard isArchived(chatId) != archived else { return }
        var changed = changes
        changed[chatId] = Change(archived: archived, at: now().timeIntervalSince1970)
        save(Self.pruned(changed, now: now()))
    }

    /// The later change per chat; on a tie, archived.
    static func merged(_ local: [String: Change], _ remote: [String: Change]) -> [String: Change] {
        local.merging(remote) { mine, theirs in
            if mine.at != theirs.at {
                return mine.at > theirs.at ? mine : theirs
            }
            return mine.archived ? mine : theirs
        }
    }

    /// Drops unarchives older than `unarchiveRetention`, then the oldest changes past `changeLimit`, unarchives first.
    static func pruned(_ changes: [String: Change], now: Date) -> [String: Change] {
        let cutoff = now.timeIntervalSince1970 - unarchiveRetention
        var kept = changes.filter { $0.value.archived || $0.value.at >= cutoff }
        guard kept.count > changeLimit else { return kept }
        let oldestFirst = kept.sorted { lhs, rhs in
            lhs.value.archived != rhs.value.archived ? !lhs.value.archived : lhs.value.at < rhs.value.at
        }
        for (chatId, _) in oldestFirst.prefix(kept.count - changeLimit) {
            kept[chatId] = nil
        }
        return kept
    }

    // MARK: Storage

    private func save(_ changed: [String: Change]) {
        guard changed != changes else { return }
        changes = changed
        defaults.set(try? JSONEncoder().encode(changed), forKey: key)
        saveRemote(changed)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private var remoteChanges: [String: Change] {
        kvStore.data(forKey: cloudKey).flatMap { try? JSONDecoder().decode([String: Change].self, from: $0) } ?? [:]
    }

    private func saveRemote(_ changes: [String: Change]) {
        guard changes != remoteChanges else { return }
        kvStore.set(try? JSONEncoder().encode(changes), forKey: cloudKey)
        kvStore.synchronize()
    }

    /// Takes other devices' later changes, and writes the result back so iCloud holds this device's too.
    private func mergeRemote() {
        let merged = Self.pruned(Self.merged(changes, remoteChanges), now: now())
        guard merged != changes else {
            saveRemote(changes)
            return
        }
        save(merged)
    }
}
