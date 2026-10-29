import Foundation

public struct XAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var handle: String?
    public var status: AccountStatusSnapshot
    public var enabledCategories: Set<XNotificationCategory>

    public init(accountId: String, handle: String?, status: AccountStatusSnapshot, enabledCategories: Set<XNotificationCategory>? = nil) {
        self.accountId = accountId
        self.handle = handle
        self.status = status
        self.enabledCategories = enabledCategories ?? Set(XNotificationCategory.allCases)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
        status = try container.decode(AccountStatusSnapshot.self, forKey: .status)
        enabledCategories = try container.decodeIfPresent(Set<XNotificationCategory>.self, forKey: .enabledCategories) ?? Set(XNotificationCategory.allCases)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encodeIfPresent(handle, forKey: .handle)
        try container.encode(status, forKey: .status)
        try container.encode(enabledCategories, forKey: .enabledCategories)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case handle
        case status
        case enabledCategories
    }
}

public struct FarcasterAccountMetadata: Codable, Equatable {
    public var username: String
    public var fid: UInt64
    public var status: AccountStatusSnapshot
    public var enabledCategories: Set<FarcasterNotificationCategory>

    public init(username: String, fid: UInt64, status: AccountStatusSnapshot, enabledCategories: Set<FarcasterNotificationCategory>? = nil) {
        self.username = username
        self.fid = fid
        self.status = status
        self.enabledCategories = enabledCategories ?? Set(FarcasterNotificationCategory.allCases)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        fid = try container.decode(UInt64.self, forKey: .fid)
        status = try container.decode(AccountStatusSnapshot.self, forKey: .status)
        enabledCategories = try container.decodeIfPresent(Set<FarcasterNotificationCategory>.self, forKey: .enabledCategories) ?? Set(FarcasterNotificationCategory.allCases)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(fid, forKey: .fid)
        try container.encode(status, forKey: .status)
        try container.encode(enabledCategories, forKey: .enabledCategories)
    }

    private enum CodingKeys: String, CodingKey {
        case username
        case fid
        case status
        case enabledCategories
    }
}

public struct InstagramAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var username: String?
    public var avatarURL: URL?
    public var status: AccountStatusSnapshot
    public var enabledCategories: Set<InstagramNotificationCategory>
    public var storiesEnabled: Bool
    public var directMediaSharesEnabled: Bool

    public init(accountId: String, username: String?, avatarURL: URL? = nil, status: AccountStatusSnapshot, enabledCategories: Set<InstagramNotificationCategory>? = nil, storiesEnabled: Bool = true, directMediaSharesEnabled: Bool = true) {
        self.accountId = accountId
        self.username = username
        self.avatarURL = avatarURL
        self.status = status
        self.enabledCategories = enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        self.storiesEnabled = storiesEnabled
        self.directMediaSharesEnabled = directMediaSharesEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        status = try container.decode(AccountStatusSnapshot.self, forKey: .status)
        enabledCategories = try container.decodeIfPresent(Set<InstagramNotificationCategory>.self, forKey: .enabledCategories) ?? Set(InstagramNotificationCategory.allCases)
        storiesEnabled = try container.decodeIfPresent(Bool.self, forKey: .storiesEnabled) ?? true
        directMediaSharesEnabled = try container.decodeIfPresent(Bool.self, forKey: .directMediaSharesEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encode(status, forKey: .status)
        try container.encode(enabledCategories, forKey: .enabledCategories)
        try container.encode(storiesEnabled, forKey: .storiesEnabled)
        try container.encode(directMediaSharesEnabled, forKey: .directMediaSharesEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case username
        case avatarURL
        case status
        case enabledCategories
        case storiesEnabled
        case directMediaSharesEnabled
    }
}

public struct DebugAccountMetadata: Codable, Equatable {
    public var serverURL: URL
    public var status: AccountStatusSnapshot

    public init(serverURL: URL, status: AccountStatusSnapshot) {
        self.serverURL = serverURL
        self.status = status
    }
}

public struct ApronServerMetadata: Codable, Equatable, Identifiable {
    public var serverURL: URL
    /// Display name requested on sign-in; the server may assign something else.
    public var requestedName: String?
    public var user: ApronUser?
    public var agent: String?
    public var welcome: String?
    public var title: String?
    public var description: String?
    public var avatar: String?
    public var status: AccountStatusSnapshot

    public var id: String {
        serverURL.absoluteString
    }

    /// The server's `title`, or its host without one (§3.1).
    public var displayTitle: String {
        ApronServerInfo.displayTitle(title, serverURL: serverURL)
    }

    public var avatarURL: URL? {
        ApronUser.avatarURL(avatar)
    }

    public init(serverURL: URL, requestedName: String?, info: ApronSignInInfo?, status: AccountStatusSnapshot) {
        self.serverURL = serverURL
        self.requestedName = requestedName
        user = info?.user
        agent = info?.agent
        welcome = info?.welcome
        title = info?.title
        description = info?.description
        avatar = info?.avatar
        self.status = status
    }
}

public struct SpotifyAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var username: String?
    public var status: AccountStatusSnapshot

    public init(accountId: String, username: String?, status: AccountStatusSnapshot) {
        self.accountId = accountId
        self.username = username
        self.status = status
    }
}

public struct BlueskyAccountMetadata: Codable, Equatable {
    public var did: String
    public var handle: String?
    public var status: AccountStatusSnapshot

    public init(did: String, handle: String?, status: AccountStatusSnapshot) {
        self.did = did
        self.handle = handle
        self.status = status
    }
}

public struct GitHubAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var username: String?
    public var status: AccountStatusSnapshot

    public init(accountId: String, username: String?, status: AccountStatusSnapshot) {
        self.accountId = accountId
        self.username = username
        self.status = status
    }
}

public enum AccountStatusSnapshot: String, Codable, Equatable, Sendable {
    case notConfigured
    case valid
    case invalidCredentials
    case iCloudUnavailable
    case networkUnavailable
    case serviceError
}

/// One account's metadata in the per-network shapes the sources read and write. Reads come from the
/// `AccountStore`; writes change the synced account (handle, avatar, preferences) and the status on this
/// device. Writing `nil` does nothing: accounts are removed through the store.
public final class AccountMetadataStore: @unchecked Sendable {
    public let accountId: String
    private let store: AccountStore

    init(accountId: String, store: AccountStore) {
        self.accountId = accountId
        self.store = store
    }

    public var account: Account? {
        store.account(id: accountId)
    }

    public var status: AccountStatusSnapshot {
        get { store.status(id: accountId) ?? .valid }
        set { store.setStatus(newValue, id: accountId) }
    }

    private func account(_ network: SocialNetwork) -> Account? {
        account.flatMap { $0.network == network ? $0 : nil }
    }

    public var xAccount: XAccountMetadata? {
        get {
            account(.x).map {
                XAccountMetadata(accountId: $0.remoteId ?? $0.id, handle: $0.handle, status: status, enabledCategories: $0.preferences.xCategories)
            }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                $0.handle = newValue.handle ?? $0.handle
                $0.preferences.xCategories = newValue.enabledCategories
            }
            status = newValue.status
        }
    }

    public var farcasterAccount: FarcasterAccountMetadata? {
        get {
            account(.farcaster).flatMap { account in
                guard let fid = account.remoteId.flatMap(UInt64.init) else { return nil }
                return FarcasterAccountMetadata(username: account.handle ?? "", fid: fid, status: status, enabledCategories: account.preferences.farcasterCategories)
            }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                $0.handle = newValue.username
                $0.remoteId = String(newValue.fid)
                $0.preferences.farcasterCategories = newValue.enabledCategories
            }
            status = newValue.status
        }
    }

    public var instagramAccount: InstagramAccountMetadata? {
        get {
            account(.instagram).map {
                InstagramAccountMetadata(
                    accountId: $0.remoteId ?? $0.id,
                    username: $0.handle,
                    avatarURL: $0.avatarURL,
                    status: status,
                    enabledCategories: $0.preferences.instagramCategories,
                    storiesEnabled: $0.preferences.instagramStoriesEnabled ?? true,
                    directMediaSharesEnabled: $0.preferences.instagramDirectMediaSharesEnabled ?? true,
                )
            }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                if newValue.accountId != $0.id {
                    $0.remoteId = newValue.accountId
                }
                $0.handle = newValue.username ?? $0.handle
                $0.avatarURL = newValue.avatarURL ?? $0.avatarURL
                $0.preferences.instagramCategories = newValue.enabledCategories
                $0.preferences.instagramStoriesEnabled = newValue.storiesEnabled
                $0.preferences.instagramDirectMediaSharesEnabled = newValue.directMediaSharesEnabled
            }
            status = newValue.status
        }
    }

    public var spotifyAccount: SpotifyAccountMetadata? {
        get {
            account(.spotify).map { SpotifyAccountMetadata(accountId: $0.id, username: $0.handle, status: status) }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                if let username = newValue.username {
                    $0.handle = username
                    $0.remoteId = username
                }
            }
            status = newValue.status
        }
    }

    public var blueskyAccount: BlueskyAccountMetadata? {
        get {
            account(.bluesky).map { BlueskyAccountMetadata(did: $0.remoteId ?? "", handle: $0.handle, status: status) }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                if !newValue.did.isEmpty {
                    $0.remoteId = newValue.did
                }
                $0.handle = newValue.handle ?? $0.handle
            }
            status = newValue.status
        }
    }

    public var githubAccount: GitHubAccountMetadata? {
        get {
            account(.github).map { GitHubAccountMetadata(accountId: $0.id, username: $0.handle, status: status) }
        }
        set {
            guard let newValue else { return }
            store.update(id: accountId) {
                if let username = newValue.username {
                    $0.handle = username
                    $0.remoteId = username
                }
            }
            status = newValue.status
        }
    }
}

/// Where accounts were kept before multi-account support: one per network in UserDefaults. Read once by
/// `AccountMigration`.
struct LegacyAccountMetadata {
    enum Key {
        static let xAccount = "account.x"
        static let farcasterAccount = "account.farcaster"
        static let instagramAccount = "account.instagram"
        static let spotifyAccount = "account.spotify"
        static let blueskyAccount = "account.bluesky"
        static let githubAccount = "account.github"
        static let apronServers = "account.apron.servers"
        static let xFollowsMigrated = "account.x.followsMigrated"
        static let all = [xAccount, farcasterAccount, instagramAccount, spotifyAccount, blueskyAccount, githubAccount, apronServers, xFollowsMigrated]
    }

    let defaults: UserDefaults

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func removeAll() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}
