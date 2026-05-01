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
        guard let account = metadataStore.xAccount else {
            throw SourceError.notConfigured
        }

        return NetworkProfile(
            id: account.accountId,
            network: .x,
            username: account.handle,
            displayName: account.handle,
            avatarURL: nil,
            followerCount: nil,
            followingCount: nil
        )
    }
}
