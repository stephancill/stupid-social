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

        _ = try await client.user(byUsername: account.username)
        return .valid
    }

    public func fetchUnreadCount() async throws -> Int? {
        guard let account = metadataStore.farcasterAccount else {
            throw SourceError.notConfigured
        }

        let response = try await client.notifications(fid: account.fid)
        return response.notifications.count
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        guard let account = metadataStore.farcasterAccount else {
            throw SourceError.notConfigured
        }

        let response = try await client.notifications(fid: account.fid)
        return response.notifications.map { normalize($0, accountId: String(account.fid)) }
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        guard let username = metadataStore.farcasterAccount?.username else {
            throw SourceError.notConfigured
        }

        let user = try await client.user(byUsername: username)
        return NetworkProfile(
            id: String(user.fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl,
            followerCount: user.followerCount,
            followingCount: user.followingCount
        )
    }

    private func normalize(
        _ notification: FarcasterNotificationResponse,
        accountId: String
    ) -> NotificationItem {
        let timestamp = notification.notificationDate
        let type = normalizeType(notification.type)
        let actors = notificationActors(notification)
        let sourceId = notification.cast?.hash ?? "\(notification.type)-\(Int(timestamp.timeIntervalSince1970))"
        let text = notificationText(notification, type: type, actors: actors)

        return NotificationItem(
            id: "farcaster:\(accountId):\(sourceId):\(Int(timestamp.timeIntervalSince1970))",
            network: .farcaster,
            accountId: accountId,
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: notification.cast.map {
                NotificationTarget(id: $0.hash, text: $0.text, url: nil)
            },
            parentTarget: nil
        )
    }

    private func normalizeType(_ type: String) -> NotificationType {
        switch type {
        case "reply": .reply
        case "mention": .mention
        case "cast-mention": .mention
        case "cast-reply": .reply
        case "reaction": .reaction
        case "follow": .follow
        default: .unknown
        }
    }

    private func notificationActors(_ notification: FarcasterNotificationResponse) -> [NotificationActor] {
        if let user = notification.user {
            return [actor(from: user)]
        }

        if let author = notification.cast?.author {
            return [actor(from: author)]
        }

        if let reactions = notification.reactions, !reactions.isEmpty {
            return reactions.compactMap(actor(from:))
        }

        if let follows = notification.follows, !follows.isEmpty {
            return follows.compactMap(actor(from:))
        }

        return []
    }

    private func actor(from user: FarcasterUserResponse) -> NotificationActor {
        NotificationActor(
            id: String(user.fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl
        )
    }

    private func actor(from user: FarcasterReactionResponse) -> NotificationActor? {
        guard let fid = user.fid else { return nil }
        return NotificationActor(
            id: String(fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl
        )
    }

    private func actor(from user: FarcasterFollowResponse) -> NotificationActor? {
        guard let fid = user.fid else { return nil }
        return NotificationActor(
            id: String(fid),
            network: .farcaster,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.pfpUrl
        )
    }

    private func notificationText(
        _ notification: FarcasterNotificationResponse,
        type: NotificationType,
        actors: [NotificationActor]
    ) -> String {
        let actorName = actors.first?.username.map { "@\($0)" } ?? "Someone"

        return switch type {
        case .mention: "\(actorName) mentioned you"
        case .reply: "\(actorName) replied to you"
        case .reaction: "\(actorName) reacted to your cast"
        case .follow: "\(actorName) followed you"
        case .unknown: notification.cast?.text ?? "New Farcaster notification"
        }
    }
}
