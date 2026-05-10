import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var instagramStoryReels: [InstagramStoryReel] = []
    @Published public private(set) var pendingNewCount = 0
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService
    private let instagramSource: InstagramNotificationSource?

    public var service: FeedService {
        feedService
    }

    public init(feedService: FeedService, instagramSource: InstagramNotificationSource?) {
        self.feedService = feedService
        self.instagramSource = instagramSource
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

        await fetchInstagramStories()
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

        await fetchInstagramStories()
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
        guard let instagramSource, instagramSource.storiesEnabled else {
            instagramStoryReels = []
            return
        }
        do {
            var reels = try await instagramSource.fetchStoryReels()
            reels.sort { $0.isSeen == false && $1.isSeen == true }
            instagramStoryReels = reels
        } catch {
            // Non-critical: stories silently fail
        }
    }

    public func markInstagramReelAsSeen(reelIndex: Int) {
        guard let instagramSource,
              instagramStoryReels.indices.contains(reelIndex) else { return }
        let reel = instagramStoryReels[reelIndex]
        guard !reel.isSeen else { return }

        Task {
            await instagramSource.markReelAsSeen(slides: reel.slides)
        }

        let updated = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true)
        instagramStoryReels[reelIndex] = updated
        instagramStoryReels.sort { $0.isSeen == false && $1.isSeen == true }
    }

    public func performCredentialHealthCheck() async {
        await feedService.healthCheckAllSources()
    }
}
