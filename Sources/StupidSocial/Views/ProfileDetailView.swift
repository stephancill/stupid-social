import AVKit
import StupidSocialCore
import SwiftUI
import UIKit

/// Someone's profile on a social network, opened from search, a notification, a story or a one-to-one chat's
/// title: photo, name and handle, then Follow, post notifications and the chat's Mute and Archive in one row of
/// buttons, bio and counts, and the posts the network shows on the profile.
struct ProfileDetailView: View {
    let actor: NotificationActor
    let feedService: FeedService
    let initialProfile: NetworkProfile?
    /// The account the profile is seen from, such as the one a notification came to; `nil` for the network's
    /// first account.
    let accountId: String?
    /// The one-to-one chat with this person when the profile opened from its title, for muting and archiving it.
    let chat: ChatViewModel?
    @Environment(\.openURL) private var openURL
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    @State private var profile: NetworkProfile?
    @State private var isLoading = true
    @State private var isHydrating = false
    @State private var isLoadingMorePosts = false
    @State private var errorMessage: String?
    @State private var postsErrorMessage: String?
    @State private var selectedPost: NetworkProfilePost?
    @State private var autoLoadedPostCursors: Set<String> = []
    @State private var isMutatingRelationship = false
    @State private var openedTimelineItem: ProfileTimelineItem?
    /// The profile's posts, where its network has them; made once the profile's id is known.
    @State private var timeline: ProfileTimelineViewModel?
    @State private var timelineKind: ProfileTimelineKind = .posts

    init(actor: NotificationActor, feedService: FeedService, initialProfile: NetworkProfile? = nil, accountId: String? = nil, chat: ChatViewModel? = nil) {
        self.actor = actor
        self.feedService = feedService
        self.initialProfile = initialProfile
        self.accountId = accountId ?? initialProfile?.accountId
        self.chat = chat
        _profile = State(initialValue: initialProfile)
        _isLoading = State(initialValue: initialProfile == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let profile {
                profileContent(profile)
            } else {
                unavailable
            }
        }
        .task {
            makeTimeline()
            await loadProfile()
            makeTimeline()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isHydrating {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                }
            }
        }
    }

    /// The profile didn't load; a chat's Mute and Archive don't need it.
    @ViewBuilder
    private var unavailable: some View {
        let content = ContentUnavailableView("No Profile", systemImage: "person.crop.circle.badge.questionmark", description: Text(errorMessage ?? ""))
        if let chat, chat.hasChatSettings {
            List {
                Section {
                    content
                }
                .listRowBackground(Color.clear)
                Section {
                    DetailActionRow { ChatSettingsButtons(viewModel: chat) }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        } else {
            content
        }
    }

    private func profileContent(_ profile: NetworkProfile) -> some View {
        List {
            Section {
                header(profile)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
            }

            if let bio = profile.bio, !bio.isEmpty {
                Section("Bio") {
                    Text(AttributedString(linkingWebURLsIn: bio))
                        .textSelection(.enabled)
                }
            }

            if !isHydrating, hasStats(profile) {
                Section {
                    if let followerCount = profile.followerCount {
                        LabeledContent("Followers", value: formatCount(followerCount))
                    }
                    if let followingCount = profile.followingCount {
                        LabeledContent("Following", value: formatCount(followingCount))
                    }
                    if let posts = profile.postsCount {
                        LabeledContent(profile.network == .github ? "Repositories" : "Posts", value: formatCount(posts))
                    }
                }
            }

            detailsSection(profile)

            if let timeline {
                ProfileTimelineSection(
                    viewModel: timeline,
                    kind: $timelineKind,
                    network: profile.network,
                    engaging: engaging(for: profile),
                    open: { openedTimelineItem = $0 },
                )
            }

            if profile.network == .instagram {
                instagramPosts(profile)
            }
        }
        .listStyle(.insetGrouped)
        // The next page loads as the list nears its end: within a screen of it, and again each time a page grows
        // the list while it is still that close. Rows' own appear events fire for rows the list prepares off
        // screen, which loaded a second page on every visit.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let nearEnd = geometry.contentOffset.y + 2 * geometry.containerSize.height > geometry.contentSize.height
            return nearEnd ? geometry.contentSize.height : 0
        } action: { _, nearEndHeight in
            if nearEndHeight > 0 {
                timeline?.loadMore(timelineKind)
            }
        }
        .navigationDestination(item: $selectedPost) { post in
            InstagramPostDetailView(post: post)
        }
        .navigationDestination(item: $openedTimelineItem) { item in
            ProfilePostView(
                item: item,
                network: profile.network,
                engaging: engaging(for: profile),
                threads: feedService.postThreads(network: profile.network, accountId: profile.accountId ?? accountId ?? ""),
            )
        }
    }

    private func makeTimeline() {
        guard timeline == nil, let profile,
              let loader = feedService.profileTimelines(network: profile.network, accountId: profile.accountId ?? accountId)
        else { return }
        timeline = ProfileTimelineViewModel(userId: profile.id, loader: loader)
    }

    private func engaging(for profile: NetworkProfile) -> (any PostEngaging)? {
        feedService.postEngagement(network: profile.network, accountId: profile.accountId ?? accountId ?? "")
    }

    private func header(_ profile: NetworkProfile) -> some View {
        VStack(spacing: 6) {
            ChatAvatarImage(url: profile.avatarURL, title: name(of: profile), size: 96, colorKey: profile.id)
                .opensFullScreenPhoto(profile.avatarURL)
                .padding(.bottom, 6)
            HStack(spacing: 4) {
                Text(DebugRedaction.username(name(of: profile), enabled: redactionEnabled))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if profile.isVerified == true {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Verified")
                }
            }
            if let username = profile.username, profile.displayName?.isEmpty == false {
                Text(redactionEnabled ? "@Redacted" : "@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            if profile.isMutualFollow == true {
                Text("You follow each other")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if hasActions(profile) {
                DetailActionRow {
                    if canFollow(profile) {
                        let isFollowing = profile.isFollowing == true
                        DetailActionButton(title: isFollowing ? "Following" : "Follow", systemImage: isFollowing ? "person.fill.checkmark" : "person.fill.badge.plus") {
                            Task { await toggleFollow(profile) }
                        }
                    }
                    if canNotify(profile) {
                        let isNotified = profile.isNotifiedForPosts == true
                        DetailActionButton(title: isNotified ? "Notifying" : "Notify", systemImage: isNotified ? "bell.badge.fill" : "bell.badge") {
                            Task { await togglePostNotifications(profile) }
                        }
                        .accessibilityLabel(isNotified ? "Turn off post notifications" : "Turn on post notifications")
                    }
                    if let chat {
                        ChatSettingsButtons(viewModel: chat)
                    }
                }
            }
        }
    }

    private func detailsSection(_ profile: NetworkProfile) -> some View {
        Section {
            if let location = profile.location, !location.isEmpty {
                LabeledContent("Location", value: location)
            }
            if let joined = profile.joinedAt {
                LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
            }
            if let website = profile.websiteURL {
                externalLink(website.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")), url: website)
            }
            if let url = profileURL(for: profile) {
                externalLink("View on \(profile.network.displayName)", url: url)
            }
        }
    }

    private func externalLink(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func instagramPosts(_ profile: NetworkProfile) -> some View {
        if !profile.posts.isEmpty {
            Section("Posts") {
                VStack(spacing: 0) {
                    LazyVGrid(columns: postGridColumns, spacing: 1) {
                        ForEach(profile.posts) { post in
                            Button {
                                selectedPost = post
                            } label: {
                                ProfilePostThumbnail(post: post)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if profile.hasMorePosts {
                        VStack(spacing: 8) {
                            if isLoadingMorePosts {
                                ProgressView()
                            } else if let postsErrorMessage {
                                Text(postsErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry") {
                                    Task { await loadMorePosts(autoTriggered: false) }
                                }
                                .font(.footnote.weight(.semibold))
                            } else {
                                Color.clear
                                    .frame(width: 1, height: 1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .task(id: profile.postsNextCursor) {
                            await loadMorePosts(autoTriggered: true)
                        }
                    }

                    if let postsErrorMessage, !profile.hasMorePosts {
                        Text(postsErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                    }
                }
                .listRowInsets(EdgeInsets())
            }
        } else if let postsErrorMessage {
            Section("Posts") {
                Text(postsErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func name(of profile: NetworkProfile) -> String {
        [profile.displayName, profile.username, actor.displayName, actor.username]
            .compactMap(\.self)
            .first { !$0.isEmpty } ?? profile.id
    }

    private func canFollow(_ profile: NetworkProfile) -> Bool {
        (profile.network == .x || profile.network == .instagram) && profile.isFollowing != nil
    }

    private func canNotify(_ profile: NetworkProfile) -> Bool {
        profile.network == .x && profile.isNotifiedForPosts != nil
    }

    private func hasActions(_ profile: NetworkProfile) -> Bool {
        canFollow(profile) || canNotify(profile) || chat?.hasChatSettings == true
    }

    private func loadProfile() async {
        guard shouldHydrateProfile else { return }

        if profile == nil {
            isLoading = true
        } else {
            isHydrating = true
        }
        errorMessage = nil

        do {
            profile = try await feedService.fetchProfile(
                for: actor.id,
                network: actor.network,
                username: actor.username,
                accountId: accountId,
            )
        } catch {
            if profile == nil {
                errorMessage = error.localizedDescription
            } else if actor.network == .instagram {
                postsErrorMessage = error.localizedDescription
            }
        }
        isLoading = false
        isHydrating = false
    }

    private var shouldHydrateProfile: Bool {
        guard let profile else { return true }
        if profile.network == .github { return false }
        if profile.network == .x || profile.network == .instagram, profile.isFollowing == nil { return true }
        if profile.network == .x, profile.isNotifiedForPosts == nil { return true }
        if profile.network == .instagram, profile.posts.isEmpty, profile.postsCount != 0 { return true }
        if profile.bio == nil { return true }
        if profile.followerCount == nil { return true }
        if profile.followingCount == nil { return true }
        if profile.postsCount == nil { return true }
        if profile.joinedAt == nil, profile.network == .x { return true }
        if profile.isMutualFollow == nil, profile.network == .instagram { return true }
        return false
    }

    private func hasStats(_ profile: NetworkProfile) -> Bool {
        profile.followerCount != nil || profile.followingCount != nil || profile.postsCount != nil
    }

    private func loadMorePosts(autoTriggered: Bool) async {
        guard let currentProfile = profile else { return }
        guard currentProfile.network == .instagram, currentProfile.hasMorePosts else { return }
        guard !isLoadingMorePosts else { return }
        let cursorKey = currentProfile.postsNextCursor ?? "__initial__"
        if autoTriggered, autoLoadedPostCursors.contains(cursorKey) { return }
        if autoTriggered { autoLoadedPostCursors.insert(cursorKey) }

        isLoadingMorePosts = true
        postsErrorMessage = nil
        defer { isLoadingMorePosts = false }

        do {
            let page = try await feedService.fetchProfilePosts(
                for: currentProfile,
                cursor: currentProfile.postsNextCursor,
            )
            profile = currentProfile.appendingPosts(page)
        } catch {
            postsErrorMessage = error.localizedDescription
        }
    }

    private func toggleFollow(_ current: NetworkProfile) async {
        guard !isMutatingRelationship, let existing = profile else { return }
        isMutatingRelationship = true
        let target = current.isFollowing != true
        profile = current.withFollowing(target)
        do {
            try await feedService.setFollowing(current, follow: target)
        } catch {
            profile = existing
        }
        isMutatingRelationship = false
    }

    private func togglePostNotifications(_ current: NetworkProfile) async {
        guard !isMutatingRelationship, let existing = profile else { return }
        isMutatingRelationship = true
        let target = current.isNotifiedForPosts != true
        profile = current.withPostNotifications(target)
        do {
            try await feedService.setPostNotifications(current, enabled: target)
        } catch {
            profile = existing
        }
        isMutatingRelationship = false
    }

    private var postGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM", millions)
        }
        if count >= 1000 {
            let thousands = Double(count) / 1000.0
            return String(format: "%.1fK", thousands)
        }
        return "\(count)"
    }

    private func profileURL(for profile: NetworkProfile) -> URL? {
        guard let username = profile.username else { return nil }
        switch profile.network {
        case .farcaster:
            return FarcasterExternalClient.profileURL(username: username)
        case .x:
            return URL(string: "https://x.com/\(username)")
        case .instagram:
            return URL(string: "https://www.instagram.com/\(username)/")
        case .spotify:
            return URL(string: "https://open.spotify.com/user/\(username)")
        case .bluesky:
            return URL(string: "https://bsky.app/profile/\(username)")
        case .github:
            return URL(string: "https://github.com/\(username)")
        case .linkedin:
            return URL(string: "https://www.linkedin.com/in/\(username)/")
        case .apron, .telegram, .discord, .debug:
            return nil
        }
    }
}

/// A profile's posts as its network shows them, under a Posts | Media switch and a Latest | Most Liked order that
/// both tabs share: post cards, or a grid of the posts with photos and videos. `ProfileTimelineViewModel` owns the
/// loads: the first page when a kind is first shown; the profile's list asks for the next as it nears its end.
private struct ProfileTimelineSection: View {
    @ObservedObject var viewModel: ProfileTimelineViewModel
    @Binding var kind: ProfileTimelineKind
    let network: SocialNetwork
    let engaging: (any PostEngaging)?
    let open: (ProfileTimelineItem) -> Void

    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        Section {
            // The card's first row, so it takes the section's rounded top corners.
            Picker("Sort By", selection: Binding(
                get: { kind.isMostLiked },
                set: { kind = ProfileTimelineKind(media: kind.isMedia, mostLiked: $0) },
            )) {
                Text("Latest").tag(false)
                Text("Most Liked").tag(true)
            }
            .onAppear { viewModel.loadIfNeeded(kind) }
            .onChange(of: kind) { _, kind in viewModel.loadIfNeeded(kind) }
            .pickerStyle(.menu)

            switch kind {
            case .posts, .mostLiked:
                ForEach(timeline.items) { item in
                    PostCardView(
                        target: item.post.target,
                        network: network,
                        fallbackActors: [],
                        details: NotificationTargetDetails(likeCount: item.post.engagement?.likeCount, engagement: item.post.engagement),
                        isLoadingDetails: false,
                        engaging: engaging,
                        context: context(of: item),
                        open: { open(item) },
                    )
                }
            case .media, .mediaMostLiked:
                let media = timeline.items.filter { $0.thumbnailURL != nil }
                if !media.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
                        ForEach(media) { item in
                            Button {
                                ProfileMediaViewer.present(timeline: viewModel, kind: kind, itemId: item.id)
                            } label: {
                                ProfileMediaThumbnail(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                }
            }

            footer
        } header: {
            // In the header, outside the card: a row with a clear background would take the card's top corners.
            Picker("Show", selection: Binding(
                get: { kind.isMedia },
                set: { kind = ProfileTimelineKind(media: $0, mostLiked: kind.isMostLiked) },
            )) {
                Text("Posts").tag(false)
                Text("Media").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .textCase(nil)
            .padding(.bottom, 6)
        }
    }

    private var timeline: ProfileTimelineViewModel.Timeline {
        viewModel.timeline(kind)
    }

    /// The error, loading, or that there's nothing to show.
    @ViewBuilder
    private var footer: some View {
        if let errorMessage = timeline.errorMessage {
            VStack(spacing: 8) {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    viewModel.retry(kind)
                }
                .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        } else if timeline.isLoading || !timeline.hasLoaded || timeline.nextCursor != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if !kind.isMedia ? timeline.items.isEmpty : !timeline.items.contains(where: { $0.thumbnailURL != nil }) {
            Text(!kind.isMedia ? "No posts" : "No photos or videos")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func context(of item: ProfileTimelineItem) -> (text: String, systemImage: String)? {
        if let repostedBy = item.repostedBy {
            return ("\(DebugRedaction.name(repostedBy, enabled: redactionEnabled)) reposted", "arrow.2.squarepath")
        }
        return item.isPinned ? ("Pinned", "pin.fill") : nil
    }
}

/// A post from a profile, in its thread when the network loads threads.
private struct ProfilePostView: View {
    let item: ProfileTimelineItem
    let network: SocialNetwork
    let engaging: (any PostEngaging)?
    let threads: (any PostThreadLoading)?

    var body: some View {
        List {
            let details = NotificationTargetDetails(likeCount: item.post.engagement?.likeCount, engagement: item.post.engagement)
            if let threads {
                PostThreadSections(
                    parent: nil,
                    parentDetails: nil,
                    isLoadingParentDetails: false,
                    focal: item.post.target,
                    focalDetails: details,
                    isLoadingFocalDetails: false,
                    network: network,
                    fallbackActors: [],
                    engaging: engaging,
                    threads: threads,
                )
            } else {
                Section {
                    PostCardView(target: item.post.target, network: network, fallbackActors: [], details: details, isLoadingDetails: false, engaging: engaging)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileMediaThumbnail: View {
    let item: ProfileTimelineItem

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = item.thumbnailURL {
                    CachedAsyncImage(url: url) {
                        Color.clear
                    } failure: {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if item.isVideo || item.hasMultipleMedia {
                    Image(systemName: item.isVideo ? "play.fill" : "square.on.square")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(item.post.target.text ?? "Post")
    }
}

private extension NetworkProfile {
    func withFollowing(_ following: Bool) -> NetworkProfile {
        NetworkProfile(
            id: id,
            network: network,
            username: username,
            displayName: displayName,
            bio: bio,
            location: location,
            avatarURL: avatarURL,
            followerCount: followerCount,
            followingCount: followingCount,
            postsCount: postsCount,
            joinedAt: joinedAt,
            websiteURL: websiteURL,
            isVerified: isVerified,
            isMutualFollow: isMutualFollow,
            isFollowing: following,
            isNotifiedForPosts: isNotifiedForPosts,
            posts: posts,
            postsNextCursor: postsNextCursor,
            hasMorePosts: hasMorePosts,
        )
    }

    func withPostNotifications(_ enabled: Bool) -> NetworkProfile {
        NetworkProfile(
            id: id,
            network: network,
            username: username,
            displayName: displayName,
            bio: bio,
            location: location,
            avatarURL: avatarURL,
            followerCount: followerCount,
            followingCount: followingCount,
            postsCount: postsCount,
            joinedAt: joinedAt,
            websiteURL: websiteURL,
            isVerified: isVerified,
            isMutualFollow: isMutualFollow,
            isFollowing: isFollowing,
            isNotifiedForPosts: enabled,
            posts: posts,
            postsNextCursor: postsNextCursor,
            hasMorePosts: hasMorePosts,
        )
    }

    func appendingPosts(_ page: NetworkProfilePostsPage) -> NetworkProfile {
        var seenIds = Set(posts.map(\.id))
        let newPosts = page.posts.filter { post in
            seenIds.insert(post.id).inserted
        }
        return NetworkProfile(
            id: id,
            network: network,
            username: username,
            displayName: displayName,
            bio: bio,
            location: location,
            avatarURL: avatarURL,
            followerCount: followerCount,
            followingCount: followingCount,
            postsCount: postsCount,
            joinedAt: joinedAt,
            websiteURL: websiteURL,
            isVerified: isVerified,
            isMutualFollow: isMutualFollow,
            isFollowing: isFollowing,
            isNotifiedForPosts: isNotifiedForPosts,
            posts: posts + newPosts,
            postsNextCursor: page.nextCursor,
            hasMorePosts: page.hasMore,
        )
    }
}

private struct InstagramPostDetailView: View {
    let post: NetworkProfilePost
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                postMediaView

                VStack(alignment: .leading, spacing: 10) {
                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.body)
                    }

                    if let url = post.url {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: 6) {
                                Text("View on Instagram")
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .navigationTitle("Post")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var postMediaView: some View {
        let media = post.media.isEmpty ? fallbackMedia : post.media
        GeometryReader { proxy in
            let side = proxy.size.width
            if media.count == 1, let item = media.first {
                InstagramPostMediaView(media: item)
                    .frame(width: side, height: side)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 1) {
                        ForEach(media) { item in
                            InstagramPostMediaView(media: item)
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var fallbackMedia: [NetworkProfilePostMedia] {
        post.imageURL.map {
            [NetworkProfilePostMedia(
                id: post.id,
                imageURL: $0,
                thumbnailURL: post.thumbnailURL,
                isVideo: post.isVideo,
            )]
        } ?? []
    }
}

private struct InstagramPostMediaView: View {
    let media: NetworkProfilePostMedia
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if media.isVideo, let videoURL = media.videoURL {
                VideoPlayer(player: player ?? AVPlayer(url: videoURL))
                    .onAppear {
                        let activePlayer = player ?? AVPlayer(url: videoURL)
                        player = activePlayer
                        activePlayer.play()
                    }
                    .onDisappear {
                        player?.pause()
                    }
            } else {
                CachedAsyncImage(url: media.imageURL, contentMode: .fit) {
                    placeholder
                } failure: {
                    placeholder
                }
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
}

private struct ProfilePostThumbnail: View {
    let post: NetworkProfilePost

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Group {
                    if let imageURL = post.thumbnailURL ?? post.imageURL {
                        CachedAsyncImage(url: imageURL) {
                            placeholder
                        } failure: {
                            placeholder
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.width)
                .clipped()

                if post.isVideo {
                    mediaBadge(systemName: "play.fill")
                } else if post.isCarousel {
                    mediaBadge(systemName: "square.on.square")
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.secondary.opacity(0.12))
        .accessibilityLabel(post.caption ?? "Instagram post")
    }

    private func mediaBadge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(7)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
}
