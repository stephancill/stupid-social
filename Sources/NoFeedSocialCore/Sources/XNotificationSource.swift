import Foundation

public struct XNotificationSource: NotificationSource {
    public let network: SocialNetwork = .x

    private let client: XClient
    private let metadataStore: AccountMetadataStore

    public init(client: XClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        try client.hasCredentials() ? .valid : .notConfigured
    }

    public func fetchUnreadCount() async throws -> Int? {
        try await client.unreadCount()
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        return try await client.notifications()
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        // id is either a screen_name (from actor.username) or numeric user_id
        // Try as screen name first via GraphQL UserByScreenName
        if let profile = try? await client.userProfile(screenName: id) {
            return NetworkProfile(
                id: profile.idStr,
                network: .x,
                username: profile.screenName,
                displayName: profile.name,
                bio: profile.description,
                avatarURL: profile.profileImageUrlHttps.flatMap { urlString in
                    URL(string: urlString.replacingOccurrences(of: "_normal", with: ""))
                },
                followerCount: profile.followersCount,
                followingCount: profile.friendsCount,
                postsCount: profile.statusesCount,
                joinedAt: profile.createdAt,
                isVerified: profile.verified,
                isMutualFollow: (profile.isFollowing == true && profile.isFollowedBy == true) ? true : nil
            )
        }
        throw SourceError.serviceError("X profile lookup failed for @\(id).")
    }
}
