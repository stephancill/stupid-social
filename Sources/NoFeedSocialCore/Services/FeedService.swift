import Foundation
import OSLog

/// What one account contributes to the feed, profiles and actions.
public struct FeedAccountSources {
    public let accountId: String
    public let network: SocialNetwork
    public var notifications: (any NotificationFetching)?
    public var validators: [any AccountValidating]
    public var profiles: (any ProfileFetching)?
    public var targetDetails: (any NotificationTargetDetailFetching)?
    public var relationships: (any RelationshipMutating)?

    public init(
        accountId: String,
        network: SocialNetwork,
        notifications: (any NotificationFetching)? = nil,
        validators: [any AccountValidating] = [],
        profiles: (any ProfileFetching)? = nil,
        targetDetails: (any NotificationTargetDetailFetching)? = nil,
        relationships: (any RelationshipMutating)? = nil,
    ) {
        self.accountId = accountId
        self.network = network
        self.notifications = notifications
        self.validators = validators
        self.profiles = profiles
        self.targetDetails = targetDetails
        self.relationships = relationships
    }
}

@MainActor
public final class FeedService {
    private let accountSources: @MainActor () -> [FeedAccountSources]
    private let cacheStore: NotificationCacheStore
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "FeedService")

    private var targetDetailsCache: [String: NotificationTargetDetails] = [:]

    /// `accountSources` is read on every use, so accounts added or removed since take effect.
    public init(accountSources: @escaping @MainActor () -> [FeedAccountSources], cacheStore: NotificationCacheStore) {
        self.accountSources = accountSources
        self.cacheStore = cacheStore
        // Apron rooms and Spotify Messages chats moved from the feed to the Chats screen; drop the feed items
        // cached before, which would otherwise linger for the 24-hour retention.
        try? cacheStore.deleteNetwork(.apron)
        try? cacheStore.deleteNetwork(.spotify)
    }

    public func loadCachedFeed() throws -> [DisplayNotificationItem] {
        if DemoData.isDemoMode {
            return DemoData.feedItems().map(DisplayNotificationItem.init)
        }
        return try cacheStore.loadRecent().map(DisplayNotificationItem.init)
    }

    public func manualRefresh() async throws -> [DisplayNotificationItem] {
        if DemoData.isDemoMode {
            return try loadCachedFeed()
        }
        logger.info("Manual refresh started")
        var errors: [String] = []
        var refreshed = 0

        let results = await fetchSourcesConcurrently(reason: .manual, timingPrefix: "manual")

        for result in results {
            if let error = result.error {
                switch error {
                case SourceError.notConfigured:
                    // Unconfigured sources are expected unless the user connected them; never treat them as a refresh failure.
                    logger.info("Skipping unconfigured source: \(result.network.rawValue, privacy: .public)")
                case SourceError.endpointSpikeRequired:
                    logger.info("Skipping source pending endpoint spike: \(result.network.rawValue, privacy: .public)")
                default:
                    logger.error("Source refresh failed: \(result.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                    errors.append("\(result.network.displayName) refresh failed")
                }
            } else {
                logger.info("Source refresh finished: \(result.network.rawValue, privacy: .public) \(result.items.count, privacy: .public) items")
                refreshed += result.items.count
                try await replaceCachedItems(of: result)
            }
        }

        try await RefreshTiming.measure("manual-cache-delete-expired") {
            try cacheStore.deleteExpired()
        }
        logger.info("Manual refresh finished")
        if !errors.isEmpty, refreshed == 0 {
            let cachedItems = try loadCachedFeed()
            if !cachedItems.isEmpty {
                return cachedItems
            }
            throw SourceError.serviceError(errors.joined(separator: ", "))
        }
        return try loadCachedFeed()
    }

    public func foregroundActivationRefresh() async throws {
        if DemoData.isDemoMode {
            return
        }
        logger.info("Foreground activation refresh started")
        let results = await fetchSourcesConcurrently(reason: .background, timingPrefix: "foreground")

        for result in results {
            if let error = result.error {
                switch error {
                case SourceError.notConfigured, SourceError.endpointSpikeRequired:
                    continue
                default:
                    logger.error("Foreground activation source refresh failed: \(result.network.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                }
            } else {
                logger.info("Foreground activation source refresh finished: \(result.network.rawValue, privacy: .public) \(result.items.count, privacy: .public) items")
                try await replaceCachedItems(of: result)
            }
        }
        try await RefreshTiming.measure("foreground-cache-delete-expired") {
            try cacheStore.deleteExpired()
        }
        logger.info("Foreground activation refresh finished")
    }

    private struct FetchResult {
        let accountId: String
        let network: SocialNetwork
        let items: [NotificationItem]
        let error: Error?
    }

    /// Replaces one account's cached items, keeping the old ones when a refresh came back empty. Items of
    /// accounts that no longer exist go too.
    private func replaceCachedItems(of result: FetchResult) async throws {
        try cacheStore.deleteAccounts(notIn: Set(accountSources().map(\.accountId)))
        guard !result.items.isEmpty else { return }
        try await RefreshTiming.measure("cache-replace-\(result.network.rawValue)") {
            try cacheStore.replaceAccount(result.items, network: result.network, accountId: result.accountId)
        }
    }

    private func fetchSourcesConcurrently(reason: RefreshReason, timingPrefix: String) async -> [FetchResult] {
        let fetchers: [(accountId: String, network: SocialNetwork, fetch: @MainActor () async throws -> [NotificationItem])] = accountSources().compactMap { sources in
            guard let source = sources.notifications else { return nil }
            return (sources.accountId, sources.network, { try await source.fetchNotifications(reason: reason) })
        }

        return await withTaskGroup(of: FetchResult.self) { group in
            for fetcher in fetchers {
                group.addTask {
                    let start = ContinuousClock.now
                    do {
                        let items = try await RefreshTiming.measure("\(timingPrefix)-source-\(fetcher.network.rawValue)") {
                            try await fetcher.fetch()
                        }
                        AppMetrics.sourceRefreshed(network: fetcher.network, trigger: timingPrefix, duration: .now - start, error: nil)
                        return FetchResult(accountId: fetcher.accountId, network: fetcher.network, items: items.map { $0.scoped(to: fetcher.accountId) }, error: nil)
                    } catch {
                        switch error {
                        case SourceError.notConfigured, SourceError.endpointSpikeRequired:
                            break
                        default:
                            AppMetrics.sourceRefreshed(network: fetcher.network, trigger: timingPrefix, duration: .now - start, error: error)
                        }
                        return FetchResult(accountId: fetcher.accountId, network: fetcher.network, items: [], error: error)
                    }
                }
            }

            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    public func healthCheckAllSources() async {
        for source in accountSources().flatMap(\.validators) {
            _ = try? await source.validateAccount()
        }
    }

    /// The account's sources, or the network's first account's when no account is named, such as for a
    /// profile opened from a story.
    private func sources(network: SocialNetwork, accountId: String?) -> FeedAccountSources? {
        let all = accountSources().filter { $0.network == network }
        return all.first { $0.accountId == accountId } ?? all.first
    }

    public func fetchProfile(for actorId: String, network: SocialNetwork, username: String? = nil, accountId: String? = nil) async throws -> NetworkProfile {
        if DemoData.isDemoMode {
            let actor = DemoData.feedItems().flatMap(\.actors).first { $0.id == actorId && $0.network == network }
            return NetworkProfile(id: actorId, network: network, username: actor?.username ?? username,
                                  displayName: actor?.displayName ?? username, bio: "Sample profile for demonstration.",
                                  avatarURL: actor?.avatarURL, followerCount: 128, followingCount: 64)
        }
        guard let sources = sources(network: network, accountId: accountId), let source = sources.profiles else {
            throw SourceError.serviceError("No source for network \(network)")
        }
        // X and Instagram can resolve profiles by username; this avoids stale or non-numeric source ids breaking detail lookup.
        let lookupId = (network == .x || network == .instagram) ? (username ?? actorId) : actorId
        var profile = try await source.fetchProfile(id: lookupId)
        profile.accountId = sources.accountId
        return profile
    }

    public func fetchProfilePosts(for profile: NetworkProfile, cursor: String?, count: Int = 12) async throws -> NetworkProfilePostsPage {
        guard let source = sources(network: profile.network, accountId: profile.accountId)?.profiles else {
            throw SourceError.serviceError("No source for network \(profile.network)")
        }
        let lookupId = profile.network == .instagram ? (profile.username ?? profile.id) : profile.id
        return try await source.fetchProfilePosts(id: lookupId, cursor: cursor, count: count)
    }

    /// Searches with each network's first account, so a network with several accounts lists each person once.
    public func searchProfiles(query: String) async -> [NetworkProfile] {
        let normalized = String(query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
        guard !normalized.isEmpty else { return [] }

        var searched = Set<SocialNetwork>()
        var profiles: [NetworkProfile] = []
        for sources in accountSources() {
            guard let source = sources.profiles, searched.insert(sources.network).inserted else { continue }
            do {
                try await profiles.append(contentsOf: source.searchProfiles(query: normalized).map { profile in
                    var profile = profile
                    profile.accountId = sources.accountId
                    return profile
                })
            } catch SourceError.notConfigured {
                searched.remove(sources.network)
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
        if item.accountId == "demo-viewer" {
            return NotificationTargetDetails(author: item.target?.author, text: item.target?.text,
                                             imageURLs: [item.target?.imageURL].compactMap(\.self),
                                             postedAt: item.target?.postedAt, likeCount: item.target?.likeCount)
        }
        let cacheKey = targetDetailsCacheKey(for: item)
        if let cached = targetDetailsCache[cacheKey] {
            return cached
        }

        guard let source = sources(network: item.network, accountId: item.accountId)?.targetDetails else {
            throw SourceError.serviceError("No source for network \(item.network)")
        }
        let details = try await source.fetchTargetDetails(for: item)
        targetDetailsCache[cacheKey] = details
        return details
    }

    public func cachedTargetDetails(for item: NotificationItem) -> NotificationTargetDetails? {
        targetDetailsCache[targetDetailsCacheKey(for: item)]
    }

    public func setFollowing(_ profile: NetworkProfile, follow: Bool) async throws {
        guard !DemoData.isDemoMode else { throw SourceError.serviceError("Connect an account after exiting preview content to use this action.") }
        guard let source = sources(network: profile.network, accountId: profile.accountId)?.relationships else {
            throw SourceError.unsupported
        }
        try await source.setFollowing(profile: profile, follow: follow)
    }

    public func setPostNotifications(_ profile: NetworkProfile, enabled: Bool) async throws {
        guard !DemoData.isDemoMode else { throw SourceError.serviceError("Connect an account after exiting preview content to use this action.") }
        guard let source = sources(network: profile.network, accountId: profile.accountId)?.relationships else {
            throw SourceError.unsupported
        }
        try await source.setPostNotifications(profile: profile, enabled: enabled)
    }

    private func targetDetailsCacheKey(for item: NotificationItem) -> String {
        let targetId = item.target?.id ?? item.sourceId ?? item.id
        return [item.network.rawValue, item.accountId, targetId].joined(separator: "|")
    }
}
