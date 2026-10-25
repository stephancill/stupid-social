import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?
    @State private var path: [HomeDestination] = []

    public init() {}

    public var body: some View {
        Group {
            if let container {
                home(container: container)
            } else {
                ProgressView()
            }
        }
        .background(refreshShortcutButton)
        .task {
            if container == nil {
                configureDependencies()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let container else { return }
            // Apron servers stream updates only while the app is in the foreground.
            guard phase == .active else {
                if phase == .background { container.apronLiveFeed.stop() }
                return
            }
            container.apronLiveFeed.start()
            Task {
                await foregroundRefreshFeedAndStories(container: container)
            }
        }
    }

    private func home(container: AppContainer) -> some View {
        NavigationStack(path: $path) {
            FeedView(
                viewModel: container.feedViewModel,
                storyViewModel: container.storyBarViewModel,
                spotifyClient: container.spotifyClient,
                settingsViewModel: container.settingsViewModel,
                apronService: container.apronService,
                onOpenSettings: { path.append(.settings) },
                onRefresh: { await refreshFeedAndStories(container: container) },
            )
            .navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .search:
                    SearchView(viewModel: container.profileSearchViewModel)
                case .settings:
                    SettingsView(
                        viewModel: container.settingsViewModel,
                        apronServersViewModel: container.apronServersViewModel,
                        onLoadDemoData: { container.loadDemoData() },
                        onClearDemoData: { container.clearDemoData() },
                    )
                }
            }
        }
    }

    private func configureDependencies() {
        let appContainer = AppContainer(modelContext: modelContext)
        container = appContainer
        appContainer.apronLiveFeed.start()

        Task {
            await foregroundRefreshFeedAndStories(container: appContainer)
        }
    }

    private func foregroundRefreshFeedAndStories(container: AppContainer) async {
        await container.settingsViewModel.refreshSyncedConnections()
        async let feedRefresh = container.feedViewModel.refreshOnForegroundActivation()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
        // Sources mark accounts invalid during refresh; reload so the Settings badge reflects it.
        container.settingsViewModel.loadStatuses()
    }

    private func refreshFeedAndStories(container: AppContainer) async {
        let feedViewModel = container.feedViewModel
        guard !feedViewModel.isRefreshing, !feedViewModel.isForegroundRefreshing else { return }
        async let feedRefresh = container.feedViewModel.refresh()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
        container.settingsViewModel.loadStatuses()
    }

    private var refreshShortcutButton: some View {
        Button {
            if let container {
                Task {
                    await refreshFeedAndStories(container: container)
                }
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("r", modifiers: .command)
        .hidden()
    }
}

enum HomeDestination: Hashable {
    case search
    case settings
}
