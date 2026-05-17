import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct FeedView: View {
    @ObservedObject var viewModel: FeedViewModel
    let settingsViewModel: SettingsViewModel
    let spotifyClient: SpotifyClient
    @State private var storyViewerSelection: StoryViewerSelection?
    @State private var showingStoryComposer = false

    var body: some View {
        NavigationStack {
            List {
                if hasVisibleStoriesBar {
                    StoriesBar(
                        items: viewModel.storyBarItems,
                        ownInstagramActor: viewModel.ownInstagramStoryActor,
                        ownInstagramReel: viewModel.ownInstagramStoryReel,
                        onComposeTap: {
                            showingStoryComposer = true
                        },
                        onOwnStoryTap: {
                            if let ownInstagramStoryReel = viewModel.ownInstagramStoryReel {
                                storyViewerSelection = StoryViewerSelection(
                                    items: [.instagram(ownInstagramStoryReel)],
                                    startIndex: 0,
                                )
                            } else {
                                showingStoryComposer = true
                            }
                        },
                        onItemTap: { selectedItem, visibleItems in
                            let items = visibleItems.filter { $0.isSeen == selectedItem.isSeen }
                            storyViewerSelection = StoryViewerSelection(
                                items: items,
                                startIndex: viewModel.storyViewerStartIndex(for: selectedItem, in: items),
                            )
                        },
                    )
                }

                if notificationItems.isEmpty, !hasVisibleStoriesBar, !viewModel.storyBarLoading {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "No Notifications",
                            systemImage: "bell.slash",
                            description: Text("Connect social accounts to get started."),
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 600)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    if !unreadItems.isEmpty {
                        Section {
                            ForEach(Array(unreadItems.enumerated()), id: \.element.id) { index, displayItem in
                                NotificationLink(displayItem: displayItem, feedService: viewModel.service)
                                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if !unreadItems.isEmpty, !readItems.isEmpty {
                        NewSeparatorRow()
                    }

                    if !readItems.isEmpty {
                        Section {
                            ForEach(Array(readItems.enumerated()), id: \.element.id) { index, displayItem in
                                NotificationLink(displayItem: displayItem, feedService: viewModel.service)
                                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .refreshable {
                await viewModel.refresh()
            }
            .navigationTitle("Notifications")
            .toolbar {
                if viewModel.isForegroundRefreshing || viewModel.pendingNewCount > 0 {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 8) {
                            if viewModel.isForegroundRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if viewModel.pendingNewCount > 0 {
                                Button {
                                    viewModel.revealPendingNotifications()
                                } label: {
                                    Text("\(viewModel.pendingNewCount) New")
                                }
                            }
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView(viewModel: settingsViewModel)
                            .onDisappear {
                                Task {
                                    await viewModel.refreshOnForegroundActivation()
                                }
                            }
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .alert("Refresh Issue", isPresented: errorBinding) {
                Button("OK", role: .cancel) {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "Refresh failed.")
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $storyViewerSelection) { selection in
            UnifiedStoryViewer(
                items: selection.items,
                startIndex: selection.startIndex,
                spotifyClient: spotifyClient,
                feedService: viewModel.service,
                ownInstagramAccountId: viewModel.ownInstagramStoryActor?.id,
                onInstagramReelSeen: { reelId in
                    viewModel.markInstagramReelAsSeen(reelId: reelId)
                },
                onSpotifyItemSeen: { userURI in
                    viewModel.markSpotifyActivityAsSeen(userURI: userURI)
                },
                onInstagramStoryDelete: { mediaId, isVideo in
                    try await viewModel.deleteInstagramStory(mediaId: mediaId, isVideo: isVideo)
                },
                onInstagramStoryLike: { mediaId, liked in
                    try await viewModel.setInstagramStoryLiked(mediaId: mediaId, liked: liked)
                },
            )
        }
        .fullScreenCover(isPresented: $showingStoryComposer) {
            StoryComposerView { imageData, width, height, mimeType in
                try await viewModel.postInstagramStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
            }
        }
        #else
        .sheet(item: $storyViewerSelection) { selection in
                    UnifiedStoryViewer(
                        items: selection.items,
                        startIndex: selection.startIndex,
                        spotifyClient: spotifyClient,
                        feedService: viewModel.service,
                        ownInstagramAccountId: viewModel.ownInstagramStoryActor?.id,
                        onInstagramReelSeen: { reelId in
                            viewModel.markInstagramReelAsSeen(reelId: reelId)
                        },
                        onSpotifyItemSeen: { userURI in
                            viewModel.markSpotifyActivityAsSeen(userURI: userURI)
                        },
                        onInstagramStoryDelete: { mediaId, isVideo in
                            try await viewModel.deleteInstagramStory(mediaId: mediaId, isVideo: isVideo)
                        },
                        onInstagramStoryLike: { mediaId, liked in
                            try await viewModel.setInstagramStoryLiked(mediaId: mediaId, liked: liked)
                        },
                    )
                }
                .sheet(isPresented: $showingStoryComposer) {
                    StoryComposerView { imageData, width, height, mimeType in
                        try await viewModel.postInstagramStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
                    }
                }
        #endif
    }

    private var notificationItems: [DisplayNotificationItem] {
        viewModel.items
    }

    private var hasVisibleStoriesBar: Bool {
        viewModel.storyBarContentLoaded && (viewModel.ownInstagramStoryActor != nil || !viewModel.storyBarItems.isEmpty)
    }

    private var unreadItems: [DisplayNotificationItem] {
        notificationItems.filter(\.isUnread)
    }

    private var readItems: [DisplayNotificationItem] {
        notificationItems.filter { !$0.isUnread }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } },
        )
    }
}

private struct StoryViewerSelection: Identifiable {
    let id = UUID()
    let items: [StoryBarItem]
    let startIndex: Int
}

private struct StoriesBar: View {
    let items: [StoryBarItem]
    let ownInstagramActor: NotificationActor?
    let ownInstagramReel: InstagramStoryReel?
    let onComposeTap: () -> Void
    let onOwnStoryTap: () -> Void
    let onItemTap: (StoryBarItem, [StoryBarItem]) -> Void
    @State private var visibleModeID: String?
    @State private var pagerOffset: CGFloat = 0

    private let rowHeight: CGFloat = 112

    var body: some View {
        let modes = availableFeedModes
        let pages = pagerModes(for: modes)

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pages) { page in
                        storyRow(mode: page.mode)
                            .frame(height: rowHeight, alignment: .top)
                            .containerRelativeFrame(.vertical, count: 1, spacing: 0)
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $visibleModeID, anchor: .top)
            .scrollTargetBehavior(.paging)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                pagerOffset = newValue
            }
            .frame(height: rowHeight)
            .clipped()
            .overlay(alignment: .leading) {
                if modes.count > 1 {
                    storyPagerDots(modes: modes)
                }
            }
            .onAppear {
                visibleModeID = modes.first?.pageID
            }
            .onChange(of: modes) { _, newModes in
                visibleModeID = normalizedModeID(for: visibleModeID, modes: newModes)
            }
            .onChange(of: visibleModeID) { _, id in
                guard modes.count > 1 else { return }
                if id == StoryBarFeedPage.trailingSentinelID, let first = modes.first {
                    Task { @MainActor in
                        jumpToMode(first, proxy: proxy)
                    }
                } else if id == StoryBarFeedPage.leadingSentinelID, let last = modes.last {
                    Task { @MainActor in
                        jumpToMode(last, proxy: proxy)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private func storyRow(mode: StoryBarFeedMode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mode.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if showsOwnInstagramBubble(in: mode) {
                        StoryComposerBubble(actor: ownInstagramActor, reel: ownInstagramReel)
                            .contentShape(Rectangle())
                            .onTapGesture { onOwnStoryTap() }
                            .overlay(alignment: .topLeading) {
                                Button {
                                    onComposeTap()
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.blue, in: Circle())
                                        .overlay {
                                            Circle()
                                                .stroke(.background, lineWidth: 2)
                                        }
                                }
                                .buttonStyle(.plain)
                                .offset(x: 49, y: 49)
                                .accessibilityLabel("Create story")
                            }
                    }

                    let rowItems = filteredItems(for: mode)
                    ForEach(rowItems) { item in
                        storyBubble(for: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let viewerItems = rowItems.filter { $0.isSeen == item.isSeen }
                                onItemTap(item, viewerItems)
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func storyBubble(for item: StoryBarItem) -> some View {
        switch item {
        case let .instagram(reel):
            InstagramStoryBubble(reel: reel)
        case let .spotify(spotifyItem):
            SpotifyStoryBubble(item: spotifyItem)
        }
    }

    private var availableFeedModes: [StoryBarFeedMode] {
        StoryBarFeedMode.allCases.filter { mode in
            switch mode {
            case .general:
                true
            case .instagram:
                ownInstagramActor != nil || items.contains(where: mode.includes)
            case .spotify:
                items.contains(where: mode.includes)
            }
        }
    }

    private func filteredItems(for mode: StoryBarFeedMode) -> [StoryBarItem] {
        items.filter(mode.includes).sorted { lhs, rhs in
            if lhs.isSeen != rhs.isSeen {
                return !lhs.isSeen && rhs.isSeen
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func showsOwnInstagramBubble(in mode: StoryBarFeedMode) -> Bool {
        ownInstagramActor != nil && mode != .spotify
    }

    private func pagerModes(for modes: [StoryBarFeedMode]) -> [StoryBarFeedPage] {
        guard modes.count > 1, let first = modes.first, let last = modes.last else {
            return modes.map { StoryBarFeedPage(id: $0.pageID, mode: $0) }
        }
        return [StoryBarFeedPage(id: StoryBarFeedPage.leadingSentinelID, mode: last)]
            + modes.map { StoryBarFeedPage(id: $0.pageID, mode: $0) }
            + [StoryBarFeedPage(id: StoryBarFeedPage.trailingSentinelID, mode: first)]
    }

    private func normalizedModeID(for id: String?, modes: [StoryBarFeedMode]) -> String? {
        guard !modes.isEmpty else { return nil }
        if let id, modes.contains(where: { $0.pageID == id }) {
            return id
        }
        return modes.first?.pageID
    }

    private func jumpToMode(_ mode: StoryBarFeedMode, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleModeID = mode.pageID
            proxy.scrollTo(mode.pageID, anchor: .top)
        }
    }

    private func storyPagerDots(modes: [StoryBarFeedMode]) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(modes.enumerated()), id: \.element) { index, _ in
                let progress = circularPagerProgress(modeCount: modes.count)
                let intensity = dotIntensity(index: index, progress: progress, modeCount: modes.count)
                Circle()
                    .fill(Color.secondary.opacity(0.25 + (0.75 * intensity)))
                    .frame(width: 5 + (2 * intensity), height: 5 + (2 * intensity))
            }
        }
        .padding(.leading, 6)
        .allowsHitTesting(false)
    }

    private func circularPagerProgress(modeCount: Int) -> CGFloat {
        guard modeCount > 0 else { return 0 }
        let rawPosition = pagerOffset / rowHeight
        var progress = rawPosition - (modeCount > 1 ? 1 : 0)
        while progress < 0 {
            progress += CGFloat(modeCount)
        }
        while progress >= CGFloat(modeCount) {
            progress -= CGFloat(modeCount)
        }
        return progress
    }

    private func dotIntensity(index: Int, progress: CGFloat, modeCount: Int) -> CGFloat {
        guard modeCount > 0 else { return 0 }
        let distance = abs(progress - CGFloat(index))
        let wrappedDistance = min(distance, CGFloat(modeCount) - distance)
        return max(0, 1 - wrappedDistance)
    }
}

private enum StoryBarFeedMode: CaseIterable {
    case general
    case instagram
    case spotify

    var label: String {
        switch self {
        case .general: "All Stories"
        case .instagram: "Instagram"
        case .spotify: "Spotify"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .general:
            Color.secondary
        case .instagram:
            Color.pink.opacity(0.75)
        case .spotify:
            Color.spotifyActivityBorder
        }
    }

    var pageID: String {
        "story-feed-\(label)"
    }

    func includes(_ item: StoryBarItem) -> Bool {
        switch self {
        case .general:
            true
        case .instagram:
            item.network == .instagram
        case .spotify:
            item.network == .spotify
        }
    }
}

private struct StoryBarFeedPage: Identifiable {
    static let leadingSentinelID = "story-feed-leading-sentinel"
    static let trailingSentinelID = "story-feed-trailing-sentinel"

    let id: String
    let mode: StoryBarFeedMode
}

private struct StoryComposerBubble: View {
    let actor: NotificationActor?
    let reel: InstagramStoryReel?
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                CachedAsyncImage(url: actor?.avatarURL, cacheKey: actor.map { "instagram-avatar-\($0.id)" }) {
                    avatarPlaceholder
                } failure: {
                    avatarPlaceholder
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(baseStoryBorderColor, lineWidth: reel == nil ? 1 : 3)
                        .overlay {
                            if reel?.isSeen == false {
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.purple, .pink, .orange],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing,
                                        ),
                                        lineWidth: 3,
                                    )
                            }
                        }
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityLabel(reel == nil ? "Create story" : "Your Instagram story")
    }

    private var baseStoryBorderColor: Color {
        if let reel {
            return reel.isSeen ? Color.gray.opacity(0.4) : Color.clear
        }
        return Color.secondary.opacity(0.25)
    }

    private var label: String {
        if let actor {
            return DebugRedaction.actorName(actor, enabled: devModeEnabled)
        }
        return "Create"
    }

    private var initial: String {
        label.first.map { String($0).uppercased() } ?? "+"
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.18)
            Text(initial)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InstagramStoryBubble: View {
    let reel: InstagramStoryReel
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: reel.user.avatarURL, cacheKey: "instagram-avatar-\(reel.user.id)") {
                    ZStack {
                        Color.secondary.opacity(0.18)
                        Text(initial)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } failure: {
                    ZStack {
                        Color.secondary.opacity(0.18)
                        Text(initial)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(
                            reel.isSeen
                                ? Color.gray.opacity(0.4)
                                : Color.clear,
                            lineWidth: reel.isSeen ? 3 : 0,
                        )
                        .overlay {
                            if !reel.isSeen {
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.purple, .pink, .orange],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing,
                                        ),
                                        lineWidth: 3,
                                    )
                            }
                        }
                }

                if reel.hasCloseFriendsMedia {
                    Image(systemName: "star.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.green, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(.background, lineWidth: 2)
                        }
                        .offset(x: 3, y: 3)
                        .accessibilityLabel("Close Friends")
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityLabel("Instagram stories from \(label)")
    }

    private var label: String {
        DebugRedaction.actorName(reel.user, enabled: devModeEnabled)
    }

    private var initial: String {
        label.first.map { String($0).uppercased() } ?? "?"
    }
}

private struct SpotifyStoryBubble: View {
    let item: SpotifyActivityItem
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                SpotifyAnimatedStoryThumbnail(
                    url: item.imageURL,
                    musicAnimation: item.musicAnimation,
                )
                .overlay {
                    Circle()
                        .stroke(item.isSeen ? Color.gray.opacity(0.4) : Color.spotifyActivityBorder, lineWidth: 3)
                }

                CachedAsyncImage(url: item.userAvatarURL, cacheKey: "spotify-avatar-\(item.userURI)") {
                    Circle().fill(Color.secondary.opacity(0.18))
                } failure: {
                    Circle().fill(Color.secondary.opacity(0.18))
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .offset(x: 3, y: 3)
            }

            Text(displayUserName)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityLabel("Listening activity from \(displayUserName)")
    }

    private var displayUserName: String {
        DebugRedaction.username(item.userName, enabled: devModeEnabled)
    }
}

private struct SpotifyAnimatedStoryThumbnail: View {
    let url: URL?
    let musicAnimation: MusicAnimationMetadata?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            albumArt
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .rotationEffect(.degrees(reduceMotion || !isAnimating ? 0 : 360))
                .animation(
                    reduceMotion ? nil : .linear(duration: rotationDuration).repeatForever(autoreverses: false),
                    value: isAnimating,
                )
        }
        .frame(width: 70, height: 70)
        .onAppear { isAnimating = true }
    }

    private var albumArt: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure, .empty:
                ZStack {
                    Color.spotifyActivityBorder.opacity(0.18)
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(Color.spotifyActivityBorder)
                }
            @unknown default:
                Color.clear
            }
        }
    }

    private var tempo: Double {
        guard let tempo = musicAnimation?.tempo, tempo > 0 else { return 108 }
        return min(max(tempo, 60), 190)
    }

    private var rotationDuration: TimeInterval {
        (60 / tempo) * 16
    }
}

private struct NotificationLink: View {
    let displayItem: DisplayNotificationItem
    let feedService: FeedService

    var body: some View {
        NavigationLink {
            NotificationDetailView(displayItem: displayItem, feedService: feedService)
        } label: {
            NotificationRow(displayItem: displayItem)
        }
    }
}

private struct NewSeparatorRow: View {
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
            Text("New")
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
    }
}

private struct NotificationRow: View {
    let displayItem: DisplayNotificationItem
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NotificationTypeIcon(type: displayItem.item.type)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    if !displayItem.item.actors.isEmpty {
                        AvatarStrip(actors: displayItem.item.actors)
                    }

                    Spacer()

                    Text(displayItem.item.timestamp.compactRelativeTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                summaryView

                previewContent
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var previewContent: some View {
        if displayItem.item.type == .follow {
            EmptyView()
        } else if let targetText = displayItem.item.target?.text, !targetText.isEmpty,
                  displayItem.item.type == .reaction || displayItem.item.type == .reply || displayItem.item.type == .mention || displayItem.item.type == .music
        {
            Text(DebugRedaction.text(targetText, actors: displayItem.item.actors, enabled: devModeEnabled))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if let imageUrl = displayItem.item.target?.imageURL {
            AsyncImage(url: imageUrl) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .failure, .empty:
                    Color.clear.frame(width: 48, height: 48)
                @unknown default:
                    Color.clear.frame(width: 48, height: 48)
                }
            }
        } else if let actor = displayItem.item.actors.first {
            Text(DebugRedaction.actorName(actor, enabled: devModeEnabled))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var summaryText: String {
        switch displayItem.item.type {
        case .mention:
            "\(actorSummary) mentioned you"
        case .reply:
            "\(actorSummary) replied to you"
        case .reaction:
            sanitizedItemText
        case .follow:
            "\(actorSummary) followed you"
        case .post:
            sanitizedItemText
        case .music:
            sanitizedItemText
        case .unknown:
            sanitizedItemText
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if displayItem.item.actors.first != nil, summaryText.hasPrefix(actorSummary) {
            summaryInlineText
                .font(.body)
                .lineLimit(2)
        } else {
            Text(summaryText)
                .font(.body)
                .lineLimit(2)
        }
    }

    private var summaryInlineText: Text {
        let remainder = String(summaryText.dropFirst(actorSummary.count))
        if let image = networkBadgeImage(named: displayItem.item.network.badgeAssetName) {
            return Text("\(Text(image).baselineOffset(-1)) \(Text(actorSummary).bold())\(Text(remainder))")
        }
        return Text("\(Text(displayItem.item.network.badgeFallbackText).bold()) \(Text(actorSummary).bold())\(Text(remainder))")
    }

    private var previewText: String? {
        if displayItem.item.type == .reaction
            || displayItem.item.type == .reply
            || displayItem.item.type == .mention
            || displayItem.item.type == .post
            || displayItem.item.type == .music,
            let targetText = displayItem.item.target?.text, !targetText.isEmpty
        {
            return targetText
        }

        if let actor = displayItem.item.actors.first {
            return actor.username ?? actor.id
        }

        return nil
    }

    private var sanitizedItemText: String {
        let sanitized = displayItem.item.actors.reduce(displayItem.item.text) { text, actor in
            guard let username = actor.username else { return text }
            return text.replacingOccurrences(of: "@\(username)", with: username)
        }
        return DebugRedaction.text(sanitized, actors: displayItem.item.actors, enabled: devModeEnabled)
    }

    private var actorSummary: String {
        guard let first = displayItem.item.actors.first else { return "Someone" }
        let firstName = DebugRedaction.actorName(first, enabled: devModeEnabled)
        let remainingCount = displayItem.item.actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }
}

private extension Color {
    static var spotifyActivityBorder: Color {
        Color(red: 0.12, green: 0.73, blue: 0.26)
    }
}

private struct NetworkUsernameBadge: View {
    let network: SocialNetwork

    var body: some View {
        Group {
            if let image = networkBadgeImage(named: network.badgeAssetName) {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Text(network.badgeFallbackText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(network.badgeForegroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(network.badgeBackgroundColor)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension SocialNetwork {
    var badgeAssetName: String {
        switch self {
        case .x:
            "XBadge"
        case .farcaster:
            "FarcasterBadge"
        case .instagram:
            "InstagramBadge"
        case .spotify:
            "SpotifyBadge"
        case .debug:
            "DebugBadge"
        }
    }

    var badgeFallbackText: String {
        switch self {
        case .x:
            "X"
        case .farcaster:
            "F"
        case .instagram:
            "I"
        case .spotify:
            "S"
        case .debug:
            "D"
        }
    }

    var badgeForegroundColor: Color {
        switch self {
        case .x:
            .black
        case .farcaster:
            .white
        case .instagram:
            .white
        case .spotify:
            .black
        case .debug:
            .white
        }
    }

    var badgeBackgroundColor: Color {
        switch self {
        case .x:
            .white
        case .farcaster:
            Color(red: 0.52, green: 0.36, blue: 0.80)
        case .instagram:
            Color(red: 0.88, green: 0.21, blue: 0.44)
        case .spotify:
            Color(red: 0.12, green: 0.73, blue: 0.26)
        case .debug:
            .orange
        }
    }
}

private func networkBadgeImage(named name: String) -> Image? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }

    #if os(iOS)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: image)
    #elseif os(macOS)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: image)
    #else
        return nil
    #endif
}

private struct NotificationTypeIcon: View {
    let type: NotificationType

    var body: some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 32)
            .accessibilityLabel(accessibilityLabel)
    }

    private var systemName: String {
        switch type {
        case .reaction:
            "heart.fill"
        case .reply:
            "arrowshape.turn.up.left.fill"
        case .mention:
            "at"
        case .follow:
            "person.fill.badge.plus"
        case .post:
            "bubble.left.and.bubble.right.fill"
        case .music:
            "music.note"
        case .unknown:
            "bell.fill"
        }
    }

    private var color: Color {
        switch type {
        case .reaction:
            .pink
        case .reply:
            .blue
        case .mention:
            .purple
        case .follow:
            .green
        case .post:
            .primary
        case .music:
            Color(red: 0.12, green: 0.73, blue: 0.26)
        case .unknown:
            .secondary
        }
    }

    private var accessibilityLabel: String {
        switch type {
        case .reaction:
            "Reaction"
        case .reply:
            "Reply"
        case .mention:
            "Mention"
        case .follow:
            "Follow"
        case .post:
            "Tweet"
        case .music:
            "Music"
        case .unknown:
            "Notification"
        }
    }
}

private struct AvatarStrip: View {
    let actors: [NotificationActor]
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(actors.prefix(5).enumerated()), id: \.element.id) { index, actor in
                ActorAvatar(actor: actor)
                    .zIndex(Double(5 - index))
            }

            if actors.count > 5 {
                Text("+\(actors.count - 5)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatarAccessibilityLabel)
    }

    private var avatarAccessibilityLabel: String {
        let visibleNames = actors.prefix(5).map { actor in
            DebugRedaction.actorName(actor, enabled: devModeEnabled)
        }
        let suffix = actors.count > 5 ? ", and \(actors.count - 5) more" : ""
        return "Actors: \(visibleNames.joined(separator: ", "))\(suffix)"
    }
}

private struct ActorAvatar: View {
    let actor: NotificationActor

    var body: some View {
        Group {
            if let avatarURL = actor.avatarURL {
                CachedAsyncImage(url: avatarURL) {
                    AvatarFallback(actor: actor)
                } failure: {
                    AvatarFallback(actor: actor)
                }
            } else {
                AvatarFallback(actor: actor)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .background(.background, in: Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct AvatarFallback: View {
    let actor: NotificationActor
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))

            Text(initial)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = DebugRedaction.actorName(actor, enabled: devModeEnabled)
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
