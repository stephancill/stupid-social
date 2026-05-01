import Foundation

public final class DebugNotificationSource: NotificationSource {
    public let network: SocialNetwork = .debug

    private let client: DebugNotificationsClient
    private let metadataStore: AccountMetadataStore

    public init(client: DebugNotificationsClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        metadataStore.debugAccount == nil ? .notConfigured : .valid
    }

    public func fetchUnreadCount() async throws -> Int? {
        nil
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        guard let account = metadataStore.debugAccount else {
            throw SourceError.notConfigured
        }

        return try await client.notifications(baseURL: account.serverURL).map { notification in
            NotificationItem(
                id: "debug:\(notification.id)",
                network: .debug,
                accountId: account.serverURL.absoluteString,
                sourceId: notification.id,
                type: notification.type,
                timestamp: notification.timestamp,
                text: notification.text,
                actors: [
                    NotificationActor(
                        id: notification.actorUsername,
                        network: .debug,
                        username: notification.actorUsername,
                        displayName: notification.actorUsername,
                        avatarURL: nil
                    ),
                ],
                target: NotificationTarget(id: notification.id, text: notification.text, url: nil)
            )
        }
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        NetworkProfile(
            id: id,
            network: .debug,
            username: id,
            displayName: id,
            avatarURL: nil,
            followerCount: nil,
            followingCount: nil
        )
    }
}
