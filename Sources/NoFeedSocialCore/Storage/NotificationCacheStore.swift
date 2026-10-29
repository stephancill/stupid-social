import Foundation
import SwiftData

@MainActor
public final class NotificationCacheStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    func loadRecent(now: Date = Date(), retention: TimeInterval = 86400) throws -> [NotificationItem] {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
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
            try context.insert(CachedNotification(item: item, cachedAt: now))
        }

        try context.save()
    }

    func deleteExpired(now: Date = Date(), retention: TimeInterval = 86400) throws {
        let cutoff = now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<CachedNotification>(
            predicate: #Predicate { $0.cachedAt < cutoff },
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

    /// Replaces one account's items, such as one Apron server's rooms after a live update.
    func replaceAccount(_ items: [NotificationItem], network: SocialNetwork, accountId: String, now: Date = Date()) throws {
        let descriptor = FetchDescriptor<CachedNotification>()
        for existing in try context.fetch(descriptor) where existing.networkRawValue == network.rawValue && existing.accountId == accountId {
            context.delete(existing)
        }
        var seenIds = Set<String>()
        for item in items where item.network == network && item.accountId == accountId {
            guard seenIds.insert(item.id).inserted else { continue }
            try context.insert(CachedNotification(item: item, cachedAt: now))
        }
        try context.save()
    }

    /// Drops items of accounts that were removed, and items cached before accounts were scoped.
    func deleteAccounts(notIn accountIds: Set<String>) throws {
        let descriptor = FetchDescriptor<CachedNotification>()
        var deleted = false
        for item in try context.fetch(descriptor) where !accountIds.contains(item.accountId) {
            context.delete(item)
            deleted = true
        }
        if deleted {
            try context.save()
        }
    }

    func deleteAccount(network: SocialNetwork, accountId: String) throws {
        let descriptor = FetchDescriptor<CachedNotification>()
        for item in try context.fetch(descriptor) where item.networkRawValue == network.rawValue && item.accountId == accountId {
            context.delete(item)
        }

        try context.save()
    }
}
