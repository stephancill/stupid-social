import Foundation

/// One account's clients and sources, built from its scoped credentials and metadata.
@MainActor
public final class AccountComponents {
    public let accountId: String
    public let network: SocialNetwork
    public let metadata: AccountMetadataStore
    public let credentials: KeychainCredentialStore

    public private(set) var notificationSource: (any NotificationFetching)?
    public private(set) var validators: [any AccountValidating] = []
    public private(set) var profileFetcher: (any ProfileFetching)?
    public private(set) var targetDetailFetcher: (any NotificationTargetDetailFetching)?
    public private(set) var relationshipMutator: (any RelationshipMutating)?

    public private(set) var xClient: XClient?
    public private(set) var xChatClient: XChatClient?
    public private(set) var xChatUnlock: XChatUnlockViewModel?
    public private(set) var xChatLiveFeed: XChatLiveFeed?
    public private(set) var instagramClient: InstagramClient?
    public private(set) var instagramSource: InstagramNotificationSource?
    public private(set) var spotifyClient: SpotifyClient?
    public private(set) var spotifyActivitySource: SpotifyActivitySource?
    public private(set) var spotifyMessagesSource: SpotifyMessagesSource?
    public private(set) var githubActivitySource: GitHubActivitySource?
    public private(set) var blueskyClient: BlueskyClient?
    public private(set) var telegramClient: TelegramClient?
    public private(set) var telegramConnection: TelegramConnectionViewModel?

    init(account: Account, store: AccountStore, keychain: KeychainCredentialStore, farcasterClient: FarcasterClient, chatList: ChatListViewModel?, onTelegramChange: (() -> Void)?, onXChatChange: (() -> Void)?) {
        accountId = account.id
        network = account.network
        metadata = store.metadata(for: account.id)
        credentials = keychain.scoped(to: account.id)

        switch account.network {
        case .x:
            let client = XClient(credentialStore: credentials)
            let source = XNotificationSource(client: client, metadataStore: metadata)
            xClient = client
            notificationSource = source
            validators = [source]
            profileFetcher = source
            targetDetailFetcher = source
            relationshipMutator = source
            let chatClient = XChatClient(credentialStore: credentials)
            xChatClient = chatClient
            let unlock = XChatUnlockViewModel(client: chatClient, keychainStore: credentials)
            if let chatList {
                let liveFeed = XChatLiveFeed(client: chatClient, accountId: account.id, chatList: chatList, keychainStore: credentials)
                xChatLiveFeed = liveFeed
                unlock.onChange = {
                    onXChatChange?()
                    // Unlocking opens the socket; without keys it stays closed.
                    liveFeed.stop()
                    liveFeed.start()
                }
            }
            xChatUnlock = unlock
        case .farcaster:
            let source = FarcasterNotificationSource(client: farcasterClient, metadataStore: metadata)
            notificationSource = source
            validators = [source]
            profileFetcher = source
            targetDetailFetcher = source
        case .instagram:
            let client = InstagramClient(credentialStore: credentials)
            let source = InstagramNotificationSource(client: client, metadataStore: metadata)
            instagramClient = client
            instagramSource = source
            notificationSource = source
            validators = [source]
            profileFetcher = source
            targetDetailFetcher = source
            relationshipMutator = source
        case .spotify:
            let client = SpotifyClient(credentialStore: credentials)
            let activity = SpotifyActivitySource(client: client, metadataStore: metadata)
            spotifyClient = client
            spotifyActivitySource = activity
            spotifyMessagesSource = SpotifyMessagesSource(client: client, metadataStore: metadata)
            validators = [activity]
            profileFetcher = activity
        case .bluesky:
            let client = BlueskyClient(credentialStore: credentials)
            let source = BlueskyNotificationSource(client: client, metadataStore: metadata)
            blueskyClient = client
            notificationSource = source
            validators = [source]
            profileFetcher = source
            targetDetailFetcher = source
        case .github:
            // Both read the same For You page; the loader fetches and parses it once per refresh.
            let loader = GitHubForYouFeedLoader()
            let activity = GitHubActivitySource(feedLoader: loader, credentialStore: credentials, metadataStore: metadata)
            let source = GitHubNotificationSource(client: GitHubClient(), feedLoader: loader, credentialStore: credentials, metadataStore: metadata)
            githubActivitySource = activity
            notificationSource = source
            validators = [activity, source]
            profileFetcher = source
            targetDetailFetcher = source
        case .telegram:
            let client = TelegramClient(keychain: credentials)
            let connection = TelegramConnectionViewModel(client: client)
            let accountId = account.id
            // Signing in again on this device, such as for an account added on another one.
            connection.onSignIn = { telegram in
                store.update(id: accountId) {
                    $0.remoteId = String(telegram.userId)
                    $0.handle = telegram.username
                    $0.displayName = telegram.name
                }
                store.setStatus(.valid, id: accountId)
            }
            connection.onChange = onTelegramChange
            telegramClient = client
            telegramConnection = connection
        case .apron, .debug:
            break
        }
    }

    public var feedSources: FeedAccountSources {
        FeedAccountSources(
            accountId: accountId,
            network: network,
            notifications: notificationSource,
            validators: validators,
            profiles: profileFetcher,
            targetDetails: targetDetailFetcher,
            relationships: relationshipMutator,
        )
    }

    /// Stops what runs in the background, when the account goes away.
    func shutDown() {
        xChatLiveFeed?.stop()
    }
}

/// Every account's components, rebuilt as accounts are added and removed. An account's components live as
/// long as the account, so stateful clients (Telegram sessions, X Chat keys, live sockets) are kept.
@MainActor
public final class AccountServices: ObservableObject {
    @Published public private(set) var components: [AccountComponents] = []
    public let store: AccountStore
    public let keychain: KeychainCredentialStore
    private let farcasterClient: FarcasterClient
    /// Set once the Chats list exists, so X accounts get a live feed into it.
    public weak var chatList: ChatListViewModel? {
        didSet { rebuild(force: true) }
    }

    /// Called after accounts were added or removed, such as to reload the feed and chats.
    public var onAccountsChange: (() -> Void)?
    /// Called after a Telegram account signed in or out on this device.
    public var onTelegramChange: (() -> Void)?
    /// Called after an X account's chats were unlocked or locked.
    public var onXChatChange: (() -> Void)?

    private func build(_ account: Account) -> AccountComponents {
        AccountComponents(
            account: account,
            store: store,
            keychain: keychain,
            farcasterClient: farcasterClient,
            chatList: chatList,
            onTelegramChange: { [weak self] in self?.onTelegramChange?() },
            onXChatChange: { [weak self] in self?.onXChatChange?() },
        )
    }

    public init(store: AccountStore, keychain: KeychainCredentialStore, farcasterClient: FarcasterClient = FarcasterClient()) {
        self.store = store
        self.keychain = keychain
        self.farcasterClient = farcasterClient
        rebuild(force: false)
        NotificationCenter.default.addObserver(forName: AccountStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild(force: false)
            }
        }
    }

    public func component(id: String) -> AccountComponents? {
        components.first { $0.accountId == id }
    }

    public func components(network: SocialNetwork) -> [AccountComponents] {
        components.filter { $0.network == network }
    }

    /// The account's components, built now when the account was saved a moment ago and the store's change
    /// notification hasn't arrived yet.
    public func components(for account: Account) -> AccountComponents {
        if let existing = component(id: account.id) {
            return existing
        }
        let built = build(account)
        components.append(built)
        return built
    }

    private func rebuild(force: Bool) {
        let accounts = store.accounts
        let existing = Dictionary(components.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        var rebuilt: [AccountComponents] = []
        for account in accounts {
            if let kept = existing[account.id], !(force && kept.network == .x && kept.xChatLiveFeed == nil) {
                rebuilt.append(kept)
            } else {
                existing[account.id]?.shutDown()
                rebuilt.append(build(account))
            }
        }
        let ids = Set(accounts.map(\.id))
        for removed in components where !ids.contains(removed.accountId) {
            removed.shutDown()
        }
        let changed = rebuilt.map(\.accountId) != components.map(\.accountId)
        components = rebuilt
        TelegramFileURLProtocol.register(clients: rebuilt.compactMap(\.telegramClient))
        if changed {
            onAccountsChange?()
        }
    }
}
