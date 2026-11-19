import Foundation

public enum XNotificationCategory: String, CaseIterable, Codable, Sendable {
    case mentions
    case replies
    case reactions
    case tweets
    case follows

    public var displayLabel: String {
        switch self {
        case .mentions: "Mentions"
        case .replies: "Replies"
        case .reactions: "Reactions"
        case .tweets: "Tweets"
        case .follows: "Follows"
        }
    }

    static func category(for type: NotificationType) -> Self? {
        switch type {
        case .mention: .mentions
        case .reply: .replies
        case .reaction: .reactions
        case .post: .tweets
        case .follow: .follows
        case .message, .music, .unknown: nil
        }
    }
}

@MainActor
public struct XClient {
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    private nonisolated static let bearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private static let searchTimelineQueryId = "hz_94eVAtrtQo_vO3my7Rw"
    private static let notificationsTimelineQueryId = "8kmedJD_u653xqEjZIS7yA"
    private nonisolated static let appUserAgent = "StupidSocial/1"

    /// Query ids, variables and feature switches as X's web client sends them, from its `main.<hash>.js`
    /// bundle and the `featureSwitch` config in the signed-in home page (see `scripts/x-web-client.py`).
    private enum TweetQueryIds {
        static let tweetResultByRestId = "U8lc5aomF5krJzZ9vJ9wxg"
        static let favoriteTweet = "lI07N6Otwv1PhnEgXILM7A"
        static let unfavoriteTweet = "ZYKSe-w7KEslx3JhSIk5LA"
        static let deleteRetweet = "ZyZigVsNiFO6v1dEks1eWg"
        static let createTweet = "l4hk8uVGvR-a8kzQ4nOhPA"
        static let tweetDetail = "qpemjmVMoTWDvcRT43JIVQ"
        static let userTweets = "D6z-FJI2pKuwEeYYxVIGbg"
        static let userMedia = "iTSlWbsmD00dAE7Sk9xvIw"
        static let userOriginalsTimeline = "ZFKu1DFS63hgrkLzR3Hsdw"
        static let userByScreenName = "AMIBMjtxEEATh4z8V9GtRg"
    }

    private static let tweetFeatures: [String: Any] = [
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": false,
        "rweb_cashtags_composer_attachment_enabled": true,
        "responsive_web_jetfuel_frame": true,
        "rweb_sports_post_context_enabled": true,
        "x_elections_post_context_enabled": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_annotations_enabled": true,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "rweb_conversational_replies_downvote_enabled": false,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "content_disclosure_indicator_enabled": true,
        "content_disclosure_ai_generated_indicator_enabled": true,
        "responsive_web_grok_show_grok_translated_post": true,
        "responsive_web_grok_analysis_button_from_backend": true,
        "post_ctas_fetch_enabled": false,
        "rweb_cashtags_enabled": true,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_profile_redirect_enabled": true,
        "rweb_tipjar_consumption_enabled": false,
        "verified_phone_label_enabled": false,
        "responsive_web_nested_quote_preview_enabled": true,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_made_on_x_label_enabled": false,
        "responsive_web_grok_community_note_auto_translation_is_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
    ]

    public init(credentialStore: KeychainCredentialStore, session: URLSession = defaultSession) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public nonisolated static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public func userProfile(screenName: String) async throws -> XProfileResponse {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        // The web client's request (`fetchOneUserByScreenName`). The older `IGgvgiOx4QZndDHuD3x9TQ` answered with
        // `legacy` and no `notifications_settings`, so the bell state never showed (observed 2026-11-17).
        let variables: [String: Any] = ["screen_name": screenName, "withGrokTranslatedBio": true]
        let features: [String: Any] = [
            "hidden_profile_subscriptions_enabled": true,
            "profile_label_improvements_pcf_label_in_post_enabled": true,
            "responsive_web_profile_redirect_enabled": true,
            "rweb_tipjar_consumption_enabled": false,
            "verified_phone_label_enabled": false,
            "subscriptions_verification_info_is_identity_verified_enabled": true,
            "subscriptions_verification_info_verified_since_enabled": true,
            "highlights_tweets_tab_ui_enabled": true,
            "responsive_web_twitter_article_notes_tab_enabled": true,
            "subscriptions_feature_can_gift_premium": false,
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

        var components = URLComponents(string: "https://x.com/i/api/graphql/\(TweetQueryIds.userByScreenName)/UserByScreenName")!
        components.queryItems = [
            URLQueryItem(name: "variables", value: varsJSON),
            URLQueryItem(name: "features", value: featJSON),
            URLQueryItem(name: "fieldToggles", value: #"{"withAuxiliaryUserLabels":true,"withPayments":false}"#),
        ]
        guard let url = components.url else { throw SourceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)
        return try XUserProfileParser.parse(data: data, screenName: screenName)
    }

    public func searchUsers(query: String) async throws -> [XProfileResponse] {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let variables: [String: Any] = [
            "rawQuery": normalized,
            "count": 20,
            "querySource": "typed_query",
            "product": "People",
            "withGrokTranslatedBio": true,
            "withQuickPromoteEligibilityTweetFields": false,
        ]
        let features = searchTimelineFeatures()

        guard
            let body = try? JSONSerialization.data(withJSONObject: [
                "variables": variables,
                "features": features,
                "queryId": Self.searchTimelineQueryId,
            ])
        else {
            throw SourceError.invalidResponse
        }

        let components = URLComponents(string: "https://x.com/i/api/graphql/\(Self.searchTimelineQueryId)/SearchTimeline")!

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.allHTTPHeaderFields = Self.apiHeaders(credentials: credentials)

        let data = try await send(request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XSearchTimelineResponse.self, from: data)
        return decoded.users.map { user in
            XProfileResponse(
                idStr: user.restId ?? user.legacy.idStr ?? "",
                screenName: user.core.screenName,
                name: user.core.name,
                description: user.legacy.description,
                followersCount: user.legacy.followersCount,
                friendsCount: user.legacy.friendsCount,
                statusesCount: user.legacy.statusesCount,
                createdAt: user.core.createdAt.flatMap(Date.twitter),
                verified: user.isBlueVerified ?? user.legacy.verified,
                profileImageUrlHttps: user.avatar?.imageUrl ?? user.legacy.profileImageUrlHttps,
                profileBannerUrl: nil,
                location: nil,
                websiteURL: nil,
                isFollowing: user.legacy.following,
                isFollowedBy: nil,
                isNotifiedForPosts: nil,
            )
        }
    }

    public func verifiedUser() async throws -> XVerifiedUser {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://x.com/i/api/1.1/account/multi/list.json")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)

        let decoded = try JSONDecoder().decode(XAccountListResponse.self, from: data)
        guard let user = decoded.users.first else {
            throw SourceError.invalidResponse
        }
        return XVerifiedUser(screenName: user.screenName, name: user.name, idStr: user.idStr)
    }

    public func setFollowing(userId: String, follow: Bool) async throws {
        var fields = friendshipFields()
        fields["user_id"] = userId
        _ = try await friendshipMutation(path: follow ? "create" : "destroy", fields: fields)
    }

    public func setPostNotifications(userId: String, enabled: Bool) async throws {
        var fields = friendshipFields()
        fields["id"] = userId
        fields["cursor"] = "-1"
        fields["device"] = enabled ? "true" : "false"
        _ = try await friendshipMutation(path: "update", fields: fields)
    }

    private func friendshipFields() -> [String: String] {
        [
            "include_profile_interstitial_type": "1",
            "include_blocking": "1",
            "include_blocked_by": "1",
            "include_followed_by": "1",
            "include_want_retweets": "1",
            "include_mute_edge": "1",
            "include_can_dm": "1",
            "include_can_media_tag": "1",
            "include_ext_is_blue_verified": "1",
            "include_ext_verified_type": "1",
            "include_ext_profile_image_shape": "1",
            "skip_status": "1",
        ]
    }

    private func friendshipMutation(path: String, fields: [String: String]) async throws -> XFriendshipMutationResponse? {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var components = URLComponents(string: "https://x.com/i/api/1.1/friendships/\(path).json")!
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = components.query?.data(using: .utf8)

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.allHTTPHeaderFields = mutationHeaders(credentials: credentials)

        let data = try await send(request)

        return try? JSONDecoder().decode(XFriendshipMutationResponse.self, from: data)
    }

    private func mutationHeaders(credentials: XCredentials) -> [String: String] {
        var headers = headers(credentials: credentials)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        return headers
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

        try await primeNotifications(credentials: credentials)

        let variables: [String: Any] = [
            "timeline_type": "All",
            "count": 40,
        ]
        let features = notificationsTimelineFeatures()

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

        guard let url = URL(string: "https://x.com/i/api/graphql/\(Self.notificationsTimelineQueryId)/NotificationsTimeline?variables=\(varsEncoded)&features=\(featEncoded)") else {
            throw SourceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(XNotificationsTimelineResponse.self, from: data)
        let items = try XNotificationsTimelineParser.parse(response: decoded)
        guard let cursor = decoded.topCursor else {
            throw SourceError.invalidResponse
        }
        try await markNotificationsRead(cursor: cursor, credentials: credentials)
        return items
    }

    /// Asks for the unread counts, as X's web client does on load. `NotificationsTimeline` alone can leave out
    /// notifications for a long time; these calls make it return them (observed 2026-11-15).
    private func primeNotifications(credentials: XCredentials) async throws {
        _ = try await unreadCount(credentials: credentials)

        var request = URLRequest(url: URL(string: "https://x.com/i/api/2/badge_count/badge_count.json?supports_ntab_urt=1")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        _ = try await send(request)
    }

    private func markNotificationsRead(cursor: String, credentials: XCredentials) async throws {
        var components = URLComponents(string: "https://x.com/i/api/2/notifications/all/last_seen_cursor.json")!
        components.queryItems = [URLQueryItem(name: "cursor", value: cursor)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = mutationHeaders(credentials: credentials)

        _ = try await send(request)
    }

    func tweetDetails(tweetId: String) async throws -> NotificationTargetDetails {
        let engagement = try await tweetEngagement(tweetId: tweetId)
        return NotificationTargetDetails(likeCount: engagement.likeCount, engagement: engagement)
    }

    /// The post's counts and whether the viewer liked or reposted it (`TweetResultByRestId`).
    func tweetEngagement(tweetId: String) async throws -> PostEngagement {
        let data = try await tweetResult(tweetId: tweetId)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let tweet = try decoder.decode(XTweetResultResponse.self, from: data).data.tweetResult?.result?.post,
              let legacy = tweet.legacy
        else {
            throw SourceError.invalidResponse
        }
        return PostEngagement(
            replyCount: legacy.replyCount ?? 0,
            repostCount: legacy.retweetCount ?? 0,
            quoteCount: legacy.quoteCount ?? 0,
            likeCount: legacy.favoriteCount ?? 0,
            isLiked: legacy.favorited ?? false,
            isReposted: legacy.retweeted ?? false,
        )
    }

    /// A post as chats preview it, or nil when X has none to show (deleted, or from a protected account).
    public func post(id: String) async throws -> XPost? {
        try await XPostParser.parse(data: tweetResult(tweetId: id))
    }

    private func tweetResult(tweetId: String) async throws -> Data {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        let variables: [String: Any] = [
            "tweetId": tweetId,
            "withCommunity": false,
            "includePromotedContent": false,
            "withVoice": false,
        ]
        guard
            let varsData = try? JSONSerialization.data(withJSONObject: variables),
            let featData = try? JSONSerialization.data(withJSONObject: Self.tweetFeatures),
            let varsJSON = String(data: varsData, encoding: .utf8),
            let featJSON = String(data: featData, encoding: .utf8)
        else {
            throw SourceError.invalidResponse
        }

        var components = URLComponents(string: "https://x.com/i/api/graphql/\(TweetQueryIds.tweetResultByRestId)/TweetResultByRestId")!
        components.queryItems = [URLQueryItem(name: "variables", value: varsJSON), URLQueryItem(name: "features", value: featJSON)]
        guard let url = components.url else { throw SourceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        return try await send(request)
    }

    /// The thread a post belongs to, up to the post (`TweetDetail`).
    func conversation(tweetId: String) async throws -> PostThread {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        let variables: [String: Any] = [
            "focalTweetId": tweetId,
            "referrer": "tweet",
            "rankingMode": "Relevance",
            "includePromotedContent": false,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": false,
            "withBirdwatchNotes": true,
            "withVoice": true,
        ]
        var features = Self.tweetFeatures
        features["rweb_video_screen_enabled"] = false
        features["responsive_web_enhance_cards_enabled"] = false
        guard
            let varsData = try? JSONSerialization.data(withJSONObject: variables),
            let featData = try? JSONSerialization.data(withJSONObject: features),
            let varsJSON = String(data: varsData, encoding: .utf8),
            let featJSON = String(data: featData, encoding: .utf8)
        else {
            throw SourceError.invalidResponse
        }

        var components = URLComponents(string: "https://x.com/i/api/graphql/\(TweetQueryIds.tweetDetail)/TweetDetail")!
        components.queryItems = [URLQueryItem(name: "variables", value: varsJSON), URLQueryItem(name: "features", value: featJSON)]
        guard let url = components.url else { throw SourceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)
        return try XThreadParser.parse(data: data, focalId: tweetId)
    }

    /// A page of a profile's posts and reposts (`UserTweets`), of its own posts most liked first
    /// (`UserOriginalsTimeline` with `sortByMostLiked`, the web profile's Popular sort; `UserTweets` ignores it), or of
    /// its posts with media (`UserMedia`), as X's web profile loads them (`scripts/x-web-client.py user-tweets` /
    /// `user-originals --most-liked` / `user-media`).
    func userTimeline(userId: String, kind: ProfileTimelineKind, cursor: String?) async throws -> ProfileTimelinePage {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var variables: [String: Any] = ["userId": userId, "count": 20, "withVoice": true]
        if let cursor {
            variables["cursor"] = cursor
        }
        let operation: String
        let queryId: String
        switch kind {
        case .posts:
            operation = "UserTweets"
            queryId = TweetQueryIds.userTweets
            variables["includePromotedContent"] = true
            variables["withQuickPromoteEligibilityTweetFields"] = true
        case .mostLiked, .mediaMostLiked:
            operation = "UserOriginalsTimeline"
            queryId = TweetQueryIds.userOriginalsTimeline
            variables["sortByMostLiked"] = true
            variables["includePromotedContent"] = true
            variables["withQuickPromoteEligibilityTweetFields"] = true
        case .media:
            operation = "UserMedia"
            queryId = TweetQueryIds.userMedia
            variables["includePromotedContent"] = false
            variables["withClientEventToken"] = false
            variables["withBirdwatchNotes"] = false
        }
        var features = Self.tweetFeatures
        features["rweb_video_screen_enabled"] = false
        features["responsive_web_enhance_cards_enabled"] = false
        guard
            let varsData = try? JSONSerialization.data(withJSONObject: variables),
            let featData = try? JSONSerialization.data(withJSONObject: features),
            let varsJSON = String(data: varsData, encoding: .utf8),
            let featJSON = String(data: featData, encoding: .utf8)
        else {
            throw SourceError.invalidResponse
        }

        var components = URLComponents(string: "https://x.com/i/api/graphql/\(queryId)/\(operation)")!
        components.queryItems = [
            URLQueryItem(name: "variables", value: varsJSON),
            URLQueryItem(name: "features", value: featJSON),
            URLQueryItem(name: "fieldToggles", value: #"{"withArticlePlainText":false}"#),
        ]
        guard let url = components.url else { throw SourceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)
        return try XUserTimelineParser.parse(data: data)
    }

    func setLiked(tweetId: String, liked: Bool) async throws {
        if liked {
            try await tweetMutation(operation: "FavoriteTweet", queryId: TweetQueryIds.favoriteTweet, variables: ["tweet_id": tweetId])
        } else {
            try await tweetMutation(operation: "UnfavoriteTweet", queryId: TweetQueryIds.unfavoriteTweet, variables: ["tweet_id": tweetId])
        }
    }

    /// Undoes the viewer's repost. Reposting itself isn't available to this client (see `docs/IMPLEMENTATION.md`).
    func deleteRetweet(tweetId: String) async throws {
        try await tweetMutation(operation: "DeleteRetweet", queryId: TweetQueryIds.deleteRetweet, variables: ["source_tweet_id": tweetId])
    }

    /// Posts `text`, as a reply to `replyTo` or quoting `quoting` (`CreateTweet`).
    func createTweet(text: String, replyTo: String? = nil, quoting: String? = nil) async throws {
        var variables: [String: Any] = [
            "tweet_text": text,
            "media": ["media_entities": [Any](), "possibly_sensitive": false],
            "semantic_annotation_ids": [Any](),
        ]
        if let replyTo {
            variables["reply"] = ["in_reply_to_tweet_id": replyTo, "exclude_reply_user_ids": [Any]()]
        }
        if let quoting {
            variables["attachment_url"] = "https://x.com/i/status/\(quoting)"
        }
        var features = Self.tweetFeatures
        features["creator_subscriptions_tweet_preview_api_enabled"] = nil
        let data = try await tweetMutation(operation: "CreateTweet", queryId: TweetQueryIds.createTweet, variables: variables, features: features)
        let decoded = try JSONDecoder().decode(XCreateTweetResponse.self, from: data)
        guard decoded.data?.createTweet?.tweetResults?.result?.restId != nil else {
            throw SourceError.serviceError(decoded.errors?.first?.message ?? "X didn't post it.")
        }
    }

    @discardableResult
    private func tweetMutation(operation: String, queryId: String, variables: [String: Any], features: [String: Any]? = nil) async throws -> Data {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var body: [String: Any] = ["variables": variables, "queryId": queryId]
        if let features {
            body["features"] = features
        }

        var request = URLRequest(url: URL(string: "https://x.com/i/api/graphql/\(queryId)/\(operation)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var headers = headers(credentials: credentials)
        headers["Content-Type"] = "application/json"
        request.allHTTPHeaderFields = headers

        let data = try await send(request)
        if let errors = try? JSONDecoder().decode(XGraphQLErrors.self, from: data).errors, let error = errors.first,
           operation != "CreateTweet"
        {
            throw SourceError.serviceError(error.message)
        }
        return data
    }

    func deviceFollowTargets(for item: NotificationItem) async throws -> [NotificationTarget] {
        guard let credentials = try credentialStore.loadXCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://x.com/i/api/2/notifications/device_follow.json")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)

        let data = try await send(request)

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

        let data = try await send(request)

        let decoded = try JSONDecoder().decode(XUnreadCountResponse.self, from: data)
        return decoded.unreadCount
    }

    /// Sends the request and returns its body; 401 and 403 mean the session is gone.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }
        // Each query has its own allowance per 15 minutes, such as `UserTweets` (observed 2026-11-17).
        if http.statusCode == 429 {
            throw SourceError.serviceError("X is limiting requests for now. Try again in a few minutes.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }
        return data
    }

    /// The bearer token and session cookies every request carries.
    private nonisolated static func authHeaders(credentials: XCredentials) -> [String: String] {
        [
            "Authorization": "Bearer \(bearerToken)",
            "Cookie": "auth_token=\(credentials.authToken); ct0=\(credentials.ct0)",
            "X-Csrf-Token": credentials.ct0,
        ]
    }

    private func headers(credentials: XCredentials) -> [String: String] {
        Self.authHeaders(credentials: credentials).merging([
            "X-Twitter-Active-User": "yes",
            "X-Twitter-Auth-Type": "OAuth2Session",
            "X-Twitter-Client-Language": "en",
            "Origin": "https://x.com",
            "Referer": "https://x.com/",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]) { _, new in new }
    }

    /// The headers X's web API needs and no more (see `scripts/x-web-client.py`); XChat uses them too.
    nonisolated static func apiHeaders(credentials: XCredentials) -> [String: String] {
        authHeaders(credentials: credentials).merging(["User-Agent": appUserAgent]) { _, new in new }
    }

    private func searchTimelineFeatures() -> [String: Any] {
        [
            "rweb_video_screen_enabled": false,
            "rweb_cashtags_enabled": true,
            "profile_label_improvements_pcf_label_in_post_enabled": true,
            "responsive_web_profile_redirect_enabled": false,
            "rweb_tipjar_consumption_enabled": false,
            "verified_phone_label_enabled": false,
            "creator_subscriptions_tweet_preview_api_enabled": true,
            "responsive_web_graphql_timeline_navigation_enabled": true,
            "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
            "premium_content_api_read_enabled": false,
            "communities_web_enable_tweet_community_results_fetch": true,
            "c9s_tweet_anatomy_moderator_badge_enabled": true,
            "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
            "responsive_web_grok_analyze_post_followups_enabled": true,
            "rweb_cashtags_composer_attachment_enabled": true,
            "responsive_web_jetfuel_frame": true,
            "responsive_web_grok_share_attachment_enabled": true,
            "responsive_web_grok_annotations_enabled": true,
            "articles_preview_enabled": true,
            "responsive_web_edit_tweet_api_enabled": true,
            "rweb_conversational_replies_downvote_enabled": false,
            "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
            "view_counts_everywhere_api_enabled": true,
            "longform_notetweets_consumption_enabled": true,
            "responsive_web_twitter_article_tweet_consumption_enabled": true,
            "content_disclosure_indicator_enabled": true,
            "content_disclosure_ai_generated_indicator_enabled": true,
            "responsive_web_grok_show_grok_translated_post": true,
            "responsive_web_grok_analysis_button_from_backend": true,
            "post_ctas_fetch_enabled": false,
            "freedom_of_speech_not_reach_fetch_enabled": true,
            "standardized_nudges_misinfo": true,
            "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
            "longform_notetweets_rich_text_read_enabled": true,
            "longform_notetweets_inline_media_enabled": false,
            "responsive_web_grok_image_annotation_enabled": true,
            "responsive_web_grok_imagine_annotation_enabled": true,
            "responsive_web_grok_community_note_auto_translation_is_enabled": true,
            "responsive_web_enhance_cards_enabled": false,
        ]
    }

    private func notificationsTimelineFeatures() -> [String: Any] {
        [
            "rweb_video_screen_enabled": false,
            "rweb_cashtags_enabled": true,
            "profile_label_improvements_pcf_label_in_post_enabled": true,
            "responsive_web_profile_redirect_enabled": true,
            "rweb_tipjar_consumption_enabled": false,
            "verified_phone_label_enabled": false,
            "creator_subscriptions_tweet_preview_api_enabled": true,
            "responsive_web_graphql_timeline_navigation_enabled": true,
            "premium_content_api_read_enabled": false,
            "communities_web_enable_tweet_community_results_fetch": true,
            "c9s_tweet_anatomy_moderator_badge_enabled": true,
            "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
            "responsive_web_grok_analyze_post_followups_enabled": true,
            "rweb_cashtags_composer_attachment_enabled": true,
            "responsive_web_jetfuel_frame": true,
            "responsive_web_grok_share_attachment_enabled": true,
            "responsive_web_grok_annotations_enabled": true,
            "articles_preview_enabled": true,
            "responsive_web_edit_tweet_api_enabled": true,
            "rweb_conversational_replies_downvote_enabled": false,
            "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
            "view_counts_everywhere_api_enabled": true,
            "longform_notetweets_consumption_enabled": true,
            "responsive_web_twitter_article_tweet_consumption_enabled": true,
            "content_disclosure_indicator_enabled": true,
            "content_disclosure_ai_generated_indicator_enabled": true,
            "responsive_web_grok_show_grok_translated_post": true,
            "responsive_web_grok_analysis_button_from_backend": true,
            "post_ctas_fetch_enabled": false,
            "freedom_of_speech_not_reach_fetch_enabled": true,
            "standardized_nudges_misinfo": true,
            "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
            "longform_notetweets_rich_text_read_enabled": true,
            "longform_notetweets_inline_media_enabled": false,
            "responsive_web_grok_image_annotation_enabled": true,
            "responsive_web_grok_imagine_annotation_enabled": true,
            "responsive_web_grok_community_note_auto_translation_is_enabled": true,
            "responsive_web_enhance_cards_enabled": false,
        ]
    }
}

public struct XVerifiedUser {
    public let screenName: String
    public let name: String
    public let idStr: String
}

private struct XFriendshipMutationResponse: Decodable {
    let following: Bool?
    let followedBy: Bool?

    enum CodingKeys: String, CodingKey {
        case following
        case followedBy = "followed_by"
    }
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
    public var location: String?
    public var websiteURL: URL?
    public let isFollowing: Bool?
    public let isFollowedBy: Bool?
    public let isNotifiedForPosts: Bool?
}

/// Maps a `UserByScreenName` result. The current request has no `legacy`: counts are in `relationship_counts` and
/// `tweet_counts`, the bio and the website's expanded link in `profile_bio`, and the bell in `notifications_settings`
/// (`scripts/x-web-client.py user`, observed 2026-11-17).
enum XUserProfileParser {
    static func parse(data: Data, screenName: String) throws -> XProfileResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(XGraphQLUserResponse.self, from: data)
        guard let result = decoded.data?.user?.result, let id = result.restId else {
            throw SourceError.serviceError("X profile lookup failed for @\(screenName).")
        }
        let bio = result.profileBio
        return XProfileResponse(
            idStr: id,
            screenName: result.core?.screenName ?? screenName,
            name: result.core?.name ?? "",
            description: bio?.description.map { expandingLinks(in: $0, urls: bio?.entities?.description?.urls ?? []) },
            followersCount: result.relationshipCounts?.followers,
            friendsCount: result.relationshipCounts?.following,
            statusesCount: result.tweetCounts?.tweets,
            createdAt: result.core?.createdAt.flatMap(Date.twitter),
            verified: result.isBlueVerified,
            profileImageUrlHttps: result.avatar?.imageUrl,
            profileBannerUrl: result.banner?.imageUrl,
            location: result.location?.location.flatMap { $0.isEmpty ? nil : $0 },
            websiteURL: bio?.entities?.url?.urls?.first?.expandedUrl.flatMap(URL.init(string:)),
            isFollowing: result.relationshipPerspectives?.following,
            isFollowedBy: result.relationshipPerspectives?.followedBy,
            isNotifiedForPosts: result.notificationsSettings?.notificationsEnabled,
        )
    }

    /// The bio with its t.co links replaced by the URLs they expand to, as X shows them.
    private static func expandingLinks(in text: String, urls: [XGraphQLUserResponse.EntityURL]) -> String {
        urls.reduce(text) { text, link in
            guard let short = link.url, let expanded = link.expandedUrl else { return text }
            return text.replacingOccurrences(of: short, with: expanded)
        }
    }
}

struct XGraphQLUserResponse: Decodable {
    let data: DataField?

    struct DataField: Decodable {
        let user: User?
    }

    struct User: Decodable {
        let result: Result?
    }

    struct Result: Decodable {
        let restId: String?
        let core: Core?
        let isBlueVerified: Bool?
        let relationshipPerspectives: Relationship?
        let notificationsSettings: NotificationsSettings?
        let avatar: ImageURL?
        let banner: ImageURL?
        let relationshipCounts: RelationshipCounts?
        let tweetCounts: TweetCounts?
        let profileBio: ProfileBio?
        let location: Location?
    }

    struct ImageURL: Decodable {
        let imageUrl: String?
    }

    struct NotificationsSettings: Decodable {
        let notificationsEnabled: Bool?
    }

    struct Core: Decodable {
        let screenName: String?
        let name: String?
        let createdAt: String?
    }

    struct Relationship: Decodable {
        let following: Bool?
        let followedBy: Bool?
    }

    struct RelationshipCounts: Decodable {
        let followers: Int?
        let following: Int?
    }

    struct TweetCounts: Decodable {
        let tweets: Int?
    }

    struct ProfileBio: Decodable {
        let description: String?
        let entities: Entities?
    }

    struct Entities: Decodable {
        let description: URLs?
        let url: URLs?
    }

    struct URLs: Decodable {
        let urls: [EntityURL]?
    }

    struct EntityURL: Decodable {
        let url: String?
        let expandedUrl: String?
    }

    struct Location: Decodable {
        let location: String?
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

private struct XSearchTimelineResponse: Decodable {
    let data: XSearchData

    var users: [XSearchUserResult] {
        data.searchByRawQuery.searchTimeline.timeline.instructions.flatMap(\.users)
    }

    struct XSearchData: Decodable {
        let searchByRawQuery: XSearchByRawQuery
    }

    struct XSearchByRawQuery: Decodable {
        let searchTimeline: XSearchTimeline
    }

    struct XSearchTimeline: Decodable {
        let timeline: XSearchTimelineBody
    }

    struct XSearchTimelineBody: Decodable {
        let instructions: [XSearchInstruction]
    }

    struct XSearchInstruction: Decodable {
        let entries: [XSearchEntry]?

        var users: [XSearchUserResult] {
            entries?.compactMap(\.content.itemContent?.userResults?.result) ?? []
        }
    }

    struct XSearchEntry: Decodable {
        let content: XSearchContent
    }

    struct XSearchContent: Decodable {
        let itemContent: XSearchItemContent?
    }

    struct XSearchItemContent: Decodable {
        let userResults: XSearchUserResults?
    }

    struct XSearchUserResults: Decodable {
        let result: XSearchUserResult?
    }

    struct XSearchUserResult: Decodable {
        let restId: String?
        let core: XSearchUserCore
        let legacy: XSearchUserLegacy
        let avatar: XSearchAvatar?
        let isBlueVerified: Bool?
    }

    struct XSearchAvatar: Decodable {
        let imageUrl: String?
    }

    struct XSearchUserCore: Decodable {
        let screenName: String
        let name: String
        let createdAt: String?
    }

    struct XSearchUserLegacy: Decodable {
        let idStr: String?
        let description: String?
        let followersCount: Int?
        let friendsCount: Int?
        let statusesCount: Int?
        let verified: Bool?
        let following: Bool?
        let profileImageUrlHttps: String?
    }
}

private struct XUnreadCountResponse: Decodable {
    let unreadCount: Int
}

// MARK: - Post Models (TweetResultByRestId, CreateTweet)

private struct XTweetResultResponse: Decodable {
    let data: DataField

    struct DataField: Decodable {
        let tweetResult: TweetResult?
    }

    struct TweetResult: Decodable {
        let result: Result?
    }

    /// A `Tweet`, or a `TweetWithVisibilityResults` wrapping one in `tweet`.
    struct Result: Decodable {
        let legacy: Legacy?
        let tweet: Tweet?

        var post: Tweet? {
            legacy.map { Tweet(legacy: $0) } ?? tweet
        }
    }

    struct Tweet: Decodable {
        let legacy: Legacy?
    }

    struct Legacy: Decodable {
        let favoriteCount: Int?
        let retweetCount: Int?
        let replyCount: Int?
        let quoteCount: Int?
        let favorited: Bool?
        let retweeted: Bool?
    }
}

private struct XCreateTweetResponse: Decodable {
    let data: DataField?
    let errors: [XGraphQLErrors.Error]?

    struct DataField: Decodable {
        let createTweet: CreateTweet?

        private enum CodingKeys: String, CodingKey {
            case createTweet = "create_tweet"
        }
    }

    struct CreateTweet: Decodable {
        let tweetResults: TweetResults?

        private enum CodingKeys: String, CodingKey {
            case tweetResults = "tweet_results"
        }
    }

    struct TweetResults: Decodable {
        let result: Result?
    }

    struct Result: Decodable {
        let restId: String?

        private enum CodingKeys: String, CodingKey {
            case restId = "rest_id"
        }
    }
}

private struct XGraphQLErrors: Decodable {
    let errors: [Error]?

    struct Error: Decodable {
        let message: String
    }
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
        guard let timestamp = Date.twitter(tweet.createdAt) else { return nil }

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
        }
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
            postedAt: Date.twitter(tweet.createdAt),
            likeCount: tweet.favoriteCount,
        )
    }
}

// MARK: - Notifications Timeline (GraphQL) Response Models

private struct XNotificationsTimelineResponse: Decodable {
    let data: XNTData

    var topCursor: String? {
        data.viewerV2.userResults.result.notificationTimeline.timeline.instructions
            .compactMap(\.entries)
            .flatMap(\.self)
            .first { $0.content?.cursorType == "Top" }?
            .content?.value
    }
}

private struct XNTData: Decodable {
    let viewerV2: XNTViewerV2
    enum CodingKeys: String, CodingKey { case viewerV2 = "viewer_v2" }
}

private struct XNTViewerV2: Decodable {
    let userResults: XNTUserResults
    enum CodingKeys: String, CodingKey { case userResults = "user_results" }
}

private struct XNTUserResults: Decodable {
    let result: XNTResult
}

private struct XNTResult: Decodable {
    let notificationTimeline: XNTTimeline
    enum CodingKeys: String, CodingKey { case notificationTimeline = "notification_timeline" }
}

private struct XNTTimeline: Decodable {
    let timeline: XNTTimelineBody
}

private struct XNTTimelineBody: Decodable {
    let instructions: [XNTInstruction]
}

private struct XNTInstruction: Decodable {
    let entries: [XNTEntry]?
}

private struct XNTEntry: Decodable {
    let entryId: String
    let sortIndex: String
    let content: XNTEntryContent?
}

private struct XNTEntryContent: Decodable {
    let entryType: String?
    let cursorType: String?
    let value: String?
    let clientEventInfo: XNTClientEventInfo?
    let itemContent: XNTItemContent?
}

private struct XNTClientEventInfo: Decodable {
    let element: String?
}

private struct XNTItemContent: Decodable {
    let itemType: String?
    let typename: String?
    let id: String?
    let notificationUrl: XNTUrl?
    let template: XNTUserActionsTemplate?
    let tweetResults: XNTTweetResult?
    enum CodingKeys: String, CodingKey {
        case itemType
        case typename = "__typename"
        case id
        case notificationUrl = "notification_url"
        case template
        case tweetResults = "tweet_results"
    }
}

private struct XNTUrl: Decodable {
    let url: String?
}

private struct XNTUserActionsTemplate: Decodable {
    let fromUsers: [XNTUserRef]?
    let targetObjects: [XNTTargetObject]?
    enum CodingKeys: String, CodingKey {
        case fromUsers = "from_users"
        case targetObjects = "target_objects"
    }
}

private struct XNTTargetObject: Decodable {
    let tweetResults: XNTTweetResult?
    enum CodingKeys: String, CodingKey { case tweetResults = "tweet_results" }
}

private struct XNTTweetResult: Decodable {
    let result: XNTTweet?
}

private struct XNTUserRef: Decodable {
    let userResults: XNTUserResultHolder?
    enum CodingKeys: String, CodingKey { case userResults = "user_results" }
}

private struct XNTUserResultHolder: Decodable {
    let result: XNTUser?
}

private struct XNTUser: Decodable {
    let id: String?
    let restId: String?
    let core: XNTCore?
    let avatar: XNTAvatar?

    var stableId: String {
        restId ?? id ?? core?.screenName ?? ""
    }

    var name: String? {
        core?.name
    }

    var screenName: String? {
        core?.screenName
    }

    var avatarURL: URL? {
        avatar?.imageUrl.flatMap { urlString in
            URL(string: urlString.replacingOccurrences(of: "_normal", with: ""))
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case restId = "rest_id"
        case core
        case avatar
    }
}

private struct XNTCore: Decodable {
    let screenName: String?
    let name: String?
    enum CodingKeys: String, CodingKey {
        case screenName = "screen_name"
        case name
    }
}

private struct XNTAvatar: Decodable {
    let imageUrl: String?
    enum CodingKeys: String, CodingKey { case imageUrl = "image_url" }
}

private struct XNTTweet: Decodable {
    let restId: String?
    let legacy: XNTTweetLegacy?
    let core: XNTTweetCore?
    let extendedEntities: XNTExtendedEntities?

    var stableId: String {
        restId ?? legacy?.idStr ?? ""
    }

    var author: XNTUser? {
        core?.userResults?.result
    }

    enum CodingKeys: String, CodingKey {
        case restId = "rest_id"
        case legacy
        case core
        case extendedEntities = "extended_entities"
    }
}

private struct XNTTweetCore: Decodable {
    let userResults: XNTUserResultHolder?
    enum CodingKeys: String, CodingKey { case userResults = "user_results" }
}

private struct XNTTweetLegacy: Decodable {
    let idStr: String?
    let createdAt: String?
    let fullText: String?
    let favoriteCount: Int?
    enum CodingKeys: String, CodingKey {
        case idStr = "id_str"
        case createdAt = "created_at"
        case fullText = "full_text"
        case favoriteCount = "favorite_count"
    }
}

private struct XNTExtendedEntities: Decodable {
    let media: [XNTMedia]?
}

private struct XNTMedia: Decodable {
    let mediaUrlHttps: String?
    enum CodingKeys: String, CodingKey { case mediaUrlHttps = "media_url_https" }
}

// MARK: - Notifications Timeline Parser

private enum XNotificationsTimelineParser {
    static func parse(response: XNotificationsTimelineResponse) throws -> [NotificationItem] {
        let entries = response.data.viewerV2.userResults.result.notificationTimeline.timeline.instructions.compactMap(\.entries).flatMap(\.self)

        var items: [NotificationItem] = []
        for entry in entries {
            guard let content = entry.content, content.cursorType == nil, let item = content.itemContent else {
                continue
            }
            let element = content.clientEventInfo?.element ?? "unknown"
            let type = notificationType(from: element)

            if item.itemType == "TimelineTweet", let tweet = item.tweetResults?.result,
               let notificationItem = parseTweetEntry(element: element, type: type, tweet: tweet)
            {
                items.append(notificationItem)
            } else if let template = item.template,
                      let notificationItem = parseAggregateEntry(entry: entry, element: element, type: type, item: item, template: template)
            {
                items.append(notificationItem)
            }
        }
        return items
    }

    private static func parseTweetEntry(element: String, type: NotificationType, tweet: XNTTweet) -> NotificationItem? {
        guard let legacy = tweet.legacy, let createdAt = legacy.createdAt, let author = tweet.author else {
            return nil
        }
        guard let timestamp = Date.twitter(createdAt) else { return nil }

        let actor = actor(from: author)
        let sourceId = tweet.stableId
        let text = notificationText(element: element, actorName: actor.username ?? actor.displayName ?? author.stableId, tweetText: legacy.fullText)

        return NotificationItem(
            id: "x:\(sourceId):\(element)",
            network: .x,
            accountId: "x",
            sourceId: sourceId,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: [actor],
            target: target(from: tweet),
            parentTarget: nil,
        )
    }

    private static func parseAggregateEntry(
        entry: XNTEntry,
        element: String,
        type: NotificationType,
        item: XNTItemContent,
        template: XNTUserActionsTemplate,
    ) -> NotificationItem? {
        guard let fromUsers = template.fromUsers else { return nil }
        let actors = fromUsers.compactMap { ref in
            ref.userResults?.result.map(actor(from:))
        }
        guard !actors.isEmpty else { return nil }

        let timestamp = Date(timeIntervalSince1970: (Double(entry.sortIndex) ?? 0) / 1000)
        let targetTweet = template.targetObjects?.first?.tweetResults?.result

        let sourceId: String
        let notificationTarget: NotificationTarget?
        if let targetTweet {
            notificationTarget = target(from: targetTweet)
            sourceId = targetTweet.stableId
        } else {
            let url = item.notificationUrl?.url.flatMap(URL.init)
            notificationTarget = type == .post ? NotificationTarget(
                id: item.id ?? entry.entryId,
                text: nil,
                url: url,
                author: actors.first,
                postedAt: timestamp,
            ) : nil
            sourceId = item.id ?? entry.entryId
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
        case "users_followed_you",
             "follow_from_recommended_user":
            .follow
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

    private static func actor(from user: XNTUser) -> NotificationActor {
        NotificationActor(
            id: user.stableId,
            network: .x,
            username: user.screenName,
            displayName: user.name,
            avatarURL: user.avatarURL,
        )
    }

    private static func target(from tweet: XNTTweet) -> NotificationTarget {
        let media = tweet.extendedEntities?.media ?? []
        let imageURL = media.first?.mediaUrlHttps.flatMap(URL.init)
        let imageURLs = media.compactMap { $0.mediaUrlHttps.flatMap(URL.init) }
        return NotificationTarget(
            id: tweet.stableId,
            text: tweet.legacy?.fullText,
            url: nil,
            imageURL: imageURL,
            imageURLs: imageURLs,
            author: tweet.author.map(actor(from:)),
            postedAt: tweet.legacy?.createdAt.flatMap(Date.twitter),
            likeCount: tweet.legacy?.favoriteCount,
        )
    }
}

// MARK: - Conversation (TweetDetail)

/// Maps a `TweetDetail` page: `tweet-<id>` entries before the focal post are its ancestors. Reply chains below it
/// (`conversationthread-…` modules) aren't shown (`scripts/x-web-client.py thread`).
enum XThreadParser {
    static func parse(data: Data, focalId: String) throws -> PostThread {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(XThreadResponse.self, from: data)
        guard let instructions = response.data?.threadedConversationWithInjectionsV2?.instructions else {
            throw SourceError.invalidResponse
        }

        var thread = PostThread()
        for entry in instructions.flatMap({ $0.entries ?? [] }) where entry.entryId.hasPrefix("tweet-") {
            guard let post = entry.content.itemContent.flatMap(post(from:)) else { continue }
            if post.target.id == focalId {
                thread.focal = post
                break
            }
            thread.ancestors.append(post)
        }
        return thread
    }

    private static func post(from itemContent: XThreadResponse.ItemContent) -> PostThread.Post? {
        guard let result = itemContent.tweetResults?.result else { return nil }
        return post(from: result.wrapped ?? result.direct)
    }

    static func post(from tweet: XThreadResponse.Tweet) -> PostThread.Post? {
        guard let id = tweet.restId, let legacy = tweet.legacy else { return nil }

        let user = tweet.core?.userResults?.result
        let author = user.flatMap { user -> NotificationActor? in
            guard let id = user.restId else { return nil }
            return NotificationActor(
                id: id,
                network: .x,
                username: user.core?.screenName,
                displayName: user.core?.name,
                avatarURL: user.avatar?.imageUrl.flatMap { URL(string: $0.replacingOccurrences(of: "_normal", with: "")) },
                isVerified: user.isBlueVerified == true || user.verification?.verified == true,
            )
        }
        let imageURLs = (legacy.extendedEntities?.media ?? []).compactMap { $0.mediaUrlHttps.flatMap(URL.init) }
        let target = NotificationTarget(
            id: id,
            text: text(of: tweet),
            url: nil,
            imageURL: imageURLs.first,
            imageURLs: imageURLs,
            author: author,
            postedAt: legacy.createdAt.flatMap(Date.twitter),
            likeCount: legacy.favoriteCount,
        )
        let engagement = PostEngagement(
            replyCount: legacy.replyCount ?? 0,
            repostCount: legacy.retweetCount ?? 0,
            quoteCount: legacy.quoteCount ?? 0,
            likeCount: legacy.favoriteCount ?? 0,
            isLiked: legacy.favorited ?? false,
            isReposted: legacy.retweeted ?? false,
        )
        return PostThread.Post(target: target, engagement: engagement)
    }

    /// A long post's whole text, or the shown part of `full_text`: `display_text_range` (in Unicode scalars) leaves out
    /// the leading @mentions of a reply and the trailing link to attached media, as X shows it.
    static func text(of tweet: XThreadResponse.Tweet) -> String? {
        if let note = tweet.noteTweet?.noteTweetResults?.result?.text {
            return unescaped(note)
        }
        guard let fullText = tweet.legacy?.fullText else { return nil }
        var text = fullText
        if let range = tweet.legacy?.displayTextRange, range.count == 2 {
            let scalars = Array(fullText.unicodeScalars)
            let lower = min(max(range[0], 0), scalars.count)
            let upper = min(max(range[1], lower), scalars.count)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[lower ..< upper])
            text = String(view)
        }
        return unescaped(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Profile timelines (UserTweets, UserMedia)

/// Maps a `UserTweets` or `UserMedia` page. Posts come as `tweet-<id>` entries, in `profile-conversation-…` modules
/// (a self-thread) and in the `profile-grid-0` module, whose later pages add to it with `TimelineAddToModule`; the
/// pinned post comes in `TimelinePinEntry`. Promoted posts and suggestions are left out, and a repost shows the
/// reposted post. X returns a bottom cursor even at the end, so a page without posts ends the timeline.
enum XUserTimelineParser {
    static func parse(data: Data) throws -> ProfileTimelinePage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(XUserTimelineResponse.self, from: data)
        guard let instructions = response.data?.user?.result?.timeline?.timeline?.instructions else {
            throw SourceError.invalidResponse
        }

        var items: [ProfileTimelineItem] = []
        var seen = Set<String>()
        var bottomCursor: String?
        func add(_ itemContent: XThreadResponse.ItemContent?, isPinned: Bool) {
            guard let item = itemContent.flatMap({ self.item(from: $0, isPinned: isPinned) }), seen.insert(item.id).inserted else { return }
            items.append(item)
        }

        for instruction in instructions {
            let isPinned = instruction.type == "TimelinePinEntry"
            for moduleItem in instruction.moduleItems ?? [] {
                add(moduleItem.item?.itemContent, isPinned: false)
            }
            for entry in (instruction.entries ?? []) + (instruction.entry.map { [$0] } ?? []) {
                if entry.content.cursorType == "Bottom" {
                    bottomCursor = entry.content.value
                }
                guard entry.entryId.hasPrefix("tweet-") || entry.entryId.hasPrefix("profile-") else { continue }
                add(entry.content.itemContent, isPinned: isPinned)
                for moduleItem in entry.content.items ?? [] {
                    add(moduleItem.item?.itemContent, isPinned: false)
                }
            }
        }
        return ProfileTimelinePage(items: items, nextCursor: items.isEmpty ? nil : bottomCursor)
    }

    private static func item(from itemContent: XThreadResponse.ItemContent, isPinned: Bool) -> ProfileTimelineItem? {
        guard let result = itemContent.tweetResults?.result else { return nil }
        let tweet = result.wrapped ?? result.direct
        var repostedBy: String?
        var shown = tweet
        if let reposted = tweet.legacy?.retweetedStatusResult?.result {
            shown = reposted.wrapped ?? reposted.direct
            let user = tweet.core?.userResults?.result?.core
            repostedBy = user?.name ?? user?.screenName
        }
        guard let post = XThreadParser.post(from: shown) else { return nil }
        let media = shown.legacy?.extendedEntities?.media ?? []
        let cardImage = shown.card?.legacy?.bindingValues?
            .first { ["photo_image_full_size_large", "thumbnail_image_large", "summary_photo_image_large", "player_image_large"].contains($0.key) }?
            .value?.imageValue?.url
        return ProfileTimelineItem(
            post: post,
            repostedBy: repostedBy,
            isPinned: isPinned,
            thumbnailURL: (media.first?.mediaUrlHttps ?? cardImage).flatMap(URL.init(string:)),
            isVideo: media.first.map { $0.type == "video" || $0.type == "animated_gif" } ?? false,
            hasMultipleMedia: media.count > 1,
            media: media.compactMap { XPostParser.media(from: $0, maxBitrate: maxBitrate) }.map { item in
                ProfileTimelineItem.Media(
                    imageURL: item.videoURL == nil ? largeImageURL(item.imageURL) : item.imageURL,
                    videoURL: item.videoURL,
                    isGIF: item.kind == .gif,
                    aspectRatio: item.aspectRatio,
                    altText: item.altText,
                )
            },
        )
    }

    /// Full-screen videos stream, so they can play a higher bitrate than chats, which load whole files.
    static let maxBitrate = 2_500_000

    /// `media_url_https` is X's medium size (up to 1200 pixels); `name=large` is up to 2048, as x.com's own photo
    /// viewer loads it.
    static func largeImageURL(_ url: URL) -> URL {
        guard url.host() == "pbs.twimg.com", url.path().hasPrefix("/media/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems == nil
        else { return url }
        components.queryItems = [URLQueryItem(name: "name", value: "large")]
        return components.url ?? url
    }
}

struct XUserTimelineResponse: Decodable {
    let data: DataField?

    struct DataField: Decodable {
        let user: User?
    }

    struct User: Decodable {
        let result: Result?
    }

    struct Result: Decodable {
        let timeline: Outer?
    }

    struct Outer: Decodable {
        let timeline: Timeline?
    }

    struct Timeline: Decodable {
        let instructions: [Instruction]
    }

    struct Instruction: Decodable {
        let type: String?
        let entries: [Entry]?
        /// `TimelinePinEntry`'s one entry.
        let entry: Entry?
        /// `TimelineAddToModule`'s items, on later `UserMedia` pages.
        let moduleItems: [ModuleItem]?
    }

    struct Entry: Decodable {
        let entryId: String
        let content: Content
    }

    struct Content: Decodable {
        let itemContent: XThreadResponse.ItemContent?
        let items: [ModuleItem]?
        let cursorType: String?
        let value: String?
    }

    struct ModuleItem: Decodable {
        let item: Item?
    }

    struct Item: Decodable {
        let itemContent: XThreadResponse.ItemContent?
    }
}

struct XThreadResponse: Decodable {
    let data: DataField?

    struct DataField: Decodable {
        let threadedConversationWithInjectionsV2: Conversation?
    }

    struct Conversation: Decodable {
        let instructions: [Instruction]
    }

    struct Instruction: Decodable {
        let entries: [Entry]?
    }

    struct Entry: Decodable {
        let entryId: String
        let content: Content
    }

    struct Content: Decodable {
        let itemContent: ItemContent?
    }

    struct ItemContent: Decodable {
        let tweetResults: TweetResults?
    }

    struct TweetResults: Decodable {
        let result: Result?
    }

    /// A `Tweet`, or a `TweetWithVisibilityResults` wrapping one in `tweet`.
    struct Result: Decodable {
        let direct: Tweet
        let wrapped: Tweet?

        private enum CodingKeys: String, CodingKey {
            case tweet
        }

        init(from decoder: any Decoder) throws {
            direct = try Tweet(from: decoder)
            wrapped = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Tweet.self, forKey: .tweet)
        }
    }

    struct Tweet: Decodable {
        let restId: String?
        let core: Core?
        let legacy: Legacy?
        let noteTweet: NoteTweet?
        let quotedStatusResult: QuotedResult?
        let card: Card?
    }

    /// A link card; its `binding_values` name its images.
    struct Card: Decodable {
        let legacy: CardLegacy?
    }

    struct CardLegacy: Decodable {
        let bindingValues: [BindingValue]?
    }

    struct BindingValue: Decodable {
        let key: String
        let value: BindingValueContent?
    }

    struct BindingValueContent: Decodable {
        let imageValue: ImageValue?
    }

    struct ImageValue: Decodable {
        let url: String?
    }

    /// The post a post quotes; a class, since a struct can't contain itself.
    final class QuotedResult: Decodable {
        let result: Result?
    }

    struct Core: Decodable {
        let userResults: UserResults?
    }

    struct UserResults: Decodable {
        let result: User?
    }

    struct User: Decodable {
        let restId: String?
        let core: UserCore?
        let avatar: Avatar?
        let isBlueVerified: Bool?
        let verification: Verification?
    }

    struct Verification: Decodable {
        let verified: Bool?
    }

    struct UserCore: Decodable {
        let screenName: String?
        let name: String?
    }

    struct Avatar: Decodable {
        let imageUrl: String?
    }

    struct Legacy: Decodable {
        let fullText: String?
        let displayTextRange: [Int]?
        let createdAt: String?
        let favoriteCount: Int?
        let retweetCount: Int?
        let replyCount: Int?
        let quoteCount: Int?
        let favorited: Bool?
        let retweeted: Bool?
        let extendedEntities: ExtendedEntities?
        let entities: Entities?
        let quotedStatusPermalink: Permalink?
        /// The post a repost reposts.
        let retweetedStatusResult: QuotedResult?
    }

    struct Entities: Decodable {
        let urls: [EntityURL]?
    }

    /// A t.co link in the text, and what it shows as.
    struct EntityURL: Decodable {
        let url: String?
        let displayUrl: String?
    }

    struct Permalink: Decodable {
        /// The t.co link to the quoted post.
        let url: String?
    }

    struct ExtendedEntities: Decodable {
        let media: [Media]?
    }

    struct Media: Decodable {
        let mediaUrlHttps: String?
        /// "photo", "video" or "animated_gif".
        let type: String?
        let originalInfo: OriginalInfo?
        let videoInfo: VideoInfo?
        let extAltText: String?
    }

    struct OriginalInfo: Decodable {
        let width: Int?
        let height: Int?
    }

    struct VideoInfo: Decodable {
        let durationMillis: Int?
        let variants: [Variant]?
    }

    struct Variant: Decodable {
        let contentType: String?
        let bitrate: Int?
        let url: String?
    }

    struct NoteTweet: Decodable {
        let noteTweetResults: NoteTweetResults?
    }

    struct NoteTweetResults: Decodable {
        let result: NoteTweetResult?
    }

    struct NoteTweetResult: Decodable {
        let text: String?
    }
}
