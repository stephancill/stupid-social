import Foundation

@MainActor
public final class InstagramNotificationSource: NotificationSource {
    public let network: SocialNetwork = .instagram

    private let client: InstagramClient
    private let metadataStore: AccountMetadataStore

    public init(client: InstagramClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        do {
            let user = try await client.verifiedUser()
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: String(user.pk),
                username: user.username,
                status: .valid
            )
            return .valid
        } catch SourceError.notConfigured {
            return .notConfigured
        } catch {
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchUnreadCount() async throws -> Int? {
        do {
            let categories = metadataStore.instagramAccount?.enabledCategories ?? []
            let items = try await client.notifications(enabledCategories: categories)
            return items.count
        } catch SourceError.notConfigured {
            return nil
        }
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        let categories = metadataStore.instagramAccount?.enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        return try await client.notifications(enabledCategories: categories)
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        do {
            let response = try await client.userInfo(uid: id)
            return NetworkProfile(
                id: String(response.user.pk ?? 0),
                network: .instagram,
                username: response.user.username,
                displayName: response.user.fullName,
                avatarURL: response.user.profilePicUrl.flatMap(URL.init),
                followerCount: response.user.followerCount,
                followingCount: response.user.followingCount
            )
        } catch {
            throw SourceError.serviceError("Could not fetch profile.")
        }
    }
}
