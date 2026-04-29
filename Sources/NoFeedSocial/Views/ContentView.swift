import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var feedViewModel: FeedViewModel?
    @State private var settingsViewModel: SettingsViewModel?

    public init() {}

    public var body: some View {
        TabView {
            if let feedViewModel {
                FeedView(viewModel: feedViewModel)
                    .tabItem { Label("Feed", systemImage: "bell") }
            } else {
                ProgressView()
                    .tabItem { Label("Feed", systemImage: "bell") }
            }

            if let settingsViewModel {
                SettingsView(viewModel: settingsViewModel)
                    .tabItem { Label("Settings", systemImage: "gear") }
            } else {
                ProgressView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
        .task {
            if feedViewModel == nil || settingsViewModel == nil {
                configureDependencies()
            }
        }
    }

    private func configureDependencies() {
        let metadataStore = AccountMetadataStore()
        let keychainStore = KeychainCredentialStore()
        let farcasterClient = FarcasterClient()
        let cacheStore = NotificationCacheStore(context: modelContext)
        let watermarkStore = ICloudReadWatermarkStore()

        let sources: [any NotificationSource] = [
            XNotificationSource(
                client: XClient(credentialStore: keychainStore),
                metadataStore: metadataStore
            ),
            FarcasterNotificationSource(
                client: farcasterClient,
                metadataStore: metadataStore
            ),
        ]

        let service = FeedService(
            sources: sources,
            cacheStore: cacheStore,
            watermarkStore: watermarkStore
        )

        let feed = FeedViewModel(feedService: service)
        feed.loadCachedFeed()
        feedViewModel = feed
        settingsViewModel = SettingsViewModel(
            keychainStore: keychainStore,
            metadataStore: metadataStore,
            farcasterClient: farcasterClient
        )
    }
}
