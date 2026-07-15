import AVKit
import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct ProfileDetailView: View {
    let actor: NotificationActor
    let feedService: FeedService
    let initialProfile: NetworkProfile?
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    @State private var profile: NetworkProfile?
    @State private var isLoading = true
    @State private var isHydrating = false
    @State private var isLoadingMorePosts = false
    @State private var errorMessage: String?
    @State private var postsErrorMessage: String?
    @State private var selectedPost: NetworkProfilePost?
    @State private var autoLoadedPostCursors: Set<String> = []

    init(actor: NotificationActor, feedService: FeedService, initialProfile: NetworkProfile? = nil) {
        self.actor = actor
        self.feedService = feedService
        self.initialProfile = initialProfile
        _profile = State(initialValue: initialProfile)
        _isLoading = State(initialValue: initialProfile == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
            } else if let profile {
                profileContent(profile)
            }
        }
        .task { await loadProfile() }
        .navigationTitle("Profile")
        .toolbar {
            if isHydrating {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func profileContent(_ profile: NetworkProfile) -> some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    avatarView(url: profile.avatarURL)
                        .frame(width: 80, height: 80)

                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            if let displayName = profile.displayName, !displayName.isEmpty {
                                Text(DebugRedaction.username(displayName, enabled: devModeEnabled))
                                    .font(.title2.weight(.bold))
                            }
                            if profile.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                            }
                        }
                        if let username = profile.username {
                            Text(devModeEnabled ? "Redacted" : "@\(username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if profile.isMutualFollow == true {
                            Text("You follow each other")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if let bio = profile.bio, !bio.isEmpty {
                Section("Bio") {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary)
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
                        LabeledContent("Posts", value: formatCount(posts))
                    }
                }
            }

            if let joined = profile.joinedAt {
                Section {
                    LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if let website = profile.websiteURL {
                Section {
                    Button {
                        openURL(website)
                    } label: {
                        HStack {
                            Text(website.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if let url = profileURL(for: profile) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 4) {
                            Text("View on \(profile.network.displayName)")
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if profile.network == .instagram, !profile.posts.isEmpty {
                Section {
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
            } else if profile.network == .instagram, let postsErrorMessage {
                Section("Posts") {
                    Text(postsErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
        .navigationDestination(item: $selectedPost) { post in
            InstagramPostDetailView(post: post)
        }
    }

    @ViewBuilder
    private func avatarView(url: URL?) -> some View {
        if let url {
            CachedAsyncImage(url: url) {
                avatarFallback
            } failure: {
                avatarFallback
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
            Text(initial)
                .font(.title.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = actor.username ?? actor.displayName ?? actor.id
        return value.first.map { String($0).uppercased() } ?? "?"
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
            return URL(string: "https://farcaster.xyz/\(username)")
        case .x:
            return URL(string: "https://x.com/\(username)")
        case .instagram:
            return URL(string: "https://www.instagram.com/\(username)/")
        case .spotify:
            return URL(string: "https://open.spotify.com/user/\(username)")
        case .bluesky:
            return URL(string: "https://bsky.app/profile/\(username)")
        case .debug:
            return nil
        }
    }
}

private extension NetworkProfile {
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
            avatarURL: avatarURL,
            followerCount: followerCount,
            followingCount: followingCount,
            postsCount: postsCount,
            joinedAt: joinedAt,
            websiteURL: websiteURL,
            isVerified: isVerified,
            isMutualFollow: isMutualFollow,
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
