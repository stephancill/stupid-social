import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var isRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService

    public init(feedService: FeedService) {
        self.feedService = feedService
    }

    public func loadCachedFeed() {
        do {
            items = try feedService.loadCachedFeed()
        } catch {
            errorMessage = "Could not load cached notifications."
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            items = feedService.markAllRead(items: try await feedService.manualRefresh())
            errorMessage = nil
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? "Refresh failed."
        } catch {
            errorMessage = "Refresh failed."
        }
    }

    public func markAllRead() {
        items = feedService.markAllRead(items: items)
    }
}
