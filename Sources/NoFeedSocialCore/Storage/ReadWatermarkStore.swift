import Foundation

public protocol ReadWatermarkProviding {
    func watermark(for network: SocialNetwork, accountId: String) -> ReadWatermark?
    func markAllRead(items: [NotificationItem], network: SocialNetwork?, accountId: String?)
    func isUnread(_ item: NotificationItem) -> Bool
}

public final class ICloudReadWatermarkStore: ReadWatermarkProviding {
    private let cloudStore: NSUbiquitousKeyValueStore
    private let localStore: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let legacyDecoder = JSONDecoder()

    public init(
        cloudStore: NSUbiquitousKeyValueStore = .default,
        localStore: UserDefaults = .standard
    ) {
        self.cloudStore = cloudStore
        self.localStore = localStore
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        legacyDecoder.dateDecodingStrategy = .iso8601
    }

    public func watermark(for network: SocialNetwork, accountId: String) -> ReadWatermark? {
        let key = self.key(network: network, accountId: accountId)
        var candidates: [ReadWatermark] = []

        if let data = cloudStore.data(forKey: key),
           let watermark = decodeWatermark(from: data) {
            candidates.append(watermark)
        }

        if let data = localStore.data(forKey: key),
           let watermark = decodeWatermark(from: data) {
            candidates.append(watermark)
        }

        return candidates.max { lhs, rhs in
            if lhs.lastReadAt == rhs.lastReadAt {
                lhs.updatedAt < rhs.updatedAt
            } else {
                lhs.lastReadAt < rhs.lastReadAt
            }
        }
    }

    public func markAllRead(items: [NotificationItem], network: SocialNetwork? = nil, accountId: String? = nil) {
        let grouped = Dictionary(grouping: filtered(items, network: network, accountId: accountId)) {
            WatermarkScope(network: $0.network, accountId: $0.accountId)
        }

        for (scope, scopedItems) in grouped {
            guard let newest = scopedItems.map(\.timestamp).max() else { continue }
            let watermark = ReadWatermark(
                network: scope.network,
                accountId: scope.accountId,
                lastReadAt: newest,
                updatedAt: Date()
            )

            guard let data = try? encoder.encode(watermark) else { continue }
            let key = self.key(network: scope.network, accountId: scope.accountId)
            cloudStore.set(data, forKey: key)
            localStore.set(data, forKey: key)
        }

        cloudStore.synchronize()
    }

    public func isUnread(_ item: NotificationItem) -> Bool {
        guard let watermark = watermark(for: item.network, accountId: item.accountId) else {
            return true
        }

        return item.timestamp > watermark.lastReadAt
    }

    private func filtered(
        _ items: [NotificationItem],
        network: SocialNetwork?,
        accountId: String?
    ) -> [NotificationItem] {
        items.filter { item in
            if let network, item.network != network { return false }
            if let accountId, item.accountId != accountId { return false }
            return true
        }
    }

    private func key(network: SocialNetwork, accountId: String) -> String {
        "readWatermark.\(network.rawValue).\(accountId)"
    }

    private func decodeWatermark(from data: Data) -> ReadWatermark? {
        if let watermark = try? decoder.decode(ReadWatermark.self, from: data) {
            return watermark
        }

        return try? legacyDecoder.decode(ReadWatermark.self, from: data)
    }
}

private struct WatermarkScope: Hashable {
    let network: SocialNetwork
    let accountId: String
}
