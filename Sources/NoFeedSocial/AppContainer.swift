import NoFeedSocialCore
import SwiftData

@MainActor
final class AppContainer {
    let feedViewModel: FeedViewModel
    let storyBarViewModel: StoryBarViewModel
    let profileSearchViewModel: ProfileSearchViewModel
    let settingsViewModel: SettingsViewModel
    let spotifyClient: SpotifyClient

    private let metadataStore: AccountMetadataStore
    private let keychainStore: KeychainCredentialStore
    private let farcasterClient: FarcasterClient
    private let cacheStore: NotificationCacheStore
    private let watermarkStore: ICloudReadWatermarkStore
    private let instagramSource: InstagramNotificationSource
    private let spotifyActivitySource: SpotifyActivitySource
    private let notificationSources: [any NotificationFetching]
    private let accountValidators: [any AccountValidating]
    private let profileFetchersByNetwork: [SocialNetwork: any ProfileFetching]
    private let targetDetailFetchersByNetwork: [SocialNetwork: any NotificationTargetDetailFetching]
    private let feedService: FeedService

    init(modelContext: ModelContext) {
        metadataStore = AccountMetadataStore()
        keychainStore = KeychainCredentialStore()
        farcasterClient = FarcasterClient()
        cacheStore = NotificationCacheStore(context: modelContext)
        watermarkStore = ICloudReadWatermarkStore()

        instagramSource = InstagramNotificationSource(
            client: InstagramClient(credentialStore: keychainStore),
            metadataStore: metadataStore,
        )

        spotifyClient = SpotifyClient(credentialStore: keychainStore)

        spotifyActivitySource = SpotifyActivitySource(
            client: spotifyClient,
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

        notificationSources = [
            xSource,
            farcasterSource,
            instagramSource,
            debugSource,
        ]
        accountValidators = [
            xSource,
            farcasterSource,
            instagramSource,
            spotifyActivitySource,
            debugSource,
        ]
        profileFetchersByNetwork = [
            .x: xSource,
            .farcaster: farcasterSource,
            .instagram: instagramSource,
            .spotify: spotifyActivitySource,
        ]
        targetDetailFetchersByNetwork = [
            .x: xSource,
            .farcaster: farcasterSource,
            .instagram: instagramSource,
        ]

        feedService = FeedService(
            notificationSources: notificationSources,
            accountValidators: accountValidators,
            profileFetchersByNetwork: profileFetchersByNetwork,
            targetDetailFetchersByNetwork: targetDetailFetchersByNetwork,
            cacheStore: cacheStore,
            watermarkStore: watermarkStore,
        )

        feedViewModel = FeedViewModel(feedService: feedService)
        feedViewModel.loadCachedFeed()

        storyBarViewModel = StoryBarViewModel(
            instagramSource: instagramSource,
            spotifyActivitySource: spotifyActivitySource,
        )

        profileSearchViewModel = ProfileSearchViewModel(feedService: feedService)

        settingsViewModel = SettingsViewModel(
            keychainStore: keychainStore,
            metadataStore: metadataStore,
            farcasterClient: farcasterClient,
            cacheStore: cacheStore,
        )
    }
}
