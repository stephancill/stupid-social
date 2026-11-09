import Foundation

public struct FarcasterNotificationSource: NotificationFetching, ProfileFetching, NotificationTargetDetailFetching, PostThreadLoading {
    public let network: SocialNetwork = .farcaster

    /// How many casts above a reply a thread loads; each is its own request.
    static let maxThreadDepth = 20

    private let client: FarcasterClient
    private let metadataStore: AccountMetadataStore

    public init(client: FarcasterClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        guard let account = metadataStore.farcasterAccount else {
            throw SourceError.notConfigured
        }

        let response = try await client.notifications(fid: account.fid)
        return Self.items(from: response.notifications, account: account)
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        guard let fid = UInt64(id) else {
            throw SourceError.serviceError("Invalid FID")
        }
        let user = try await client.user(byFid: fid)
        return profile(from: user)
    }

    public func searchProfiles(query: String) async throws -> [NetworkProfile] {
        try await client.searchUsers(query: query).map(profile(from:))
    }

    private func profile(from user: FarcasterUserResponse) -> NetworkProfile {
        NetworkProfile(
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

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        guard let target = item.target else {
            throw SourceError.unsupported
        }
        let authorFid = target.author?.id ?? metadataStore.farcasterAccount.map { String($0.fid) } ?? ""
        let likeCount = try await client.reactionCount(castHash: target.id, authorFid: authorFid)
        let cast = try? await client.cast(hash: target.id, fid: authorFid)

        return NotificationTargetDetails(
            author: cast?.author.map { Self.actor(from: $0) },
            text: cast?.displayText ?? cast?.text,
            imageURLs: cast.map(Self.imageURLs(in:)) ?? [],
            postedAt: cast?.timestamp,
            likeCount: likeCount,
        )
    }

    /// Hypersnap's `/cast/conversation` returns no casts above the one asked for (observed 2026-11-09), so this
    /// walks `parent_hash` up one cast at a time (`scripts/farcaster-client.py thread`).
    public func fetchThread(postId: String) async throws -> PostThread {
        let focal = try await client.cast(hash: postId, fid: nil)
        var ancestors: [FarcasterCastResponse] = []
        var parentHash = focal.parentHash
        while let hash = parentHash, ancestors.count < Self.maxThreadDepth {
            let parent = try await client.cast(hash: hash, fid: nil)
            ancestors.append(parent)
            parentHash = parent.parentHash
        }
        return PostThread(
            ancestors: ancestors.reversed().map { PostThread.Post(target: Self.target(from: $0), engagement: nil) },
            focal: PostThread.Post(target: Self.target(from: focal), engagement: nil),
        )
    }

    // ── Normalizing ──

    /// What a Hypersnap notification's `type` means, with `include_quotes_and_deep_replies` set.
    enum Kind: Equatable {
        case like
        case recast
        case quote
        /// A cast replying to the user's cast, deeper in their thread, or mentioning them (Hypersnap's `reply`).
        case cast
        case follow
        case other
    }

    static func kind(of type: String) -> Kind {
        switch type {
        case "likes", "reaction": .like
        case "recasts": .recast
        case "quote": .quote
        case "reply", "mention", "cast-mention", "cast-reply": .cast
        case "follows", "follow": .follow
        default: .other
        }
    }

    static func items(from notifications: [FarcasterNotificationResponse], account: FarcasterAccountMetadata) -> [NotificationItem] {
        let accountId = String(account.fid)
        let normalized = notifications
            .map { (kind: kind(of: $0.type), notification: $0) }
            .map { (kind: $0.kind, item: normalize($0.notification, kind: $0.kind, accountFid: account.fid)) }
            .filter { entry in
                guard let category = FarcasterNotificationCategory.category(for: entry.item.type) else { return false }
                return account.enabledCategories.contains(category)
            }
        return groupItems(normalized, accountId: accountId)
    }

    private static func normalize(_ notification: FarcasterNotificationResponse, kind: Kind, accountFid: UInt64) -> NotificationItem {
        let accountId = String(accountFid)
        let timestamp = notification.notificationDate
        let type = notificationType(kind, cast: notification.cast, accountFid: accountFid)
        let actors = notificationActors(notification, timestamp: timestamp)
        let sourceId = stableSourceId(notification, kind: kind)

        return NotificationItem(
            id: "farcaster:\(accountId):\(sourceId)",
            network: .farcaster,
            accountId: accountId,
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: notificationText(kind: kind, type: type, cast: notification.cast, accountFid: accountFid, actors: actors),
            actors: actors,
            target: notification.cast.map(target(from:)),
            parentTarget: parentTarget(from: notification.cast),
        )
    }

    /// Quotes count as replies and recasts as reactions, as X's notifications do.
    private static func notificationType(_ kind: Kind, cast: FarcasterCastResponse?, accountFid: UInt64) -> NotificationType {
        switch kind {
        case .like, .recast: return .reaction
        case .quote: return .reply
        case .follow: return .follow
        case .other: return .unknown
        case .cast:
            // Hypersnap calls every cast `reply`: a reply to the user's cast, one deeper in their thread, or a
            // cast that mentions them. A reply deeper down that mentions them is a mention.
            guard let cast, cast.parentHash != nil else { return .mention }
            if cast.parentAuthor?.fid == accountFid { return .reply }
            return mentions(cast, fid: accountFid) ? .mention : .reply
        }
    }

    private static func mentions(_ cast: FarcasterCastResponse, fid: UInt64) -> Bool {
        cast.mentionedProfiles?.contains { $0.fid == fid } == true
    }

    static func target(from cast: FarcasterCastResponse) -> NotificationTarget {
        let imageURLs = imageURLs(in: cast)
        return NotificationTarget(
            id: cast.hash,
            text: cast.displayText ?? cast.text,
            url: nil,
            imageURL: imageURLs.first,
            imageURLs: imageURLs,
            author: cast.author.map { actor(from: $0) },
            postedAt: cast.timestamp,
            likeCount: cast.reactions?.likesCount,
        )
    }

    /// URL embeds; embedded casts (quotes) have no URL.
    private static func imageURLs(in cast: FarcasterCastResponse) -> [URL] {
        cast.embeds?.compactMap { $0.url.flatMap(URL.init) } ?? []
    }

    private static func parentTarget(from cast: FarcasterCastResponse?) -> NotificationTarget? {
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

    /// Likes and recasts of one cast are separate groups, so recasts get their own id.
    private static func stableSourceId(_ notification: FarcasterNotificationResponse, kind: Kind) -> String {
        let type = notification.type
        if let hash = notification.cast?.hash {
            return kind == .recast ? "\(type):\(hash)" : hash
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

    private static func notificationActors(_ notification: FarcasterNotificationResponse, timestamp: Date) -> [NotificationActor] {
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

    private static func actor(from user: FarcasterUserResponse, timestamp: Date? = nil) -> NotificationActor {
        NotificationActor(
            id: String(user.fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl,
            timestamp: timestamp,
        )
    }

    private static func actor(from user: FarcasterReactionResponse, timestamp: Date) -> NotificationActor? {
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

    private static func actor(from user: FarcasterFollowResponse, timestamp: Date) -> NotificationActor? {
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

    private static func notificationText(
        kind: Kind,
        type: NotificationType,
        cast: FarcasterCastResponse?,
        accountFid: UInt64,
        actors: [NotificationActor],
    ) -> String {
        let actorName = actors.first?.username.map { "@\($0)" } ?? "Someone"

        switch kind {
        case .like: return "\(actorName) reacted to your cast"
        case .recast: return "\(actorName) recast your cast"
        case .quote: return "\(actorName) quoted your cast"
        case .follow: return "\(actorName) followed you"
        case .other: return cast?.text ?? "New Farcaster notification"
        case .cast:
            if type == .mention { return "\(actorName) mentioned you" }
            if cast?.parentAuthor?.fid == accountFid { return "\(actorName) replied to you" }
            return "\(actorName) replied in your thread"
        }
    }

    // ── Grouping ──

    private static func groupItems(_ entries: [(kind: Kind, item: NotificationItem)], accountId _: String) -> [NotificationItem] {
        var reactionGroups: [String: [NotificationItem]] = [:]
        var reactionKinds: [String: Kind] = [:]
        var followItems: [NotificationItem] = []
        var ungrouped: [NotificationItem] = []

        for (kind, item) in entries {
            if item.type == .reaction, item.target != nil, let sourceId = item.sourceId {
                reactionGroups[sourceId, default: []].append(item)
                reactionKinds[sourceId] = kind
            } else if item.type == .follow {
                followItems.append(item)
            } else {
                ungrouped.append(item)
            }
        }

        let groupedReactions: [NotificationItem] = reactionGroups.compactMap { sourceId, group in
            mergeGroup(group, kind: reactionKinds[sourceId] ?? .like)
        }

        let groupedFollows: [NotificationItem] = followItems.isEmpty
            ? []
            : [mergeGroup(followItems, kind: .follow)].compactMap(\.self)

        return (ungrouped + groupedReactions + groupedFollows).sorted { $0.timestamp > $1.timestamp }
    }

    private static func mergeGroup(_ group: [NotificationItem], kind: Kind) -> NotificationItem? {
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
        let text: String = switch kind {
        case .like: "\(actorName)\(suffix) reacted to your cast"
        case .recast: "\(actorName)\(suffix) recast your cast"
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
