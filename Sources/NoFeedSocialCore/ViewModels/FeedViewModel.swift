import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var pendingNewCount = 0
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService

    public var service: FeedService {
        feedService
    }

    public init(feedService: FeedService) {
        self.feedService = feedService
    }

    public func loadCachedFeed() {
        do {
            items = try feedService.loadCachedFeed()
            pendingNewCount = feedService.pendingNewCount()
        } catch {
            errorMessage = "Could not load cached notifications."
        }
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard !isRefreshing, !isForegroundRefreshing else { return false }
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

        return true
    }

    public func markAllRead() {
        items = feedService.markAllRead(items: items)
    }

    @discardableResult
    public func refreshOnForegroundActivation() async -> Bool {
        guard !isRefreshing, !isForegroundRefreshing else { return false }
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

        return true
    }

    public func revealPendingNotifications() {
        do {
            items = try feedService.revealPendingNotifications()
            pendingNewCount = feedService.pendingNewCount()
        } catch {
            errorMessage = "Could not load new notifications."
        }
    }

    public func performCredentialHealthCheck() async {
        await feedService.healthCheckAllSources()
    }
}
