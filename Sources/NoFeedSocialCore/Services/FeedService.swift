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
        watermarkStore: ReadWatermarkProviding,
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
        var refreshedNetworks = Set<SocialNetwork>()

        for source in sources {
            do {
                let items = try await source.fetchNotifications(reason: .manual)
                logger.info("Source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
                if !items.isEmpty {
                    refreshedNetworks.insert(source.network)
                }
            } catch SourceError.notConfigured {
                errors.append("\(source.network.displayName) is not configured")
            } catch SourceError.endpointSpikeRequired {
                logger.info("Skipping source pending endpoint spike: \(source.network.rawValue, privacy: .public)")
            } catch {
                logger.error("Source refresh failed: \(source.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                errors.append("\(source.network.displayName) refresh failed")
            }
        }

        let oldItems = (try? cacheStore.loadRecent()) ?? []
        let oldItemsById = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        let oldIds = Set(oldItemsById.keys)
        let incomingIds = Set(incoming.map(\.id))
        let changedGroupedIds = incoming.compactMap { item -> String? in
            guard item.network != .x else { return nil }
            guard let old = oldItemsById[item.id] else { return nil }
            let oldActorIds = Set(old.actors.map(\.id))
            let incomingActorIds = Set(item.actors.map(\.id))
            guard !incomingActorIds.subtracting(oldActorIds).isEmpty else { return nil }
            return item.id
        }
        let freshIds = incomingIds.subtracting(oldIds).union(changedGroupedIds)

        pendingIds.removeAll()
        revealedIds = freshIds

        if !refreshedNetworks.isEmpty {
            try cacheStore.replaceNetworks(incoming, networks: refreshedNetworks)
        }
        try cacheStore.deleteExpired()
        logger.info("Manual refresh finished")
        if !errors.isEmpty, incoming.isEmpty {
            let cachedItems = try loadCachedFeed()
            if !cachedItems.isEmpty {
                return cachedItems
            }
            throw SourceError.serviceError(errors.joined(separator: ", "))
        }
        return try loadCachedFeed()
    }

    public func foregroundActivationRefresh() async throws {
        logger.info("Foreground activation refresh started")
        var incoming: [NotificationItem] = []
        var refreshedNetworks = Set<SocialNetwork>()

        for source in sources {
            do {
                let items = try await source.fetchNotifications(reason: .background)
                logger.info("Foreground activation source refresh finished: \(source.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
                if !items.isEmpty {
                    refreshedNetworks.insert(source.network)
                }
            } catch SourceError.notConfigured, SourceError.endpointSpikeRequired {
                continue
            } catch {
                logger.error("Foreground activation source refresh failed: \(source.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
            }
        }

        if !refreshedNetworks.isEmpty {
            let oldIds = Set((try? cacheStore.loadRecent())?.map(\.id) ?? [])
            let incomingIds = Set(incoming.map(\.id))
            let freshIds = incomingIds.subtracting(oldIds)
            pendingIds.formUnion(freshIds)

            try cacheStore.replaceNetworks(incoming, networks: refreshedNetworks)
            try cacheStore.deleteExpired()
        }
        logger.info("Foreground activation refresh finished")
    }

    public func revealPendingNotifications() throws -> [DisplayNotificationItem] {
        revealedIds = pendingIds
        pendingIds.removeAll()
        return try loadCachedFeed()
    }

    public func healthCheckAllSources() async {
        for source in sources {
            _ = try? await source.validateAccount()
        }
    }

    public func fetchProfile(for actorId: String, network: SocialNetwork, username: String? = nil) async throws -> NetworkProfile {
        guard let source = sources.first(where: { $0.network == network }) else {
            throw SourceError.serviceError("No source for network \(network)")
        }
        // X and Instagram can resolve profiles by username; this avoids stale or non-numeric source ids breaking detail lookup.
        let lookupId = (network == .x || network == .instagram) ? (username ?? actorId) : actorId
        return try await source.fetchProfile(id: lookupId)
    }

    public func fetchTargetMetrics(for item: NotificationItem) async throws -> NotificationTargetMetrics {
        guard let source = sources.first(where: { $0.network == item.network }) else {
            throw SourceError.serviceError("No source for network \(item.network)")
        }
        return try await source.fetchTargetMetrics(for: item)
    }

    public func markAllRead(items: [DisplayNotificationItem]) -> [DisplayNotificationItem] {
        watermarkStore.markAllRead(items: items.map(\.item), network: nil, accountId: nil)
        revealedIds.removeAll()
        return items.map { DisplayNotificationItem(item: $0.item, isUnread: false) }
    }
}
