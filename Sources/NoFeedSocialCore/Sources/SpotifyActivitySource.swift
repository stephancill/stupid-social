import Foundation

@MainActor
public final class SpotifyActivitySource: ActivityFetching, AccountValidating, ProfileFetching {
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
                status: .valid,
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

    public func fetchActivity(reason _: RefreshReason) async throws -> [SpotifyActivityItem] {
        let friends: [SpotifyFriend]
        do {
            friends = try await client.friendActivity()
        } catch SourceError.notConfigured {
            return []
        }

        var items: [SpotifyActivityItem] = []

        for friend in friends {
            let timestamp = Date(timeIntervalSince1970: Double(friend.timestamp) / 1000.0)
            let trackId = trackId(from: friend.track.uri)
            let animation = await musicAnimation(for: trackId)

            items.append(SpotifyActivityItem(
                id: "spotify-friend-\(friend.user.uri)-\(friend.timestamp)",
                timestamp: timestamp,
                userName: friend.user.name,
                userURI: friend.user.uri,
                userAvatarURL: friend.user.imageUrl.flatMap { URL(string: $0) },
                trackName: friend.track.name,
                artistName: friend.track.artist?.name,
                albumName: friend.track.album?.name,
                contextName: friend.track.context?.name,
                trackURI: friend.track.uri,
                trackURL: URL(string: "https://open.spotify.com/track/\(trackId)"),
                imageURL: friend.track.imageUrl.flatMap { URL(string: $0) },
                musicAnimation: animation,
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
                websiteURL: website,
            )
        } catch {
            return NetworkProfile(
                id: id,
                network: .spotify,
                username: username,
                displayName: username,
                avatarURL: nil,
                followerCount: nil,
                followingCount: nil,
            )
        }
    }

    public func searchProfiles(query: String) async throws -> [NetworkProfile] {
        guard (try? client.hasCredentials()) == true else {
            throw SourceError.notConfigured
        }
        let normalized = String(query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
        guard !normalized.isEmpty else { return [] }

        let profiles = try await client.searchUsers(query: normalized)
        var results: [NetworkProfile] = []
        for profile in profiles {
            await results.append(networkProfile(from: profile))
        }
        return results
    }

    private func networkProfile(from profile: SpotifyUserProfile) async -> NetworkProfile {
        let username = profile.id
        let followingCount = try? await client.userFollowingCount(username: username)
        let followerCount = try? await client.userFollowerCount(username: username)
        let avatar: Foundation.URL? = if let urlStr = profile.images?.first?.url {
            Foundation.URL(string: urlStr)
        } else { nil }
        let website: Foundation.URL? = if let urlStr = profile.external_urls?.spotify {
            Foundation.URL(string: urlStr)
        } else { nil }
        return NetworkProfile(
            id: username,
            network: .spotify,
            username: username,
            displayName: profile.display_name,
            avatarURL: avatar,
            followerCount: followerCount,
            followingCount: followingCount,
            websiteURL: website,
        )
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
            mode: analysis.track.mode,
        )
        audioAnimationCache[trackId] = metadata
        return metadata
    }
}
