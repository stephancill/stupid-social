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

    func upsert(_ items: [NotificationItem], now: Date = Date()) throws {
        for item in items {
            let itemId = item.id
            var descriptor = FetchDescriptor<CachedNotification>(
                predicate: #Predicate { $0.id == itemId }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                try existing.update(with: item, cachedAt: now)
            } else {
                context.insert(try CachedNotification(item: item, cachedAt: now))
            }
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
}
