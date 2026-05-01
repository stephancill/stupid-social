import Foundation

public enum InstagramNotificationCategory: String, CaseIterable, Codable, Sendable {
    case follows
    case comments
    case likes
    case storyHighlights

    public var displayLabel: String {
        switch self {
        case .follows: "Follows"
        case .comments: "Comments"
        case .likes: "Likes"
        case .storyHighlights: "Story Highlights"
        }
    }

    static func category(for notifName: String) -> Self? {
        switch notifName {
        case "user_followed":
            .follows
        case "comment":
            .comments
        case "post_like", "story_like", "comment_like":
            .likes
        case "ig_profile_story_highlight":
            .storyHighlights
        default:
            nil
        }
    }
}

@MainActor
public struct InstagramClient {
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    private static let baseURL = "https://i.instagram.com"

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

    public func verifiedUser() async throws -> InstagramVerifiedUser {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/accounts/current_user/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(InstagramCurrentUserResponse.self, from: data)
        return InstagramVerifiedUser(
            pk: decoded.user.pk,
            username: decoded.user.username,
            fullName: decoded.user.fullName
        )
    }

    func hasCredentials() throws -> Bool {
        try credentialStore.loadInstagramCredentials() != nil
    }

    func notifications(enabledCategories: Set<InstagramNotificationCategory>) async throws -> [NotificationItem] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/news/inbox/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(InstagramNewsInboxResponse.self, from: data)
        let allStories = (decoded.newStories ?? []) + (decoded.oldStories ?? [])
        return InstagramNotificationParser.parse(
            stories: allStories,
            accountId: credentials.dsUserId,
            enabledCategories: enabledCategories
        )
    }

    public func userInfo(uid: String) async throws -> InstagramUserInfoResponse {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/users/\(uid)/info/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        return try JSONDecoder().decode(InstagramUserInfoResponse.self, from: data)
    }

    private func headers(credentials: InstagramCredentials) -> [String: String] {
        var cookie = "ds_user_id=\(credentials.dsUserId); csrftoken=\(credentials.csrfToken); sessionid=\(credentials.sessionId)"
        if let mid = credentials.mid {
            cookie += "; mid=\(mid)"
        }

        return [
            "Cookie": cookie,
            "X-CSRFToken": credentials.csrfToken,
            "User-Agent": "Instagram 416.0.0.47.66 Android (35/35; 480dpi; 1080x2400; samsung; SM-S938U; qcom; en_US; 718621835)",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
    }
}

// MARK: - Response models

public struct InstagramVerifiedUser {
    public let pk: UInt64
    public let username: String
    public let fullName: String
}

private struct InstagramCurrentUserResponse: Decodable {
    struct User: Decodable {
        let pk: UInt64
        let username: String
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
        }
    }

    let user: User
    let status: String
}

struct InstagramNewsInboxResponse: Decodable {
    let newStories: [InstagramNewsStory]?
    let oldStories: [InstagramNewsStory]?

    enum CodingKeys: String, CodingKey {
        case newStories = "new_stories"
        case oldStories = "old_stories"
    }
}

struct InstagramNewsStory: Decodable {
    let pk: String
    let notifName: String
    let storyType: Int
    let args: InstagramNewsStoryArgs
    let counts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case pk
        case notifName = "notif_name"
        case storyType = "story_type"
        case args
        case counts
    }
}

struct InstagramNewsStoryArgs: Decodable {
    let richText: String?
    let profileId: UInt64?
    let profileName: String?
    let profileImage: String?
    let secondProfileId: UInt64?
    let secondProfileImage: String?
    let timestamp: Double?
    let media: [InstagramMediaThumbnail]?
    let images: [InstagramMediaThumbnail]?
    let destination: String?

    enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
        case profileId = "profile_id"
        case profileName = "profile_name"
        case profileImage = "profile_image"
        case secondProfileId = "second_profile_id"
        case secondProfileImage = "second_profile_image"
        case timestamp
        case media
        case images
        case destination
    }
}

struct InstagramMediaThumbnail: Decodable {
    let id: String
    let image: String
}

public struct InstagramUserInfoResponse: Decodable {
    public struct InfoUser: Decodable {
        public let pk: UInt64?
        public let username: String?
        public let fullName: String?
        public let profilePicUrl: String?
        public let followerCount: Int?
        public let followingCount: Int?

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
            case followerCount = "follower_count"
            case followingCount = "following_count"
        }
    }

    public let user: InfoUser
    public let status: String?
}

// MARK: - Parser

private enum InstagramNotificationParser {
    static func parse(stories: [InstagramNewsStory], accountId: String, enabledCategories: Set<InstagramNotificationCategory>) -> [NotificationItem] {
        stories.compactMap { story in
            parseSingle(story: story, accountId: accountId, enabledCategories: enabledCategories)
        }
    }

    private static func parseSingle(story: InstagramNewsStory, accountId: String, enabledCategories: Set<InstagramNotificationCategory>) -> NotificationItem? {
        guard let category = InstagramNotificationCategory.category(for: story.notifName),
              enabledCategories.contains(category) else {
            return nil
        }
        let type = notificationType(from: story.notifName)
        let timestamp = story.args.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let actionText = actionText(for: story.notifName)

        let parsedBlocks = parseRichTextBlocks(from: story.args.richText ?? "")
        let contentAfterColon = parseContentAfterColon(from: story.args.richText ?? "")

        let actors = buildActors(from: story.args, blocks: parsedBlocks)
        let text = "\(buildActorSummary(actors: actors)) \(actionText)"

        let mediaImageUrl = story.args.media?.first?.image ?? story.args.images?.first?.image
        let imageURL = mediaImageUrl.flatMap(URL.init)
        let storyURL = parseStoryURL(from: story.args.destination)
        let linkURL = storyURL ?? imageURL

        let target: NotificationTarget?
        if let content = contentAfterColon, !content.isEmpty {
            target = NotificationTarget(id: story.pk, text: content, url: linkURL, imageURL: imageURL)
        } else if linkURL != nil || imageURL != nil {
            target = NotificationTarget(id: story.args.media?.first?.id ?? story.pk, text: nil, url: linkURL, imageURL: imageURL)
        } else {
            target = nil
        }

        return NotificationItem(
            id: "instagram:\(story.pk)",
            network: .instagram,
            accountId: accountId,
            sourceId: story.pk,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: target,
            parentTarget: nil
        )
    }

    private static func notificationType(from notifName: String) -> NotificationType {
        switch notifName {
        case "user_followed":
            .follow
        case "comment":
            .reply
        case "post_like", "story_like", "comment_like":
            .reaction
        default:
            .unknown
        }
    }

    private static func actionText(for notifName: String) -> String {
        switch notifName {
        case "user_followed":
            "followed you"
        case "comment":
            "commented"
        case "post_like":
            "liked your post"
        case "story_like":
            "liked your story"
        case "comment_like":
            "liked your comment"
        default:
            ""
        }
    }

    // MARK: - Rich text parsing

    private struct RichTextBlock {
        let username: String
        let userId: String
    }

    private static func parseRichTextBlocks(from raw: String) -> [RichTextBlock] {
        let pattern = #"\{([^|]+)\|[^|]*\|[^|]*\|user\?id=(\d+)[^}]*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        return matches.compactMap { match in
            guard let userRange = Range(match.range(at: 1), in: raw),
                  let idRange = Range(match.range(at: 2), in: raw) else { return nil }
            return RichTextBlock(username: String(raw[userRange]), userId: String(raw[idRange]))
        }
    }

    private static func parseContentAfterColon(from raw: String) -> String? {
        let stripped = stripRichTextBlocks(from: raw)
        guard let colonIndex = stripped.lastIndex(of: ":") else { return nil }
        let content = stripped[stripped.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func stripRichTextBlocks(from raw: String) -> String {
        let pattern = #"\{[^}]+\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    // MARK: - Actor building

    private static func buildActors(from args: InstagramNewsStoryArgs, blocks: [RichTextBlock]) -> [NotificationActor] {
        var actors: [NotificationActor] = []
        let avatarById = avatarMap(from: args)
        var seenIds: Set<String> = []

        for block in blocks.prefix(2) {
            let avatar = avatarById[block.userId]
            if seenIds.insert(block.userId).inserted {
                actors.append(NotificationActor(
                    id: block.userId,
                    network: .instagram,
                    username: block.username,
                    displayName: nil,
                    avatarURL: avatar.flatMap(URL.init)
                ))
            }
        }

        if actors.isEmpty, let id = args.profileId, let name = args.profileName {
            actors.append(NotificationActor(
                id: String(id),
                network: .instagram,
                username: name,
                displayName: nil,
                avatarURL: args.profileImage.flatMap(URL.init)
            ))
        }

        return actors
    }

    private static func avatarMap(from args: InstagramNewsStoryArgs) -> [String: String] {
        var map: [String: String] = [:]
        if let id = args.profileId, let image = args.profileImage {
            map[String(id)] = image
        }
        if let id = args.secondProfileId, let image = args.secondProfileImage {
            map[String(id)] = image
        }
        return map
    }

    private static func buildActorSummary(actors: [NotificationActor]) -> String {
        guard let first = actors.first, let firstName = first.username else { return "Someone" }
        let remainingCount = actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }

    private static func parseStoryURL(from destination: String?) -> URL? {
        guard let destination else { return nil }
        guard let questionIndex = destination.firstIndex(of: "?") else { return nil }
        let query = String(destination[destination.index(after: questionIndex)...])
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instagram.com"
        components.query = query
        guard let parsedQuery = components.queryItems else { return nil }
        guard let reelId = parsedQuery.first(where: { $0.name == "reel_id" })?.value?.removingPercentEncoding else { return nil }
        guard let feedItemId = parsedQuery.first(where: { $0.name == "feeditem_id" })?.value else { return nil }

        let hash: String
        if reelId.hasPrefix("archiveDay:") {
            hash = String(reelId.dropFirst("archiveDay:".count))
        } else {
            hash = reelId
        }

        let mediaId = feedItemId.split(separator: "_").first.map(String.init) ?? feedItemId
        return URL(string: "https://www.instagram.com/stories/archive/\(hash)/?initial_media_id=\(mediaId)")
    }
}