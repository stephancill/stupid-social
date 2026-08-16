@testable import NoFeedSocialCore
import SwiftData
import XCTest

final class FeedServiceTests: XCTestCase {
    @MainActor
    func testManualRefreshShowsMergedItemsChronologically() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let known = item(id: "known", timestamp: Date(timeIntervalSince1970: 200))
        try cacheStore.replaceAll([known])

        let source = StubNotificationFetcher(items: [
            known,
            item(id: "new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = FeedService(
            notificationSources: [source],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["known", "new"])
    }

    @MainActor
    func testForegroundActivationRefreshShowsNewItemsImmediately() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let source = StubNotificationFetcher(items: [
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = FeedService(
            notificationSources: [source],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        try await service.foregroundActivationRefresh()

        let displayed = try service.loadCachedFeed()
        XCTAssertEqual(displayed.map(\.id), ["background-new"])
    }

    @MainActor
    func testManualRefreshReturnsCachedItemsWhenAllSourcesFail() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let cached = item(id: "cached", timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cached])

        let service = FeedService(
            notificationSources: [FailingNotificationFetcher()],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["cached"])
    }

    @MainActor
    func testManualRefreshThrowsWhenAllSourcesFailAndCacheIsEmpty() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let service = FeedService(
            notificationSources: [FailingNotificationFetcher()],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        do {
            _ = try await service.manualRefresh()
            XCTFail("Expected refresh to fail without cached items")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    @MainActor
    func testManualRefreshPreservesFailedNetworkCacheWhenAnotherSourceSucceeds() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let cachedX = item(id: "cached-x", network: .x, timestamp: Date(timeIntervalSince1970: 200))
        let cachedFarcaster = item(id: "cached-farcaster", network: .farcaster, timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cachedX, cachedFarcaster])

        let service = FeedService(
            notificationSources: [
                FailingNotificationFetcher(network: .x),
                StubNotificationFetcher(network: .farcaster, items: [cachedFarcaster]),
            ],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["cached-x", "cached-farcaster"])
    }

    @MainActor
    func testManualRefreshPreservesNetworkCacheWhenSourceReturnsEmpty() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let cachedX = item(id: "cached-x", network: .x, timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cachedX])

        let service = FeedService(
            notificationSources: [StubNotificationFetcher(network: .x, items: [])],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["cached-x"])
    }

    @MainActor
    func testManualRefreshRunsSourcesConcurrently() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let service = FeedService(
            notificationSources: [
                DelayedNotificationFetcher(network: .x, delay: 0.5, items: [item(id: "x", network: .x, timestamp: Date(timeIntervalSince1970: 300))]),
                DelayedNotificationFetcher(network: .farcaster, delay: 0.1, items: [item(id: "fc", network: .farcaster, timestamp: Date(timeIntervalSince1970: 200))]),
            ],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await service.manualRefresh()
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, 0.55, "Serial execution of a 0.1s and 0.5s source should take roughly 0.6s; concurrent should take roughly 0.5s")
    }

    @MainActor
    func testForegroundActivationRefreshRunsSourcesConcurrently() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let service = FeedService(
            notificationSources: [
                DelayedNotificationFetcher(network: .x, delay: 0.5, items: [item(id: "x", network: .x, timestamp: Date(timeIntervalSince1970: 300))]),
                DelayedNotificationFetcher(network: .farcaster, delay: 0.1, items: [item(id: "fc", network: .farcaster, timestamp: Date(timeIntervalSince1970: 200))]),
            ],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await service.foregroundActivationRefresh()
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, 0.55, "Foreground refresh should fetch sources concurrently")
    }

    private func item(id: String, network: SocialNetwork = .farcaster, timestamp: Date) -> NotificationItem {
        NotificationItem(
            id: id,
            network: network,
            accountId: "1",
            sourceId: id,
            type: .reply,
            timestamp: timestamp,
            text: "Test",
            actors: [],
            target: nil,
        )
    }
}

private final class FailingNotificationFetcher: NotificationFetching {
    let network: SocialNetwork

    init(network: SocialNetwork = .x) {
        self.network = network
    }

    func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        throw SourceError.serviceError("Failed")
    }
}

private final class StubNotificationFetcher: NotificationFetching {
    let network: SocialNetwork
    private let items: [NotificationItem]

    init(network: SocialNetwork = .farcaster, items: [NotificationItem]) {
        self.network = network
        self.items = items
    }

    func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        items
    }
}

private final class DelayedNotificationFetcher: NotificationFetching {
    let network: SocialNetwork
    private let delay: TimeInterval
    private let items: [NotificationItem]

    init(network: SocialNetwork, delay: TimeInterval, items: [NotificationItem]) {
        self.network = network
        self.delay = delay
        self.items = items
    }

    func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        try await Task.sleep(for: .seconds(delay))
        return items
    }
}
