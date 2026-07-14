import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?
    @State private var selectedTab = MainTab.home

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
        let tabView = TabView(selection: tabSelection(container: container)) {
            FeedView(
                viewModel: container.feedViewModel,
                storyViewModel: container.storyBarViewModel,
                spotifyClient: container.spotifyClient,
                onOpenSettings: {
                    selectedTab = .settings
                },
            )
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(MainTab.home)

            SearchView(
                viewModel: container.profileSearchViewModel,
            )
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
            .tag(MainTab.search)

            NavigationStack {
                SettingsView(viewModel: container.settingsViewModel)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(MainTab.settings)
            .onDisappear {
                Task {
                    await foregroundRefreshFeedAndStories(container: container)
                }
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

    private func refreshFeedAndStories(container: AppContainer) async {
        async let feedRefresh = container.feedViewModel.refresh()
        async let storyRefresh: Void = container.storyBarViewModel.fetchStoryBarContent()
        _ = await (feedRefresh, storyRefresh)
    }

    private func tabSelection(container: AppContainer) -> Binding<MainTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if selectedTab == .home, newTab == .home {
                    Task {
                        await refreshFeedAndStories(container: container)
                    }
                }

                selectedTab = newTab
            },
        )
    }
}

private enum MainTab: Hashable {
    case home
    case search
    case settings
}
