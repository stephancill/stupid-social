import Foundation
import CryptoKit

@MainActor
public struct SpotifyClient {
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    private static let spclientBase = "https://spclient.wg.spotify.com"
    private static let appVersion = "1.2.90.229.g33aad738"
    private static let tokenRefreshLeeway: TimeInterval = 120

    public init(credentialStore: KeychainCredentialStore, session: URLSession = defaultSession) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func hasCredentials() throws -> Bool {
        try credentialStore.loadSpotifyCredentials() != nil
    }

    private func credentials() throws -> SpotifyCredentials {
        guard let creds = try credentialStore.loadSpotifyCredentials() else {
            throw SourceError.notConfigured
        }
        return creds
    }

    private func credentialsForRequest() async throws -> SpotifyCredentials {
        let creds = try credentials()
        guard let expiresAt = creds.accessTokenExpiresAt else { return creds }
        guard expiresAt.timeIntervalSinceNow <= Self.tokenRefreshLeeway else { return creds }
        return try await refreshWebPlayerToken(existing: creds)
    }

    private func makeRequest(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let creds = try await credentialsForRequest()
        return try await makeRequest(path, credentials: creds, allowsTokenRefresh: true)
    }

    private func makeRequest(
        _ path: String,
        credentials creds: SpotifyCredentials,
        allowsTokenRefresh: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "\(Self.spclientBase)/\(path)")!)
        request.setValue("Bearer \(creds.bearerToken)", forHTTPHeaderField: "authorization")
        request.setValue(creds.clientToken, forHTTPHeaderField: "client-token")
        request.setValue(Self.appVersion, forHTTPHeaderField: "spotify-app-version")
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("en", forHTTPHeaderField: "accept-language")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.serviceError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            if allowsTokenRefresh {
                let refreshed = try await refreshWebPlayerToken(existing: creds)
                return try await makeRequest(path, credentials: refreshed, allowsTokenRefresh: false)
            }
            throw SourceError.serviceError("Invalid credentials")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SourceError.serviceError("HTTP \(httpResponse.statusCode)")
        }

        return (data, httpResponse)
    }

    private func refreshWebPlayerToken(existing creds: SpotifyCredentials) async throws -> SpotifyCredentials {
        guard !creds.spDC.isEmpty else {
            throw SourceError.serviceError("Spotify login expired")
        }

        var components = URLComponents(string: "https://open.spotify.com/api/token")!
        let token = SpotifyWebPlayerToken.current()
        let serverToken = await SpotifyWebPlayerToken.serverSynchronized(session: session) ?? "unavailable"
        components.queryItems = [
            URLQueryItem(name: "reason", value: "transport"),
            URLQueryItem(name: "productType", value: "web-player"),
            URLQueryItem(name: "totp", value: token),
            URLQueryItem(name: "totpServer", value: serverToken),
            URLQueryItem(name: "totpVer", value: SpotifyWebPlayerToken.version)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("sp_dc=\(creds.spDC)", forHTTPHeaderField: "cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.serviceError("Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SourceError.serviceError("Spotify token refresh failed")
        }

        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        let refreshed = creds.updatingWebPlayerToken(
            decoded.accessToken,
            expiresAt: decoded.accessTokenExpirationTimestampMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        )
        _ = try credentialStore.saveSpotifyCredentials(refreshed)
        return refreshed
    }

    public func validateAccount() async throws -> String {
        let (data, _) = try await makeRequest("presence-view/v1/buddylist")
        _ = try JSONDecoder().decode(SpotifyBuddyListResponse.self, from: data)

        if let username = try? await resolveUsername() {
            return username
        }
        return "spotify"
    }

    private func resolveUsername() async throws -> String {
        let creds = try await credentialsForRequest()
        var request = URLRequest(url: URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(creds.bearerToken)", forHTTPHeaderField: "authorization")
        request.setValue(creds.clientToken, forHTTPHeaderField: "client-token")
        request.setValue(Self.appVersion, forHTTPHeaderField: "spotify-app-version")
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let body: [String: Any] = [
            "variables": [:],
            "operationName": "profileAttributes",
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": "53bcb064f6cd18c23f752bc324a791194d20df612d8e1239c735144ab0399ced"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SourceError.serviceError("Could not resolve username")
        }

        let decoded = try JSONDecoder().decode(SpotifyProfileAttributesResponse.self, from: data)
        return decoded.data.me.profile.username
    }

    func friendActivity() async throws -> [SpotifyFriend] {
        let (data, _) = try await makeRequest("presence-view/v1/buddylist")
        let response = try JSONDecoder().decode(SpotifyBuddyListResponse.self, from: data)
        return response.friends
    }

    func needsRefresh() -> Bool {
        guard let creds = try? credentialStore.loadSpotifyCredentials() else { return false }
        return !creds.spDC.isEmpty
    }

    func userProfile(username: String) async throws -> SpotifyUserProfile {
        let (data, _) = try await makeRequest("user-profile-view/v3/profile/\(username)")
        let profile = try JSONDecoder().decode(SpotifyUserProfileJSON.self, from: data)
        return SpotifyUserProfile(
            id: profile.username ?? username,
            display_name: profile.name,
            images: profile.image_url.map { [SpotifyImage(url: $0)] },
            followers: profile.followers_count.map { SpotifyFollowers(total: $0) },
            external_urls: profile.username.map { SpotifyExternalURLs(spotify: "https://open.spotify.com/user/\($0)") }
        )
    }

    func userFollowingCount(username: String) async throws -> Int {
        let (data, _) = try await makeRequest("user-profile-view/v3/profile/\(username)/following?market=from_token")
        let profiles = try JSONDecoder().decode(SpotifyProfileList.self, from: data)
        return profiles.profiles.count
    }

    func userFollowerCount(username: String) async throws -> Int {
        let (data, _) = try await makeRequest("user-profile-view/v3/profile/\(username)/followers?market=from_token")
        let profiles = try JSONDecoder().decode(SpotifyProfileList.self, from: data)
        return profiles.profiles.count
    }

    func audioAnalysis(trackId: String) async throws -> SpotifyAudioAnalysis {
        let (data, _) = try await makeRequest("audio-attributes/v1/audio-analysis/\(trackId)")
        return try JSONDecoder().decode(SpotifyAudioAnalysis.self, from: data)
    }
}

enum SpotifyWebPlayerToken {
    static let version = "61"

    private static let period: TimeInterval = 30
    private static let secret = obfuscatedSecret(",7/*F(\"rLJ2oxaKL^f+E1xvP@N")

    static func current(date: Date = Date()) -> String {
        generate(timestamp: date.timeIntervalSince1970)
    }

    static func serverSynchronized(session: URLSession) async -> String? {
        do {
            let (data, response) = try await session.data(from: URL(string: "https://open.spotify.com/api/server-time")!)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(SpotifyServerTimeResponse.self, from: data)
            return generate(timestamp: decoded.serverTime)
        } catch {
            return nil
        }
    }

    private static func generate(timestamp: TimeInterval) -> String {
        var counter = UInt64(floor(timestamp / period)).bigEndian
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)
        let hash = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let bytes = Array(hash)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let truncated =
            (UInt32(bytes[offset] & 0x7f) << 24) |
            (UInt32(bytes[offset + 1] & 0xff) << 16) |
            (UInt32(bytes[offset + 2] & 0xff) << 8) |
            UInt32(bytes[offset + 3] & 0xff)
        return String(format: "%06u", truncated % 1_000_000)
    }

    private static func obfuscatedSecret(_ value: String) -> Data {
        let scalars = Array(value.unicodeScalars)
        let decoded = scalars.enumerated().map { index, scalar in
            Int(scalar.value) ^ (index % 33 + 9)
        }
        return Data(decoded.map(String.init).joined().utf8)
    }
}

// MARK: - Response models

struct SpotifyBuddyListResponse: Decodable {
    let friends: [SpotifyFriend]
}

struct SpotifyFriend: Decodable {
    let timestamp: UInt64
    let user: SpotifyFriendUser
    let track: SpotifyFriendTrack
}

struct SpotifyFriendUser: Decodable {
    let uri: String
    let name: String
    let imageUrl: String?
}

struct SpotifyFriendTrack: Decodable {
    let uri: String
    let name: String
    let imageUrl: String?
    let album: SpotifyFriendAlbum?
    let artist: SpotifyFriendArtist?
    let context: SpotifyFriendContext?
}

struct SpotifyFriendAlbum: Decodable {
    let uri: String?
    let name: String?
}

struct SpotifyFriendArtist: Decodable {
    let uri: String?
    let name: String?
}

struct SpotifyFriendContext: Decodable {
    let uri: String?
    let name: String?
    let index: Int?
}

struct SpotifyProfileAttributesResponse: Decodable {
    let data: SpotifyProfileAttributesData
}
struct SpotifyProfileAttributesData: Decodable {
    let me: SpotifyProfileAttributesMe
}
struct SpotifyProfileAttributesMe: Decodable {
    let profile: SpotifyProfileAttributesProfile
}
struct SpotifyProfileAttributesProfile: Decodable {
    let username: String
}

struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let accessTokenExpirationTimestampMs: Int64?
}

struct SpotifyServerTimeResponse: Decodable {
    let serverTime: TimeInterval
}

struct SpotifyUserProfileJSON: Decodable {
    let username: String?
    let name: String?
    let image_url: String?
    let followers_count: Int?
    let following_count: Int?
}

struct SpotifyUserProfile: Decodable {
    let id: String
    let display_name: String?
    let images: [SpotifyImage]?
    let followers: SpotifyFollowers?
    let external_urls: SpotifyExternalURLs?
}

struct SpotifyImage: Decodable {
    let url: String
}

struct SpotifyFollowers: Decodable {
    let total: Int
}

struct SpotifyExternalURLs: Decodable {
    let spotify: String?
}

struct SpotifyProfileList: Decodable {
    let profiles: [SpotifyProfileEntry]
}

struct SpotifyProfileEntry: Decodable {
    let uri: String
}

struct SpotifyAudioAnalysis: Decodable {
    let track: SpotifyAudioAnalysisTrack
}

struct SpotifyAudioAnalysisTrack: Decodable {
    let loudness: Double?
    let tempo: Double?
    let tempoConfidence: Double?
    let mode: Int?

    enum CodingKeys: String, CodingKey {
        case loudness
        case tempo
        case tempoConfidence = "tempo_confidence"
        case mode
    }
}
