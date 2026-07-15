import Foundation

public struct BlueskyNotificationSource: NotificationFetching, AccountValidating, ProfileFetching, NotificationTargetDetailFetching {
    public let network: SocialNetwork = .bluesky

    private let client: BlueskyClient
    private let metadataStore: AccountMetadataStore

    public init(client: BlueskyClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        guard (try? client.hasCredentials()) == true else { return .notConfigured }
        do {
            _ = try await client.validateAccount()
            return .valid
        } catch {
            if var account = metadataStore.blueskyAccount {
                account.status = .invalidCredentials
                metadataStore.blueskyAccount = account
            }
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        guard let account = metadataStore.blueskyAccount else { throw SourceError.notConfigured }
        return try await client.notifications().map { notification in
            normalize(notification, account: account)
        }
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        let profile = try await client.profile(did: id)
        return networkProfile(from: profile)
    }

    public func searchProfiles(query: String) async throws -> [NetworkProfile] {
        try await client.searchProfiles(query: query).map(networkProfile(from:))
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        guard let uri = item.target?.id ?? item.sourceId else { throw SourceError.unsupported }
        guard let post = try await client.postThread(uri: uri) else { throw SourceError.invalidResponse }
        return NotificationTargetDetails(
            author: actor(from: post.author, timestamp: post.indexedAt),
            text: post.record?.text,
            postedAt: post.record?.createdAt ?? post.indexedAt,
            likeCount: post.likeCount,
        )
    }

    private func normalize(_ notification: BlueskyNotification, account: BlueskyAccountMetadata) -> NotificationItem {
        let type = notificationType(reason: notification.reason)
        let actor = actor(from: notification.author, timestamp: notification.indexedAt)
        let sourceId = notification.reasonSubject ?? notification.uri
        return NotificationItem(
            id: "bluesky:\(account.did):\(notification.reason):\(sourceId)",
            network: .bluesky,
            accountId: account.did,
            sourceId: sourceId,
            type: type,
            timestamp: notification.indexedAt,
            text: text(for: type, actor: actor, notification: notification),
            actors: [actor],
            target: NotificationTarget(
                id: notification.reasonSubject ?? notification.uri,
                text: notification.record?.text,
                url: postURL(from: notification.reasonSubject ?? notification.uri),
                author: actor,
                postedAt: notification.record?.createdAt,
            ),
        )
    }

    private func notificationType(reason: String) -> NotificationType {
        switch reason {
        case "mention": .mention
        case "reply": .reply
        case "like", "repost", "quote": .reaction
        case "follow": .follow
        default: .unknown
        }
    }

    private func text(for type: NotificationType, actor: NotificationActor, notification: BlueskyNotification) -> String {
        let name = actor.username.map { "@\($0)" } ?? "Someone"
        return switch type {
        case .mention: "\(name) mentioned you"
        case .reply: "\(name) replied to you"
        case .reaction: "\(name) \(reactionVerb(reason: notification.reason)) your post"
        case .follow: "\(name) followed you"
        default: notification.record?.text ?? "New Bluesky notification"
        }
    }

    private func reactionVerb(reason: String) -> String {
        switch reason {
        case "like": "liked"
        case "repost": "reposted"
        case "quote": "quoted"
        default: "reacted to"
        }
    }

    private func postURL(from uri: String) -> URL? {
        let parts = uri.split(separator: "/")
        guard parts.count >= 2, parts[0].hasPrefix("at:"), parts[parts.count - 2] == "app.bsky.feed.post" else {
            return nil
        }
        return URL(string: "https://bsky.app/profile/\(parts[1])/post/\(parts[parts.count - 1])")
    }

    private func actor(from profile: BlueskyProfileViewBasic, timestamp: Date?) -> NotificationActor {
        NotificationActor(id: profile.did, network: .bluesky, username: profile.handle, displayName: profile.displayName, avatarURL: profile.avatar, timestamp: timestamp)
    }

    private func networkProfile(from profile: BlueskyProfileViewBasic) -> NetworkProfile {
        NetworkProfile(id: profile.did, network: .bluesky, username: profile.handle, displayName: profile.displayName, avatarURL: profile.avatar, followerCount: nil, followingCount: nil)
    }

    private func networkProfile(from profile: BlueskyProfileViewDetailed) -> NetworkProfile {
        NetworkProfile(id: profile.did, network: .bluesky, username: profile.handle, displayName: profile.displayName, bio: profile.description, avatarURL: profile.avatar, followerCount: profile.followersCount, followingCount: profile.followsCount, postsCount: profile.postsCount)
    }
}
