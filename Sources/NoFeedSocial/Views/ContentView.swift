import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedViewModel: FeedViewModel?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var spotifyClient: SpotifyClient?

    public init() {}

    public var body: some View {
        Group {
            if let feedViewModel, let settingsViewModel, let spotifyClient {
                FeedView(viewModel: feedViewModel, settingsViewModel: settingsViewModel, spotifyClient: spotifyClient)
            } else {
                ProgressView()
            }
        }
        .task {
            if feedViewModel == nil || settingsViewModel == nil {
                configureDependencies()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let feedViewModel else { return }
            Task {
                await feedViewModel.refreshOnForegroundActivation()
            }
        }
    }

    private func configureDependencies() {
        let metadataStore = AccountMetadataStore()
        let keychainStore = KeychainCredentialStore()
        let farcasterClient = FarcasterClient()
        let cacheStore = NotificationCacheStore(context: modelContext)
        let watermarkStore = ICloudReadWatermarkStore()

        let instagramSource = InstagramNotificationSource(
            client: InstagramClient(credentialStore: keychainStore),
            metadataStore: metadataStore
        )

        let spotifyClientRef = SpotifyClient(credentialStore: keychainStore)

        let spotifyActivitySource = SpotifyActivitySource(
            client: spotifyClientRef,
            metadataStore: metadataStore
        )

        let sources: [any NotificationSource] = [
            XNotificationSource(
                client: XClient(credentialStore: keychainStore),
                metadataStore: metadataStore
            ),
            FarcasterNotificationSource(
                client: farcasterClient,
                metadataStore: metadataStore
            ),
            instagramSource,
            spotifyActivitySource,
            DebugNotificationSource(
                client: DebugNotificationsClient(),
                metadataStore: metadataStore
            ),
        ]

        let service = FeedService(
            sources: sources,
            cacheStore: cacheStore,
            watermarkStore: watermarkStore
        )

        let feed = FeedViewModel(feedService: service, instagramSource: instagramSource, spotifyActivitySource: spotifyActivitySource)
        feed.loadCachedFeed()
        feedViewModel = feed
        settingsViewModel = SettingsViewModel(
            keychainStore: keychainStore,
            metadataStore: metadataStore,
            farcasterClient: farcasterClient,
            cacheStore: cacheStore
        )
        spotifyClient = spotifyClientRef

        Task {
            await feed.fetchStoryBarContent()
        }
    }
}
