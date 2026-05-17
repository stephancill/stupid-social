import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var storyBarItems: [StoryBarItem] = []
    @Published public private(set) var ownInstagramStoryActor: NotificationActor?
    @Published public private(set) var ownInstagramStoryReel: InstagramStoryReel?
    @Published public private(set) var storyBarContentLoaded = false
    @Published public private(set) var storyBarLoading = false
    @Published public private(set) var storyBarNextPageLoading = false
    @Published public private(set) var pendingNewCount = 0
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService
    private let instagramSource: InstagramNotificationSource?
    private let spotifyActivitySource: SpotifyActivitySource?
    private let spotifySeenDefaultsKey = "spotifyActivitySeenTimestamps"
    private let chronologicalInstagramPrefixCount = 15
    private var orderedInstagramStoryReels: [InstagramStoryReel] = []
    private var hasMoreInstagramStoryReels = false
    private var optimisticInstagramStorySlideID: String?

    public var service: FeedService {
        feedService
    }

    public init(feedService: FeedService, instagramSource: InstagramNotificationSource?, spotifyActivitySource: SpotifyActivitySource? = nil) {
        self.feedService = feedService
        self.instagramSource = instagramSource
        self.spotifyActivitySource = spotifyActivitySource
    }

    public func loadCachedFeed() {
        do {
            items = try feedService.loadCachedFeed()
            pendingNewCount = feedService.pendingNewCount()
        } catch {
            errorMessage = "Could not load cached notifications."
        }
    }

    public func refresh() async {
        guard !isRefreshing, !isForegroundRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            items = try await feedService.manualRefresh()
            pendingNewCount = feedService.pendingNewCount()
            errorMessage = nil
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? "Refresh failed."
        } catch {
            errorMessage = "Refresh failed."
        }

        await fetchStoryBarContent()
    }

    public func markAllRead() {
        items = feedService.markAllRead(items: items)
    }

    public func refreshOnForegroundActivation() async {
        guard !isRefreshing, !isForegroundRefreshing else { return }
        isForegroundRefreshing = true
        defer { isForegroundRefreshing = false }

        do {
            try await feedService.foregroundActivationRefresh()
            items = try feedService.loadCachedFeed()
            pendingNewCount = feedService.pendingNewCount()
            errorMessage = nil
        } catch {
            errorMessage = "Foreground refresh failed."
        }

        await fetchStoryBarContent()
    }

    public func revealPendingNotifications() {
        do {
            items = try feedService.revealPendingNotifications()
            pendingNewCount = feedService.pendingNewCount()
        } catch {
            errorMessage = "Could not load new notifications."
        }
    }

    public func fetchInstagramStories() async {
        await fetchStoryBarContent()
    }

    public func fetchSpotifyActivity() async {
        await fetchStoryBarContent()
    }

    public func fetchStoryBarContent() async {
        storyBarLoading = true
        async let reels = instagramReels()
        async let spots = spotifyItems()
        async let ownInstagramActor = instagramSource?.ownStoryActor()
        let fallbackInstagramReels = ([ownInstagramStoryReel].compactMap(\.self) + instagramStoryReels)
        let fetchedReels = await reels ?? fallbackInstagramReels
        let fetchedSpots = await spots
        let fetchedOwnInstagramActor = await ownInstagramActor ?? ownInstagramStoryActor
        ownInstagramStoryActor = fetchedOwnInstagramActor

        var ownReel: InstagramStoryReel?
        var instagramReels: [InstagramStoryReel] = []
        for reel in fetchedReels {
            if let fetchedOwnInstagramActor, reel.user.id == fetchedOwnInstagramActor.id {
                ownReel = reel
                continue
            }
            instagramReels.append(reel)
        }
        ownInstagramStoryReel = preservingOptimisticStorySlide(in: ownReel)
        orderedInstagramStoryReels = instagramReels
        hasMoreInstagramStoryReels = instagramSource?.hasMoreStoryReels ?? false
        storyBarItems = mergedStoryBarItems(instagramReels: instagramReels, spotifyItems: fetchedSpots)
        storyBarContentLoaded = true
        storyBarLoading = false
    }

    public func loadNextStoryBarPageIfNeeded(currentItem item: StoryBarItem) async {
        switch item {
        case let .instagram(reel):
            guard reel.id == orderedInstagramStoryReels.last?.id else { return }
        case .spotify:
            guard item.id == storyBarItems.last?.id else { return }
        }
        await loadNextStoryBarPage()
    }

    public func loadNextStoryBarPage() async {
        guard !storyBarLoading, !storyBarNextPageLoading, hasMoreInstagramStoryReels else { return }
        guard let instagramSource, instagramSource.storiesEnabled else { return }
        storyBarNextPageLoading = true
        defer { storyBarNextPageLoading = false }

        do {
            let nextReels = try await instagramSource.fetchNextStoryReelPage()
            hasMoreInstagramStoryReels = instagramSource.hasMoreStoryReels
            guard !nextReels.isEmpty else { return }

            let existingReelIds = Set(orderedInstagramStoryReels.map(\.id))
            var appendedReels = nextReels.filter { !existingReelIds.contains($0.id) }
            if let ownInstagramStoryActor {
                appendedReels.removeAll { reel in
                    if reel.user.id == ownInstagramStoryActor.id {
                        ownInstagramStoryReel = preservingOptimisticStorySlide(in: reel)
                        return true
                    }
                    return false
                }
            }

            orderedInstagramStoryReels.append(contentsOf: appendedReels)
            storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems)
        } catch {
            hasMoreInstagramStoryReels = instagramSource.hasMoreStoryReels
        }
    }

    public func postInstagramStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        let actor: NotificationActor? = if let ownInstagramStoryActor {
            ownInstagramStoryActor
        } else {
            await instagramSource.ownStoryActor()
        }
        guard let actor else { throw SourceError.notConfigured }

        let previewURL = try writeOptimisticStoryPreview(imageData: imageData, mimeType: mimeType)
        let slideID = "optimistic-instagram-story-\(UUID().uuidString)"
        optimisticInstagramStorySlideID = slideID
        ownInstagramStoryActor = actor
        insertOptimisticInstagramStory(actor: actor, slideID: slideID, imageURL: previewURL)

        Task {
            do {
                try await instagramSource.postPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
                await fetchStoryBarContent()
            } catch {
                removeOptimisticInstagramStory(slideID: slideID)
                errorMessage = "Could not post Instagram story."
            }
        }
    }

    public func deleteInstagramStory(mediaId: String, isVideo: Bool) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.deleteStory(mediaId: mediaId, isVideo: isVideo)
        await fetchStoryBarContent()
    }

    public func setInstagramStoryLiked(mediaId: String, liked: Bool) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.setStoryLiked(mediaId: mediaId, liked: liked)
        updateInstagramStorySlide(mediaId: mediaId) { slide in
            InstagramStorySlide(
                id: slide.id,
                imageURL: slide.imageURL,
                videoURL: slide.videoURL,
                isVideo: slide.isVideo,
                videoDuration: slide.videoDuration,
                embedURL: slide.embedURL,
                embedLabel: slide.embedLabel,
                music: slide.music,
                mentions: slide.mentions,
                links: slide.links,
                ownerId: slide.ownerId,
                takenAt: slide.takenAt,
                isLiked: liked,
            )
        }
    }

    private func instagramReels() async -> [InstagramStoryReel]? {
        guard let instagramSource, instagramSource.storiesEnabled else { return [] }
        do {
            return try await instagramSource.fetchStoryReels()
        } catch SourceError.notConfigured {
            return []
        } catch {
            return nil
        }
    }

    private func spotifyItems() async -> [SpotifyActivityItem] {
        guard let spotifyActivitySource else { return [] }
        do {
            var seenUserURIs = Set<String>()
            return try await spotifyActivitySource.fetchActivity(reason: .manual)
                .sorted { $0.timestamp > $1.timestamp }
                .filter { item in
                    seenUserURIs.insert(item.userURI).inserted
                }
                .map(spotifyItemWithSeenState)
                .sorted { a, b in
                    if a.isSeen != b.isSeen {
                        return !a.isSeen
                    }
                    return a.timestamp > b.timestamp
                }
        } catch {
            return []
        }
    }

    private func spotifyItemWithSeenState(_ item: SpotifyActivityItem) -> SpotifyActivityItem {
        let seenTimestamps = UserDefaults.standard.dictionary(forKey: spotifySeenDefaultsKey) as? [String: Double] ?? [:]
        let seenTimestamp = seenTimestamps[item.userURI] ?? 0
        return SpotifyActivityItem(
            id: item.id,
            timestamp: item.timestamp,
            userName: item.userName,
            userURI: item.userURI,
            userAvatarURL: item.userAvatarURL,
            trackName: item.trackName,
            artistName: item.artistName,
            albumName: item.albumName,
            contextName: item.contextName,
            trackURI: item.trackURI,
            trackURL: item.trackURL,
            imageURL: item.imageURL,
            musicAnimation: item.musicAnimation,
            isSeen: seenTimestamp >= item.timestamp.timeIntervalSince1970,
        )
    }

    public func markSpotifyActivityAsSeen(userURI: String) {
        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .spotify(item) = $0, item.userURI == userURI { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .spotify(item) = storyItem else { return }

        var seenTimestamps = UserDefaults.standard.dictionary(forKey: spotifySeenDefaultsKey) as? [String: Double] ?? [:]
        seenTimestamps[userURI] = max(seenTimestamps[userURI] ?? 0, item.timestamp.timeIntervalSince1970)
        UserDefaults.standard.set(seenTimestamps, forKey: spotifySeenDefaultsKey)

        let updated = spotifyItemWithSeenState(item)
        storyBarItems[itemIndex] = .spotify(updated)
        storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems)
    }

    public func markInstagramReelAsSeen(reelIndex: Int) {
        guard instagramStoryReels.indices.contains(reelIndex) else { return }
        let reel = instagramStoryReels[reelIndex]
        guard !reel.isSeen else { return }
        markInstagramReelAsSeen(reelId: reel.id)
    }

    public func markInstagramReelAsSeen(reelId: String) {
        if let reel = ownInstagramStoryReel, reel.id == reelId, !reel.isSeen {
            Task {
                await instagramSource?.markReelAsSeen(slides: reel.slides)
            }

            ownInstagramStoryReel = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
            return
        }

        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .instagram(reel) = $0, reel.id == reelId { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .instagram(reel) = storyItem, !reel.isSeen else { return }

        Task {
            await instagramSource?.markReelAsSeen(slides: reel.slides)
        }

        let updated = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
        if let orderedIndex = orderedInstagramStoryReels.firstIndex(where: { $0.id == reel.id }) {
            orderedInstagramStoryReels[orderedIndex] = updated
        }
        storyBarItems[itemIndex] = .instagram(updated)
    }

    public func storyViewerItems(for selectedItem: StoryBarItem, in visibleItems: [StoryBarItem]) -> [StoryBarItem] {
        let items = visibleItems.filter { $0.isSeen == selectedItem.isSeen }
        guard !selectedItem.isSeen else { return items }

        return items
            .map(storyItemWithOldestFirstSlides)
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            }
    }

    public func storyViewerStartIndex(for selectedItem: StoryBarItem, in items: [StoryBarItem]) -> Int {
        guard selectedItem.isSeen else { return 0 }
        return items.firstIndex(where: { $0.id == selectedItem.id }) ?? 0
    }

    private func storyItemWithOldestFirstSlides(_ item: StoryBarItem) -> StoryBarItem {
        guard case let .instagram(reel) = item else { return item }
        let slides = reel.slides.sorted { lhs, rhs in
            if lhs.takenAt == rhs.takenAt {
                return lhs.id < rhs.id
            }
            return lhs.takenAt < rhs.takenAt
        }
        return .instagram(InstagramStoryReel(id: reel.id, user: reel.user, slides: slides, isSeen: reel.isSeen, hasCloseFriendsMedia: reel.hasCloseFriendsMedia))
    }

    public func performCredentialHealthCheck() async {
        await feedService.healthCheckAllSources()
    }

    var instagramStoryReels: [InstagramStoryReel] {
        storyBarItems.compactMap {
            if case let .instagram(reel) = $0 { return reel }
            return nil
        }
    }

    var spotifyActivityItems: [SpotifyActivityItem] {
        storyBarItems.compactMap {
            if case let .spotify(item) = $0 { return item }
            return nil
        }
    }

    private func mergedStoryBarItems(instagramReels: [InstagramStoryReel], spotifyItems: [SpotifyActivityItem]) -> [StoryBarItem] {
        let chronologicalInstagram = instagramReels.prefix(chronologicalInstagramPrefixCount).map(StoryBarItem.instagram)
        let chronologicalSpotify = spotifyItems.map(StoryBarItem.spotify)
        let chronologicalItems = (chronologicalInstagram + chronologicalSpotify).sorted { $0.timestamp > $1.timestamp }
        let remainingInstagram = instagramReels.dropFirst(chronologicalInstagramPrefixCount).map(StoryBarItem.instagram)

        return chronologicalItems + remainingInstagram
    }

    private func writeOptimisticStoryPreview(imageData: Data, mimeType: String) throws -> URL {
        let fileExtension = mimeType == "image/webp" ? "webp" : "jpg"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoFeedSocialOptimisticStories", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try imageData.write(to: url, options: .atomic)
        return url
    }

    private func insertOptimisticInstagramStory(actor: NotificationActor, slideID: String, imageURL: URL) {
        let optimisticSlide = InstagramStorySlide(
            id: slideID,
            imageURL: imageURL,
            videoURL: nil,
            isVideo: false,
            ownerId: actor.id,
            takenAt: Date().timeIntervalSince1970,
        )

        let existingSlides = ownInstagramStoryReel?.slides.filter { $0.id != slideID } ?? []
        ownInstagramStoryReel = InstagramStoryReel(
            id: actor.id,
            user: actor,
            slides: [optimisticSlide] + existingSlides,
            isSeen: false,
            hasCloseFriendsMedia: ownInstagramStoryReel?.hasCloseFriendsMedia ?? false,
        )
        storyBarContentLoaded = true
    }

    private func preservingOptimisticStorySlide(in fetchedReel: InstagramStoryReel?) -> InstagramStoryReel? {
        guard let optimisticInstagramStorySlideID,
              let optimisticSlide = ownInstagramStoryReel?.slides.first(where: { $0.id == optimisticInstagramStorySlideID })
        else { return fetchedReel }

        if let fetchedReel {
            guard !fetchedReel.slides.contains(where: { $0.id == optimisticInstagramStorySlideID }) else { return fetchedReel }
            if fetchedReel.slides.contains(where: { $0.takenAt >= optimisticSlide.takenAt - 60 }) {
                self.optimisticInstagramStorySlideID = nil
                return fetchedReel
            }
            return InstagramStoryReel(
                id: fetchedReel.id,
                user: fetchedReel.user,
                slides: [optimisticSlide] + fetchedReel.slides,
                isSeen: false,
                hasCloseFriendsMedia: fetchedReel.hasCloseFriendsMedia,
            )
        }

        guard let actor = ownInstagramStoryActor ?? ownInstagramStoryReel?.user else { return nil }
        return InstagramStoryReel(id: actor.id, user: actor, slides: [optimisticSlide], isSeen: false)
    }

    private func removeOptimisticInstagramStory(slideID: String) {
        guard optimisticInstagramStorySlideID == slideID, let reel = ownInstagramStoryReel else { return }
        optimisticInstagramStorySlideID = nil
        let slides = reel.slides.filter { $0.id != slideID }
        ownInstagramStoryReel = slides.isEmpty
            ? nil
            : InstagramStoryReel(
                id: reel.id,
                user: reel.user,
                slides: slides,
                isSeen: reel.isSeen,
                hasCloseFriendsMedia: reel.hasCloseFriendsMedia,
            )
    }

    private func updateInstagramStorySlide(mediaId: String, transform: @escaping (InstagramStorySlide) -> InstagramStorySlide) {
        let updateReel: (InstagramStoryReel) -> InstagramStoryReel = { reel in
            let slides = reel.slides.map { slide in
                slide.id == mediaId ? transform(slide) : slide
            }
            return InstagramStoryReel(id: reel.id, user: reel.user, slides: slides, isSeen: reel.isSeen, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
        }

        if let ownReel = ownInstagramStoryReel, ownReel.slides.contains(where: { $0.id == mediaId }) {
            ownInstagramStoryReel = updateReel(ownReel)
        }

        orderedInstagramStoryReels = orderedInstagramStoryReels.map { reel in
            reel.slides.contains(where: { $0.id == mediaId }) ? updateReel(reel) : reel
        }
        storyBarItems = storyBarItems.map { item in
            guard case let .instagram(reel) = item, reel.slides.contains(where: { $0.id == mediaId }) else { return item }
            return .instagram(updateReel(reel))
        }
    }
}

private extension InstagramStoryReel {
    var timestamp: Date {
        Date(timeIntervalSince1970: slides.first?.takenAt ?? 0)
    }
}
