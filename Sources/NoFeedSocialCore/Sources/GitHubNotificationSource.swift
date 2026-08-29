import Foundation

@MainActor
public final class GitHubNotificationSource: NotificationFetching, AccountValidating, ProfileFetching, NotificationTargetDetailFetching {
    public let network: SocialNetwork = .github

    private let client: GitHubClient
    private let credentialStore: KeychainCredentialStore
    private let metadataStore: AccountMetadataStore

    public init(client: GitHubClient, credentialStore: KeychainCredentialStore, metadataStore: AccountMetadataStore) {
        self.client = client
        self.credentialStore = credentialStore
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        guard let credentials = try credentialStore.loadGitHubCredentials() else {
            return .notConfigured
        }
        do {
            _ = try await fetch(credentials: credentials)
            return .valid
        } catch SourceError.notConfigured {
            markInvalid()
            return .invalidCredentials
        } catch {
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        guard let credentials = try credentialStore.loadGitHubCredentials() else { return [] }
        let accountId = credentials.username ?? "github"
        return try await fetch(credentials: credentials).notificationItems.map { item in
            notificationItem(from: item, accountId: accountId)
        }
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        let avatarURL = URL(string: "https://github.com/\(id).png?size=192")
        return NetworkProfile(id: id, network: .github, username: id, displayName: nil, avatarURL: avatarURL, followerCount: nil, followingCount: nil)
    }

    public func searchProfiles(query _: String) async throws -> [NetworkProfile] {
        []
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        NotificationTargetDetails(
            author: item.actors.first,
            text: item.target?.text,
            postedAt: item.timestamp,
        )
    }

    private func fetch(credentials: GitHubCredentials) async throws -> GitHubFeedParseResult {
        let result = try await client.forYouFeed(credentials: credentials)
        guard case let .feed(response) = result else {
            return GitHubFeedParseResult(storyGroups: [], notificationItems: [])
        }
        return try GitHubActivityParser.parse(response.html, viewerUsername: credentials.username)
    }

    private func notificationItem(from item: GitHubActivityItem, accountId: String) -> NotificationItem {
        let actor = NotificationActor(
            id: item.actor.username ?? item.actor.id,
            network: .github,
            username: item.actor.username,
            displayName: item.actor.displayName,
            avatarURL: item.actor.avatarURL,
            timestamp: item.timestamp,
        )
        return NotificationItem(
            id: "github:\(accountId):\(item.id)",
            network: .github,
            accountId: accountId,
            sourceId: item.id,
            type: .reaction,
            timestamp: item.timestamp,
            text: "\(actor.username ?? "Someone") starred your repository",
            actors: [actor],
            target: NotificationTarget(
                id: item.targetName,
                text: item.targetName,
                url: item.targetURL,
                author: actor,
                postedAt: item.timestamp,
            ),
        )
    }

    private func markInvalid() {
        guard var account = metadataStore.githubAccount else { return }
        account.status = .invalidCredentials
        metadataStore.githubAccount = account
    }
}
