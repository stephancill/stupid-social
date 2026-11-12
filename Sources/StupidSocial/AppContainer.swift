import Foundation
import StupidSocialCore
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
    /// Command-line chat access on a Mac; created when first read, once Settings or launch asks for it.
    lazy var chatControlServer = ChatControlServer(chatList: chatListViewModel) { [unowned self] chat in
        try chatViewModel(for: chat)
    }

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
        chatListViewModel = ChatListViewModel(sources: { [services] in
            if DemoData.isDemoMode {
                return [ChatListSource(provider: DemoChatListProvider(), accountId: DemoData.viewerAccountId, label: "Preview")]
            }
            return [ChatListSource(provider: apronSource, accountId: nil, label: SocialNetwork.apron.displayName)] + services.chatListSources
        })
        services.chatList = chatListViewModel
        // Links to X posts draw as the post in every chat, loaded through the first signed-in X account.
        ChatKit.resolveLink = { [services] url in
            services.components.lazy.compactMap(\.xPostResolver).first?.embed(for: url)
        }

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
        AppMetrics.accounts(accountStore.accounts)
        chatListViewModel.prefetcher = { [weak self] chat in
            // X Chat keeps no snapshot (decrypting needs the account's keys), so loading it ahead would be lost.
            if case .x = chat.destination { return nil }
            return self?.unfollowedChatViewModel(for: chat)
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

    /// Live connections (Apron servers, and each account's that has one) stream updates only while the app is in
    /// the foreground.
    func startLiveFeeds() {
        apronLiveFeed.start()
        for component in services.components {
            component.liveConnection?.start()
        }
    }

    func stopLiveFeeds() {
        apronLiveFeed.stop()
        for component in services.components {
            component.liveConnection?.stop()
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
        return { AdapterChatViewModel(adapter: SpotifyChatAdapter(client: client, chatId: chatId, title: title, viewerUsername: viewer), accountId: accountId) }
    }

    /// `nil` when the Instagram account is gone.
    func instagramChatFactory(accountId: String, threadFbid: String, title: String) -> (() -> ChatViewModel)? {
        guard let client = services.component(id: accountId)?.instagramClient else { return nil }
        return { AdapterChatViewModel(adapter: InstagramChatAdapter(client: client, threadFbid: threadFbid, title: title), accountId: accountId) }
    }

    /// `nil` when the Bluesky account is gone.
    func blueskyChatFactory(accountId: String, convoId: String, title: String) -> (() -> ChatViewModel)? {
        guard let client = services.component(id: accountId)?.blueskyClient else { return nil }
        return { AdapterChatViewModel(adapter: BlueskyChatAdapter(client: client, convoId: convoId, title: title), accountId: accountId) }
    }

    /// `nil` when the Discord account is gone.
    func discordChatFactory(accountId: String, channelId: String, title: String) -> (chat: () -> ChatViewModel, profile: (String) -> DiscordProfileViewModel, dmRecipient: String?)? {
        guard let gateway = services.component(id: accountId)?.discordGateway else { return nil }
        return (
            chat: { AdapterChatViewModel(adapter: DiscordChatAdapter(gateway: gateway, channelId: channelId, title: title), accountId: accountId) },
            profile: { DiscordProfileViewModel(gateway: gateway, userId: $0) },
            dmRecipient: DiscordProfileViewModel.dmRecipient(channelId: channelId, gateway: gateway),
        )
    }

    /// `nil` when the LinkedIn account is gone.
    func linkedinChatFactory(accountId: String, conversationUrn: String, title: String) -> (() -> ChatViewModel)? {
        guard let component = services.component(id: accountId), let client = component.linkedinClient else { return nil }
        let liveFeed = component.linkedinLiveFeed
        return { AdapterChatViewModel(adapter: LinkedInChatAdapter(client: client, conversationUrn: conversationUrn, title: title, liveFeed: liveFeed), accountId: accountId) }
    }

    /// `nil` until the X Chat PIN has unlocked the account's keys.
    func xChatFactory(accountId: String, conversationId: String, title: String) -> (() -> ChatViewModel)? {
        guard let component = services.component(id: accountId), component.credentials.hasXChatKeys(),
              let client = component.xChatClient, let liveFeed = component.xChatLiveFeed
        else { return nil }
        return { AdapterChatViewModel(adapter: XChatAdapter(client: client, liveFeed: liveFeed, conversationId: conversationId, title: title), accountId: accountId) }
    }

    /// The chat and its group's member list.
    func telegramChatFactory(accountId: String, peer: TelegramPeer, title: String, userStatus: ChatPresence?, avatarURL: URL?) -> (chat: () -> ChatViewModel, members: () -> TelegramMembersViewModel)? {
        guard let client = services.component(id: accountId)?.telegramClient else { return nil }
        return (
            chat: { AdapterChatViewModel(adapter: TelegramChatAdapter(client: client, peer: peer, title: title, userStatus: userStatus, avatarURL: avatarURL), accountId: accountId) },
            members: { TelegramMembersViewModel(client: client, peer: peer) },
        )
    }

    /// A chat for the command line (`ChatControlServer`), built from the same factories the Chats screen uses.
    func chatViewModel(for chat: ChatSummary) throws -> ChatViewModel {
        guard let viewModel = unfollowedChatViewModel(for: chat) else {
            throw ChatControlError("\(chat.network.displayName) account isn't connected or is locked")
        }
        return chatListViewModel.follow(viewModel, chatId: chat.id)
    }

    /// The chat for a row, not yet reporting to its row; nil when its account isn't connected or is locked.
    private func unfollowedChatViewModel(for chat: ChatSummary) -> ChatViewModel? {
        switch chat.destination {
        case let .apron(serverURL, roomId):
            AdapterChatViewModel(
                adapter: ApronChatAdapter(service: apronService, serverURL: serverURL, roomId: roomId, title: chat.title),
                accountId: Account.apronId(serverURL: serverURL),
                draftStore: apronService.draftStore,
            )
        case let .apronDirect(serverURL, user):
            AdapterChatViewModel(
                adapter: ApronChatAdapter(service: apronService, serverURL: serverURL, directWith: user),
                accountId: Account.apronId(serverURL: serverURL),
                draftStore: apronService.draftStore,
            )
        case let .spotify(chatId):
            spotifyChatFactory(accountId: chat.accountId, chatId: chatId, title: chat.title)?()
        case let .instagram(threadFbid):
            instagramChatFactory(accountId: chat.accountId, threadFbid: threadFbid, title: chat.title)?()
        case let .telegram(peer):
            telegramChatFactory(accountId: chat.accountId, peer: peer, title: chat.title, userStatus: chat.presence, avatarURL: chat.avatarURL)?.chat()
        case let .x(conversationId):
            xChatFactory(accountId: chat.accountId, conversationId: conversationId, title: chat.title)?()
        case let .bluesky(convoId):
            blueskyChatFactory(accountId: chat.accountId, convoId: convoId, title: chat.title)?()
        case let .discord(channelId):
            discordChatFactory(accountId: chat.accountId, channelId: channelId, title: chat.title)?.chat()
        case let .linkedin(conversationUrn):
            linkedinChatFactory(accountId: chat.accountId, conversationUrn: conversationUrn, title: chat.title)?()
        case let .demo(chatId):
            AdapterChatViewModel(adapter: DemoChatAdapter(chatId: chatId), accountId: chat.accountId)
        }
    }

    func loadDemoData() {
        DemoData.enableDemoMode()
        feedViewModel.loadCachedFeed()
        storyBarViewModel.loadDemoStoryBarItems()
        Task { await chatListViewModel.load() }
    }

    /// Turns demo mode off, clears the story bar, then reloads
    /// live content so the app returns to its real state.
    func clearDemoData() {
        DemoData.disableDemoMode()
        feedViewModel.loadCachedFeed()
        storyBarViewModel.clearDemoStoryItems()
        Task {
            await chatListViewModel.load()
            try? await feedService.foregroundActivationRefresh()
            feedViewModel.loadCachedFeed()
            await storyBarViewModel.fetchStoryBarContent()
        }
    }
}
