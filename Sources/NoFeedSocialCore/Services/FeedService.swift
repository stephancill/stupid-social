import Foundation
import OSLog

@MainActor
public final class FeedService {
    private let sources: [any NotificationSource]
    private let cacheStore: NotificationCacheStore
    private let watermarkStore: ReadWatermarkProviding
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "FeedService")

    public init(
        sources: [any NotificationSource],
        cacheStore: NotificationCacheStore,
        watermarkStore: ReadWatermarkProviding
    ) {
        self.sources = sources
        self.cacheStore = cacheStore
        self.watermarkStore = watermarkStore
    }

    public func loadCachedFeed() throws -> [DisplayNotificationItem] {
        let cached = try cacheStore.loadRecent()
        return displayItems(from: cached)
    }

    public func manualRefresh() async throws -> [DisplayNotificationItem] {
        logger.info("Manual refresh started")
        var refreshed: [NotificationItem] = []
        var errors: [String] = []

        for source in sources {
            do {
                let items = try await source.fetchNotifications(reason: .manual)
                logger.info("Source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                refreshed.append(contentsOf: items)
            } catch SourceError.notConfigured {
                errors.append("\(source.network.displayName) is not configured")
            } catch SourceError.endpointSpikeRequired {
                logger.info("Skipping source pending endpoint spike: \(source.network.rawValue, privacy: .public)")
            } catch {
                logger.error("Source refresh failed: \(source.network.rawValue, privacy: .public)")
                errors.append("\(source.network.displayName) refresh failed")
            }
        }

        try cacheStore.upsert(refreshed)
        try cacheStore.deleteExpired()
        logger.info("Manual refresh finished")
        if !errors.isEmpty, refreshed.isEmpty {
            throw SourceError.serviceError(errors.joined(separator: ", "))
        }
        return try loadCachedFeed()
    }

    public func markAllRead(items: [DisplayNotificationItem]) -> [DisplayNotificationItem] {
        watermarkStore.markAllRead(items: items.map(\.item), network: nil, accountId: nil)
        return displayItems(from: items.map(\.item))
    }

    private func displayItems(from items: [NotificationItem]) -> [DisplayNotificationItem] {
        items
            .sorted { $0.timestamp > $1.timestamp }
            .map { DisplayNotificationItem(item: $0, isUnread: watermarkStore.isUnread($0)) }
    }
}
