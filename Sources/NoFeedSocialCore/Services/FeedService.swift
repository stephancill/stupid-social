import Foundation
import OSLog

@MainActor
public final class FeedService {
    private let notificationSources: [any NotificationFetching]
    private let accountValidators: [any AccountValidating]
    private let profileFetchersByNetwork: [SocialNetwork: any ProfileFetching]
    private let targetDetailFetchersByNetwork: [SocialNetwork: any NotificationTargetDetailFetching]
    private let cacheStore: NotificationCacheStore
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "FeedService")

    private var targetDetailsCache: [String: NotificationTargetDetails] = [:]

    public init(
        notificationSources: [any NotificationFetching],
        accountValidators: [any AccountValidating],
        profileFetchersByNetwork: [SocialNetwork: any ProfileFetching],
        targetDetailFetchersByNetwork: [SocialNetwork: any NotificationTargetDetailFetching],
        cacheStore: NotificationCacheStore,
    ) {
        self.notificationSources = notificationSources
        self.accountValidators = accountValidators
        self.profileFetchersByNetwork = profileFetchersByNetwork
        self.targetDetailFetchersByNetwork = targetDetailFetchersByNetwork
        self.cacheStore = cacheStore
    }

    public func loadCachedFeed() throws -> [DisplayNotificationItem] {
        try cacheStore.loadRecent().map(DisplayNotificationItem.init)
    }

    public func manualRefresh() async throws -> [DisplayNotificationItem] {
        logger.info("Manual refresh started")
        var incoming: [NotificationItem] = []
        var errors: [String] = []
        var refreshedNetworks = Set<SocialNetwork>()

        let refreshResult = await fetchSourcesConcurrently(reason: .manual, timingPrefix: "manual")

        for result in refreshResult {
            if let error = result.error {
                switch error {
                case SourceError.notConfigured:
                    errors.append("\(result.network.displayName) is not configured")
                case SourceError.endpointSpikeRequired:
                    logger.info("Skipping source pending endpoint spike: \(result.network.rawValue, privacy: .public)")
                default:
                    logger.error("Source refresh failed: \(result.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                    errors.append("\(result.network.displayName) refresh failed")
                }
            } else {
                let items = result.items
                logger.info("Source refresh finished: \(result.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
                if !items.isEmpty {
                    refreshedNetworks.insert(result.network)
                }
            }
        }

        if !refreshedNetworks.isEmpty {
            try await RefreshTiming.measure("manual-cache-replace") {
                try cacheStore.replaceNetworks(incoming, networks: refreshedNetworks)
            }
        }
        try await RefreshTiming.measure("manual-cache-delete-expired") {
            try cacheStore.deleteExpired()
        }
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

        let refreshResult = await fetchSourcesConcurrently(reason: .background, timingPrefix: "foreground")

        for result in refreshResult {
            if let error = result.error {
                switch error {
                case SourceError.notConfigured, SourceError.endpointSpikeRequired:
                    continue
                default:
                    logger.error("Foreground activation source refresh failed: \(result.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                }
            } else {
                let items = result.items
                logger.info("Foreground activation source refresh finished: \(result.network.rawValue, privacy: .public) \(items.count, privacy: .public) items")
                incoming.append(contentsOf: items)
                if !items.isEmpty {
                    refreshedNetworks.insert(result.network)
                }
            }
        }

        if !refreshedNetworks.isEmpty {
            try await RefreshTiming.measure("foreground-cache-replace") {
                try cacheStore.replaceNetworks(incoming, networks: refreshedNetworks)
            }
            try await RefreshTiming.measure("foreground-cache-delete-expired") {
                try cacheStore.deleteExpired()
            }
        }
        logger.info("Foreground activation refresh finished")
    }

    private func fetchSourcesConcurrently(
        reason: RefreshReason,
        timingPrefix: String,
    ) async -> [(network: SocialNetwork, items: [NotificationItem], error: Error?)] {
        let fetchers: [(network: SocialNetwork, fetch: @MainActor () async throws -> [NotificationItem])] = notificationSources.map { source in
            (source.network, { try await source.fetchNotifications(reason: reason) })
        }

        return await withTaskGroup(of: (SocialNetwork, [NotificationItem], Error?).self) { group in
            for fetcher in fetchers {
                group.addTask {
                    do {
                        let items = try await RefreshTiming.measure("\(timingPrefix)-source-\(fetcher.network.rawValue)") {
                            try await fetcher.fetch()
                        }
                        return (fetcher.network, items, nil)
                    } catch {
                        return (fetcher.network, [], error)
                    }
                }
            }

            var results: [(network: SocialNetwork, items: [NotificationItem], error: Error?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    public func healthCheckAllSources() async {
        for source in accountValidators {
            _ = try? await source.validateAccount()
        }
    }

    public func fetchProfile(for actorId: String, network: SocialNetwork, username: String? = nil) async throws -> NetworkProfile {
        guard let source = profileFetchersByNetwork[network] else {
            throw SourceError.serviceError("No source for network \(network)")
        }
        // X and Instagram can resolve profiles by username; this avoids stale or non-numeric source ids breaking detail lookup.
        let lookupId = (network == .x || network == .instagram) ? (username ?? actorId) : actorId
        return try await source.fetchProfile(id: lookupId)
    }

    public func fetchProfilePosts(for profile: NetworkProfile, cursor: String?, count: Int = 12) async throws -> NetworkProfilePostsPage {
        guard let source = profileFetchersByNetwork[profile.network] else {
            throw SourceError.serviceError("No source for network \(profile.network)")
        }
        let lookupId = profile.network == .instagram ? (profile.username ?? profile.id) : profile.id
        return try await source.fetchProfilePosts(id: lookupId, cursor: cursor, count: count)
    }

    public func searchProfiles(query: String) async -> [NetworkProfile] {
        let normalized = String(query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
        guard !normalized.isEmpty else { return [] }

        var profiles: [NetworkProfile] = []
        for source in profileFetchersByNetwork.values {
            do {
                try await profiles.append(contentsOf: source.searchProfiles(query: normalized))
            } catch SourceError.notConfigured {
                continue
            } catch {
                logger.info("Profile search failed: \(source.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
            }
        }
        return profiles.sorted { lhs, rhs in
            lhs.network.displayName < rhs.network.displayName
        }
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        let cacheKey = targetDetailsCacheKey(for: item)
        if let cached = targetDetailsCache[cacheKey] {
            return cached
        }

        guard let source = targetDetailFetchersByNetwork[item.network] else {
            throw SourceError.serviceError("No source for network \(item.network)")
        }
        let details = try await source.fetchTargetDetails(for: item)
        targetDetailsCache[cacheKey] = details
        return details
    }

    public func cachedTargetDetails(for item: NotificationItem) -> NotificationTargetDetails? {
        targetDetailsCache[targetDetailsCacheKey(for: item)]
    }

    private func targetDetailsCacheKey(for item: NotificationItem) -> String {
        let targetId = item.target?.id ?? item.sourceId ?? item.id
        return [item.network.rawValue, item.accountId, targetId].joined(separator: "|")
    }
}
