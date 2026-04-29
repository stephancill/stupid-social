import XCTest
@testable import NoFeedSocialCore

final class ReadWatermarkTests: XCTestCase {
    func testMarkAllReadAdvancesWatermarkToNewestItem() {
        let store = InMemoryReadWatermarkStore()
        let older = item(id: "older", timestamp: Date(timeIntervalSince1970: 100))
        let newer = item(id: "newer", timestamp: Date(timeIntervalSince1970: 200))

        store.markAllRead(items: [older, newer], network: nil, accountId: nil)

        XCTAssertFalse(store.isUnread(older))
        XCTAssertFalse(store.isUnread(newer))
        XCTAssertTrue(store.isUnread(item(id: "future", timestamp: Date(timeIntervalSince1970: 300))))
    }

    func testICloudStorePreservesSubsecondWatermarkPrecision() {
        let suiteName = "tech.stupid.StupidSocial.watermarkTests.\(UUID().uuidString)"
        let localStore = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = ICloudReadWatermarkStore(localStore: localStore)
        let item = item(id: "fractional", timestamp: Date(timeIntervalSince1970: 100.987))

        store.markAllRead(items: [item], network: nil, accountId: nil)

        XCTAssertFalse(store.isUnread(item))
    }

    private func item(id: String, timestamp: Date) -> NotificationItem {
        NotificationItem(
            id: id,
            network: .farcaster,
            accountId: "1",
            sourceId: id,
            type: .mention,
            timestamp: timestamp,
            text: "Test",
            actors: [],
            target: nil
        )
    }
}

private final class InMemoryReadWatermarkStore: ReadWatermarkProviding {
    private var watermarks: [String: ReadWatermark] = [:]

    func watermark(for network: SocialNetwork, accountId: String) -> ReadWatermark? {
        watermarks[key(network: network, accountId: accountId)]
    }

    func markAllRead(items: [NotificationItem], network: SocialNetwork?, accountId: String?) {
        let filtered = items.filter { item in
            if let network, item.network != network { return false }
            if let accountId, item.accountId != accountId { return false }
            return true
        }

        let grouped = Dictionary(grouping: filtered) { item in
            key(network: item.network, accountId: item.accountId)
        }

        for (key, scopedItems) in grouped {
            guard let newest = scopedItems.map(\.timestamp).max(), let first = scopedItems.first else {
                continue
            }

            watermarks[key] = ReadWatermark(
                network: first.network,
                accountId: first.accountId,
                lastReadAt: newest,
                updatedAt: Date()
            )
        }
    }

    func isUnread(_ item: NotificationItem) -> Bool {
        guard let watermark = watermark(for: item.network, accountId: item.accountId) else {
            return true
        }

        return item.timestamp > watermark.lastReadAt
    }

    private func key(network: SocialNetwork, accountId: String) -> String {
        "\(network.rawValue).\(accountId)"
    }
}
