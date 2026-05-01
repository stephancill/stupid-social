import Foundation
import OSLog

@MainActor
public final class FeedService {
    private let sources: [any NotificationSource]
    private let cacheStore: NotificationCacheStore
    private let watermarkStore: ReadWatermarkProviding
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "FeedService")

    private var pendingIds = Set<String>()
    private var revealedIds = Set<String>()

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
        let items = try cacheStore.loadRecent()
        return items
            .filter { !pendingIds.contains($0.id) }
            .map { DisplayNotificationItem(item: $0, isUnread: revealedIds.contains($0.id)) }
    }

    public func pendingNewCount() -> Int {
        pendingIds.count
    }

    public func manualRefresh() async throws -> [DisplayNotificationItem] {
        logger.info("Manual refresh started")
        var incoming: [NotificationItem] = []
        var errors: [String] = []

        for source in sources {
            do {
                let items = try await source.fetchNotifications(reason: .manual)
                logger.info("Source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
            } catch SourceError.notConfigured {
                errors.append("\(source.network.displayName) is not configured")
            } catch SourceError.endpointSpikeRequired {
                logger.info("Skipping source pending endpoint spike: \(source.network.rawValue, privacy: .public)")
            } catch {
                logger.error("Source refresh failed: \(source.network.rawValue, privacy: .public)")
                errors.append("\(source.network.displayName) refresh failed")
            }
        }

        let oldIds = Set((try? cacheStore.loadRecent())?.map(\.id) ?? [])
        let incomingIds = Set(incoming.map(\.id))
        let freshIds = incomingIds.subtracting(oldIds)

        pendingIds.removeAll()
        revealedIds = freshIds

        if !incoming.isEmpty {
            try cacheStore.replaceAll(incoming)
        }
        try cacheStore.deleteExpired()
        logger.info("Manual refresh finished")
        if !errors.isEmpty, incoming.isEmpty {
            throw SourceError.serviceError(errors.joined(separator: ", "))
        }
        return try loadCachedFeed()
    }

    public func foregroundActivationRefresh() async throws {
        logger.info("Foreground activation refresh started")
        var incoming: [NotificationItem] = []

        for source in sources {
            do {
                let items = try await source.fetchNotifications(reason: .background)
                logger.info("Foreground activation source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
            } catch SourceError.notConfigured, SourceError.endpointSpikeRequired {
                continue
            } catch {
                logger.error("Foreground activation source refresh failed: \(source.network.rawValue, privacy: .public)")
            }
        }

        if !incoming.isEmpty {
            let oldIds = Set((try? cacheStore.loadRecent())?.map(\.id) ?? [])
            let incomingIds = Set(incoming.map(\.id))
            let freshIds = incomingIds.subtracting(oldIds)
            pendingIds.formUnion(freshIds)

            try cacheStore.replaceAll(incoming)
            try cacheStore.deleteExpired()
        }
        logger.info("Foreground activation refresh finished")
    }

    public func revealPendingNotifications() throws -> [DisplayNotificationItem] {
        revealedIds.formUnion(pendingIds)
        pendingIds.removeAll()
        return try loadCachedFeed()
    }

    public func markAllRead(items: [DisplayNotificationItem]) -> [DisplayNotificationItem] {
        watermarkStore.markAllRead(items: items.map(\.item), network: nil, accountId: nil)
        revealedIds.removeAll()
        return items.map { DisplayNotificationItem(item: $0.item, isUnread: false) }
    }
}
