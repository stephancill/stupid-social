import Foundation
import NoFeedSocialCore
import SwiftData

@MainActor
final class AppContainer {
    let feedViewModel: FeedViewModel
    let storyBarViewModel: StoryBarViewModel
    let profileSearchViewModel: ProfileSearchViewModel
    let settingsViewModel: SettingsViewModel
    let services: AccountServices
    let apronService: ApronService
    let apronServersViewModel: ApronServersViewModel
    let apronLiveFeed: ApronLiveFeed
    let chatListViewModel: ChatListViewModel
    let telegramPushService: TelegramPushService

    private let accountStore: AccountStore
    private let keychainStore: KeychainCredentialStore
    private let cacheStore: NotificationCacheStore
    private let debugSource: DebugNotificationSource
    private let feedService: FeedService

    init(modelContext: ModelContext) {
        keychainStore = KeychainCredentialStore()
        accountStore = AccountStore(keychain: keychainStore)
        cacheStore = NotificationCacheStore(context: modelContext)
        let farcasterClient = FarcasterClient()
        services = AccountServices(store: accountStore, keychain: keychainStore, farcasterClient: farcasterClient)
        debugSource = DebugNotificationSource(client: DebugNotificationsClient(), accountStore: accountStore)

        feedService = FeedService(
            accountSources: { [services, debugSource] in
                services.components.map(\.feedSources) + [debugSource.feedSources]
            },
            cacheStore: cacheStore,
        )

        feedViewModel = FeedViewModel(feedService: feedService)
        feedViewModel.loadCachedFeed()

        storyBarViewModel = StoryBarViewModel(
            instagramSources: { [services] in services.components.compactMap(\.instagramSource) },
            spotifyActivitySources: { [services] in services.components.compactMap(\.spotifyActivitySource) },
            githubActivitySources: { [services] in services.components.compactMap(\.githubActivitySource) },
            seenSync: StorySeenSync(),
        )

        profileSearchViewModel = ProfileSearchViewModel(feedService: feedService)

        apronService = ApronService(accountStore: accountStore, keychainStore: keychainStore)
        let apronSource = ApronNotificationSource(service: apronService)
        chatListViewModel = ChatListViewModel(apronSource: apronSource, services: services)
        services.chatList = chatListViewModel

        settingsViewModel = SettingsViewModel(
            services: services,
            farcasterClient: farcasterClient,
            cacheStore: cacheStore,
            apronService: apronService,
        )

        telegramPushService = TelegramPushService(clients: { [services] in services.components.compactMap(\.telegramClient) })
        services.onTelegramChange = { [chatListViewModel, telegramPushService] in
            Task { await chatListViewModel.load() }
            // Signing in is when the app asks to show Telegram's notifications.
            Task { await telegramPushService.register(askingPermission: true) }
        }
        services.onXChatChange = { [chatListViewModel] in
            Task { await chatListViewModel.load() }
        }
        Task { [telegramPushService] in await telegramPushService.register(askingPermission: false) }
        apronServersViewModel = ApronServersViewModel(service: apronService, chatList: chatListViewModel)
        apronLiveFeed = ApronLiveFeed(service: apronService, source: apronSource, chatList: chatListViewModel)

        services.onAccountsChange = { [weak self] in
            self?.accountsDidChange()
        }

        if DemoData.shouldAutoLoad {
            loadDemoData()
        }
    }

    /// An account was added or removed, here or on another device: open its live connections and reload.
    private func accountsDidChange() {
        startLiveFeeds()
        feedViewModel.loadCachedFeed()
        Task {
            await chatListViewModel.load()
            await storyBarViewModel.fetchStoryBarContent()
        }
    }

    /// Apron servers and X Chat stream updates only while the app is in the foreground.
    func startLiveFeeds() {
        apronLiveFeed.start()
        for component in services.components {
            component.xChatLiveFeed?.start()
        }
    }

    func stopLiveFeeds() {
        apronLiveFeed.stop()
        for component in services.components {
            component.xChatLiveFeed?.stop()
        }
    }

    /// The first Spotify account's client, for saving tracks and previews; without one, a client with no
    /// credentials, which still loads previews.
    var spotifyClient: SpotifyClient {
        services.components(network: .spotify).first?.spotifyClient
            ?? SpotifyClient(credentialStore: keychainStore.scoped(to: Account.newId(network: .spotify)))
    }

    /// `nil` when the Spotify account is gone or has no username, since the chat needs the viewer's username.
    func spotifyChatFactory(accountId: String, chatId: String, title: String) -> (() -> ChatViewModel)? {
        guard let component = services.component(id: accountId), let client = component.spotifyClient,
              let viewer = component.metadata.spotifyAccount?.username
        else { return nil }
        return { SpotifyChatViewModel(client: client, chatId: chatId, title: title, viewerUsername: viewer) }
    }

    /// `nil` when the Instagram account is gone.
    func instagramChatFactory(accountId: String, threadFbid: String, title: String) -> (() -> ChatViewModel)? {
        guard let client = services.component(id: accountId)?.instagramClient else { return nil }
        return { InstagramChatViewModel(client: client, threadFbid: threadFbid, title: title) }
    }

    /// `nil` until the X Chat PIN has unlocked the account's keys.
    func xChatFactory(accountId: String, conversationId: String, title: String) -> (() -> ChatViewModel)? {
        guard let component = services.component(id: accountId), component.credentials.hasXChatKeys(),
              let client = component.xChatClient, let liveFeed = component.xChatLiveFeed
        else { return nil }
        return { XChatViewModel(client: client, liveFeed: liveFeed, conversationId: conversationId, title: title) }
    }

    func telegramChatFactory(accountId: String, peer: TelegramPeer, title: String, userStatus: TelegramMember.Status?) -> (() -> TelegramChatViewModel)? {
        guard let client = services.component(id: accountId)?.telegramClient else { return nil }
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
