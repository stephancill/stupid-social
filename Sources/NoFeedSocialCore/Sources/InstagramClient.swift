import Foundation

public enum InstagramNotificationCategory: String, CaseIterable, Codable, Sendable {
    case follows
    case comments
    case likes
    case storyHighlights
    case directMessages

    public var displayLabel: String {
        switch self {
        case .follows: "Follows"
        case .comments: "Comments"
        case .likes: "Likes"
        case .storyHighlights: "Story Highlights"
        case .directMessages: "Direct Messages"
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
public final class InstagramClient {
    let credentialStore: KeychainCredentialStore
    let session: URLSession

    static let baseURL = "https://www.instagram.com"
    private static let uploadBaseURL = "https://i.instagram.com"
    static let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    static let webAppID = "1217981644879628"
    static let asbdID = "359341"
    var webState: InstagramWebState?
    var docIds: [String: String] = [:]
    var requestCount = 0
    let webSessionID = InstagramClient.randomBase36(length: 6)
    var wwwClaim: String?

    public init(credentialStore: KeychainCredentialStore, session: URLSession = defaultSession) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    public func verifiedUser() async throws -> InstagramVerifiedUser {
        let user = try await currentUserProfile()
        return InstagramVerifiedUser(
            pk: user.pk,
            username: user.username,
            fullName: user.fullName ?? user.username,
            profilePicURL: user.profilePicURL,
        )
    }

    public func currentUserProfile() async throws -> InstagramCurrentUserProfile {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }
        let viewer = try await directInboxViewer(credentials: credentials)
        let profileResponse = try await webProfile(username: viewer.username, credentials: credentials)
        let profile = profileResponse.data.user
        return InstagramCurrentUserProfile(
            pk: profile.id.flatMap(UInt64.init) ?? UInt64(viewer.pk) ?? UInt64(credentials.dsUserId) ?? 0,
            username: profile.username ?? viewer.username,
            fullName: profile.fullName,
            profilePicURL: profile.profilePicUrl.flatMap(URL.init) ?? viewer.profilePicUrl.flatMap(URL.init),
            followerCount: profile.edgeFollowedBy?.count,
            followingCount: profile.edgeFollow?.count,
            postsCount: profile.edgeOwnerToTimelineMedia?.count,
            bio: profile.biography,
            websiteURL: profile.externalUrl.flatMap(URL.init),
            isVerified: profile.isVerified,
            isPrivate: profile.isPrivate,
        )
    }

    func hasCredentials() throws -> Bool {
        try credentialStore.loadInstagramCredentials() != nil
    }

    func notifications(
        enabledCategories: Set<InstagramNotificationCategory>,
        accountUsername: String? = nil,
        accountAvatarURL: URL? = nil,
        includeDirectMediaShares: Bool = true,
    ) async throws -> [NotificationItem] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let fields = ["selected_filters": "", "max_id": "", "jazoest": jazoest(csrfToken: credentials.csrfToken)]
        let data = try await webJSONRequest(
            credentials: credentials,
            method: "POST",
            path: "/api/v1/news/inbox/",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formURLEncoded(fields).data(using: .utf8),
        )
        let decoded = try JSONDecoder().decode(InstagramNewsInboxResponse.self, from: data)
        let allStories = (decoded.priorityStories ?? []) + (decoded.newStories ?? []) + (decoded.oldStories ?? [])
        var items = InstagramNotificationParser.parse(
            stories: allStories,
            accountId: credentials.dsUserId,
            accountUsername: accountUsername,
            accountAvatarURL: accountAvatarURL,
            enabledCategories: enabledCategories,
        )

        if enabledCategories.contains(.directMessages) {
            do {
                try await items.append(contentsOf: directMessages(credentials: credentials, includeMediaShares: includeDirectMediaShares))
            } catch {
                // Direct has separate server-side gating; keep regular Instagram notifications available.
            }
        }

        return items
    }

    private func directMessages(credentials: InstagramCredentials, includeMediaShares: Bool) async throws -> [NotificationItem] {
        var components = URLComponents(string: "\(Self.baseURL)/api/v1/direct_v2/inbox/")!
        components.queryItems = [
            URLQueryItem(name: "visual_message_return_type", value: "unseen"),
            URLQueryItem(name: "thread_message_limit", value: "10"),
            URLQueryItem(name: "persistentBadging", value: "true"),
            URLQueryItem(name: "limit", value: "20"),
        ]

        let data = try await webJSONRequest(credentials: credentials, method: "GET", url: components.url!)
        let decoded = try JSONDecoder().decode(InstagramDirectInboxResponse.self, from: data)
        return InstagramDirectMessageParser.parse(response: decoded, accountId: credentials.dsUserId, includeMediaShares: includeMediaShares)
    }

    func reelsTray() async throws -> [InstagramTrayItem] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        return try await storiesTrayResponse(credentials: credentials).tray
    }

    func storyReel(username: String) async throws -> InstagramReel? {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }
        let pageURL = Self.baseURL + "/stories/\(username.urlPathEncoded)/"
        let html = try await webTextRequest(credentials: credentials, method: "GET", url: URL(string: pageURL)!, headers: basePageHeaders(credentials: credentials))
        try await mergeStoryPageDocIds(html: html, credentials: credentials)
        guard let payloadData = extractStoryPayloadData(from: html) else { return nil }
        let payload = try JSONDecoder().decode(InstagramStoryPagePayload.self, from: payloadData)
        return payload.xdtAPIReelsMedia.reelsMedia.first
    }

    func reelsMedia(reelIds _: [String]) async throws -> [String: InstagramReel] {
        [:]
    }

    private static let reelsMediaBatchSize = 30

    public func userInfo(uid: String) async throws -> InstagramUserInfoResponse {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let trimmedIdentifier = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedIdentifier = trimmedIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedIdentifier
        let username: String = if trimmedIdentifier.allSatisfy(\.isNumber), let account = try? await verifiedUser(), String(account.pk) == trimmedIdentifier {
            account.username
        } else {
            escapedIdentifier
        }
        let decoded = try await webProfile(username: username, credentials: credentials)
        return InstagramUserInfoResponse(user: decoded.data.user.asInfoUser, status: decoded.status)
    }

    private func webProfile(username: String, credentials: InstagramCredentials) async throws -> InstagramWebProfileInfoResponse {
        let data = try await webJSONRequest(credentials: credentials, method: "GET", path: "/api/v1/users/web_profile_info/?username=\(username.urlFormEncoded)")
        return try JSONDecoder().decode(InstagramWebProfileInfoResponse.self, from: data)
    }

    func mediaInfo(mediaId: String) async throws -> InstagramMediaInfoResponse {
        do {
            return try await mediaInfoRequest(mediaId: mediaId)
        } catch {
            let stripped = mediaId.split(separator: "_").first.map(String.init)
            guard let stripped, stripped != mediaId else { throw error }
            return try await mediaInfoRequest(mediaId: stripped)
        }
    }

    private func mediaInfoRequest(mediaId _: String) async throws -> InstagramMediaInfoResponse {
        guard try (credentialStore.loadInstagramCredentials()) != nil else {
            throw SourceError.notConfigured
        }

        throw SourceError.unsupported
    }

    func markStorySeen(mediaItems: [(mediaId: String, ownerId: String, takenAt: Double)]) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        try await ensureBootstrapped(credentials: credentials)
        for item in mediaItems {
            let variables: [String: Any] = [
                "reelId": item.ownerId,
                "reelMediaId": item.mediaId,
                "reelMediaOwnerId": item.ownerId,
                "reelMediaTakenAt": Int(item.takenAt),
                "viewSeenAt": Int(Date().timeIntervalSince1970),
            ]
            let docID = try await docId(credentials: credentials, command: "story-seen")
            _ = try await graphqlPost(credentials: credentials, docID: docID, variables: variables, endpoint: "/graphql/query")
        }
    }

    func setMediaLiked(mediaId: String, liked: Bool) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let command = liked ? "like-story" : "unlike-story"
        let docID = try await docId(credentials: credentials, command: command)
        var input = ["media_id": mediaId]
        if liked {
            input["container_module"] = "story_viewer"
        }
        _ = try await graphqlPost(
            credentials: credentials,
            docID: docID,
            variables: ["input": input],
            friendlyName: operationNames[command],
            rootFieldName: liked ? "xig_media_like" : "xig_media_unlike",
            endpoint: "/graphql/query",
        )
    }

    public func publishPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        try await ensureBootstrapped(credentials: credentials)
        let uploadId = String(Int(Date().timeIntervalSince1970 * 1000))
        let uploadName = "fb_uploader_\(uploadId)"
        let ruploadParams: [String: Any] = [
            "media_type": 1,
            "upload_id": uploadId,
            "upload_media_height": height,
            "upload_media_width": width,
        ]

        var uploadRequest = URLRequest(url: URL(string: "\(Self.uploadBaseURL)/rupload_igphoto/\(uploadName)")!)
        uploadRequest.httpMethod = "POST"
        uploadRequest.httpBody = imageData
        var uploadHeaders = webHeaders(credentials: credentials, referer: Self.baseURL + "/")
        uploadHeaders.removeValue(forKey: "X-IG-WWW-Claim")
        uploadHeaders.removeValue(forKey: "X-Web-Device-Id")
        uploadHeaders["Content-Type"] = "application/octet-stream"
        uploadHeaders["Content-Length"] = String(imageData.count)
        uploadHeaders["Offset"] = "0"
        uploadHeaders["X-Entity-Length"] = String(imageData.count)
        uploadHeaders["X-Entity-Name"] = uploadName
        uploadHeaders["X-Entity-Type"] = mimeType == "image/webp" ? "image/webp" : "image/jpeg"
        uploadHeaders["X-Instagram-Rupload-Params"] = jsonString(ruploadParams)
        uploadRequest.allHTTPHeaderFields = uploadHeaders
        configureRequest(&uploadRequest)

        let (uploadData, uploadResponse) = try await session.data(for: uploadRequest)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200 ..< 300).contains(uploadHTTP.statusCode) else {
            throw SourceError.serviceError(instagramPublishError(step: "upload", statusCode: uploadHTTP.statusCode, data: uploadData))
        }
        if let response = try? JSONDecoder().decode(InstagramStatusResponse.self, from: uploadData), response.status != "ok" {
            throw SourceError.serviceError(instagramPublishError(step: "upload", statusCode: uploadHTTP.statusCode, data: uploadData))
        }

        let body = formURLEncoded([
            "caption": "",
            "configure_mode": "1",
            "share_to_facebook": "",
            "share_to_fb_destination_id": "",
            "share_to_fb_destination_type": "USER",
            "upload_id": uploadId,
            "jazoest": jazoest(csrfToken: credentials.csrfToken),
        ])

        var storyConfigureRequest = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/media/configure_to_story/")!)
        storyConfigureRequest.httpMethod = "POST"
        storyConfigureRequest.httpBody = body.data(using: .utf8)
        var configureHeaders = webHeaders(credentials: credentials, referer: Self.baseURL + "/")
        configureHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        storyConfigureRequest.allHTTPHeaderFields = configureHeaders
        configureRequest(&storyConfigureRequest)

        let (configureData, configureResponse) = try await session.data(for: storyConfigureRequest)
        guard let configureHTTP = configureResponse as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200 ..< 300).contains(configureHTTP.statusCode) else {
            throw SourceError.serviceError(instagramPublishError(step: "configure", statusCode: configureHTTP.statusCode, data: configureData))
        }
        if let response = try? JSONDecoder().decode(InstagramStatusResponse.self, from: configureData), response.status != "ok" {
            throw SourceError.serviceError(instagramPublishError(step: "configure", statusCode: configureHTTP.statusCode, data: configureData))
        }
    }

    public func deleteStory(mediaId: String, isVideo _: Bool) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }
        let docID = try await docId(credentials: credentials, command: "delete-story")
        _ = try await graphqlPost(
            credentials: credentials,
            docID: docID,
            variables: ["mediaId": mediaId.split(separator: "_").first.map(String.init) ?? mediaId],
            friendlyName: operationNames["delete-story"],
            rootFieldName: "xdt_api__v1__create__delete",
            endpoint: "/graphql/query",
        )
    }

    private func instagramPublishError(step: String, statusCode: Int, data: Data) -> String {
        let responseMessage = (try? JSONDecoder().decode(InstagramErrorResponse.self, from: data))?.message
        if let responseMessage, !responseMessage.isEmpty {
            return "Instagram story \(step) failed (HTTP \(statusCode)): \(responseMessage)"
        }
        let responseStatus = (try? JSONDecoder().decode(InstagramErrorResponse.self, from: data))?.status
        if let responseStatus, !responseStatus.isEmpty, responseStatus != "ok" {
            return "Instagram story \(step) failed (HTTP \(statusCode)): \(responseStatus)"
        }
        return "Instagram story \(step) failed (HTTP \(statusCode))."
    }
}
