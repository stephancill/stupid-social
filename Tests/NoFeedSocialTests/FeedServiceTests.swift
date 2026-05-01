import XCTest
import SwiftData
@testable import NoFeedSocialCore

final class FeedServiceTests: XCTestCase {
    func testDisplayItemsSortDescendingAndDeriveUnread() {
        let store = InMemoryReadWatermarkStoreForFeed()
        let older = item(id: "older", timestamp: Date(timeIntervalSince1970: 100))
        let newer = item(id: "newer", timestamp: Date(timeIntervalSince1970: 200))

        store.markAllRead(items: [older], network: nil, accountId: nil)

        let displayed = [older, newer]
            .sorted { $0.timestamp > $1.timestamp }
            .map { DisplayNotificationItem(item: $0, isUnread: store.isUnread($0)) }

        XCTAssertEqual(displayed.map(\.id), ["newer", "older"])
        XCTAssertTrue(displayed[0].isUnread)
        XCTAssertFalse(displayed[1].isUnread)
    }

    @MainActor
    func testManualRefreshMarksOnlyNewItemsUnread() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let known = item(id: "known", timestamp: Date(timeIntervalSince1970: 200))
        try cacheStore.replaceAll([known])

        let source = StubNotificationSource(items: [
            known,
            item(id: "new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = FeedService(
            sources: [source],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed()
        )

        let displayed = try await service.manualRefresh()

        XCTAssertEqual(displayed.map(\.id), ["known", "new"])
        XCTAssertFalse(displayed[0].isUnread)
        XCTAssertTrue(displayed[1].isUnread)
    }

    @MainActor
    func testForegroundActivationRefreshKeepsNewItemsPendingUntilRevealed() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let source = StubNotificationSource(items: [
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let service = FeedService(
            sources: [source],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed()
        )

        try await service.foregroundActivationRefresh()

        XCTAssertEqual(service.pendingNewCount(), 1)
        XCTAssertTrue(try service.loadCachedFeed().isEmpty)

        let displayed = try service.revealPendingNotifications()

        XCTAssertEqual(service.pendingNewCount(), 0)
        XCTAssertEqual(displayed.map(\.id), ["background-new"])
        XCTAssertTrue(displayed[0].isUnread)
    }

    @MainActor
    func testManualRefreshClearsPendingNewCount() async throws {
        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let backgroundSource = StubNotificationSource(items: [
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let backgroundService = FeedService(
            sources: [backgroundSource],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed()
        )
        try await backgroundService.foregroundActivationRefresh()
        XCTAssertEqual(backgroundService.pendingNewCount(), 1)

        let manualSource = StubNotificationSource(items: [
            item(id: "manual-new", timestamp: Date(timeIntervalSince1970: 200)),
            item(id: "background-new", timestamp: Date(timeIntervalSince1970: 100)),
        ])
        let manualService = FeedService(
            sources: [manualSource],
            cacheStore: cacheStore,
            watermarkStore: InMemoryReadWatermarkStoreForFeed()
        )

        let displayed = try await manualService.manualRefresh()

        XCTAssertEqual(manualService.pendingNewCount(), 0)
        XCTAssertEqual(displayed.map(\.id), ["manual-new", "background-new"])
        XCTAssertTrue(displayed[0].isUnread)
        XCTAssertFalse(displayed[1].isUnread)
    }

    private func item(id: String, timestamp: Date) -> NotificationItem {
        NotificationItem(
            id: id,
            network: .farcaster,
            accountId: "1",
            sourceId: id,
            type: .reply,
            timestamp: timestamp,
            text: "Test",
            actors: [],
            target: nil
        )
    }
}

private final class StubNotificationSource: NotificationSource {
    let network: SocialNetwork = .farcaster
    private let items: [NotificationItem]

    init(items: [NotificationItem]) {
        self.items = items
    }

    func validateAccount() async throws -> AccountStatus {
        .valid
    }

    func fetchUnreadCount() async throws -> Int? {
        nil
    }

    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        items
    }

    func fetchProfile(id: String) async throws -> NetworkProfile {
        throw SourceError.unsupported
    }
}

private final class InMemoryReadWatermarkStoreForFeed: ReadWatermarkProviding {
    private var watermark: ReadWatermark?

    func watermark(for network: SocialNetwork, accountId: String) -> ReadWatermark? {
        watermark
    }

    func markAllRead(items: [NotificationItem], network: SocialNetwork?, accountId: String?) {
        guard let newest = items.map(\.timestamp).max(), let first = items.first else { return }
        watermark = ReadWatermark(
            network: first.network,
            accountId: first.accountId,
            lastReadAt: newest,
            updatedAt: Date()
        )
    }

    func isUnread(_ item: NotificationItem) -> Bool {
        guard let watermark else { return true }
        return item.timestamp > watermark.lastReadAt
    }
}
