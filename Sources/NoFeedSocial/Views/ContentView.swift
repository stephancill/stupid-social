import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?

    public init() {}

    public var body: some View {
        Group {
            if let container {
                tabs(container: container)
            } else {
                ProgressView()
            }
        }
        .task {
            if container == nil {
                configureDependencies()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let container else { return }
            Task {
                async let feedRefresh = container.feedViewModel.refreshOnForegroundActivation()
                async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
                _ = await (feedRefresh, storyRefresh)
            }
        }
    }

    @ViewBuilder
    private func tabs(container: AppContainer) -> some View {
        let tabView = TabView {
            FeedView(
                viewModel: container.feedViewModel,
                storyViewModel: container.storyBarViewModel,
                settingsViewModel: container.settingsViewModel,
                spotifyClient: container.spotifyClient,
            )
            .tabItem {
                Label("Home", systemImage: "house")
            }

            SearchView(
                viewModel: container.profileSearchViewModel,
                settingsViewModel: container.settingsViewModel,
                onSettingsDisappear: {
                    Task {
                        await foregroundRefreshFeedAndStories(container: container)
                    }
                },
            )
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
        }

        #if os(iOS)
            if #available(iOS 26.0, *) {
                tabView.tabBarMinimizeBehavior(.onScrollDown)
            } else {
                tabView
            }
        #else
            tabView
        #endif
    }

    private func configureDependencies() {
        let appContainer = AppContainer(modelContext: modelContext)
        container = appContainer

        Task {
            await foregroundRefreshFeedAndStories(container: appContainer)
        }
    }

    private func foregroundRefreshFeedAndStories(container: AppContainer) async {
        async let feedRefresh = container.feedViewModel.refreshOnForegroundActivation()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
    }
}
