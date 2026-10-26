import Foundation

/// Syncs the list of saved Apron servers across the user's devices through iCloud Key-Value storage. Tokens
/// already sync through the iCloud Keychain, so a server added on one device signs in with the same identity
/// on the others.
///
/// Each server URL has one entry: its requested name, whether it was removed, and when it last changed.
/// Removals stay as entries so a device that hasn't heard of one can't bring the server back. Local and
/// remote dictionaries merge per server with the newer change winning, and the result is written to both.
public final class ApronServerSync: NSObject {
    public struct Entry: Codable, Equatable, Sendable {
        public var requestedName: String?
        public var removed: Bool
        /// Seconds since 1970; the newer change wins a merge.
        public var changedAt: Double

        public init(requestedName: String?, removed: Bool, changedAt: Double) {
            self.requestedName = requestedName
            self.removed = removed
            self.changedAt = changedAt
        }
    }

    /// Posted on the main queue after another device's changes merged in.
    public static let didChangeNotification = Notification.Name("ApronServerSync.didChange")

    private let defaults: UserDefaults
    private let kvStore: NSUbiquitousKeyValueStore
    private let localKey = "apronServerSync"
    private let cloudKey = "com.stupid.apron.servers"

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

    /// Every known server, keyed by URL, including removed ones.
    public var entries: [String: Entry] {
        Self.decode(defaults.data(forKey: localKey)).filter { URL(string: $0.key).map(Self.isSynced) ?? false }
    }

    /// A loopback server, such as a local test server, means a different machine on each device, so it stays
    /// on the device that added it.
    public static func isSynced(_ serverURL: URL) -> Bool {
        !["localhost", "127.0.0.1", "::1"].contains(serverURL.host()?.lowercased() ?? "")
    }

    public func recordAdded(_ serverURL: URL, requestedName: String?, at date: Date = Date()) {
        guard Self.isSynced(serverURL) else { return }
        update(serverURL, Entry(requestedName: requestedName, removed: false, changedAt: date.timeIntervalSince1970))
    }

    public func recordRemoved(_ serverURL: URL, at date: Date = Date()) {
        guard Self.isSynced(serverURL) else { return }
        update(serverURL, Entry(requestedName: nil, removed: true, changedAt: date.timeIntervalSince1970))
    }

    /// Per server, the entry that changed last. Pure for testability.
    public static func merged(_ local: [String: Entry], _ remote: [String: Entry]) -> [String: Entry] {
        local.merging(remote) { $1.changedAt > $0.changedAt ? $1 : $0 }
    }

    private func update(_ serverURL: URL, _ entry: Entry) {
        var all = Self.merged(entries, Self.decode(kvStore.data(forKey: cloudKey)).filter { URL(string: $0.key).map(Self.isSynced) ?? false })
        all[serverURL.absoluteString] = entry
        save(all)
    }

    @objc private func remoteDidChange() {
        guard mergeRemote() else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ApronServerSync.didChangeNotification, object: nil)
        }
    }

    private func mergeRemote() -> Bool {
        let local = entries
        let remote = Self.decode(kvStore.data(forKey: cloudKey)).filter { URL(string: $0.key).map(Self.isSynced) ?? false }
        let merged = Self.merged(local, remote)
        if merged != remote {
            kvStore.set(Self.encode(merged), forKey: cloudKey)
            kvStore.synchronize()
        }
        guard merged != local else { return false }
        defaults.set(Self.encode(merged), forKey: localKey)
        return true
    }

    private func save(_ all: [String: Entry]) {
        let data = Self.encode(all)
        defaults.set(data, forKey: localKey)
        kvStore.set(data, forKey: cloudKey)
        kvStore.synchronize()
    }

    private static func decode(_ data: Data?) -> [String: Entry] {
        data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func encode(_ entries: [String: Entry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }
}
