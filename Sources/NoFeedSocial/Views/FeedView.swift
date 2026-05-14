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

    var body: some View {
        NavigationStack {
            List {
                if hasStoryBarContent {
                    StoriesBar(
                        items: viewModel.storyBarItems,
                        onItemTap: { index in
                            let selectedItem = viewModel.storyBarItems[index]
                            let items = viewModel.storyViewerItems(for: index)
                            storyViewerSelection = StoryViewerSelection(
                                items: items,
                                startIndex: viewModel.storyViewerStartIndex(for: selectedItem, in: items)
                            )
                        }
                    )
                }

                if notificationItems.isEmpty && !hasStoryBarContent && !viewModel.storyBarLoading {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "No Notifications",
                            systemImage: "bell.slash",
                            description: Text("Connect social accounts to get started.")
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

                    if !unreadItems.isEmpty && !readItems.isEmpty {
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
                onInstagramReelSeen: { reelId in
                    viewModel.markInstagramReelAsSeen(reelId: reelId)
                },
                onSpotifyItemSeen: { userURI in
                    viewModel.markSpotifyActivityAsSeen(userURI: userURI)
                }
            )
        }
        #else
        .sheet(item: $storyViewerSelection) { selection in
                    UnifiedStoryViewer(
                        items: selection.items,
                        startIndex: selection.startIndex,
                        spotifyClient: spotifyClient,
                        feedService: viewModel.service,
                        onInstagramReelSeen: { reelId in
                            viewModel.markInstagramReelAsSeen(reelId: reelId)
                        },
                        onSpotifyItemSeen: { userURI in
                            viewModel.markSpotifyActivityAsSeen(userURI: userURI)
                        }
                    )
                }
        #endif
    }

    private var notificationItems: [DisplayNotificationItem] {
        viewModel.items
    }

    private var unreadItems: [DisplayNotificationItem] {
        notificationItems.filter(\.isUnread)
    }

    private var readItems: [DisplayNotificationItem] {
        notificationItems.filter { !$0.isUnread }
    }

    private var hasStoryBarContent: Bool {
        !viewModel.storyBarItems.isEmpty
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
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
    let onItemTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onItemTap(index)
                    } label: {
                        storyBubble(for: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
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
}

private struct InstagramStoryBubble: View {
    let reel: InstagramStoryReel
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
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
                            lineWidth: reel.isSeen ? 3 : 0
                        )
                        .overlay {
                            if !reel.isSeen {
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.purple, .pink, .orange],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 3
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
                    musicAnimation: item.musicAnimation
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
                    value: isAnimating
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
            return Text(image).baselineOffset(-1) + Text(" ").kerning(-2) + Text(actorSummary).bold() + Text(remainder)
        }
        return Text(displayItem.item.network.badgeFallbackText).bold() + Text(" ").kerning(-2) + Text(actorSummary).bold() + Text(remainder)
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
