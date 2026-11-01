import Foundation

/// One connected account. Accounts sync across the user's devices through iCloud (`AccountStore`); their
/// credentials sync through the iCloud Keychain under the account's id (`KeychainCredentialStore.scoped(to:)`).
public struct Account: Codable, Hashable, Identifiable, Sendable {
    /// Stable for the account's life and the same on every device. New accounts get
    /// `<network>-<uuid>`; accounts from before multi-account support keep their network's name ("x",
    /// "instagram"…), which is where their credentials already are. Apron's is `apron.<server URL>`.
    public let id: String
    public let network: SocialNetwork
    /// The network's own id for the account (X user id, Instagram pk, Bluesky DID, Farcaster fid, GitHub or
    /// Spotify username, Telegram user id, Apron user id), so adding the same account twice updates it.
    public var remoteId: String?
    /// Username without "@".
    public var handle: String?
    public var displayName: String?
    public var avatarURL: URL?
    /// The Apron server this account signs in to.
    public var serverURL: URL?
    public var addedAt: Date
    public var preferences: AccountPreferences

    public init(
        id: String,
        network: SocialNetwork,
        remoteId: String? = nil,
        handle: String? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        serverURL: URL? = nil,
        addedAt: Date = Date(),
        preferences: AccountPreferences = AccountPreferences(),
    ) {
        self.id = id
        self.network = network
        self.remoteId = remoteId
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.serverURL = serverURL
        self.addedAt = addedAt
        self.preferences = preferences
    }

    public static func newId(network: SocialNetwork) -> String {
        "\(network.rawValue)-\(UUID().uuidString.lowercased())"
    }

    public static func apronId(serverURL: URL) -> String {
        "apron.\(serverURL.absoluteString)"
    }

    /// "@handle", the display name, or the Apron server's host.
    public var label: String? {
        if network == .apron {
            return serverURL.map { $0.host() ?? $0.absoluteString }
        }
        if let handle, !handle.isEmpty {
            return "@\(handle)"
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return nil
    }
}

/// Per-account settings. Optional category sets mean every category, so new categories start enabled.
public struct AccountPreferences: Codable, Hashable, Sendable {
    public var xCategories: Set<XNotificationCategory>?
    public var farcasterCategories: Set<FarcasterNotificationCategory>?
    public var instagramCategories: Set<InstagramNotificationCategory>?
    public var instagramStoriesEnabled: Bool?
    public var instagramDirectMediaSharesEnabled: Bool?
    /// The display name asked for when signing in to an Apron server.
    public var apronRequestedName: String?

    public init(
        xCategories: Set<XNotificationCategory>? = nil,
        farcasterCategories: Set<FarcasterNotificationCategory>? = nil,
        instagramCategories: Set<InstagramNotificationCategory>? = nil,
        instagramStoriesEnabled: Bool? = nil,
        instagramDirectMediaSharesEnabled: Bool? = nil,
        apronRequestedName: String? = nil,
    ) {
        self.xCategories = xCategories
        self.farcasterCategories = farcasterCategories
        self.instagramCategories = instagramCategories
        self.instagramStoriesEnabled = instagramStoriesEnabled
        self.instagramDirectMediaSharesEnabled = instagramDirectMediaSharesEnabled
        self.apronRequestedName = apronRequestedName
    }
}

public extension SocialNetwork {
    /// Networks the user can add accounts for, in the order Add Account lists them.
    static let addable: [SocialNetwork] = [.x, .farcaster, .instagram, .bluesky, .spotify, .github, .telegram, .apron]
}

public extension NotificationItem {
    /// The item as one account's: ids are prefixed with the account id so two accounts on one network
    /// seeing the same event keep separate rows.
    func scoped(to accountId: String) -> NotificationItem {
        NotificationItem(
            id: "\(accountId)|\(id)",
            network: network,
            accountId: accountId,
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: target,
            parentTarget: parentTarget,
            unreadCount: unreadCount,
        )
    }
}
