import Foundation

public struct XNotificationSource: NotificationFetching, AccountValidating, ProfileFetching, NotificationTargetDetailFetching {
    public let network: SocialNetwork = .x

    private let client: XClient
    private let metadataStore: AccountMetadataStore

    public init(client: XClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        guard (try? client.hasCredentials()) == true else {
            return .notConfigured
        }
        do {
            _ = try await client.verifiedUser()
            return .valid
        } catch {
            if var account = metadataStore.xAccount {
                account.status = .invalidCredentials
                metadataStore.xAccount = account
            }
            return .serviceError(error.localizedDescription)
        }
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

    private func networkProfile(from profile: XProfileResponse) -> NetworkProfile {
        NetworkProfile(
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
            isMutualFollow: (profile.isFollowing == true && profile.isFollowedBy == true) ? true : nil,
        )
    }
}
