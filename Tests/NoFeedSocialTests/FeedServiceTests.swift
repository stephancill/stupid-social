@testable import NoFeedSocialCore
import SwiftData
import XCTest

final class FeedServiceTests: XCTestCase {
    @MainActor
    func testManualRefreshShowsMergedItemsChronologically() async throws {
        let cacheStore = try makeCacheStore()
        let known = item(id: "known", timestamp: Date(timeIntervalSince1970: 200))
        try cacheStore.replaceAll([known])

        let source = StubNotificationFetcher(items: [
            known,
            item(id: "new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = makeService([source], cacheStore: cacheStore)

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.item.sourceId), ["known", "new"])
    }

    @MainActor
    func testForegroundActivationRefreshShowsNewItemsImmediately() async throws {
        let cacheStore = try makeCacheStore()
        let source = StubNotificationFetcher(items: [
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = makeService([source], cacheStore: cacheStore)

        try await service.foregroundActivationRefresh()

        let displayed = try service.loadCachedFeed()
        XCTAssertEqual(displayed.map(\.item.sourceId), ["background-new"])
    }

    @MainActor
    func testManualRefreshReturnsCachedItemsWhenAllSourcesFail() async throws {
        let cacheStore = try makeCacheStore()
        let cached = item(id: "cached", network: .x, timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cached])

        let service = makeService([FailingNotificationFetcher()], cacheStore: cacheStore)

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.item.sourceId), ["cached"])
    }

    @MainActor
    func testManualRefreshThrowsWhenAllSourcesFailAndCacheIsEmpty() async throws {
        let cacheStore = try makeCacheStore()
        let service = makeService([FailingNotificationFetcher()], cacheStore: cacheStore)

        do {
            _ = try await service.manualRefresh()
            XCTFail("Expected refresh to fail without cached items")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    @MainActor
    func testManualRefreshPreservesFailedNetworkCacheWhenAnotherSourceSucceeds() async throws {
        let cacheStore = try makeCacheStore()
        let cachedX = item(id: "cached-x", network: .x, timestamp: Date(timeIntervalSince1970: 200))
        let cachedFarcaster = item(id: "cached-farcaster", network: .farcaster, timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cachedX, cachedFarcaster])

        let service = makeService([
            FailingNotificationFetcher(network: .x),
            StubNotificationFetcher(network: .farcaster, items: [cachedFarcaster]),
        ], cacheStore: cacheStore)

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.item.sourceId), ["cached-x", "cached-farcaster"])
    }

    @MainActor
    func testManualRefreshPreservesNetworkCacheWhenSourceReturnsEmpty() async throws {
        let cacheStore = try makeCacheStore()
        let cachedX = item(id: "cached-x", network: .x, timestamp: Date(timeIntervalSince1970: 100))
        try cacheStore.replaceAll([cachedX])

        let service = makeService([StubNotificationFetcher(network: .x, items: [])], cacheStore: cacheStore)

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.item.sourceId), ["cached-x"])
    }

    @MainActor
    func testTwoAccountsOnOneNetworkKeepSeparateItems() async throws {
        let cacheStore = try makeCacheStore()
        let shared = item(id: "same-event", network: .x, timestamp: Date(timeIntervalSince1970: 100))
        let service = FeedService(
            accountSources: {
                [
                    FeedAccountSources(accountId: "x-1", network: .x, notifications: StubNotificationFetcher(network: .x, items: [shared])),
                    FeedAccountSources(accountId: "x-2", network: .x, notifications: StubNotificationFetcher(network: .x, items: [shared])),
                ]
            },
            cacheStore: cacheStore,
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(Set(displayed.map(\.item.accountId)), ["x-1", "x-2"])
        XCTAssertEqual(Set(displayed.map(\.id)), ["x-1|same-event", "x-2|same-event"])
    }

    @MainActor
    func testRemovedAccountsItemsLeaveTheFeed() async throws {
        let cacheStore = try makeCacheStore()
        try cacheStore.replaceAll([item(id: "gone", network: .x, timestamp: Date(timeIntervalSince1970: 100)).scoped(to: "x-removed")])
        let service = makeService([StubNotificationFetcher(network: .farcaster, items: [item(id: "kept", timestamp: Date(timeIntervalSince1970: 200))])], cacheStore: cacheStore)

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.item.sourceId), ["kept"])
    }

    @MainActor
    func testManualRefreshRunsSourcesConcurrently() async throws {
        let cacheStore = try makeCacheStore()
        let service = makeService([
            DelayedNotificationFetcher(network: .x, delay: 0.5, items: [item(id: "x", network: .x, timestamp: Date(timeIntervalSince1970: 300))]),
            DelayedNotificationFetcher(network: .farcaster, delay: 0.1, items: [item(id: "fc", network: .farcaster, timestamp: Date(timeIntervalSince1970: 200))]),
        ], cacheStore: cacheStore)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await service.manualRefresh()
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, 0.55, "Serial execution of a 0.1s and 0.5s source should take roughly 0.6s; concurrent should take roughly 0.5s")
    }

    @MainActor
    func testForegroundActivationRefreshRunsSourcesConcurrently() async throws {
        let cacheStore = try makeCacheStore()
        let service = makeService([
            DelayedNotificationFetcher(network: .x, delay: 0.5, items: [item(id: "x", network: .x, timestamp: Date(timeIntervalSince1970: 300))]),
            DelayedNotificationFetcher(network: .farcaster, delay: 0.1, items: [item(id: "fc", network: .farcaster, timestamp: Date(timeIntervalSince1970: 200))]),
        ], cacheStore: cacheStore)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await service.foregroundActivationRefresh()
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, 0.55, "Foreground refresh should fetch sources concurrently")
    }

    /// iOS cancels a refresh whose background time runs out; that isn't a source failure.
    @MainActor
    func testCancelledRefreshIsNotAFailure() async throws {
        let cacheStore = try makeCacheStore()
        let service = makeService([
            DelayedNotificationFetcher(network: .x, delay: 5, items: [item(id: "x", network: .x, timestamp: Date(timeIntervalSince1970: 300))]),
        ], cacheStore: cacheStore)

        let refresh = Task { try await service.manualRefresh().count }
        try await Task.sleep(for: .milliseconds(100))
        refresh.cancel()

        let displayed = try await refresh.value
        XCTAssertEqual(displayed, 0)
    }

    /// Kept for the test's duration, as the cache's context needs its container.
    private var containers: [ModelContainer] = []

    @MainActor
    private func makeCacheStore() throws -> NotificationCacheStore {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        containers.append(container)
        return NotificationCacheStore(context: container.mainContext)
    }

    /// One account per source, named after its network, as the cached items are.
    @MainActor
    private func makeService(_ sources: [any NotificationFetching], cacheStore: NotificationCacheStore) -> FeedService {
        FeedService(
            accountSources: { sources.map { FeedAccountSources(accountId: $0.network.rawValue, network: $0.network, notifications: $0) } },
            cacheStore: cacheStore,
        )
    }

    private func item(id: String, network: SocialNetwork = .farcaster, timestamp: Date) -> NotificationItem {
        NotificationItem(
            id: id,
            network: network,
            accountId: network.rawValue,
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
