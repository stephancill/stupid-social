import Foundation

public struct XNotificationSource: NotificationFetching, ProfileFetching, NotificationTargetDetailFetching, RelationshipMutating, PostEngaging, PostThreadLoading, ProfileTimelineLoading {
    public let network: SocialNetwork = .x

    private let client: XClient
    private let metadataStore: AccountMetadataStore

    public init(client: XClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let categories = metadataStore.xAccount?.enabledCategories ?? Set(XNotificationCategory.allCases)
        return try await client.notifications().filter { item in
            guard let category = XNotificationCategory.category(for: item.type) else { return false }
            return categories.contains(category)
        }
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        // id is either a screen_name (from actor.username) or numeric user_id
        // Try as screen name first via GraphQL UserByScreenName
        if let profile = try? await client.userProfile(screenName: id) {
            return networkProfile(from: profile)
        }
        throw SourceError.serviceError("X profile lookup failed for @\(id).")
    }

    public func searchProfiles(query: String) async throws -> [NetworkProfile] {
        let users = try await client.searchUsers(query: query)
        return users.map(networkProfile(from:))
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        if item.type == .post {
            let relatedTargets = try await client.deviceFollowTargets(for: item)
            return NotificationTargetDetails(relatedTargets: relatedTargets)
        }

        guard let tweetId = item.target?.id ?? item.sourceId,
              tweetId.allSatisfy(\.isNumber), !tweetId.isEmpty
        else {
            throw SourceError.unsupported
        }

        return try await client.tweetDetails(tweetId: tweetId)
    }

    public func setFollowing(profile: NetworkProfile, follow: Bool) async throws {
        try await client.setFollowing(userId: profile.id, follow: follow)
    }

    public func setPostNotifications(profile: NetworkProfile, enabled: Bool) async throws {
        try await client.setPostNotifications(userId: profile.id, enabled: enabled)
    }

    public func fetchEngagement(postId: String) async throws -> PostEngagement {
        try await client.tweetEngagement(tweetId: postId)
    }

    public func setLiked(postId: String, liked: Bool) async throws {
        try await client.setLiked(tweetId: postId, liked: liked)
    }

    /// X turns away `CreateRetweet` from this client, so reposting opens X's repost page; undoing works here.
    public func setReposted(postId: String, reposted: Bool) async throws {
        guard !reposted else { throw SourceError.unsupported }
        try await client.deleteRetweet(tweetId: postId)
    }

    public func repostPageURL(postId: String) -> URL? {
        var components = URLComponents(string: "https://x.com/intent/retweet")!
        components.queryItems = [URLQueryItem(name: "tweet_id", value: postId)]
        return components.url
    }

    public func reply(to postId: String, text: String) async throws {
        try await client.createTweet(text: text, replyTo: postId)
    }

    public func quote(postId: String, text: String) async throws {
        try await client.createTweet(text: text, quoting: postId)
    }

    public func fetchThread(postId: String) async throws -> PostThread {
        try await client.conversation(tweetId: postId)
    }

    /// Media by likes is the most-liked posts with a photo, video or card image: `UserMedia` ignores
    /// `sortByMostLiked`, and `ProfileFilter`, the web client's sorted filter, answers empty for every profile
    /// (observed 2026-11-17). About one most-liked post in seven has media, so this reads up to four pages for some.
    public func fetchProfileTimeline(userId: String, kind: ProfileTimelineKind, cursor: String?) async throws -> ProfileTimelinePage {
        guard kind == .mediaMostLiked else {
            return try await client.userTimeline(userId: userId, kind: kind, cursor: cursor)
        }
        var items: [ProfileTimelineItem] = []
        var next = cursor
        for _ in 0 ..< 4 {
            let page = try await client.userTimeline(userId: userId, kind: kind, cursor: next)
            items += page.items.filter { $0.thumbnailURL != nil }
            next = page.nextCursor
            if !items.isEmpty || next == nil { break }
        }
        return ProfileTimelinePage(items: items, nextCursor: next)
    }

    private func networkProfile(from profile: XProfileResponse) -> NetworkProfile {
        NetworkProfile(
            id: profile.idStr,
            network: .x,
            username: profile.screenName,
            displayName: profile.name,
            bio: profile.description,
            location: profile.location,
            avatarURL: profile.profileImageUrlHttps.flatMap { urlString in
                URL(string: urlString.replacingOccurrences(of: "_normal", with: ""))
            },
            followerCount: profile.followersCount,
            followingCount: profile.friendsCount,
            postsCount: profile.statusesCount,
            joinedAt: profile.createdAt,
            websiteURL: profile.websiteURL,
            isVerified: profile.verified,
            isMutualFollow: (profile.isFollowing == true && profile.isFollowedBy == true) ? true : nil,
            isFollowing: profile.isFollowing,
            isNotifiedForPosts: profile.isNotifiedForPosts,
        )
    }
}
