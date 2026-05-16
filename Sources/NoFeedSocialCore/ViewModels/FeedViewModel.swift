import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var storyBarItems: [StoryBarItem] = []
    @Published public private(set) var ownInstagramStoryActor: NotificationActor?
    @Published public private(set) var ownInstagramStoryReel: InstagramStoryReel?
    @Published public private(set) var storyBarContentLoaded = false
    @Published public private(set) var storyBarLoading = false
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
        let fetchedReels = await reels ?? instagramStoryReels
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
        ownInstagramStoryReel = ownReel
        orderedInstagramStoryReels = instagramReels
        storyBarItems = mergedStoryBarItems(instagramReels: instagramReels, spotifyItems: fetchedSpots)
        storyBarContentLoaded = true
        storyBarLoading = false
    }

    public func postInstagramStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.postPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
        await fetchStoryBarContent()
    }

    public func deleteInstagramStory(mediaId: String, isVideo: Bool) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.deleteStory(mediaId: mediaId, isVideo: isVideo)
        await fetchStoryBarContent()
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

    public func storyViewerItems(for selectedIndex: Int) -> [StoryBarItem] {
        guard storyBarItems.indices.contains(selectedIndex) else { return storyBarItems }
        let selected = storyBarItems[selectedIndex]
        switch selected {
        case let .instagram(reel):
            return storyBarItems.filter { $0.isSeen == reel.isSeen }
        case let .spotify(item):
            return storyBarItems.filter { $0.isSeen == item.isSeen }
        }
    }

    public func storyViewerStartIndex(for selectedItem: StoryBarItem, in items: [StoryBarItem]) -> Int {
        items.firstIndex(where: { $0.id == selectedItem.id }) ?? 0
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
}

private extension InstagramStoryReel {
    var timestamp: Date {
        Date(timeIntervalSince1970: slides.first?.takenAt ?? 0)
    }
}
