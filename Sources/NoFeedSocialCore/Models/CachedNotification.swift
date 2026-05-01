import Foundation
import SwiftData

@Model
public final class CachedNotification {
    @Attribute(.unique) public var id: String
    public var networkRawValue: String
    public var accountId: String
    public var sourceId: String?
    public var typeRawValue: String
    public var timestamp: Date
    public var text: String
    public var actorsData: Data
    public var targetData: Data?
    public var parentTargetData: Data?
    public var cachedAt: Date
    public var isNew: Bool = false
    public var isPending: Bool = false

    init(item: NotificationItem, cachedAt: Date = Date()) throws {
        id = item.id
        networkRawValue = item.network.rawValue
        accountId = item.accountId
        sourceId = item.sourceId
        typeRawValue = item.type.rawValue
        timestamp = item.timestamp
        text = item.text
        actorsData = try JSONEncoder().encode(item.actors)
        targetData = try item.target.map { try JSONEncoder().encode($0) }
        parentTargetData = try item.parentTarget.map { try JSONEncoder().encode($0) }
        self.cachedAt = cachedAt
    }

    func toItem() throws -> NotificationItem {
        let actors = try JSONDecoder().decode([NotificationActor].self, from: actorsData)
        let target = try targetData.map { try JSONDecoder().decode(NotificationTarget.self, from: $0) }
        let parentTarget = try parentTargetData.map { try JSONDecoder().decode(NotificationTarget.self, from: $0) }

        return NotificationItem(
            id: id,
            network: SocialNetwork(rawValue: networkRawValue) ?? .x,
            accountId: accountId,
            sourceId: sourceId,
            type: NotificationType(rawValue: typeRawValue) ?? .unknown,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: target,
            parentTarget: parentTarget
        )
    }
}
