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
            guard phase == .active, let container else { return }
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
                settingsNeedsAttention: container.settingsViewModel.hasInvalidCredentials,
            )
            .navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .search:
                    SearchView(viewModel: container.profileSearchViewModel)
                case .settings:
                    SettingsView(
                        viewModel: container.settingsViewModel,
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

        Task {
            await foregroundRefreshFeedAndStories(container: appContainer)
        }
    }

    private func foregroundRefreshFeedAndStories(container: AppContainer) async {
        await container.settingsViewModel.refreshSyncedConnections()
        async let feedRefresh = container.feedViewModel.refreshOnForegroundActivation()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
    }

    private func refreshFeedAndStories(container: AppContainer) async {
        async let feedRefresh = container.feedViewModel.refresh()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
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
