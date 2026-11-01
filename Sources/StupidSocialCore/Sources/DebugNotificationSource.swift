import Foundation

@MainActor
public final class DebugNotificationSource: NotificationFetching {
    public let network: SocialNetwork = .debug
    /// The debug server is a device setting, so its items belong to this one fixed account id.
    public static let accountId = "debug"

    public var feedSources: FeedAccountSources {
        FeedAccountSources(accountId: Self.accountId, network: .debug, notifications: self)
    }

    private let client: DebugNotificationsClient
    private let accountStore: AccountStore

    public init(client: DebugNotificationsClient, accountStore: AccountStore) {
        self.client = client
        self.accountStore = accountStore
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        guard let account = accountStore.debugAccount else {
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
                        avatarURL: nil,
                    ),
                ],
                target: NotificationTarget(id: notification.id, text: notification.text, url: nil),
            )
        }
    }
}
