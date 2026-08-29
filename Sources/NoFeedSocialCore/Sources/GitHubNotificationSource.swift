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
        let items = try await fetch(credentials: credentials).notificationItems.map { item in
            notificationItem(from: item, accountId: accountId)
        }
        return mergeByRepository(items)
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        let avatarURL = URL(string: "https://github.com/\(id).png?size=192")
        return NetworkProfile(id: id, network: .github, username: id, displayName: nil, avatarURL: avatarURL, followerCount: nil, followingCount: nil)
    }

    public func searchProfiles(query _: String) async throws -> [NetworkProfile] {
        []
    }

    public func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails {
        let viewer = NotificationActor(
            id: item.accountId,
            network: .github,
            username: item.accountId,
            displayName: nil,
            avatarURL: URL(string: "https://github.com/\(item.accountId).png?size=96"),
        )
        return NotificationTargetDetails(
            author: item.target?.author ?? viewer,
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

    /// Groups "starred your repository" notifications by repo, the same way
    /// reactions are grouped onto the same post: many people starring the same
    /// owned repo collapse into a single row like "SystemAbort and 4 others
    /// starred stephancill/pfwc".
    private func mergeByRepository(_ items: [NotificationItem]) -> [NotificationItem] {
        var byRepo: [String: [NotificationItem]] = [:]
        var ungrouped: [NotificationItem] = []
        for item in items {
            if item.type == .reaction, let repo = item.target?.id {
                byRepo[repo, default: []].append(item)
            } else {
                ungrouped.append(item)
            }
        }
        let grouped = byRepo.compactMap { _, group in
            mergeRepositoryGroup(group)
        }
        return (ungrouped + grouped).sorted { $0.timestamp > $1.timestamp }
    }

    private func mergeRepositoryGroup(_ group: [NotificationItem]) -> NotificationItem {
        let first = group[0]
        guard group.count > 1 else { return first }

        var seen = Set<String>()
        var actors: [NotificationActor] = []
        for item in group {
            for actor in item.actors where seen.insert(actor.id).inserted {
                actors.append(actor)
            }
        }
        let newestTimestamp = group.map(\.timestamp).max() ?? first.timestamp
        let firstActor = actors.first?.username.map { "@\($0)" } ?? "Someone"
        let suffix = actors.count > 1
            ? " and \(actors.count - 1) other\(actors.count == 2 ? "" : "s")"
            : ""
        let repoKey = (first.target?.id ?? "").lowercased()
        return NotificationItem(
            id: "github:\(first.accountId):yourstar:\(repoKey)",
            network: .github,
            accountId: first.accountId,
            sourceId: first.sourceId,
            type: .reaction,
            timestamp: newestTimestamp,
            text: "\(firstActor)\(suffix) starred your repository",
            actors: actors,
            target: first.target,
        )
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
        let viewer = NotificationActor(
            id: accountId,
            network: .github,
            username: accountId,
            displayName: nil,
            avatarURL: URL(string: "https://github.com/\(accountId).png?size=96"),
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
                text: item.repoDescription ?? item.targetName,
                url: item.targetURL,
                imageURL: item.targetAvatarURL,
                author: viewer,
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
