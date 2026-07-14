import Foundation

@MainActor
public final class InstagramNotificationSource: NotificationFetching, AccountValidating, ProfileFetching, NotificationTargetDetailFetching, StoryFetching, StoryPosting {
    public let network: SocialNetwork = .instagram

    private let client: InstagramClient
    private let metadataStore: AccountMetadataStore
    private let storyPageSize = 15
    private var storyTrayEntries: [StoryTrayEntry] = []
    private var nextStoryTrayIndex = 0

    public init(client: InstagramClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public var storiesEnabled: Bool {
        metadataStore.instagramAccount?.storiesEnabled ?? true
    }

    public var hasMoreStoryReels: Bool {
        nextStoryTrayIndex < storyTrayEntries.count
    }

    public func ownStoryActor() async -> NotificationActor? {
        guard let account = metadataStore.instagramAccount else { return nil }
        do {
            let profile = try await client.currentUserProfile()
            return NotificationActor(
                id: String(profile.pk),
                network: .instagram,
                username: profile.username,
                displayName: profile.fullName,
                avatarURL: profile.profilePicURL ?? account.avatarURL,
            )
        } catch {
            return NotificationActor(
                id: account.accountId,
                network: .instagram,
                username: account.username,
                displayName: nil,
                avatarURL: account.avatarURL,
            )
        }
    }

    public func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        try await client.publishPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
    }

    public func deleteStory(mediaId: String, isVideo: Bool) async throws {
        try await client.deleteStory(mediaId: mediaId, isVideo: isVideo)
    }

    public func validateAccount() async throws -> AccountStatus {
        do {
            let user = try await client.currentUserProfile()
            let existing = metadataStore.instagramAccount
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: String(user.pk),
                username: user.username,
                avatarURL: user.profilePicURL,
                status: .valid,
                enabledCategories: existing?.enabledCategories,
                storiesEnabled: existing?.storiesEnabled ?? true,
                directMediaSharesEnabled: existing?.directMediaSharesEnabled ?? true,
            )
            return .valid
        } catch {
            invalidateAccount()
            return .notConfigured
        }
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let account = await currentAccountForNotificationTargets()
        let categories = account?.enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        let includeDirectMediaShares = account?.directMediaSharesEnabled ?? true
        return try await client.notifications(
            enabledCategories: categories,
            accountUsername: account?.username,
            accountAvatarURL: account?.avatarURL,
            includeDirectMediaShares: includeDirectMediaShares,
        )
    }

    private func currentAccountForNotificationTargets() async -> InstagramAccountMetadata? {
        guard let account = metadataStore.instagramAccount else { return nil }
        guard account.avatarURL == nil else { return account }
        guard let profile = try? await client.currentUserProfile() else { return account }

        let updated = InstagramAccountMetadata(
            accountId: String(profile.pk),
            username: profile.username,
            avatarURL: profile.profilePicURL,
            status: .valid,
            enabledCategories: account.enabledCategories,
            storiesEnabled: account.storiesEnabled,
            directMediaSharesEnabled: account.directMediaSharesEnabled,
        )
        metadataStore.instagramAccount = updated
        return updated
    }

    public func fetchStoryReels() async throws -> [InstagramStoryReel] {
        try await refreshStoryTray()
        return try await fetchNextStoryReelPage()
    }

    public func fetchNextStoryReelPage() async throws -> [InstagramStoryReel] {
        guard nextStoryTrayIndex < storyTrayEntries.count else { return [] }

        let endIndex = min(nextStoryTrayIndex + storyPageSize, storyTrayEntries.count)
        let pageEntries = Array(storyTrayEntries[nextStoryTrayIndex ..< endIndex])
        nextStoryTrayIndex = endIndex

        return try await storyReels(from: pageEntries)
    }

    private func refreshStoryTray() async throws {
        let tray: [InstagramTrayItem]
        do {
            tray = try await client.reelsTray()
        } catch SourceError.notConfigured {
            invalidateAccount()
            throw SourceError.notConfigured
        } catch {
            invalidateAccount()
            throw error
        }

        // Successful tray fetch means credentials are valid
        if var account = metadataStore.instagramAccount, account.status != .valid {
            account.status = .valid
            metadataStore.instagramAccount = account
        }

        var trayEntries: [StoryTrayEntry] = []
        var seenUserIds: Set<UInt64> = []
        for item in tray {
            let userId = item.user.pk
            let reelId = item.id
            guard !item.isMuted else { continue }
            guard reelId == String(userId) else { continue }
            if seenUserIds.contains(userId) { continue }
            seenUserIds.insert(userId)

            trayEntries.append(StoryTrayEntry(item: item, reelId: reelId))
        }

        storyTrayEntries = trayEntries
        nextStoryTrayIndex = 0
    }

    private func storyReels(from trayEntries: [StoryTrayEntry]) async throws -> [InstagramStoryReel] {
        var reels: [InstagramStoryReel] = []
        for entry in trayEntries {
            let item = entry.item
            let userId = item.user.pk

            let actor = NotificationActor(
                id: String(userId),
                network: .instagram,
                username: item.user.username,
                displayName: item.user.fullName,
                avatarURL: item.user.profilePicUrl.flatMap(URL.init),
            )

            var slides: [InstagramStorySlide] = []
            if let username = item.user.username, let reel = try await client.storyReel(username: username) {
                for media in reel.items ?? [] {
                    if let candidates = media.imageVersions2?.candidates,
                       let best = candidates.sorted(by: { (a: InstagramMediaCandidate, b: InstagramMediaCandidate) in (a.width ?? 0) > (b.width ?? 0) }).first,
                       let imageURL = URL(string: best.url)
                    {
                        let videoVersion = media.videoVersions?.first
                        let videoURL: URL? = videoVersion.flatMap { URL(string: $0.url) }
                        let embed = media.storyFeedMedia?.first { $0.url != nil }
                        let music = media.storyMusicStickers?.compactMap(\.music).first
                        let mentions = media.reelMentions?.compactMap(\.mention) ?? []
                        let links = media.storyLinkStickers?.compactMap(\.link) ?? []
                        let mediaId = media.pk ?? media.id.split(separator: "_").first.map(String.init) ?? media.id
                        slides.append(InstagramStorySlide(
                            id: mediaId,
                            imageURL: imageURL,
                            videoURL: videoURL,
                            isVideo: media.mediaType == 2,
                            videoDuration: media.videoDuration,
                            embedURL: embed?.url,
                            embedLabel: embed?.label,
                            music: music,
                            mentions: mentions,
                            links: links,
                            ownerId: String(reel.user?.pk ?? userId),
                            takenAt: media.takenAt ?? 0,
                            isLiked: media.hasLiked ?? false,
                        ))
                    }
                }
            }

            if !slides.isEmpty {
                slides.sort { $0.takenAt > $1.takenAt }
                let latestSlideTakenAt = slides.first?.takenAt ?? 0
                let isSeen = item.seen > 0 && Double(item.seen) >= latestSlideTakenAt
                reels.append(InstagramStoryReel(
                    id: entry.reelId,
                    user: actor,
                    slides: slides,
                    isSeen: isSeen,
                    hasCloseFriendsMedia: item.hasBestiesMedia,
                ))
            }
        }

        return reels
    }

    private struct StoryTrayEntry {
        let item: InstagramTrayItem
        let reelId: String
    }

    private func invalidateAccount() {
        guard var account = metadataStore.instagramAccount else { return }
        account.status = .invalidCredentials
        metadataStore.instagramAccount = account
    }

    public func markReelAsSeen(slides: [InstagramStorySlide]) async {
        let items = slides.map { slide in
            (mediaId: slide.id, ownerId: slide.ownerId, takenAt: slide.takenAt)
        }
        try? await client.markStorySeen(mediaItems: items)
    }

    public func setStoryLiked(mediaId: String, liked: Bool) async throws {
        try await client.setMediaLiked(mediaId: mediaId, liked: liked)
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        let response = try await client.userInfo(uid: id)
        let postLookupId = response.user.username ?? response.user.pk.map(String.init) ?? id
        let postsPage: NetworkProfilePostsPage? = if !postLookupId.isEmpty {
            try await client.userPostsPage(uid: postLookupId, cursor: nil)
        } else {
            nil
        }

        if (response.user.mediaCount ?? 0) > 0, postsPage?.posts.isEmpty != false {
            throw SourceError.serviceError("Instagram profile has posts, but no posts were decoded.")
        }
        return networkProfile(from: response.user, postsPage: postsPage)
    }

    public func fetchProfilePosts(id: String, cursor: String?, count: Int) async throws -> NetworkProfilePostsPage {
        try await client.userPostsPage(uid: id, cursor: cursor, count: count)
    }

    public func searchProfiles(query: String) async throws -> [NetworkProfile] {
        try await client.searchUsers(query: query).map { networkProfile(from: $0) }
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        guard let mediaId = item.target?.id else {
            throw SourceError.unsupported
        }

        let response = try await client.mediaInfo(mediaId: mediaId)
        guard let media = response.items.first else {
            throw SourceError.invalidResponse
        }

        let author = media.user.map { user in
            NotificationActor(
                id: user.pk.map(String.init) ?? user.username ?? mediaId,
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicUrl.flatMap(URL.init),
            )
        }

        return NotificationTargetDetails(
            author: author,
            text: media.caption?.text,
            imageURLs: media.bestImageURLs,
            postedAt: media.takenAt.map { Date(timeIntervalSince1970: $0) },
            likeCount: media.likeCount,
        )
    }

    private func networkProfile(from user: InstagramUserInfoResponse.InfoUser, postsPage: NetworkProfilePostsPage? = nil) -> NetworkProfile {
        NetworkProfile(
            id: String(user.pk ?? 0),
            network: .instagram,
            username: user.username,
            displayName: user.fullName,
            bio: user.biography,
            avatarURL: user.profilePicUrl.flatMap(URL.init),
            followerCount: user.followerCount,
            followingCount: user.followingCount,
            postsCount: user.mediaCount,
            websiteURL: user.externalUrl.flatMap(URL.init),
            isVerified: user.isVerified,
            isMutualFollow: (user.friendshipStatus?.following == true && user.friendshipStatus?.followedBy == true) ? true : nil,
            posts: postsPage?.posts ?? [],
            postsNextCursor: postsPage?.nextCursor,
            hasMorePosts: postsPage?.hasMore ?? false,
        )
    }
}
