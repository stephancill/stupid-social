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
