import Foundation
import NoFeedSocialCore
import SwiftData

@MainActor
final class AppContainer {
    let feedViewModel: FeedViewModel
    let storyBarViewModel: StoryBarViewModel
    let profileSearchViewModel: ProfileSearchViewModel
    let settingsViewModel: SettingsViewModel
    let spotifyClient: SpotifyClient
    let apronService: ApronService
    let apronServersViewModel: ApronServersViewModel
    let apronLiveFeed: ApronLiveFeed
    let chatListViewModel: ChatListViewModel
    let telegramClient: TelegramClient
    let telegramConnectionViewModel: TelegramConnectionViewModel
    let telegramPushService: TelegramPushService
    let xChatClient: XChatClient
    let xChatUnlockViewModel: XChatUnlockViewModel
    let xChatLiveFeed: XChatLiveFeed

    private let metadataStore: AccountMetadataStore
    private let keychainStore: KeychainCredentialStore
    private let farcasterClient: FarcasterClient
    private let cacheStore: NotificationCacheStore
    private let instagramClient: InstagramClient
    private let instagramSource: InstagramNotificationSource
    private let spotifyActivitySource: SpotifyActivitySource
    private let githubActivitySource: GitHubActivitySource
    private let githubNotificationSource: GitHubNotificationSource
    private let notificationSources: [any NotificationFetching]
    private let accountValidators: [any AccountValidating]
    private let profileFetchersByNetwork: [SocialNetwork: any ProfileFetching]
    private let targetDetailFetchersByNetwork: [SocialNetwork: any NotificationTargetDetailFetching]
    private let relationshipMutatorsByNetwork: [SocialNetwork: any RelationshipMutating]
    private let feedService: FeedService

    init(modelContext: ModelContext) {
        metadataStore = AccountMetadataStore()
        keychainStore = KeychainCredentialStore()
        farcasterClient = FarcasterClient()
        cacheStore = NotificationCacheStore(context: modelContext)

        instagramClient = InstagramClient(credentialStore: keychainStore)
        instagramSource = InstagramNotificationSource(
            client: instagramClient,
            metadataStore: metadataStore,
        )

        spotifyClient = SpotifyClient(credentialStore: keychainStore)

        spotifyActivitySource = SpotifyActivitySource(
            client: spotifyClient,
            metadataStore: metadataStore,
        )
        let spotifyMessagesSource = SpotifyMessagesSource(
            client: spotifyClient,
            metadataStore: metadataStore,
        )
        // Both read the same For You page; the loader fetches and parses it once per refresh.
        let githubFeedLoader = GitHubForYouFeedLoader()
        githubActivitySource = GitHubActivitySource(
            feedLoader: githubFeedLoader,
            credentialStore: keychainStore,
            metadataStore: metadataStore,
        )
        githubNotificationSource = GitHubNotificationSource(
            client: GitHubClient(),
            feedLoader: githubFeedLoader,
            credentialStore: keychainStore,
            metadataStore: metadataStore,
        )

        let xSource = XNotificationSource(
            client: XClient(credentialStore: keychainStore),
            metadataStore: metadataStore,
        )
        let farcasterSource = FarcasterNotificationSource(
            client: farcasterClient,
            metadataStore: metadataStore,
        )
        let debugSource = DebugNotificationSource(
            client: DebugNotificationsClient(),
            metadataStore: metadataStore,
        )
        apronService = ApronService(metadataStore: metadataStore, keychainStore: keychainStore)
        let apronSource = ApronNotificationSource(service: apronService)
        let blueskySource = BlueskyNotificationSource(
            client: BlueskyClient(credentialStore: keychainStore),
            metadataStore: metadataStore,
        )

        notificationSources = [
            xSource,
            farcasterSource,
            instagramSource,
            blueskySource,
            githubNotificationSource,
            debugSource,
        ]
        accountValidators = [
            xSource,
            farcasterSource,
            instagramSource,
            spotifyActivitySource,
            blueskySource,
            githubActivitySource,
            githubNotificationSource,
            apronSource,
            debugSource,
        ]
        profileFetchersByNetwork = [
            .x: xSource,
            .farcaster: farcasterSource,
            .instagram: instagramSource,
            .spotify: spotifyActivitySource,
            .bluesky: blueskySource,
            .github: githubNotificationSource,
        ]
        targetDetailFetchersByNetwork = [
            .x: xSource,
            .farcaster: farcasterSource,
            .instagram: instagramSource,
            .bluesky: blueskySource,
            .github: githubNotificationSource,
        ]
        relationshipMutatorsByNetwork = [
            .x: xSource,
            .instagram: instagramSource,
        ]

        feedService = FeedService(
            notificationSources: notificationSources,
            accountValidators: accountValidators,
            profileFetchersByNetwork: profileFetchersByNetwork,
            targetDetailFetchersByNetwork: targetDetailFetchersByNetwork,
            relationshipMutatorsByNetwork: relationshipMutatorsByNetwork,
            cacheStore: cacheStore,
        )

        feedViewModel = FeedViewModel(feedService: feedService)
        feedViewModel.loadCachedFeed()

        storyBarViewModel = StoryBarViewModel(
            instagramSource: instagramSource,
            spotifyActivitySource: spotifyActivitySource,
            githubActivitySource: githubActivitySource,
            seenSync: StorySeenSync(),
        )

        profileSearchViewModel = ProfileSearchViewModel(feedService: feedService)

        settingsViewModel = SettingsViewModel(
            keychainStore: keychainStore,
            metadataStore: metadataStore,
            farcasterClient: farcasterClient,
            cacheStore: cacheStore,
        )

        telegramClient = TelegramClient()
        TelegramFileURLProtocol.register(client: telegramClient)
        xChatClient = XChatClient()
        chatListViewModel = ChatListViewModel(apronSource: apronSource, spotifySource: spotifyMessagesSource, instagramClient: instagramClient, telegramClient: telegramClient, xChatClient: xChatClient)
        xChatUnlockViewModel = XChatUnlockViewModel(client: xChatClient, keychainStore: keychainStore)
        xChatLiveFeed = XChatLiveFeed(client: xChatClient, chatList: chatListViewModel, keychainStore: keychainStore)
        xChatUnlockViewModel.onChange = { [chatListViewModel, xChatLiveFeed] in
            Task { await chatListViewModel.load() }
            // Unlocking opens the socket; without keys it stays closed.
            xChatLiveFeed.stop()
            xChatLiveFeed.start()
        }
        telegramConnectionViewModel = TelegramConnectionViewModel(client: telegramClient)
        telegramPushService = TelegramPushService(client: telegramClient)
        telegramConnectionViewModel.onChange = { [chatListViewModel, telegramPushService] in
            Task { await chatListViewModel.load() }
            // Signing in is when the app asks to show Telegram's notifications.
            Task { await telegramPushService.register(askingPermission: true) }
        }
        Task { [telegramPushService] in await telegramPushService.register(askingPermission: false) }
        apronServersViewModel = ApronServersViewModel(service: apronService, chatList: chatListViewModel)
        apronLiveFeed = ApronLiveFeed(service: apronService, source: apronSource, chatList: chatListViewModel)

        if DemoData.shouldAutoLoad {
            loadDemoData()
        }
    }

    /// `nil` when Spotify isn't connected, since the chat needs the viewer's username.
    func spotifyChatFactory(chatId: String, title: String) -> (() -> ChatViewModel)? {
        guard let viewer = metadataStore.spotifyAccount?.username else { return nil }
        let client = spotifyClient
        return { SpotifyChatViewModel(client: client, chatId: chatId, title: title, viewerUsername: viewer) }
    }

    /// `nil` when Instagram isn't connected.
    func instagramChatFactory(threadFbid: String, title: String) -> (() -> ChatViewModel)? {
        guard (try? keychainStore.loadInstagramCredentials()) != nil else { return nil }
        let client = instagramClient
        return { InstagramChatViewModel(client: client, threadFbid: threadFbid, title: title) }
    }

    /// `nil` until the XChat PIN has unlocked the account's keys.
    func xChatFactory(conversationId: String, title: String) -> (() -> ChatViewModel)? {
        guard keychainStore.hasXChatKeys() else { return nil }
        let client = xChatClient, liveFeed = xChatLiveFeed
        return { XChatViewModel(client: client, liveFeed: liveFeed, conversationId: conversationId, title: title) }
    }

    func telegramChatFactory(peer: TelegramPeer, title: String, userStatus: TelegramMember.Status?) -> () -> TelegramChatViewModel {
        let client = telegramClient
        return { TelegramChatViewModel(client: client, peer: peer, title: title, userStatus: userStatus) }
    }

    func loadDemoData() {
        DemoData.enableDemoMode()
        feedViewModel.loadCachedFeed()
        storyBarViewModel.loadDemoStoryBarItems()
    }

    /// Turns demo mode off, clears the story bar, then reloads
    /// live content so the app returns to its real state.
    func clearDemoData() {
        DemoData.disableDemoMode()
        feedViewModel.loadCachedFeed()
        storyBarViewModel.clearDemoStoryItems()
        Task {
            try? await feedService.foregroundActivationRefresh()
            feedViewModel.loadCachedFeed()
            await storyBarViewModel.fetchStoryBarContent()
        }
    }
}
