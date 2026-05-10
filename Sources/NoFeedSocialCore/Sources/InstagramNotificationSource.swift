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
        } catch {
            invalidateAccount()
            return .notConfigured
        }
    }

    public func fetchUnreadCount() async throws -> Int? {
        do {
            let categories = metadataStore.instagramAccount?.enabledCategories ?? []
            let username = metadataStore.instagramAccount?.username
            let items = try await client.notifications(enabledCategories: categories, accountUsername: username)
            return items.count
        } catch SourceError.notConfigured {
            return nil
        }
    }

    public func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem] {
        let categories = metadataStore.instagramAccount?.enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        let username = metadataStore.instagramAccount?.username
        return try await client.notifications(enabledCategories: categories, accountUsername: username)
    }

    public func fetchStoryReels() async throws -> [InstagramStoryReel] {
        let tray: [InstagramTrayItem]
        do {
            tray = try await client.reelsTray()
        } catch {
            invalidateAccount()
            return []
        }

        // Successful tray fetch means credentials are valid
        if var account = metadataStore.instagramAccount, account.status != .valid {
            account.status = .valid
            metadataStore.instagramAccount = account
        }

        var reels: [InstagramStoryReel] = []
        for item in tray {
            let actor = NotificationActor(
                id: String(item.user.pk),
                network: .instagram,
                username: item.user.username,
                displayName: item.user.fullName,
                avatarURL: item.user.profilePicUrl.flatMap(URL.init)
            )

            var slides: [InstagramStorySlide] = []
            let userId = String(item.user.pk)
            if let reel = try? await client.userStory(userId: userId).reel {
                for media in reel.items ?? [] {
                    if let candidates = media.imageVersions2?.candidates,
                       let best = candidates.sorted(by: { (a: InstagramMediaCandidate, b: InstagramMediaCandidate) in (a.width ?? 0) > (b.width ?? 0) }).first,
                       let imageURL = URL(string: best.url) {
                        let videoVersion = media.videoVersions?.first
                        let videoURL: URL? = videoVersion.flatMap { URL(string: $0.url) }
                        slides.append(InstagramStorySlide(
                            id: media.id,
                            imageURL: imageURL,
                            videoURL: videoURL,
                            isVideo: media.mediaType == 2
                        ))
                    }
                }
            }

            if !slides.isEmpty {
                reels.append(InstagramStoryReel(
                    id: String(item.id),
                    user: actor,
                    slides: slides
                ))
            }
        }

        return reels
    }

    private func invalidateAccount() {
        guard var account = metadataStore.instagramAccount else { return }
        account.status = .invalidCredentials
        metadataStore.instagramAccount = account
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        do {
            let response = try await client.userInfo(uid: id)
            return NetworkProfile(
                id: String(response.user.pk ?? 0),
                network: .instagram,
                username: response.user.username,
                displayName: response.user.fullName,
                bio: response.user.biography,
                avatarURL: response.user.profilePicUrl.flatMap(URL.init),
                followerCount: response.user.followerCount,
                followingCount: response.user.followingCount,
                postsCount: response.user.mediaCount,
                websiteURL: response.user.externalUrl.flatMap(URL.init),
                isVerified: response.user.isVerified,
                isMutualFollow: (response.user.friendshipStatus?.following == true && response.user.friendshipStatus?.followedBy == true) ? true : nil
            )
        } catch {
            throw SourceError.serviceError("Could not fetch profile.")
        }
    }
}
