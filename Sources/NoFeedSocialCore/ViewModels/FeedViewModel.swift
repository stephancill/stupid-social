import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var storyBarItems: [StoryBarItem] = []
    @Published public private(set) var storyBarLoading = false
    @Published public private(set) var pendingNewCount = 0
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService
    private let instagramSource: InstagramNotificationSource?
    private let spotifyActivitySource: SpotifyActivitySource?
    private let spotifySeenDefaultsKey = "spotifyActivitySeenTimestamps"

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
        guard !isRefreshing else { return }
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
        let fetchedReels = await reels ?? instagramStoryReels
        let fetchedSpots = await spots

        var merged: [StoryBarItem] = []
        for reel in fetchedReels {
            merged.append(.instagram(reel))
        }
        for item in fetchedSpots {
            merged.append(.spotify(item))
        }
        sortStoryBarItems(&merged)
        storyBarItems = merged
        storyBarLoading = false
    }

    private func instagramReels() async -> [InstagramStoryReel]? {
        guard let instagramSource, instagramSource.storiesEnabled else { return [] }
        do {
            var reels = try await instagramSource.fetchStoryReels()
            sortReels(&reels)
            return reels
        } catch SourceError.notConfigured {
            return []
        } catch {
            return nil
        }
    }

    private func sortReels(_ reels: inout [InstagramStoryReel]) {
        reels.sort { a, b in
            if a.isSeen != b.isSeen {
                return !a.isSeen
            }
            let latestA = a.slides.first?.takenAt ?? 0
            let latestB = b.slides.first?.takenAt ?? 0
            return latestA > latestB
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
            trackURI: item.trackURI,
            trackURL: item.trackURL,
            imageURL: item.imageURL,
            musicAnimation: item.musicAnimation,
            isSeen: seenTimestamp >= item.timestamp.timeIntervalSince1970
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
        sortStoryBarItems(&storyBarItems)
    }

    public func markInstagramReelAsSeen(reelIndex: Int) {
        guard instagramStoryReels.indices.contains(reelIndex) else { return }
        let reel = instagramStoryReels[reelIndex]
        guard !reel.isSeen else { return }
        markInstagramReelAsSeen(reelId: reel.id)
    }

    public func markInstagramReelAsSeen(reelId: String) {
        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .instagram(reel) = $0, reel.id == reelId { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .instagram(reel) = storyItem, !reel.isSeen else { return }

        Task {
            await instagramSource?.markReelAsSeen(slides: reel.slides)
        }

        let updated = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true)
        storyBarItems[itemIndex] = .instagram(updated)
        sortStoryBarItems(&storyBarItems)
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

    private func sortStoryBarItems(_ items: inout [StoryBarItem]) {
        items.sort { a, b in
            if a.isSeen != b.isSeen {
                return !a.isSeen
            }
            return a.timestamp > b.timestamp
        }
    }
}
