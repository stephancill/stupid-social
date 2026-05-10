import Foundation

@MainActor
public final class SpotifyNotificationSource: NotificationSource {
    public let network: SocialNetwork = .spotify

    private let client: SpotifyClient
    private let metadataStore: AccountMetadataStore
    private var audioAnimationCache: [String: MusicAnimationMetadata] = [:]

    public init(client: SpotifyClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        do {
            let username = try await client.validateAccount()
            metadataStore.spotifyAccount = SpotifyAccountMetadata(
                accountId: "spotify",
                username: username,
                status: .valid
            )
            return .valid
        } catch SourceError.notConfigured {
            if var account = metadataStore.spotifyAccount {
                account.status = .invalidCredentials
                metadataStore.spotifyAccount = account
            }
            return .notConfigured
        } catch {
            if var account = metadataStore.spotifyAccount {
                account.status = .invalidCredentials
                metadataStore.spotifyAccount = account
            }
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchUnreadCount() async throws -> Int? {
        return nil
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let accountId = metadataStore.spotifyAccount?.accountId ?? "spotify"
        return try await normalizeFriendActivity(accountId: accountId)
    }

    private func normalizeFriendActivity(accountId: String) async throws -> [NotificationItem] {
        let friends: [SpotifyFriend]
        do {
            friends = try await client.friendActivity()
        } catch SourceError.notConfigured {
            return []
        }

        var items: [NotificationItem] = []

        for friend in friends {
            let timestamp = Date(timeIntervalSince1970: Double(friend.timestamp) / 1000.0)

            let actor = NotificationActor(
                id: friend.user.uri,
                network: .spotify,
                username: friend.user.name,
                displayName: friend.user.name,
                avatarURL: friend.user.imageUrl.flatMap { URL(string: $0) }
            )

            let trackURL = URL(string: "https://open.spotify.com/track/\(trackId(from: friend.track.uri))")
            let imageURL = friend.track.imageUrl.flatMap { URL(string: $0) }
            let trackId = trackId(from: friend.track.uri)
            let animation = await musicAnimation(for: trackId)

            let target = NotificationTarget(
                id: friend.track.uri,
                text: "\(friend.track.name) — \(friend.track.artist?.name ?? "Unknown")",
                url: trackURL,
                imageURL: imageURL,
                album: friend.track.album?.name,
                musicAnimation: animation
            )

            let text = "\(friend.user.name) listened to a song"

            items.append(NotificationItem(
                id: "spotify-friend-\(friend.user.uri)-\(friend.timestamp)",
                network: .spotify,
                accountId: accountId,
                sourceId: "\(friend.timestamp)",
                type: .music,
                timestamp: timestamp,
                text: text,
                actors: [actor],
                target: target
            ))
        }

        return items
    }

    public func fetchProfile(id: String) async throws -> NetworkProfile {
        let username = id.replacingOccurrences(of: "spotify:user:", with: "")

        do {
            let profile = try await client.userProfile(username: username)
            let followingCount = try? await client.userFollowingCount(username: username)
            let followerCount = try? await client.userFollowerCount(username: username)
            let avatar: Foundation.URL? = if let urlStr = profile.images?.first?.url {
                Foundation.URL(string: urlStr)
            } else { nil }
            let website: Foundation.URL? = if let urlStr = profile.external_urls?.spotify {
                Foundation.URL(string: urlStr)
            } else { nil }
            return NetworkProfile(
                id: id,
                network: .spotify,
                username: profile.id,
                displayName: profile.display_name,
                avatarURL: avatar,
                followerCount: followerCount,
                followingCount: followingCount,
                websiteURL: website
            )
        } catch {
            return NetworkProfile(
                id: id,
                network: .spotify,
                username: username,
                displayName: username,
                avatarURL: nil,
                followerCount: nil,
                followingCount: nil
            )
        }
    }

    private func trackId(from uri: String) -> String {
        uri.replacingOccurrences(of: "spotify:track:", with: "")
            .replacingOccurrences(of: "spotify:album:", with: "")
            .replacingOccurrences(of: "spotify:playlist:", with: "")
            .replacingOccurrences(of: "spotify:artist:", with: "")
            .replacingOccurrences(of: "spotify:user:", with: "")
            .replacingOccurrences(of: "spotify:socialsession:", with: "")
    }

    private func musicAnimation(for trackId: String) async -> MusicAnimationMetadata? {
        guard !trackId.isEmpty else { return nil }
        if let cached = audioAnimationCache[trackId] { return cached }

        guard let analysis = try? await client.audioAnalysis(trackId: trackId) else { return nil }
        let metadata = MusicAnimationMetadata(
            tempo: analysis.track.tempo,
            tempoConfidence: analysis.track.tempoConfidence,
            loudness: analysis.track.loudness,
            mode: analysis.track.mode
        )
        audioAnimationCache[trackId] = metadata
        return metadata
    }
}
