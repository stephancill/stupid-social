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
        return try displayItems(from: cacheStore.loadRecentEntries())
    }

    public func pendingNewCount() throws -> Int {
        try cacheStore.pendingCount()
    }

    public func manualRefresh() async throws -> [DisplayNotificationItem] {
        logger.info("Manual refresh started")
        var refreshed: [NotificationItem] = []
        var errors: [String] = []

        try cacheStore.clearPending()

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

        if !refreshed.isEmpty {
            try cacheStore.markAllKnown()
        }
        try cacheStore.upsert(refreshed, markInsertedAsNew: true)
        try cacheStore.deleteExpired()
        logger.info("Manual refresh finished")
        if !errors.isEmpty, refreshed.isEmpty {
            throw SourceError.serviceError(errors.joined(separator: ", "))
        }
        return try loadCachedFeed()
    }

    public func foregroundActivationRefresh() async throws {
        logger.info("Foreground activation refresh started")
        var refreshed: [NotificationItem] = []

        for source in sources {
            do {
                switch source.network {
                case .x:
                    _ = try await source.fetchUnreadCount()
                case .farcaster, .instagram, .debug:
                    let items = try await source.fetchNotifications(reason: .background)
                    logger.info("Foreground activation source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                    refreshed.append(contentsOf: items)
                }
            } catch SourceError.notConfigured, SourceError.endpointSpikeRequired {
                continue
            } catch {
                logger.error("Foreground activation source refresh failed: \(source.network.rawValue, privacy: .public)")
            }
        }

        try cacheStore.upsert(refreshed, markInsertedAsNew: true, markInsertedAsPending: true)
        try cacheStore.deleteExpired()
        logger.info("Foreground activation refresh finished")
    }

    public func revealPendingNotifications() throws -> [DisplayNotificationItem] {
        try cacheStore.revealPending()
        return try loadCachedFeed()
    }

    public func markAllRead(items: [DisplayNotificationItem]) -> [DisplayNotificationItem] {
        watermarkStore.markAllRead(items: items.map(\.item), network: nil, accountId: nil)
        try? cacheStore.markAllKnown()
        return items.map { DisplayNotificationItem(item: $0.item, isUnread: false) }
    }

    private func displayItems(from entries: [CachedNotificationEntry]) -> [DisplayNotificationItem] {
        entries
            .sorted { $0.item.timestamp > $1.item.timestamp }
            .map { DisplayNotificationItem(item: $0.item, isUnread: $0.isNew) }
    }
}
