import Foundation

@MainActor
public struct FarcasterClient {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://haatz.quilibrium.com")!,
        session: URLSession = defaultSession
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func user(byUsername username: String) async throws -> FarcasterUserResponse {
        let normalized = String(username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
        guard !normalized.isEmpty else { throw SourceError.notConfigured }

        var components = URLComponents(
            url: baseURL.appending(path: "/v2/farcaster/user/by-username"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "username", value: normalized)]

        let response: FarcasterUserWrapperResponse = try await get(components.url!)
        return response.user
    }

    func notifications(fid: UInt64, limit: Int = 50, cursor: String? = nil) async throws -> FarcasterNotificationsResponse {
        var components = URLComponents(
            url: baseURL.appending(path: "/v2/farcaster/notifications"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fid", value: String(fid)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }

        return try await get(components.url!)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = parseHypersnapDate(value) {
                return date
            }
            throw SourceError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }
}

private func parseHypersnapDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

public struct FarcasterUserResponse: Decodable {
    public let fid: UInt64
    public let username: String?
    public let displayName: String?
    public let pfpUrl: URL?
    public let followerCount: Int?
    public let followingCount: Int?
}

private struct FarcasterUserWrapperResponse: Decodable {
    let user: FarcasterUserResponse
}

struct FarcasterNotificationsResponse: Decodable {
    let notifications: [FarcasterNotificationResponse]
    let next: FarcasterNextCursor?
}

struct FarcasterNextCursor: Decodable {
    let cursor: String?
}

struct FarcasterNotificationResponse: Decodable {
    let type: String
    let mostRecentTimestamp: Int?
    let timestamp: Date?
    let cast: FarcasterCastResponse?
    let user: FarcasterUserResponse?
    let reactions: [FarcasterReactionResponse]?
    let follows: [FarcasterFollowResponse]?

    var notificationDate: Date {
        if let timestamp { return timestamp }
        if let mostRecentTimestamp {
            return Date(timeIntervalSince1970: TimeInterval(mostRecentTimestamp))
        }
        return Date(timeIntervalSince1970: 0)
    }
}

struct FarcasterCastResponse: Decodable {
    let hash: String
    let text: String?
    let timestamp: Date?
    let type: String?
    let parentHash: String?
    let parentUrl: String?
    let parentAuthor: FarcasterParentAuthorResponse?
    let author: FarcasterUserResponse?
}

struct FarcasterParentAuthorResponse: Decodable {
    let fid: UInt64?
}

struct FarcasterReactionResponse: Decodable {
    let fid: UInt64?
    let username: String?
    let displayName: String?
    let pfpUrl: URL?
}

struct FarcasterFollowResponse: Decodable {
    let fid: UInt64?
    let username: String?
    let displayName: String?
    let pfpUrl: URL?
}
