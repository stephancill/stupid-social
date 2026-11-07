import Foundation

@MainActor
public final class SpotifyActivitySource: ActivityFetching, ProfileFetching {
    public let network: SocialNetwork = .spotify

    private let client: SpotifyClient
    private let metadataStore: AccountMetadataStore
    private let audioAnalysisStore: SpotifyAudioAnalysisStore
    private var audioAnimationCache: [String: MusicAnimationMetadata] = [:]
    /// Friend activity carries only URIs; these hold what each refresh looked up, by username, track id
    /// and context URI.
    private var profileCache: [String: SpotifyUserProfile] = [:]
    private var trackCache: [String: SpotifyTrackMetadata] = [:]
    private var contextTitleCache: [String: String] = [:]

    public init(client: SpotifyClient, metadataStore: AccountMetadataStore, audioAnalysisStore: SpotifyAudioAnalysisStore = SpotifyAudioAnalysisStore()) {
        self.client = client
        self.metadataStore = metadataStore
        self.audioAnalysisStore = audioAnalysisStore
    }

    public func fetchActivity(reason _: RefreshReason) async throws -> [SpotifyActivityItem] {
        let friends: [SpotifyFriendActivity]
        do {
            friends = try await RefreshTiming.measure("spotify-listening-activity") {
                try await client.friendActivity()
            }
        } catch SourceError.notConfigured {
            return []
        }

        // The lookups don't depend on each other, so they run together.
        let trackIds = unique(friends.compactMap(\.trackId))
        async let tracks: Void = loadTracks(trackIds)
        async let profiles: Void = loadProfiles(unique(friends.map(\.username)))
        async let contexts: Void = loadContextTitles(unique(friends.compactMap(\.contextURI)))
        async let musicAnimations = fetchMusicAnimations(for: trackIds)
        let animations = await musicAnimations
        await profiles
        await contexts
        try await tracks

        var items: [SpotifyActivityItem] = []
        for friend in friends {
            // Only tracks become stories; an episode or a track whose details didn't load is left out.
            guard let trackId = friend.trackId, let track = trackCache[trackId], let trackName = track.name else { continue }
            let profile = profileCache[friend.username]
            items.append(SpotifyActivityItem(
                id: "spotify-friend-\(friend.userURI)-\(Int(friend.timestamp.timeIntervalSince1970 * 1000))",
                timestamp: friend.timestamp,
                userName: profile?.display_name ?? friend.username,
                userURI: friend.userURI,
                userAvatarURL: profile?.images?.first.flatMap { URL(string: $0.url) },
                trackName: trackName,
                artistName: track.artists.first,
                albumName: track.album,
                contextName: friend.contextURI.flatMap { contextTitleCache[$0] },
                trackURI: friend.trackURI,
                trackURL: URL(string: "https://open.spotify.com/track/\(trackId)"),
                imageURL: track.coverURL,
                musicAnimation: animations[trackId],
            ))
        }
        return items
    }

    /// Track details for every track not yet cached. Throws when none of them load, so a broken
    /// lookup is reported instead of showing an empty bar.
    private func loadTracks(_ trackIds: [String]) async throws {
        let missing = trackIds.filter { trackCache[$0] == nil }
        guard !missing.isEmpty else { return }
        let results = await boundedMap(missing) { trackId -> Result<SpotifyTrackMetadata, any Error> in
            do {
                return try await .success(self.client.trackMetadata(trackId: trackId))
            } catch {
                return .failure(error)
            }
        }
        var lastError: (any Error)?
        for (trackId, result) in results {
            switch result {
            case let .success(metadata): trackCache[trackId] = metadata
            case let .failure(error): lastError = error
            }
        }
        if let lastError, !trackIds.contains(where: { trackCache[$0] != nil }) {
            throw lastError
        }
    }

    /// Profiles are best effort: a friend whose profile doesn't load shows their username.
    private func loadProfiles(_ usernames: [String]) async {
        let missing = usernames.filter { profileCache[$0] == nil }
        let results = await boundedMap(missing) { username in
            try? await self.client.userProfile(username: username)
        }
        for (username, profile) in results {
            if let profile { profileCache[username] = profile }
        }
    }

    /// Playlist, album, artist and show titles through oEmbed; other contexts (`spotify:list:…`, say) have none.
    private func loadContextTitles(_ contextURIs: [String]) async {
        let missing = contextURIs.filter { uri in
            contextTitleCache[uri] == nil && Self.titledContextKinds.contains(uri.split(separator: ":").dropFirst().first.map(String.init) ?? "")
        }
        let results = await boundedMap(missing) { uri -> String? in
            guard let url = SpotifyMessagesSource.openURL(forShareURI: uri) else { return nil }
            return try? await self.client.shareMetadata(url: url).title
        }
        for (uri, title) in results {
            if let title { contextTitleCache[uri] = title }
        }
    }

    private static let titledContextKinds: Set<String> = ["playlist", "album", "artist", "show"]

    private func fetchMusicAnimations(for trackIds: [String]) async -> [String: MusicAnimationMetadata] {
        let results = await boundedMap(trackIds) { trackId -> MusicAnimationMetadata? in
            if let cached = self.audioAnimationCache[trackId] { return cached }
            if let persisted = self.audioAnalysisStore.cachedAnalysis(for: trackId) {
                self.audioAnimationCache[trackId] = persisted
                return persisted
            }
            let analysis = try? await RefreshTiming.measure("spotify-audio-analysis-\(trackId)") {
                try await self.client.audioAnalysis(trackId: trackId)
            }
            guard let analysis else { return nil }
            let metadata = MusicAnimationMetadata(
                tempo: analysis.track.tempo,
                tempoConfidence: analysis.track.tempoConfidence,
                loudness: analysis.track.loudness,
                mode: analysis.track.mode,
            )
            self.audioAnimationCache[trackId] = metadata
            self.audioAnalysisStore.cacheAnalysis(metadata, for: trackId)
            return metadata
        }
        return results.compactMapValues(\.self)
    }

    /// Runs `transform` for every key, at most `spotifyConcurrencyLimit` at a time.
    private func boundedMap<Value: Sendable>(
        _ keys: [String],
        _ transform: @escaping @MainActor (String) async -> Value,
    ) async -> [String: Value] {
        var results: [String: Value] = [:]
        var iterator = keys.makeIterator()
        await withTaskGroup(of: (String, Value).self) { group in
            var inFlight = 0
            while inFlight < Self.spotifyConcurrencyLimit, let key = iterator.next() {
                group.addTask { await (key, transform(key)) }
                inFlight += 1
            }
            while let (key, value) = await group.next() {
                results[key] = value
                if let next = iterator.next() {
                    group.addTask { await (next, transform(next)) }
                }
            }
        }
        return results
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
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

    private static let spotifyConcurrencyLimit = 4
}
