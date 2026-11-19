import Foundation

@MainActor
public final class InstagramNotificationSource: NotificationFetching, ProfileFetching, NotificationTargetDetailFetching, StoryFetching, StoryPosting, RelationshipMutating {
    public let network: SocialNetwork = .instagram

    private let client: InstagramClient
    private let metadataStore: AccountMetadataStore
    private var storyTrayEntries: [StoryTrayEntry] = []
    private var storyTrayFetchedAt: Date?
    private var lastNotifications: (fetchedAt: Date, items: [NotificationItem])?
    /// Reels whose story page has loaded, kept while the tray lists the same newest media for them.
    private var loadedReels: [String: InstagramStoryReel] = [:]
    private var reelLoads: [String: Task<InstagramStoryReel, Error>] = [:]

    /// Automatic refreshes (opening the app) reuse what was fetched this recently; pull-to-refresh always fetches.
    /// Instagram's web client fetches notifications and stories only when a page loads, and opening the app
    /// many times an hour otherwise sent a burst of requests each time.
    static let automaticRefreshInterval: TimeInterval = 5 * 60

    public init(client: InstagramClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public var storiesEnabled: Bool {
        metadataStore.instagramAccount?.storiesEnabled ?? true
    }

    public func ownStoryActor() async -> NotificationActor? {
        guard let account = metadataStore.instagramAccount else { return nil }
        if account.avatarURL != nil, let username = account.username, !username.isEmpty {
            return NotificationActor(
                id: account.accountId,
                network: .instagram,
                username: account.username,
                displayName: nil,
                avatarURL: account.avatarURL,
            )
        }
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

    public func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String, mentions: [InstagramStoryMentionPlacement], closeFriends: Bool) async throws {
        try await client.publishPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType, mentions: mentions, closeFriends: closeFriends)
    }

    public func deleteStory(mediaId: String, isVideo: Bool) async throws {
        try await client.deleteStory(mediaId: mediaId, isVideo: isVideo)
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        if reason != .manual, let lastNotifications, Date().timeIntervalSince(lastNotifications.fetchedAt) < Self.automaticRefreshInterval {
            return lastNotifications.items
        }
        let account = await currentAccountForNotificationTargets()
        let categories = account?.enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        let includeDirectMediaShares = account?.directMediaSharesEnabled ?? true
        let items = try await reportingStatus {
            try await client.notifications(
                enabledCategories: categories,
                accountUsername: account?.username,
                accountAvatarURL: account?.avatarURL,
                includeDirectMediaShares: includeDirectMediaShares,
            )
        }
        lastNotifications = (Date(), items)
        return items
    }

    private func currentAccountForNotificationTargets() async -> InstagramAccountMetadata? {
        guard let account = metadataStore.instagramAccount else { return nil }
        guard account.avatarURL == nil || account.username?.isEmpty != false else { return account }
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

    /// Everyone in the tray, without their stories: `loadStoryReel(id:)` loads a person's stories when the viewer
    /// gets to them, as Instagram's web client does, instead of a story page per person on every refresh.
    public func fetchStoryReels(reason: RefreshReason) async throws -> [InstagramStoryReel] {
        if reason == .manual || storyTrayFetchedAt.map({ Date().timeIntervalSince($0) >= Self.automaticRefreshInterval }) ?? true {
            try await refreshStoryTray()
        }
        return storyTrayEntries.map(reel(for:))
    }

    public func loadStoryReel(id: String) async throws -> InstagramStoryReel {
        if let loaded = loadedReels[id], let entry = storyTrayEntries.first(where: { $0.reelId == id }) {
            return reel(for: entry, slides: loaded.slides)
        }
        if let inFlight = reelLoads[id] { return try await inFlight.value }
        guard let entry = storyTrayEntries.first(where: { $0.reelId == id }) else { throw SourceError.invalidResponse }
        let task = Task { try await self.fetchStoryReel(entry) }
        reelLoads[id] = task
        defer { reelLoads[id] = nil }
        let reel = try await task.value
        loadedReels[id] = reel
        return reel
    }

    private func refreshStoryTray() async throws {
        let tray = try await reportingStatus {
            try await RefreshTiming.measure("instagram-story-tray") {
                try await client.reelsTray()
            }
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

            trayEntries.append(StoryTrayEntry(item: item, reelId: reelId, seen: Double(item.seen)))
        }

        let latestMedia = Dictionary(trayEntries.map { ($0.reelId, $0.item.latestReelMedia) }, uniquingKeysWith: { first, _ in first })
        loadedReels = loadedReels.filter { id, reel in
            latestMedia[id].map { $0 == reel.latestMediaAt } ?? false
        }
        storyTrayEntries = trayEntries
        storyTrayFetchedAt = Date()
    }

    /// Runs a request that tells whether the account works: a dead session marks it invalid, being rate limited
    /// marks it so, and success marks it valid.
    private func reportingStatus<T>(_ request: () async throws -> T) async throws -> T {
        do {
            let result = try await request()
            setStatus(.valid)
            return result
        } catch SourceError.notConfigured {
            setStatus(.invalidCredentials)
            throw SourceError.notConfigured
        } catch let SourceError.rateLimited(until) {
            setStatus(.rateLimited)
            throw SourceError.rateLimited(until: until)
        }
    }

    private func setStatus(_ status: AccountStatusSnapshot) {
        guard var account = metadataStore.instagramAccount, account.status != status else { return }
        account.status = status
        metadataStore.instagramAccount = account
    }

    private func actor(for item: InstagramTrayItem) -> NotificationActor {
        NotificationActor(
            id: String(item.user.pk),
            network: .instagram,
            username: item.user.username,
            displayName: item.user.fullName,
            avatarURL: item.user.profilePicUrl.flatMap(URL.init),
        )
    }

    private func reel(for entry: StoryTrayEntry) -> InstagramStoryReel {
        reel(for: entry, slides: loadedReels[entry.reelId]?.slides ?? [])
    }

    /// A tray entry as a reel. `seen` is when the viewer last saw the person's stories, so they are seen once it
    /// reaches the newest one.
    private func reel(for entry: StoryTrayEntry, slides: [InstagramStorySlide]) -> InstagramStoryReel {
        let latestMediaAt = entry.item.latestReelMedia ?? slides.map(\.takenAt).max() ?? 0
        return InstagramStoryReel(
            id: entry.reelId,
            user: actor(for: entry.item),
            slides: slides,
            isSeen: entry.seen > 0 && entry.seen >= latestMediaAt,
            seenTimestamp: entry.seen,
            hasCloseFriendsMedia: entry.item.hasBestiesMedia,
            latestMediaAt: latestMediaAt,
        )
    }

    private func fetchStoryReel(_ entry: StoryTrayEntry) async throws -> InstagramStoryReel {
        guard let username = entry.item.user.username else { throw SourceError.invalidResponse }
        let fetched = try await reportingStatus {
            try await RefreshTiming.measure("instagram-story-reel") {
                try await client.storyReel(username: username)
            }
        }
        let userId = entry.item.user.pk
        var slides: [InstagramStorySlide] = []
        for media in fetched?.items ?? [] {
            guard let imageURL = media.bestImageURL else { continue }
            let videoVersion = media.videoVersions?.first
            let embed = media.storyFeedMedia?.first { $0.url != nil }
            slides.append(InstagramStorySlide(
                id: media.pk ?? media.id.split(separator: "_").first.map(String.init) ?? media.id,
                imageURL: imageURL,
                videoURL: videoVersion.flatMap { URL(string: $0.url) },
                isVideo: media.mediaType == 2,
                videoDuration: media.videoDuration,
                embedURL: embed?.url,
                embedLabel: embed?.label,
                music: media.storyMusicStickers?.compactMap(\.music).first,
                mentions: storyMentions(from: media),
                links: media.storyLinkStickers?.compactMap(\.link) ?? [],
                ownerId: String(fetched?.user?.pk ?? userId),
                takenAt: media.takenAt ?? 0,
                isLiked: media.hasLiked ?? false,
            ))
        }
        guard !slides.isEmpty else { throw SourceError.serviceError("These stories are no longer available.") }
        slides.sort { $0.takenAt > $1.takenAt }
        return reel(for: entry, slides: slides)
    }

    private struct StoryTrayEntry {
        let item: InstagramTrayItem
        let reelId: String
        /// The tray's `seen`, moved forward when the user sees the stories here.
        var seen: Double
    }

    private func storyMentions(from media: InstagramStoryMedia) -> [InstagramStoryMention] {
        var mentions = (media.reelMentions?.compactMap(\.mention) ?? []) + (media.storyBloksStickers?.compactMap(\.mention) ?? [])
        var seenUsernames: Set<String> = []
        mentions.removeAll { mention in
            let key = mention.username.lowercased()
            if seenUsernames.contains(key) {
                return true
            }
            seenUsernames.insert(key)
            return false
        }
        return mentions
    }

    public func markReelAsSeen(slides: [InstagramStorySlide]) async throws {
        let items = slides.map { slide in
            (mediaId: slide.id, ownerId: slide.ownerId, takenAt: slide.takenAt)
        }
        try await client.markStorySeen(mediaItems: items)
        // Until the tray is fetched again, it would otherwise show these stories as unseen.
        guard let ownerId = slides.first?.ownerId, let newest = slides.map(\.takenAt).max(),
              let index = storyTrayEntries.firstIndex(where: { $0.reelId == ownerId }) else { return }
        storyTrayEntries[index].seen = max(storyTrayEntries[index].seen, newest)
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

        if response.user.isPrivate != true, (response.user.mediaCount ?? 0) > 0, postsPage?.posts.isEmpty != false {
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

        if let storyDetails = try await fetchStoryTargetDetails(item: item, mediaId: storyTargetMediaID(item: item, fallback: mediaId)) {
            return storyDetails
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

    private func fetchStoryTargetDetails(item: NotificationItem, mediaId: String) async throws -> NotificationTargetDetails? {
        guard item.target?.url?.pathComponents.contains("stories") == true || item.text.localizedCaseInsensitiveContains("liked your story") else {
            return nil
        }
        guard let reel = try await storyReel(for: item), let media = bestStoryMedia(from: reel, mediaId: mediaId) else {
            return nil
        }
        guard let imageURL = media.bestImageURL else {
            return nil
        }

        let author = reel.user.map { user in
            NotificationActor(
                id: String(user.pk),
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicUrl.flatMap(URL.init),
            )
        } ?? item.target?.author

        return NotificationTargetDetails(
            author: author,
            text: item.target?.text,
            imageURLs: [imageURL],
            postedAt: media.takenAt.map { Date(timeIntervalSince1970: $0) } ?? item.target?.postedAt,
            likeCount: item.target?.likeCount,
        )
    }

    private func storyReel(for item: NotificationItem) async throws -> InstagramReel? {
        if let archiveReelId = archiveReelID(from: item.target?.url) {
            return try await client.archivedStoryReel(archiveReelId: archiveReelId)
        }
        guard let username = item.target?.author?.username ?? metadataStore.instagramAccount?.username else {
            return nil
        }
        return try await client.storyReel(username: username)
    }

    private func bestStoryMedia(from reel: InstagramReel, mediaId: String) -> InstagramStoryMedia? {
        let items = reel.items ?? []
        return items.first(where: { storyMediaId($0) == strippedMediaId(mediaId) })
    }

    private func storyMediaId(_ media: InstagramStoryMedia) -> String {
        media.pk ?? strippedMediaId(media.id)
    }

    private func strippedMediaId(_ mediaId: String) -> String {
        mediaId.split(separator: "_").first.map(String.init) ?? mediaId
    }

    private func storyTargetMediaID(item: NotificationItem, fallback: String) -> String {
        guard let url = item.target?.url else { return fallback }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let initialMediaId = components.queryItems?.first(where: { $0.name == "initial_media_id" })?.value,
           !initialMediaId.isEmpty
        {
            return initialMediaId
        }
        let numericPathComponent = url.pathComponents.reversed().first { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }
        return numericPathComponent ?? fallback
    }

    private func archiveReelID(from url: URL?) -> String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let archiveIndex = components.firstIndex(of: "archive") else { return nil }
        let idIndex = components.index(after: archiveIndex)
        guard components.indices.contains(idIndex) else { return nil }
        return components[idIndex].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func setFollowing(profile: NetworkProfile, follow: Bool) async throws {
        try await client.setUserFollowed(userId: profile.id, follow: follow)
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
            isFollowing: user.friendshipStatus?.following ?? user.followedByViewer,
            posts: postsPage?.posts ?? [],
            postsNextCursor: postsPage?.nextCursor,
            hasMorePosts: postsPage?.hasMore ?? false,
        )
    }
}
