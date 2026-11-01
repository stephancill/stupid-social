import Foundation

/// The user's accounts, synced across their devices through iCloud Key-Value storage. Credentials sync
/// separately through the iCloud Keychain, keyed by account id, so an account added on one device works on
/// the others once both have synced. Telegram's sign-in stays on each device; its account syncs so other
/// devices can offer to sign in.
///
/// Each account id has one entry: the account, whether it was removed, and when it last changed. Removals
/// stay as entries so a device that hasn't heard of one can't bring the account back. Local and remote
/// dictionaries merge per account with the newer change winning, and the result is written to both.
/// Per-device state (validation status, what an Apron server reported at sign-in) stays local.
public final class AccountStore: NSObject, @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var account: Account?
        public var removed: Bool
        /// Seconds since 1970; the newer change wins a merge.
        public var changedAt: Double

        public init(account: Account?, removed: Bool, changedAt: Double) {
            self.account = account
            self.removed = removed
            self.changedAt = changedAt
        }
    }

    /// Posted on the main queue after accounts were added, changed or removed, here or on another device.
    public static let didChangeNotification = Notification.Name("AccountStore.didChange")
    /// Posted on the main queue after an account's status, or what its Apron server said, changed on this device.
    public static let statusDidChangeNotification = Notification.Name("AccountStore.statusDidChange")

    private let lock = NSRecursiveLock()
    private let defaults: UserDefaults
    private let kvStore: NSUbiquitousKeyValueStore
    private enum Key {
        static let entries = "accounts.entries"
        static let statuses = "accounts.statuses"
        static let apronInfo = "accounts.apronInfo"
        static let debugAccount = "account.debug"
        static let cloud = "com.stupid.accounts"
    }

    public init(
        defaults: UserDefaults = .standard,
        kvStore: NSUbiquitousKeyValueStore = .default,
        keychain: KeychainCredentialStore = KeychainCredentialStore(),
    ) {
        self.defaults = defaults
        self.kvStore = kvStore
        super.init()
        AccountMigration.migrateIfNeeded(store: self, defaults: defaults, keychain: keychain)
        kvStore.synchronize()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
        )
        _ = mergeRemote()
    }

    // MARK: Accounts

    /// Every account, oldest first. When two devices added the same account before syncing, the older one is
    /// listed and the newer hidden.
    public var accounts: [Account] {
        let live = entries.values.compactMap { $0.removed ? nil : $0.account }
            .sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
        var seen = Set<String>()
        return live.filter { account in
            // Apron user ids are per server, and the account id already names the server.
            guard account.network != .apron, let remoteId = account.remoteId else { return true }
            return seen.insert("\(account.network.rawValue)|\(remoteId)").inserted
        }
    }

    public func account(id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func accounts(network: SocialNetwork) -> [Account] {
        accounts.filter { $0.network == network }
    }

    /// The account already saved for this network identity, so adding it again updates it.
    public func account(network: SocialNetwork, remoteId: String) -> Account? {
        accounts.first { $0.network == network && $0.remoteId == remoteId }
    }

    /// Adds or replaces an account. Writes and notifies only when something changed.
    public func save(_ account: Account, at date: Date = Date()) {
        lock.lock()
        let current = entries[account.id]
        guard current?.account != account || current?.removed == true else {
            lock.unlock()
            return
        }
        write(account.id, Entry(account: account, removed: false, changedAt: date.timeIntervalSince1970), synced: Self.isSynced(account))
        lock.unlock()
        postChange()
    }

    /// Changes a saved account in place; does nothing for an unknown or removed account.
    public func update(id: String, _ change: (inout Account) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var account = entries[id].flatMap({ $0.removed ? nil : $0.account }) else { return }
        change(&account)
        save(account)
    }

    public func remove(id: String, at date: Date = Date()) {
        lock.lock()
        guard let current = entries[id], !current.removed else {
            lock.unlock()
            return
        }
        let synced = current.account.map(Self.isSynced) ?? true
        write(id, Entry(account: nil, removed: true, changedAt: date.timeIntervalSince1970), synced: synced)
        var statuses = statusMap
        statuses[id] = nil
        defaults.set(Self.encode(statuses), forKey: Key.statuses)
        var info = apronInfoMap
        info[id] = nil
        defaults.set(Self.encode(info), forKey: Key.apronInfo)
        lock.unlock()
        postChange()
    }

    /// A loopback Apron server, such as a local test server, means a different machine on each device, so it
    /// stays on the device that added it.
    public static func isSynced(_ account: Account) -> Bool {
        guard let host = account.serverURL?.host()?.lowercased() else { return true }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// The account's view in the per-network metadata shapes the sources use.
    public func metadata(for accountId: String) -> AccountMetadataStore {
        AccountMetadataStore(accountId: accountId, store: self)
    }

    // MARK: Per-device state

    /// The account's status on this device; `nil` before anything checked it.
    public func status(id: String) -> AccountStatusSnapshot? {
        statusMap[id]
    }

    public func setStatus(_ status: AccountStatusSnapshot, id: String) {
        lock.lock()
        var statuses = statusMap
        guard statuses[id] != status else {
            lock.unlock()
            return
        }
        statuses[id] = status
        defaults.set(Self.encode(statuses), forKey: Key.statuses)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AccountStore.statusDidChangeNotification, object: nil)
        }
    }

    /// What an Apron server said about the user at the last sign-in on this device.
    public func apronInfo(id: String) -> ApronSignInInfo? {
        apronInfoMap[id]
    }

    public func setApronInfo(_ info: ApronSignInInfo, id: String) {
        lock.lock()
        var all = apronInfoMap
        guard all[id] != info else {
            lock.unlock()
            return
        }
        all[id] = info
        defaults.set(Self.encode(all), forKey: Key.apronInfo)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AccountStore.statusDidChangeNotification, object: nil)
        }
    }

    /// The developer notifications server, which is a device setting rather than an account.
    public var debugAccount: DebugAccountMetadata? {
        get { defaults.data(forKey: Key.debugAccount).flatMap { try? JSONDecoder().decode(DebugAccountMetadata.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.debugAccount)
            } else {
                defaults.removeObject(forKey: Key.debugAccount)
            }
        }
    }

    private var statusMap: [String: AccountStatusSnapshot] {
        defaults.data(forKey: Key.statuses).flatMap { try? JSONDecoder().decode([String: AccountStatusSnapshot].self, from: $0) } ?? [:]
    }

    private var apronInfoMap: [String: ApronSignInInfo] {
        defaults.data(forKey: Key.apronInfo).flatMap { try? JSONDecoder().decode([String: ApronSignInInfo].self, from: $0) } ?? [:]
    }

    // MARK: Sync

    /// Every known account by id, including removed ones and ones that stay on this device.
    public var entries: [String: Entry] {
        Self.decode(defaults.data(forKey: Key.entries))
    }

    /// Per account, the entry that changed last. Pure for testability.
    public static func merged(_ local: [String: Entry], _ remote: [String: Entry]) -> [String: Entry] {
        local.merging(remote) { $1.changedAt > $0.changedAt ? $1 : $0 }
    }

    private func write(_ id: String, _ entry: Entry, synced: Bool) {
        var local = entries
        local[id] = entry
        defaults.set(Self.encode(local), forKey: Key.entries)
        guard synced else { return }
        var cloud = Self.merged(syncedEntries(local), Self.decode(kvStore.data(forKey: Key.cloud)))
        cloud[id] = entry
        kvStore.set(Self.encode(cloud), forKey: Key.cloud)
        kvStore.synchronize()
    }

    private func syncedEntries(_ entries: [String: Entry]) -> [String: Entry] {
        entries.filter { $0.value.account.map(Self.isSynced) ?? true }
    }

    @objc private func remoteDidChange() {
        guard mergeRemote() else { return }
        postChange()
    }

    private func mergeRemote() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let local = entries
        let remote = Self.decode(kvStore.data(forKey: Key.cloud))
        let mergedSynced = Self.merged(syncedEntries(local), remote)
        if mergedSynced != remote {
            kvStore.set(Self.encode(mergedSynced), forKey: Key.cloud)
            kvStore.synchronize()
        }
        let merged = local.merging(mergedSynced) { $1 }
        guard merged != local else { return false }
        defaults.set(Self.encode(merged), forKey: Key.entries)
        return true
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AccountStore.didChangeNotification, object: nil)
        }
    }

    private static func decode(_ data: Data?) -> [String: Entry] {
        data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }
}

/// What an Apron server reported at the last sign-in on this device.
public struct ApronSignInInfo: Codable, Equatable, Sendable {
    public var user: ApronUser?
    public var agent: String?
    public var welcome: String?
    /// The server's own `title`, `description` and `avatar` (§3.1).
    public var title: String?
    public var description: String?
    public var avatar: String?

    public init(user: ApronUser?, agent: String?, welcome: String?, title: String? = nil, description: String? = nil, avatar: String? = nil) {
        self.user = user
        self.agent = agent
        self.welcome = welcome
        self.title = title
        self.description = description
        self.avatar = avatar
    }

    public init(user: ApronUser, server: ApronServerInfo) {
        self.init(user: user, agent: server.agent, welcome: server.welcome, title: server.title, description: server.description, avatar: server.avatar)
    }
}
