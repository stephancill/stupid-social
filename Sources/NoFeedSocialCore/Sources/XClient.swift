import Foundation

public enum XNotificationCategory: String, CaseIterable, Codable, Sendable {
    case mentions
    case replies
    case reactions
    case tweets

    public var displayLabel: String {
        switch self {
        case .mentions: "Mentions"
        case .replies: "Replies"
        case .reactions: "Reactions"
        case .tweets: "Tweets"
        }
    }

    static func category(for type: NotificationType) -> Self? {
        switch type {
        case .mention: .mentions
        case .reply: .replies
        case .reaction: .reactions
        case .post: .tweets
        case .follow, .message, .music, .unknown: nil
        }
    }
}

@MainActor
public struct XClient {
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    private static let bearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

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

    public func userProfile(screenName: String) async throws -> XProfileResponse {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        let queryId = "IGgvgiOx4QZndDHuD3x9TQ"
        let variables: [String: Any] = ["screen_name": screenName, "withSafetyModeUserFields": true]
        let features: [String: Any] = [
            "hidden_profile_subscriptions_enabled": true,
            "rweb_tipjar_consumption_enabled": true,
            "responsive_web_graphql_exclude_directive_enabled": true,
            "highlights_tweets_tab_ui_enabled": true,
            "responsive_web_twitter_article_notes_tab_enabled": true,
            "creator_subscriptions_tweet_preview_api_enabled": true,
            "responsive_web_graphql_timeline_navigation_enabled": true,
        ]

        guard
            let varsData = try? JSONSerialization.data(withJSONObject: variables),
            let featData = try? JSONSerialization.data(withJSONObject: features),
            let varsJSON = String(data: varsData, encoding: .utf8),
            let featJSON = String(data: featData, encoding: .utf8)
        else {
            throw SourceError.invalidResponse
        }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let varsEncoded = varsJSON.addingPercentEncoding(withAllowedCharacters: allowed) ?? varsJSON
        let featEncoded = featJSON.addingPercentEncoding(withAllowedCharacters: allowed) ?? featJSON

        guard let url = URL(string: "https://x.com/i/api/graphql/\(queryId)/UserByScreenName?variables=\(varsEncoded)&features=\(featEncoded)") else {
            throw SourceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XGraphQLUserResponse.self, from: data)
        let result = decoded.data?.user?.result
        guard let legacy = result?.legacy else {
            throw SourceError.invalidResponse
        }
        return XProfileResponse(
            idStr: result?.restId ?? "",
            screenName: result?.core?.screenName ?? screenName,
            name: result?.core?.name ?? "",
            description: legacy.description,
            followersCount: legacy.followersCount,
            friendsCount: legacy.friendsCount,
            statusesCount: legacy.statusesCount,
            createdAt: result?.core?.createdAt.flatMap(Self.twitterDate(from:)),
            verified: result?.isBlueVerified,
            profileImageUrlHttps: result?.avatar?.imageUrl,
            profileBannerUrl: legacy.profileBannerUrl,
            isFollowing: result?.relationshipPerspectives?.following,
            isFollowedBy: result?.relationshipPerspectives?.followedBy,
        )
    }

    public func verifiedUser() async throws -> XVerifiedUser {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://x.com/i/api/1.1/account/multi/list.json")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(XAccountListResponse.self, from: data)
        guard let user = decoded.users.first else {
            throw SourceError.invalidResponse
        }
        return XVerifiedUser(screenName: user.screenName, name: user.name, idStr: user.idStr)
    }

    func hasCredentials() throws -> Bool {
        try credentialStore.loadXCredentials() != nil
    }

    func unreadCount() async throws -> Int? {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        return try await unreadCount(credentials: credentials)
    }

    func notifications() async throws -> [NotificationItem] {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var components = URLComponents(string: "https://x.com/i/api/2/notifications/all.json")!
        components.queryItems = [
            URLQueryItem(name: "include_tweet_replies", value: "true"),
            URLQueryItem(name: "count", value: "40"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XNotificationsResponse.self, from: data)
        return try XNotificationParser.parse(response: decoded)
    }

    func tweetDetails(tweetId: String) async throws -> NotificationTargetDetails {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var components = URLComponents(string: "https://x.com/i/api/1.1/statuses/show.json")!
        components.queryItems = [
            URLQueryItem(name: "id", value: tweetId),
            URLQueryItem(name: "tweet_mode", value: "extended"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XTweetMetricsResponse.self, from: data)
        return NotificationTargetDetails(likeCount: decoded.favoriteCount)
    }

    func deviceFollowTargets(for item: NotificationItem) async throws -> [NotificationTarget] {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://x.com/i/api/2/notifications/device_follow.json")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XNotificationsResponse.self, from: data)
        return XNotificationParser.deviceFollowTargets(response: decoded, matching: item)
    }

    public func unreadCount(credentials: XCredentials) async throws -> Int {
        var components = URLComponents(string: "https://x.com/i/api/2/notifications/all/unread_count.json")!
        components.queryItems = [URLQueryItem(name: "include_tweet_replies", value: "true")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(XUnreadCountResponse.self, from: data)
        return decoded.unreadCount
    }

    private static func twitterDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }

    private func headers(credentials: XCredentials) -> [String: String] {
        [
            "Authorization": "Bearer \(Self.bearerToken)",
            "Cookie": "auth_token=\(credentials.authToken); ct0=\(credentials.ct0)",
            "X-Csrf-Token": credentials.ct0,
            "X-Twitter-Active-User": "yes",
            "X-Twitter-Auth-Type": "OAuth2Session",
            "X-Twitter-Client-Language": "en",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
            "Origin": "https://x.com",
            "Referer": "https://x.com/",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
    }
}

public struct XVerifiedUser {
    public let screenName: String
    public let name: String
    public let idStr: String
}

public struct XProfileResponse {
    public let idStr: String
    public let screenName: String
    public let name: String
    public let description: String?
    public let followersCount: Int?
    public let friendsCount: Int?
    public let statusesCount: Int?
    public let createdAt: Date?
    public let verified: Bool?
    public let profileImageUrlHttps: String?
    public let profileBannerUrl: String?
    public let isFollowing: Bool?
    public let isFollowedBy: Bool?
}

private struct XGraphQLUserResponse: Decodable {
    let data: XGraphQLData?

    struct XGraphQLData: Decodable {
        let user: XGraphQLUser?
    }

    struct XGraphQLUser: Decodable {
        let result: XGraphQLResult?
    }

    struct XGraphQLResult: Decodable {
        let restId: String?
        let core: XGraphQLCore?
        let legacy: XGraphQLLegacy?
        let isBlueVerified: Bool?
        let relationshipPerspectives: XGraphQLRelationship?
        let avatar: XGraphQLAvatar?
    }

    struct XGraphQLAvatar: Decodable {
        let imageUrl: String?
    }

    struct XGraphQLCore: Decodable {
        let screenName: String?
        let name: String?
        let createdAt: String?
    }

    struct XGraphQLLegacy: Decodable {
        let description: String?
        let followersCount: Int?
        let friendsCount: Int?
        let statusesCount: Int?
        let profileBannerUrl: String?
    }

    struct XGraphQLRelationship: Decodable {
        let following: Bool?
        let followedBy: Bool?
    }
}

private struct XAccountListResponse: Decodable {
    let users: [XAccountListUser]
}

private struct XAccountListUser: Decodable {
    let screenName: String
    let name: String
    let userId: String

    var idStr: String {
        userId
    }

    enum CodingKeys: String, CodingKey {
        case screenName = "screen_name"
        case name
        case userId = "user_id"
    }
}

private struct XUnreadCountResponse: Decodable {
    let unreadCount: Int
}

private struct XTweetMetricsResponse: Decodable {
    let favoriteCount: Int?
}

// MARK: - Notification List Response Models

private struct XNotificationsResponse: Decodable {
    let globalObjects: XGlobalObjects
    let timeline: XTimeline
}

private struct XGlobalObjects: Decodable {
    let users: [String: XUserObject]
    let tweets: [String: XTweetObject]
}

private struct XTimeline: Decodable {
    let instructions: [XTimelineInstruction]
}

private struct XTimelineInstruction: Decodable {
    let addEntries: XAddEntries?
}

private struct XAddEntries: Decodable {
    let entries: [XTimelineEntry]
}

private struct XTimelineEntry: Decodable {
    let entryId: String
    let sortIndex: String
    let content: XEntryContent
}

private struct XEntryContent: Decodable {
    let item: XEntryItem?
    let operation: XCursorOperation?
}

private struct XEntryItem: Decodable {
    let content: XItemContent
    let clientEventInfo: XClientEventInfo?
}

private struct XItemContent: Decodable {
    let tweet: XTweetRef?
    let notification: XNotificationRef?
}

private struct XTweetRef: Decodable {
    let id: String
    let displayType: String
}

private struct XNotificationRef: Decodable {
    let id: String
    let fromUsers: [String]
    let targetTweets: [String]?
}

private struct XClientEventInfo: Decodable {
    let element: String
}

private struct XCursorOperation: Decodable {
    let cursor: XCursor
}

private struct XCursor: Decodable {
    let value: String
    let cursorType: String
}

private struct XUserObject: Decodable {
    let id: Int64?
    let idStr: String?
    let name: String
    let screenName: String
    let profileImageUrlHttps: String?

    var stableId: String {
        idStr ?? id.map(String.init) ?? screenName
    }
}

private struct XTweetObject: Decodable {
    let id: Int64?
    let idStr: String?
    let createdAt: String
    let fullText: String
    let userIdStr: String
    let inReplyToStatusIdStr: String?
    let inReplyToUserIdStr: String?
    let extendedEntities: XExtendedEntities?
    let favoriteCount: Int?

    var stableId: String {
        idStr ?? id.map(String.init) ?? ""
    }

    var firstMediaUrl: String? {
        extendedEntities?.media?.first?.mediaUrlHttps
    }

    var mediaURLs: [URL] {
        extendedEntities?.media?.compactMap { $0.mediaUrlHttps.flatMap(URL.init) } ?? []
    }
}

private struct XExtendedEntities: Decodable {
    let media: [XMediaEntity]?
}

private struct XMediaEntity: Decodable {
    let mediaUrlHttps: String?
}

// MARK: - Parser

private enum XNotificationParser {
    static func parse(response: XNotificationsResponse) throws -> [NotificationItem] {
        let users = response.globalObjects.users
        let tweets = response.globalObjects.tweets

        guard let entries = response.timeline.instructions.first(where: { $0.addEntries != nil })?.addEntries?.entries else {
            return []
        }

        var items: [NotificationItem] = []
        for entry in entries {
            if entry.content.operation != nil { continue }
            guard let item = entry.content.item else { continue }

            let element = item.clientEventInfo?.element ?? "unknown"
            let type = notificationType(from: element)

            if let tweetRef = item.content.tweet {
                if let notificationItem = parseTweetEntry(
                    entryId: entry.entryId,
                    sortIndex: entry.sortIndex,
                    tweetRef: tweetRef,
                    element: element,
                    type: type,
                    tweets: tweets,
                    users: users,
                ) {
                    items.append(notificationItem)
                }
            } else if let notificationRef = item.content.notification {
                if let notificationItem = parseNotificationEntry(
                    entryId: entry.entryId,
                    sortIndex: entry.sortIndex,
                    notificationRef: notificationRef,
                    element: element,
                    type: type,
                    tweets: tweets,
                    users: users,
                ) {
                    items.append(notificationItem)
                }
            }
        }

        return items
    }

    static func deviceFollowTargets(response: XNotificationsResponse, matching _: NotificationItem) -> [NotificationTarget] {
        let users = response.globalObjects.users
        let tweets = response.globalObjects.tweets

        guard let entries = response.timeline.instructions.first(where: { $0.addEntries != nil })?.addEntries?.entries else {
            return []
        }

        var seenTweetIds = Set<String>()
        return entries.compactMap { entry -> NotificationTarget? in
            guard let tweetId = entry.content.item?.content.tweet?.id,
                  let tweet = tweets[tweetId],
                  !seenTweetIds.contains(tweet.stableId)
            else {
                return nil
            }
            seenTweetIds.insert(tweet.stableId)
            return target(from: tweet, users: users)
        }
    }

    private static func parseTweetEntry(
        entryId _: String,
        sortIndex _: String,
        tweetRef: XTweetRef,
        element: String,
        type: NotificationType,
        tweets: [String: XTweetObject],
        users: [String: XUserObject],
    ) -> NotificationItem? {
        guard let tweet = tweets[tweetRef.id] else { return nil }
        guard let user = users[tweet.userIdStr] else { return nil }
        guard let timestamp = parseTwitterDate(tweet.createdAt) else { return nil }

        let actor = actor(from: user)

        let text = notificationText(element: element, actorName: user.name, tweetText: tweet.fullText)

        let parentTarget = tweet.inReplyToStatusIdStr.flatMap { parentId in
            tweets[parentId].map { target(from: $0, users: users) }
        }

        return NotificationItem(
            id: "x:\(tweet.stableId):\(element)",
            network: .x,
            accountId: "x",
            sourceId: tweet.stableId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: [actor],
            target: target(from: tweet, users: users),
            parentTarget: parentTarget,
        )
    }

    private static func parseNotificationEntry(
        entryId _: String,
        sortIndex: String,
        notificationRef: XNotificationRef,
        element: String,
        type: NotificationType,
        tweets: [String: XTweetObject],
        users: [String: XUserObject],
    ) -> NotificationItem? {
        guard isEngagementElement(element) else { return nil }

        let actors = notificationRef.fromUsers.compactMap { userId in
            users[userId].map(actor(from:))
        }.reversed().map(\.self)
        guard !actors.isEmpty else { return nil }

        let notificationTarget: NotificationTarget?
        let sourceId: String
        let timestamp = Date(timeIntervalSince1970: (Double(sortIndex) ?? 0) / 1000)
        if let targetTweetId = notificationRef.targetTweets?.first,
           let tweet = tweets[targetTweetId]
        {
            notificationTarget = target(from: tweet, users: users)
            sourceId = tweet.stableId
        } else {
            notificationTarget = type == .post ? NotificationTarget(
                id: notificationRef.id,
                text: nil,
                url: nil,
                author: actors.first,
                postedAt: timestamp,
            ) : nil
            sourceId = notificationRef.fromUsers.sorted().joined(separator: ",")
        }

        let text = groupedNotificationText(element: element, actors: actors, tweetText: notificationTarget?.text)

        return NotificationItem(
            id: "x:\(sourceId):\(element)",
            network: .x,
            accountId: "x",
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: notificationTarget,
            parentTarget: nil,
        )
    }

    private static func notificationType(from element: String) -> NotificationType {
        switch element {
        case "user_mentioned_you",
             "user_mentioned_you_in_a_quote_tweet":
            .mention
        case "user_replied_to_your_tweet",
             "user_quoted_your_tweet":
            .reply
        case "users_liked_your_tweet",
             "user_liked_multiple_tweets",
             "users_retweeted_your_tweet":
            .reaction
        case "device_follow_tweet_notification_entry",
             "user_tweeted",
             "user_tweeted_entry",
             "tweet_notification",
             "user_posted":
            .post
        default:
            .unknown
        }
    }

    private static func isEngagementElement(_ element: String) -> Bool {
        switch element {
        case "user_mentioned_you",
             "user_mentioned_you_in_a_quote_tweet",
             "user_replied_to_your_tweet",
             "user_quoted_your_tweet",
             "users_liked_your_tweet",
             "user_liked_multiple_tweets",
             "users_retweeted_your_tweet",
             "device_follow_tweet_notification_entry",
             "user_tweeted",
             "user_tweeted_entry",
             "tweet_notification",
             "user_posted":
            true
        default:
            false
        }
    }

    private static func notificationText(element: String, actorName: String, tweetText: String?) -> String {
        switch element {
        case "user_mentioned_you":
            "\(actorName) mentioned you"
        case "user_mentioned_you_in_a_quote_tweet":
            "\(actorName) mentioned you in a quote tweet"
        case "user_replied_to_your_tweet":
            "\(actorName) replied to your tweet"
        case "user_quoted_your_tweet":
            "\(actorName) quoted your tweet"
        case "users_liked_your_tweet",
             "user_liked_multiple_tweets":
            "\(actorName) liked your tweet"
        case "users_retweeted_your_tweet":
            "\(actorName) retweeted your tweet"
        case "follow_from_recommended_user",
             "users_followed_you":
            "\(actorName) followed you"
        case "device_follow_tweet_notification_entry",
             "user_tweeted",
             "user_tweeted_entry",
             "tweet_notification",
             "user_posted":
            "New post from \(actorName)"
        default:
            tweetText ?? "New X notification"
        }
    }

    private static func groupedNotificationText(
        element: String,
        actors: [NotificationActor],
        tweetText: String?,
    ) -> String {
        let actorName = actors.first?.username.map { "@\($0)" } ?? actors.first?.displayName ?? "Someone"
        let suffix = actors.count > 1 ? " and \(actors.count - 1) other\(actors.count == 2 ? "" : "s")" : ""

        switch element {
        case "users_liked_your_tweet",
             "user_liked_multiple_tweets":
            return "\(actorName)\(suffix) liked your tweet"
        case "users_retweeted_your_tweet":
            return "\(actorName)\(suffix) retweeted your tweet"
        case "follow_from_recommended_user",
             "users_followed_you":
            return "\(actorName)\(suffix) followed you"
        case "device_follow_tweet_notification_entry":
            return "New post from \(actorName)\(suffix)"
        default:
            return notificationText(element: element, actorName: actorName, tweetText: tweetText)
        }
    }

    private static func actor(from user: XUserObject) -> NotificationActor {
        NotificationActor(
            id: user.stableId,
            network: .x,
            username: user.screenName,
            displayName: user.name,
            avatarURL: user.profileImageUrlHttps.map { URL(string: $0.replacingOccurrences(of: "_normal", with: "")) } ?? nil,
        )
    }

    private static func target(from tweet: XTweetObject, users: [String: XUserObject]) -> NotificationTarget {
        let imageURL = tweet.firstMediaUrl.flatMap(URL.init)
        return NotificationTarget(
            id: tweet.stableId,
            text: tweet.fullText,
            url: nil,
            imageURL: imageURL,
            imageURLs: tweet.mediaURLs,
            author: users[tweet.userIdStr].map(actor(from:)),
            postedAt: parseTwitterDate(tweet.createdAt),
            likeCount: tweet.favoriteCount,
        )
    }

    private static func parseTwitterDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }
}
