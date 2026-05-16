import Foundation

public struct FarcasterNotificationSource: NotificationSource {
    public let network: SocialNetwork = .farcaster

    private let client: FarcasterClient
    private let metadataStore: AccountMetadataStore

    public init(client: FarcasterClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        guard let account = metadataStore.farcasterAccount else {
            return .notConfigured
        }

        do {
            _ = try await client.user(byUsername: account.username)
            return .valid
        } catch {
            var updated = account
            updated.status = .invalidCredentials
            metadataStore.farcasterAccount = updated
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchUnreadCount() async throws -> Int? {
        guard let account = metadataStore.farcasterAccount else {
            throw SourceError.notConfigured
        }

        let response = try await client.notifications(fid: account.fid)
        let items = filteredItems(from: response.notifications, account: account)
        return groupItems(items, accountId: String(account.fid)).count
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        guard let account = metadataStore.farcasterAccount else {
            throw SourceError.notConfigured
        }

        let response = try await client.notifications(fid: account.fid)
        let items = filteredItems(from: response.notifications, account: account)
        return groupItems(items, accountId: String(account.fid))
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        guard let fid = UInt64(id) else {
            throw SourceError.serviceError("Invalid FID")
        }
        let user = try await client.user(byFid: fid)
        return NetworkProfile(
            id: String(user.fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            bio: user.bio,
            avatarURL: user.pfpUrl,
            followerCount: user.followerCount,
            followingCount: user.followingCount,
            joinedAt: user.registeredAt,
        )
    }

    public func fetchTargetMetrics(for item: NotificationItem) async throws -> NotificationTargetMetrics {
        guard let target = item.target else {
            throw SourceError.unsupported
        }
        let authorFid = target.author?.id ?? item.accountId
        let likeCount = try await client.reactionCount(castHash: target.id, authorFid: authorFid)
        let cast = try? await client.cast(hash: target.id, fid: authorFid)
        let imageURLs = cast?.embeds?.compactMap { $0.url.flatMap(URL.init) } ?? []

        return NotificationTargetMetrics(
            author: cast?.author.map { author in
                NotificationActor(
                    id: String(author.fid),
                    network: .farcaster,
                    username: author.username,
                    displayName: author.displayName,
                    avatarURL: author.pfpUrl,
                )
            },
            text: cast?.displayText ?? cast?.text,
            imageURLs: imageURLs,
            postedAt: cast?.timestamp,
            likeCount: likeCount,
        )
    }

    private func normalize(
        _ notification: FarcasterNotificationResponse,
        accountId: String,
    ) -> NotificationItem {
        let timestamp = notification.notificationDate
        let type = normalizeType(notification.type, notification: notification, accountFid: accountId)
        let actors = notificationActors(notification, timestamp: timestamp)
        let sourceId = stableSourceId(notification, type: notification.type)
        let text = notificationText(notification, type: type, actors: actors)

        let imageURLs = notification.cast?
            .embeds?
            .compactMap { $0.url.flatMap(URL.init) } ?? []
        let imageURL = imageURLs.first

        return NotificationItem(
            id: "farcaster:\(accountId):\(sourceId)",
            network: .farcaster,
            accountId: accountId,
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: notification.cast.map { cast in
                NotificationTarget(
                    id: cast.hash,
                    text: cast.displayText ?? cast.text,
                    url: nil,
                    imageURL: imageURL,
                    imageURLs: imageURLs,
                    author: cast.author.map { author in
                        NotificationActor(
                            id: String(author.fid),
                            network: .farcaster,
                            username: author.username,
                            displayName: author.displayName,
                            avatarURL: author.pfpUrl,
                        )
                    },
                    postedAt: cast.timestamp,
                    likeCount: cast.reactions?.likesCount,
                )
            },
            parentTarget: parentTarget(from: notification.cast),
        )
    }

    private func parentTarget(from cast: FarcasterCastResponse?) -> NotificationTarget? {
        guard let cast, let parentHash = cast.parentHash else { return nil }
        let author = cast.parentAuthor?.fid.map { fid in
            NotificationActor(
                id: String(fid),
                network: .farcaster,
                username: nil,
                displayName: nil,
                avatarURL: nil,
            )
        }
        return NotificationTarget(
            id: parentHash,
            text: nil,
            url: nil,
            author: author,
        )
    }

    private func filteredItems(
        from notifications: [FarcasterNotificationResponse],
        account: FarcasterAccountMetadata,
    ) -> [NotificationItem] {
        notifications
            .map { normalize($0, accountId: String(account.fid)) }
            .filter { item in
                guard let category = FarcasterNotificationCategory.category(for: item.type) else { return false }
                return account.enabledCategories.contains(category)
            }
    }

    private func stableSourceId(_ notification: FarcasterNotificationResponse, type: String) -> String {
        if let hash = notification.cast?.hash {
            return hash
        }
        if let user = notification.user {
            return "\(type):\(user.fid)"
        }
        if let reaction = notification.reactions?.first, let fid = reaction.fid {
            return "\(type):\(fid)"
        }
        if let follow = notification.follows?.first, let fid = follow.fid {
            return "\(type):\(fid)"
        }
        return "\(type):fallback"
    }

    private func normalizeType(_ type: String, notification: FarcasterNotificationResponse, accountFid: String) -> NotificationType {
        switch type {
        case "reply":
            // Hypersnap returns "reply" for all CastAdd messages.
            // Distinguish: replies have parent_author.fid == accountFid, mentions do not.
            if let parentFid = notification.cast?.parentAuthor?.fid, String(parentFid) == accountFid {
                return .reply
            }
            return .mention
        case "mention", "cast-mention": return .mention
        case "cast-reply": return .reply
        case "reaction", "likes": return .reaction
        case "follow", "follows": return .follow
        default: return .unknown
        }
    }

    private func notificationActors(_ notification: FarcasterNotificationResponse, timestamp: Date) -> [NotificationActor] {
        if let user = notification.user {
            return [actor(from: user, timestamp: timestamp)]
        }

        if let author = notification.cast?.author {
            return [actor(from: author, timestamp: timestamp)]
        }

        if let reactions = notification.reactions, !reactions.isEmpty {
            return reactions.compactMap { actor(from: $0, timestamp: timestamp) }
        }

        if let follows = notification.follows, !follows.isEmpty {
            return follows.compactMap { actor(from: $0, timestamp: timestamp) }
        }

        return []
    }

    private func actor(from user: FarcasterUserResponse, timestamp: Date) -> NotificationActor {
        NotificationActor(
            id: String(user.fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl,
            timestamp: timestamp,
        )
    }

    private func actor(from user: FarcasterReactionResponse, timestamp: Date) -> NotificationActor? {
        guard let fid = user.fid else { return nil }
        return NotificationActor(
            id: String(fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl,
            timestamp: timestamp,
        )
    }

    private func actor(from user: FarcasterFollowResponse, timestamp: Date) -> NotificationActor? {
        guard let fid = user.fid else { return nil }
        return NotificationActor(
            id: String(fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl,
            timestamp: timestamp,
        )
    }

    private func notificationText(
        _ notification: FarcasterNotificationResponse,
        type: NotificationType,
        actors: [NotificationActor],
    ) -> String {
        let actorName = actors.first?.username.map { "@\($0)" } ?? "Someone"

        return switch type {
        case .mention: "\(actorName) mentioned you"
        case .reply: "\(actorName) replied to you"
        case .reaction: "\(actorName) reacted to your cast"
        case .follow: "\(actorName) followed you"
        case .post: "New Farcaster post"
        case .music: "New Farcaster notification"
        case .unknown: notification.cast?.text ?? "New Farcaster notification"
        }
    }

    // ── Grouping ──

    private func groupItems(_ items: [NotificationItem], accountId: String) -> [NotificationItem] {
        var reactionGroups: [String: [NotificationItem]] = [:]
        var followItems: [NotificationItem] = []
        var ungrouped: [NotificationItem] = []

        for item in items {
            if item.type == .reaction, let targetId = item.target?.id {
                reactionGroups[targetId, default: []].append(item)
            } else if item.type == .follow {
                followItems.append(item)
            } else {
                ungrouped.append(item)
            }
        }

        let groupedReactions: [NotificationItem] = reactionGroups.compactMap { _, group in
            mergeGroup(group, type: .reaction, accountId: accountId)
        }

        let groupedFollows: [NotificationItem] = followItems.isEmpty
            ? []
            : [mergeGroup(followItems, type: .follow, accountId: accountId)].compactMap(\.self)

        return (ungrouped + groupedReactions + groupedFollows).sorted { $0.timestamp > $1.timestamp }
    }

    private func mergeGroup(_ group: [NotificationItem], type: NotificationType, accountId _: String) -> NotificationItem? {
        guard let first = group.first else { return nil }

        var seenIds: Set<String> = []
        var mergedActors: [NotificationActor] = []
        for item in group {
            for actor in item.actors where seenIds.insert(actor.id).inserted {
                mergedActors.append(actor)
            }
        }

        let newestTimestamp = group.map(\.timestamp).max() ?? first.timestamp

        let actorName = mergedActors.first?.username.map { "@\($0)" } ?? "Someone"
        let suffix = mergedActors.count > 1
            ? " and \(mergedActors.count - 1) other\(mergedActors.count == 2 ? "" : "s")"
            : ""
        let text: String = switch type {
        case .reaction: "\(actorName)\(suffix) reacted to your cast"
        case .follow: "\(actorName)\(suffix) followed you"
        default: first.text
        }

        return NotificationItem(
            id: first.id,
            network: first.network,
            accountId: first.accountId,
            sourceId: first.sourceId,
            type: first.type,
            timestamp: newestTimestamp,
            text: text,
            actors: mergedActors,
            target: first.target,
            parentTarget: first.parentTarget,
        )
    }
}
