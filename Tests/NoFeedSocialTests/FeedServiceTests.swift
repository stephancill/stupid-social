@testable import NoFeedSocialCore
import SwiftData
import XCTest

final class FeedServiceTests: XCTestCase {
    func testDisplayItemsSortDescendingAndExposeNewState() {
        let older = item(id: "older", timestamp: Date(timeIntervalSince1970: 100))
        let newer = item(id: "newer", timestamp: Date(timeIntervalSince1970: 200))
        let newIds: Set<String> = [newer.id]

        let displayed = [older, newer]
            .sorted { $0.timestamp > $1.timestamp }
            .map { DisplayNotificationItem(item: $0, isNew: newIds.contains($0.id)) }

        XCTAssertEqual(displayed.map(\.id), ["newer", "older"])
        XCTAssertTrue(displayed[0].isNew)
        XCTAssertFalse(displayed[1].isNew)
    }

    @MainActor
    func testManualRefreshMarksOnlyFreshItemsNew() async throws {
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["known", "new"])
        XCTAssertFalse(displayed[0].isNew)
        XCTAssertTrue(displayed[1].isNew)
    }

    @MainActor
    func testForegroundActivationRefreshKeepsNewItemsPendingUntilRevealed() async throws {
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
        )

        try await service.foregroundActivationRefresh()

        XCTAssertEqual(service.pendingNewCount(), 1)
        XCTAssertTrue(try service.loadCachedFeed().isEmpty)

        let displayed = try service.revealPendingNotifications()

        XCTAssertEqual(service.pendingNewCount(), 0)
        XCTAssertEqual(displayed.map(\.id), ["background-new"])
        XCTAssertTrue(displayed[0].isNew)
    }

    @MainActor
    func testManualRefreshClearsPendingNewCount() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let backgroundSource = StubNotificationFetcher(items: [
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let backgroundService = FeedService(
            notificationSources: [backgroundSource],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
        )
        try await backgroundService.foregroundActivationRefresh()
        XCTAssertEqual(backgroundService.pendingNewCount(), 1)

        let manualSource = StubNotificationFetcher(items: [
            item(id: "manual-new", timestamp: Date(timeIntervalSince1970: 200)),
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let manualService = FeedService(
            notificationSources: [manualSource],
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
        )

        let displayed = try await manualService.manualRefresh()

        XCTAssertEqual(manualService.pendingNewCount(), 0)
        XCTAssertEqual(displayed.map(\.id), ["manual-new", "background-new"])
        XCTAssertTrue(displayed[0].isNew)
        XCTAssertFalse(displayed[1].isNew)
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
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
            watermarkStore: InMemoryReadWatermarkStoreForFeed(),
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

private final class InMemoryReadWatermarkStoreForFeed: ReadWatermarkProviding {
    private var watermark: ReadWatermark?

    func watermark(for _: SocialNetwork, accountId _: String) -> ReadWatermark? {
        watermark
    }

    func markAllRead(items: [NotificationItem], network _: SocialNetwork?, accountId _: String?) {
        guard let newest = items.map(\.timestamp).max(), let first = items.first else { return }
        watermark = ReadWatermark(
            network: first.network,
            accountId: first.accountId,
            lastReadAt: newest,
            updatedAt: Date(),
        )
    }

    func isUnread(_ item: NotificationItem) -> Bool {
        guard let watermark else { return true }
        return item.timestamp > watermark.lastReadAt
    }
}
