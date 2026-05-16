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

    public var storiesEnabled: Bool {
        metadataStore.instagramAccount?.storiesEnabled ?? true
    }

    public func ownStoryActor() async -> NotificationActor? {
        guard let account = metadataStore.instagramAccount else { return nil }
        do {
            let response = try await client.userInfo(uid: account.accountId)
            return NotificationActor(
                id: account.accountId,
                network: .instagram,
                username: response.user.username ?? account.username,
                displayName: response.user.fullName,
                avatarURL: response.user.profilePicUrl.flatMap(URL.init) ?? account.avatarURL,
            )
        } catch {
            return NotificationActor(
                id: account.accountId,
                network: .instagram,
                username: account.username,
                displayName: nil,
                avatarURL: account.avatarURL,
            )
        }
    }

    public func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        try await client.publishPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType)
    }

    public func deleteStory(mediaId: String, isVideo: Bool) async throws {
        try await client.deleteStory(mediaId: mediaId, isVideo: isVideo)
    }

    public func validateAccount() async throws -> AccountStatus {
        do {
            let user = try await client.verifiedUser()
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: String(user.pk),
                username: user.username,
                avatarURL: user.profilePicURL,
                status: .valid,
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

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let categories = metadataStore.instagramAccount?.enabledCategories ?? Set(InstagramNotificationCategory.allCases)
        let username = metadataStore.instagramAccount?.username
        return try await client.notifications(enabledCategories: categories, accountUsername: username)
    }

    public func fetchStoryReels() async throws -> [InstagramStoryReel] {
        let tray: [InstagramTrayItem]
        do {
            tray = try await client.reelsTray()
        } catch SourceError.notConfigured {
            invalidateAccount()
            throw SourceError.notConfigured
        } catch {
            invalidateAccount()
            throw error
        }

        // Successful tray fetch means credentials are valid
        if var account = metadataStore.instagramAccount, account.status != .valid {
            account.status = .valid
            metadataStore.instagramAccount = account
        }

        struct TrayEntry {
            let item: InstagramTrayItem
            let reelId: String
        }

        var trayEntries: [TrayEntry] = []
        var seenUserIds: Set<UInt64> = []
        for item in tray {
            let userId = item.user.pk
            let reelId = item.id
            guard !item.isMuted else { continue }
            guard reelId == String(userId) else { continue }
            if seenUserIds.contains(userId) { continue }
            seenUserIds.insert(userId)

            trayEntries.append(TrayEntry(item: item, reelId: reelId))
        }

        let mediaByReelId = try await client.reelsMedia(reelIds: trayEntries.map(\.reelId))

        var reels: [InstagramStoryReel] = []
        for entry in trayEntries {
            let item = entry.item
            let userId = item.user.pk

            let actor = NotificationActor(
                id: String(userId),
                network: .instagram,
                username: item.user.username,
                displayName: item.user.fullName,
                avatarURL: item.user.profilePicUrl.flatMap(URL.init),
            )

            var slides: [InstagramStorySlide] = []
            if let reel = mediaByReelId[entry.reelId] {
                for media in reel.items ?? [] {
                    if let candidates = media.imageVersions2?.candidates,
                       let best = candidates.sorted(by: { (a: InstagramMediaCandidate, b: InstagramMediaCandidate) in (a.width ?? 0) > (b.width ?? 0) }).first,
                       let imageURL = URL(string: best.url)
                    {
                        let videoVersion = media.videoVersions?.first
                        let videoURL: URL? = videoVersion.flatMap { URL(string: $0.url) }
                        let embed = media.storyFeedMedia?.first { $0.url != nil }
                        let music = media.storyMusicStickers?.compactMap(\.music).first
                        let mentions = media.reelMentions?.compactMap(\.mention) ?? []
                        let links = media.storyLinkStickers?.compactMap(\.link) ?? []
                        slides.append(InstagramStorySlide(
                            id: media.id,
                            imageURL: imageURL,
                            videoURL: videoURL,
                            isVideo: media.mediaType == 2,
                            videoDuration: media.videoDuration,
                            embedURL: embed?.url,
                            embedLabel: embed?.label,
                            music: music,
                            mentions: mentions,
                            links: links,
                            ownerId: String(reel.user?.pk ?? userId),
                            takenAt: media.takenAt ?? 0,
                        ))
                    }
                }
            }

            if !slides.isEmpty {
                slides.sort { $0.takenAt > $1.takenAt }
                let latestSlideTakenAt = slides.first?.takenAt ?? 0
                let isSeen = item.seen > 0 && Double(item.seen) >= latestSlideTakenAt
                reels.append(InstagramStoryReel(
                    id: entry.reelId,
                    user: actor,
                    slides: slides,
                    isSeen: isSeen,
                    hasCloseFriendsMedia: item.hasBestiesMedia,
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

    public func markReelAsSeen(slides: [InstagramStorySlide]) async {
        let items = slides.map { slide in
            (mediaId: slide.id, ownerId: slide.ownerId, takenAt: slide.takenAt)
        }
        try? await client.markStorySeen(mediaItems: items)
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
                isMutualFollow: (response.user.friendshipStatus?.following == true && response.user.friendshipStatus?.followedBy == true) ? true : nil,
            )
        } catch {
            throw SourceError.serviceError("Could not fetch profile.")
        }
    }

    public func fetchTargetMetrics(for item: NotificationItem) async throws -> NotificationTargetMetrics {
        guard let mediaId = item.target?.id else {
            throw SourceError.unsupported
        }

        let response = try await client.mediaInfo(mediaId: mediaId)
        guard let media = response.items.first else {
            throw SourceError.invalidResponse
        }

        let author = media.user.map { user in
            NotificationActor(
                id: user.pk.map(String.init) ?? user.username ?? mediaId,
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicUrl.flatMap(URL.init),
            )
        }

        return NotificationTargetMetrics(
            author: author,
            text: media.caption?.text,
            imageURLs: media.bestImageURLs,
            postedAt: media.takenAt.map { Date(timeIntervalSince1970: $0) },
            likeCount: media.likeCount,
        )
    }
}
