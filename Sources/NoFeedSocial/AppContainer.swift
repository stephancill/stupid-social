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

    private let metadataStore: AccountMetadataStore
    private let keychainStore: KeychainCredentialStore
    private let farcasterClient: FarcasterClient
    private let cacheStore: NotificationCacheStore
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

        instagramSource = InstagramNotificationSource(
            client: InstagramClient(credentialStore: keychainStore),
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
            spotifyMessagesSource,
            apronSource,
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

        apronServersViewModel = ApronServersViewModel(service: apronService, cacheStore: cacheStore)
        apronLiveFeed = ApronLiveFeed(service: apronService, source: apronSource, cacheStore: cacheStore)
        let feedViewModel = feedViewModel
        NotificationCenter.default.addObserver(forName: ApronLiveFeed.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { feedViewModel.loadCachedFeed() }
        }

        if DemoData.shouldAutoLoad {
            loadDemoData()
        }
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
