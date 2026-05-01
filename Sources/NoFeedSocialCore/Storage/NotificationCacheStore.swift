import Foundation
import SwiftData

@MainActor
public final class NotificationCacheStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    func loadRecent(now: Date = Date(), retention: TimeInterval = 86_400) throws -> [NotificationItem] {
        try loadRecentEntries(now: now, retention: retention).map(\.item)
    }

    func loadRecentEntries(now: Date = Date(), retention: TimeInterval = 86_400) throws -> [CachedNotificationEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt >= cutoff && !$0.isPending },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        return try context.fetch(descriptor).compactMap { cached in
            guard let item = try? cached.toItem() else { return nil }
            return CachedNotificationEntry(item: item, isNew: cached.isNew)
        }
    }

    func upsert(
        _ items: [NotificationItem],
        now: Date = Date(),
        markInsertedAsNew: Bool = false,
        markInsertedAsPending: Bool = false
    ) throws {
        for item in items {
            let itemId = item.id
            var descriptor = FetchDescriptor<CachedNotification>(
                predicate: #Predicate { $0.id == itemId }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                try existing.update(with: item, cachedAt: now)
            } else {
                context.insert(try CachedNotification(
                    item: item,
                    cachedAt: now,
                    isNew: markInsertedAsNew,
                    isPending: markInsertedAsPending
                ))
            }
        }

        try context.save()
    }

    func markAllKnown() throws {
        let descriptor = FetchDescriptor<CachedNotification>()
        for item in try context.fetch(descriptor) {
            item.isNew = false
        }

        try context.save()
    }

    func pendingCount(now: Date = Date(), retention: TimeInterval = 86_400) throws -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt >= cutoff && $0.isPending }
        )

        return try context.fetchCount(descriptor)
    }

    func revealPending() throws {
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.isPending }
        )

        for item in try context.fetch(descriptor) {
            item.isPending = false
            item.isNew = true
        }

        try context.save()
    }

    func clearPending() throws {
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.isPending }
        )

        for item in try context.fetch(descriptor) {
            item.isPending = false
            item.isNew = false
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

struct CachedNotificationEntry {
    let item: NotificationItem
    let isNew: Bool
}
