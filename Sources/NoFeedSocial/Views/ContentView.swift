import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?
    @State private var path: [HomeDestination] = []
    /// Kept across launches, so the app reopens on the side it was left on.
    @AppStorage("homePage") private var page = HomePage.social
    @State private var isShowingChat = false
    @State private var isShowingFeedDetail = false
    @ObservedObject private var notificationRouter = NotificationRouter.shared

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
        // `apron:` links, and link.apron.chat links once the app is in its registry.
        .onOpenURL { url in
            _ = notificationRouter.open(url)
        }
        .task {
            if container == nil {
                configureDependencies()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let container else { return }
            // Apron servers and X Chat stream updates only while the app is in the foreground.
            guard phase == .active else {
                if phase == .background {
                    container.stopLiveFeeds()
                }
                return
            }
            container.startLiveFeeds()
            Task {
                await foregroundRefreshFeedAndStories(container: container)
            }
        }
    }

    /// Chats sits to the left of the feed: swipe right from the feed to reach it.
    private func home(container: AppContainer) -> some View {
        HomePager(
            page: $page,
            isPagingEnabled: isPagingEnabled,
            chats: NavigationStack {
                ChatsView(
                    viewModel: container.chatListViewModel,
                    apronService: container.apronService,
                    spotifyChat: { container.spotifyChatFactory(accountId: $0, chatId: $1, title: $2) },
                    instagramChat: { container.instagramChatFactory(accountId: $0, threadFbid: $1, title: $2) },
                    telegramChat: { container.telegramChatFactory(accountId: $0, peer: $1, title: $2, userStatus: $3, avatarURL: $4) },
                    xChat: { container.xChatFactory(accountId: $0, conversationId: $1, title: $2) },
                    blueskyChat: { container.blueskyChatFactory(accountId: $0, convoId: $1, title: $2) },
                    accountSettings: { accountId in
                        guard container.settingsViewModel.account(id: accountId) != nil else { return nil }
                        return AnyView(AccountDetailView(viewModel: container.settingsViewModel, apronServersViewModel: container.apronServersViewModel, accountId: accountId))
                    },
                    isShowingChat: $isShowingChat,
                    openRequest: $notificationRouter.pendingChat,
                )
            },
            social: socialStack(container: container),
        )
        .ignoresSafeArea()
        .sheet(item: $notificationRouter.linkRequest) { request in
            switch request {
            case let .link(link):
                ApronLinkView(
                    viewModel: ApronLinkViewModel(link: link, service: container.apronService, chatList: container.chatListViewModel),
                    openRoom: { notificationRouter.openRoom(of: $0) },
                )
            case let .invalid(message):
                NavigationStack {
                    ContentUnavailableView("Can't Open Link", systemImage: "link", description: Text(message))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { notificationRouter.linkRequest = nil }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
        }
        .onChange(of: notificationRouter.pendingChat, initial: true) { _, request in
            // A tapped notification's chat opens on the Chats side.
            if request != nil {
                page = .chats
            }
        }
    }

    /// Paging stops while the visible side has a screen pushed, so back swipes and swipe-to-reply aren't taken
    /// over. Tracked from navigation state: a page's `onDisappear` also fires as a swipe starts.
    private var isPagingEnabled: Bool {
        page == .chats ? !isShowingChat : !isShowingFeedDetail && path.isEmpty
    }

    private func socialStack(container: AppContainer) -> some View {
        NavigationStack(path: $path) {
            // Re-created when accounts change, so the feed gets the current Spotify account's client.
            AccountsObserving(services: container.services) {
                FeedView(
                    viewModel: container.feedViewModel,
                    storyViewModel: container.storyBarViewModel,
                    spotifyClient: container.spotifyClient,
                    settingsViewModel: container.settingsViewModel,
                    onOpenSettings: { path.append(.settings) },
                    onRefresh: { await refreshFeedAndStories(container: container) },
                    isShowingDetail: $isShowingFeedDetail,
                )
            }
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
                        chatControlServer: ChatControlServer.isAvailable ? container.chatControlServer : nil,
                    )
                }
            }
        }
    }

    private func configureDependencies() {
        let appContainer = AppContainer(modelContext: modelContext)
        container = appContainer
        NotificationRouter.shared.apronService = appContainer.apronService
        NotificationRouter.shared.chatList = appContainer.chatListViewModel
        appContainer.startLiveFeeds()
        if ChatControlServer.isAvailable {
            _ = appContainer.chatControlServer
        }

        Task {
            await foregroundRefreshFeedAndStories(container: appContainer)
        }
    }

    private func foregroundRefreshFeedAndStories(container: AppContainer) async {
        await container.settingsViewModel.repairAccountIdentities()
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

/// Re-renders its content when accounts are added or removed.
private struct AccountsObserving<Content: View>: View {
    @ObservedObject var services: AccountServices
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

enum HomeDestination: Hashable {
    case search
    case settings
}
