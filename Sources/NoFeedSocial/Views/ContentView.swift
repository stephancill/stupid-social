import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                await foregroundRefreshFeedAndStories(container: container)
            }
        }
    }

    @ViewBuilder
    private func tabs(container: AppContainer) -> some View {
        if horizontalSizeClass == .regular {
            wideLayout(container: container)
        } else {
            compactLayout(container: container)
        }
    }

    @ViewBuilder
    private func compactLayout(container: AppContainer) -> some View {
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
            .badge(container.settingsViewModel.hasInvalidCredentials ? "" : nil)
            .tag(MainTab.settings)
            .onDisappear {
                Task {
                    await foregroundRefreshFeedAndStories(container: container)
                }
            }
        }

        if #available(iOS 26.0, *) {
            tabView.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabView
        }
    }

    private func wideLayout(container: AppContainer) -> some View {
        NavigationSplitView {
            List(selection: tabSelectionOptional(container: container)) {
                Label("Home", systemImage: "house")
                    .tag(MainTab.home)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(MainTab.search)
                Label("Settings", systemImage: "gear")
                    .badge(container.settingsViewModel.hasInvalidCredentials ? "!" : nil)
                    .tag(MainTab.settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .navigationTitle("Social")
        } detail: {
            detailView(for: selectedTab, container: container)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func detailView(for tab: MainTab, container: AppContainer) -> some View {
        switch tab {
        case .home:
            FeedView(
                viewModel: container.feedViewModel,
                storyViewModel: container.storyBarViewModel,
                spotifyClient: container.spotifyClient,
                onOpenSettings: {
                    selectedTab = .settings
                },
            )
        case .search:
            SearchView(
                viewModel: container.profileSearchViewModel,
            )
        case .settings:
            NavigationStack {
                SettingsView(viewModel: container.settingsViewModel)
            }
            .onDisappear {
                Task {
                    await foregroundRefreshFeedAndStories(container: container)
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

    private func tabSelection(container: AppContainer) -> Binding<MainTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                setSelectedTab(newTab, container: container)
            },
        )
    }

    private func tabSelectionOptional(container: AppContainer) -> Binding<MainTab?> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if let newTab {
                    setSelectedTab(newTab, container: container)
                }
            },
        )
    }

    private func setSelectedTab(_ newTab: MainTab, container: AppContainer) {
        if selectedTab == .home, newTab == .home {
            Task {
                await refreshFeedAndStories(container: container)
            }
        }

        selectedTab = newTab
    }
}

private enum MainTab: Hashable {
    case home
    case search
    case settings
}
