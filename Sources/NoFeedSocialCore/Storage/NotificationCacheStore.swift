import Foundation
import SwiftData

@MainActor
public final class NotificationCacheStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    func loadRecent(now: Date = Date(), retention: TimeInterval = 86_400) throws -> [NotificationItem] {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        return try context.fetch(descriptor).compactMap { try? $0.toItem() }
    }

    func replaceAll(_ items: [NotificationItem], now: Date = Date()) throws {
        let allDescriptor = FetchDescriptor<CachedNotification>()
        for existing in try context.fetch(allDescriptor) {
            context.delete(existing)
        }

        var seenIds = Set<String>()
        for item in items {
            guard seenIds.insert(item.id).inserted else { continue }
            context.insert(try CachedNotification(item: item, cachedAt: now))
        }

        try context.save()
    }

    func deleteExpired(now: Date = Date(), retention: TimeInterval = 86_400) throws {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        )

        for item in try context.fetch(descriptor) {
            context.delete(item)
        }

        try context.save()
    }

    func deleteNetwork(_ network: SocialNetwork) throws {
        let descriptor = FetchDescriptor<CachedNotification>()
        for item in try context.fetch(descriptor) where item.networkRawValue == network.rawValue {
            context.delete(item)
        }

        try context.save()
    }
}
