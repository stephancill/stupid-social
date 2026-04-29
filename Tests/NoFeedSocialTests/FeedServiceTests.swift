import XCTest
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
