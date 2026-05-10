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
    @State private var selectedInstagramReelIndex: Int?
    @State private var showStoryViewer = false

    var body: some View {
        NavigationStack {
            List {
                if !storyItems.isEmpty || !viewModel.instagramStoryReels.isEmpty {
                    StoriesBar(
                        items: storyItems,
                        instagramReels: viewModel.instagramStoryReels,
                        feedService: viewModel.service,
                        onInstagramReelTap: { index in
                            selectedInstagramReelIndex = index
                            showStoryViewer = true
                        }
                    )
                }

                if notificationItems.isEmpty && storyItems.isEmpty && viewModel.instagramStoryReels.isEmpty {
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
        .fullScreenCover(isPresented: $showStoryViewer) {
            InstagramStoryViewer(
                reels: viewModel.instagramStoryReels,
                startIndex: selectedInstagramReelIndex ?? 0,
                onReelSeen: { index in
                    viewModel.markInstagramReelAsSeen(reelIndex: index)
                }
            )
        }
    }

    private var storyItems: [DisplayNotificationItem] {
        viewModel.items.filter(\.isStoryBarItem)
    }

    private var notificationItems: [DisplayNotificationItem] {
        viewModel.items.filter { !$0.isStoryBarItem }
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
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct StoriesBar: View {
    let items: [DisplayNotificationItem]
    let instagramReels: [InstagramStoryReel]
    let feedService: FeedService
    let onInstagramReelTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(instagramReels.enumerated()), id: \.element.id) { index, reel in
                    Button {
                        onInstagramReelTap(index)
                    } label: {
                        InstagramStoryBubble(reel: reel)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(items) { displayItem in
                    NavigationLink {
                        NotificationDetailView(displayItem: displayItem, feedService: feedService)
                    } label: {
                        StoryBubble(displayItem: displayItem)
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
}

private struct InstagramStoryBubble: View {
    let reel: InstagramStoryReel

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AsyncImage(url: reel.user.avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        ZStack {
                            Color.secondary.opacity(0.18)
                            Text(initial)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    @unknown default:
                        Color.clear
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
        reel.user.username ?? reel.user.displayName ?? reel.user.id
    }

    private var initial: String {
        label.first.map { String($0).uppercased() } ?? "?"
    }
}

private struct StoryBubble: View {
    let displayItem: DisplayNotificationItem

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                StoryThumbnail(
                    url: displayItem.item.target?.imageURL,
                    network: displayItem.item.network,
                    musicAnimation: displayItem.item.target?.musicAnimation
                )
                .overlay {
                    storyThumbnailShape
                        .stroke(displayItem.item.network.storyAccentColor, lineWidth: 2)
                }

                if let actor = displayItem.item.actors.first {
                    StoryActorAvatar(actor: actor)
                        .offset(x: 3, y: 3)
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        guard let actor = displayItem.item.actors.first else { return displayItem.item.network.displayName }
        return actor.username ?? actor.displayName ?? actor.id
    }

    private var accessibilityLabel: String {
        switch displayItem.item.network {
        case .spotify:
            "Listening activity from \(label)"
        case .instagram:
            "Instagram story activity from \(label)"
        case .x, .farcaster, .debug:
            displayItem.item.text
        }
    }

    private var storyThumbnailShape: AnyShape {
        if displayItem.item.network == .spotify {
            return AnyShape(Circle())
        }
        return AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct StoryThumbnail: View {
    let url: URL?
    let network: SocialNetwork
    let musicAnimation: MusicAnimationMetadata?

    var body: some View {
        if network == .spotify {
            SpotifyAnimatedStoryThumbnail(url: url, musicAnimation: musicAnimation)
        } else {
            staticThumbnail
        }
    }

    private var staticThumbnail: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure, .empty:
                ZStack {
                    network.storyAccentColor.opacity(0.18)
                    Image(systemName: network == .spotify ? "music.note" : "camera")
                        .font(.title2)
                        .foregroundStyle(network.storyAccentColor)
                }
            @unknown default:
                Color.clear
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(thumbnailShape)
    }

    private var thumbnailShape: AnyShape {
        if network == .spotify {
            return AnyShape(Circle())
        }
        return AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SpotifyAnimatedStoryThumbnail: View {
    let url: URL?
    let musicAnimation: MusicAnimationMetadata?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                SpotifyPulseRing(
                    delay: 0,
                    isAnimating: isAnimating,
                    duration: pulseDuration,
                    scale: pulseScale,
                    opacity: pulseOpacity
                )
                SpotifyPulseRing(
                    delay: pulseDuration * 0.48,
                    isAnimating: isAnimating,
                    duration: pulseDuration,
                    scale: pulseScale * 1.08,
                    opacity: pulseOpacity * 0.72
                )
            }

            albumArt
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.spotifyActivityBorder, lineWidth: 2)
                }
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

    private var confidence: Double {
        min(max(musicAnimation?.tempoConfidence ?? 0.55, 0.3), 1)
    }

    private var loudnessIntensity: Double {
        guard let loudness = musicAnimation?.loudness else { return 0.58 }
        return min(max((loudness + 24) / 18, 0.22), 1)
    }

    private var rotationDuration: TimeInterval {
        // One revolution spans roughly sixteen beats, making faster tracks spin faster without becoming frantic.
        (60 / tempo) * 16
    }

    private var pulseDuration: TimeInterval {
        min(max((60 / tempo) * 2, 0.65), 1.55)
    }

    private var pulseScale: Double {
        0.98 + loudnessIntensity * 0.36
    }

    private var pulseOpacity: Double {
        min((0.72 + loudnessIntensity * 0.28) * confidence, 1)
    }
}

private struct SpotifyPulseRing: View {
    let delay: TimeInterval
    let isAnimating: Bool
    let duration: TimeInterval
    let scale: Double
    let opacity: Double

    var body: some View {
        Circle()
            .stroke(Color.spotifyActivityBorder.opacity(opacity), lineWidth: 7)
            .frame(width: 70, height: 70)
            .scaleEffect(isAnimating ? scale : 1)
            .opacity(isAnimating ? 0 : opacity)
            .animation(
                .easeOut(duration: duration)
                    .delay(delay)
                    .repeatForever(autoreverses: false),
                value: isAnimating
            )
    }
}

private struct StoryActorAvatar: View {
    let actor: NotificationActor

    var body: some View {
        AsyncImage(url: actor.avatarURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure, .empty:
                ZStack {
                    Color.secondary.opacity(0.18)
                    Text(initial)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Color.clear
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.storyAvatarBorder, lineWidth: 2)
        }
    }

    private var initial: String {
        let name = actor.username ?? actor.displayName ?? actor.id
        return name.first.map { String($0).uppercased() } ?? "?"
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
            Text(targetText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if let imageUrl = displayItem.item.target?.imageURL,
                  imageUrl.absoluteString.contains("cdninstagram.com") || displayItem.item.type == .music
        {
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
            Text(actor.username ?? actor.id)
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
        displayItem.item.actors.reduce(displayItem.item.text) { text, actor in
            guard let username = actor.username else { return text }
            return text.replacingOccurrences(of: "@\(username)", with: username)
        }
    }

    private var actorSummary: String {
        guard let first = displayItem.item.actors.first else { return "Someone" }
        let firstName = first.username ?? first.id
        let remainingCount = displayItem.item.actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }
}

private extension DisplayNotificationItem {
    var isStoryBarItem: Bool {
        item.network == .spotify && item.type == .music
    }
}

private extension Color {
    static var spotifyGreen: Color {
        Color(red: 0.12, green: 0.73, blue: 0.26)
    }

    static var spotifyActivityBorder: Color {
        Color.secondary
    }

    static var storyAvatarBorder: Color {
        #if os(iOS)
            Color(uiColor: .systemBackground)
        #elseif os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color.white
        #endif
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

    var storyAccentColor: Color {
        switch self {
        case .instagram:
            Color(red: 0.88, green: 0.21, blue: 0.44)
        case .spotify:
            Color(red: 0.12, green: 0.73, blue: 0.26)
        case .x, .farcaster, .debug:
            badgeBackgroundColor
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
        case .music:
            "Music"
        case .unknown:
            "Notification"
        }
    }
}

private struct AvatarStrip: View {
    let actors: [NotificationActor]

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
            actor.username ?? actor.displayName ?? actor.id
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
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        AvatarFallback(actor: actor)
                    @unknown default:
                        AvatarFallback(actor: actor)
                    }
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
        let value = actor.username ?? actor.displayName ?? actor.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
