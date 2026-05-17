import CryptoKit
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
    private static let androidUserAgent = "Instagram 416.0.0.47.66 Android (35/35; 480dpi; 1080x2400; samsung; SM-S938U; qcom; en_US; 718621835)"
    private static let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Mobile/15E148 Safari/604.1"

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

    private func ensureCookies(credentials: InstagramCredentials) {
        let storage = HTTPCookieStorage.shared
        storage.cookieAcceptPolicy = .always

        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".instagram.com",
            .path: "/",
        ]

        let setCookie: (String, String) -> Void = { name, value in
            var props = properties
            props[.name] = name
            props[.value] = value
            if let cookie = HTTPCookie(properties: props) {
                storage.setCookie(cookie)
            }
        }

        setCookie("ds_user_id", credentials.dsUserId)
        setCookie("csrftoken", credentials.csrfToken)
        setCookie("sessionid", credentials.sessionId)
        if let mid = credentials.mid { setCookie("mid", mid) }
        if let rur = credentials.rur { setCookie("rur", rur) }
        if let igDid = credentials.igDid { setCookie("ig_did", igDid) }
    }

    public func verifiedUser() async throws -> InstagramVerifiedUser {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/accounts/current_user/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        configureRequest(&request)

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

        let decoded = try JSONDecoder().decode(InstagramCurrentUserResponse.self, from: data)
        return InstagramVerifiedUser(
            pk: decoded.user.pk,
            username: decoded.user.username,
            fullName: decoded.user.fullName,
            profilePicURL: decoded.user.profilePicUrl.flatMap(URL.init),
        )
    }

    func hasCredentials() throws -> Bool {
        try credentialStore.loadInstagramCredentials() != nil
    }

    func notifications(
        enabledCategories: Set<InstagramNotificationCategory>,
        accountUsername: String? = nil,
    ) async throws -> [NotificationItem] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/news/inbox/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        configureRequest(&request)

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

        let decoded = try JSONDecoder().decode(InstagramNewsInboxResponse.self, from: data)
        let allStories = (decoded.priorityStories ?? []) + (decoded.newStories ?? []) + (decoded.oldStories ?? [])
        return InstagramNotificationParser.parse(
            stories: allStories,
            accountId: credentials.dsUserId,
            accountUsername: accountUsername,
            enabledCategories: enabledCategories,
        )
    }

    func reelsTray() async throws -> [InstagramTrayItem] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let caps = "supported_capabilities_new=%5B%7B%22name%22%3A%22SUPPORTED_SDK_VERSIONS%22%2C%22value%22%3A%2266.0%2C67.0%2C68.0%2C69.0%2C70.0%22%7D%2C%7B%22name%22%3A%22FACE_TRACKER_VERSION%22%2C%22value%22%3A14%7D%2C%7B%22name%22%3A%22COMPRESSION%22%2C%22value%22%3A%22ETC2_COMPRESSION%22%7D%5D"
        let body = "\(caps)&reason=cold_start&_csrftoken=\(credentials.csrfToken)&_uuid=\(credentials.dsUserId)"
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/feed/reels_tray/")!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        var hdrs = headers(credentials: credentials)
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        request.allHTTPHeaderFields = hdrs
        configureRequest(&request)

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

        let decoded = try JSONDecoder().decode(InstagramReelsTrayResponse.self, from: data)
        return decoded.tray
    }

    func userStory(userId: String) async throws -> InstagramUserStoryResponse {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/feed/user/\(userId)/story/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        configureRequest(&request)

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

        return try JSONDecoder().decode(InstagramUserStoryResponse.self, from: data)
    }

    func reelsMedia(reelIds: [String]) async throws -> [String: InstagramReel] {
        guard !reelIds.isEmpty else { return [:] }

        var reels: [String: InstagramReel] = [:]
        let batches = stride(from: 0, to: reelIds.count, by: Self.reelsMediaBatchSize).map { start in
            let end = min(start + Self.reelsMediaBatchSize, reelIds.count)
            return Array(reelIds[start ..< end])
        }

        try await withThrowingTaskGroup(of: [String: InstagramReel].self) { group in
            for batch in batches {
                group.addTask {
                    try await reelsMediaBatch(reelIds: batch)
                }
            }

            for try await batchReels in group {
                reels.merge(batchReels) { current, _ in current }
            }
        }

        return reels
    }

    private func reelsMediaBatch(reelIds: [String]) async throws -> [String: InstagramReel] {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let body = formURLEncoded([
            "reel_ids": jsonString(reelIds),
            "source": "reel_feed_timeline",
            "_csrftoken": credentials.csrfToken,
            "_uuid": credentials.igDid ?? credentials.dsUserId,
        ])

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/feed/reels_media/")!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        var hdrs = headers(credentials: credentials)
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        request.allHTTPHeaderFields = hdrs
        configureRequest(&request)

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

        return try JSONDecoder().decode(InstagramReelsMediaResponse.self, from: data).reels
    }

    private static let reelsMediaBatchSize = 30

    public func userInfo(uid: String) async throws -> InstagramUserInfoResponse {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let trimmedIdentifier = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedIdentifier = trimmedIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedIdentifier
        let path = trimmedIdentifier.allSatisfy(\.isNumber)
            ? "/api/v1/users/\(escapedIdentifier)/info/"
            : "/api/v1/users/\(escapedIdentifier)/usernameinfo/"

        var request = URLRequest(url: URL(string: "\(Self.baseURL)\(path)")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        configureRequest(&request)

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

        return try JSONDecoder().decode(InstagramUserInfoResponse.self, from: data)
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

    private func mediaInfoRequest(mediaId: String) async throws -> InstagramMediaInfoResponse {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/media/\(mediaId)/info/")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers(credentials: credentials)
        configureRequest(&request)

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

        return try JSONDecoder().decode(InstagramMediaInfoResponse.self, from: data)
    }

    func markStorySeen(mediaItems: [(mediaId: String, ownerId: String, takenAt: Double)]) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let seenAt = Int(Date().timeIntervalSince1970)
        var reels: [String: [String]] = [:]
        for item in mediaItems {
            let takenAt = Int(item.takenAt)
            let seenKey = "\(item.mediaId)_\(item.ownerId)"
            reels[seenKey, default: []].append("\(takenAt)_\(seenAt)")
        }

        let signedBodyObject: [String: Any] = [
            "reels": reels,
            "container_module": "feed_timeline",
            "reel_media_skipped": [],
            "live_vods": [],
            "live_vods_skipped": [],
            "nuxes": [],
            "nuxes_skipped": [],
            "_uuid": credentials.igDid ?? credentials.dsUserId,
            "_uid": credentials.dsUserId,
            "_csrftoken": credentials.csrfToken,
            "device_id": credentials.dsUserId,
        ]
        let signedBodyData = try JSONSerialization.data(withJSONObject: signedBodyObject, options: [])
        guard let signedBodyJSON = String(data: signedBodyData, encoding: .utf8) else {
            throw SourceError.invalidResponse
        }

        let signatureData = signedBodyJSON.data(using: .utf8)!
        let hmacKey = Self.instagramSignatureKey.data(using: .utf8)!
        let hmac = HMAC<SHA256>.authenticationCode(for: signatureData, using: SymmetricKey(data: hmacKey))
        let signatureHex = hmac.map { String(format: "%02x", $0) }.joined()

        let body = formURLEncoded([
            "signed_body": "\(signatureHex).\(signedBodyJSON)",
            "ig_sig_key_version": "4",
        ])

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v2/media/seen/?reel=1&live_vod=0")!)
        request.httpMethod = "POST"
        var hdrs = headers(credentials: credentials)
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        request.allHTTPHeaderFields = hdrs
        request.httpBody = body.data(using: .utf8)
        configureRequest(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }
    }

    func setMediaLiked(mediaId: String, liked: Bool) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let action = liked ? "send_story_like" : "unsend_story_like"
        let body = formURLEncoded([
            "module_name": "feed_timeline",
            "media_id": mediaId,
            "container_module": "reel_feed_timeline",
            "tray_session_id": UUID().uuidString.lowercased(),
            "tray_position": "0",
            "viewer_session_id": UUID().uuidString.lowercased(),
            "delivery_class": "organic",
            "like_type": "REGULAR",
            "like_duration": "0",
        ])

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/story_interactions/\(action)/")!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        var hdrs = storyPostingHeaders(credentials: credentials)
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        request.allHTTPHeaderFields = hdrs
        configureRequest(&request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }

        if let response = try? JSONDecoder().decode(InstagramStatusResponse.self, from: data), response.status != "ok" {
            throw SourceError.invalidResponse
        }
    }

    public func publishPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let format = storyPhotoFormat(mimeType: mimeType)
        let uploadId = String(Int64.random(in: 3_000_000_000_000 ... 3_999_999_999_999))
        let uploadName = "\(uploadId)_0_\(Int.random(in: 1_000_000_000 ... 2_147_483_647))"
        let ruploadParams: [String: Any] = [
            "upload_id": uploadId,
            "session_id": uploadId,
            "media_type": "1",
            "upload_engine_config_enum": "0",
            "share_type": "stories",
            "is_optimistic_upload": "false",
            "image_compression": imageCompressionJSON(format: format, width: width, height: height),
            "xsharing_user_ids": "[]",
            "retry_context": jsonString([
                "num_reupload": 0,
                "num_step_manual_retry": 0,
                "num_step_auto_retry": 0,
            ]),
        ]
        let ruploadParamsJSON = jsonString(ruploadParams)

        var uploadRequest = URLRequest(url: URL(string: "\(Self.baseURL)/rupload_igphoto/\(uploadName)")!)
        uploadRequest.httpMethod = "POST"
        uploadRequest.httpBody = imageData
        var uploadHeaders = storyUploadHeaders(credentials: credentials)
        uploadHeaders["Content-Type"] = "application/octet-stream"
        uploadHeaders["Content-Length"] = String(imageData.count)
        uploadHeaders["Offset"] = "0"
        uploadHeaders["X-Entity-Length"] = String(imageData.count)
        uploadHeaders["X-Entity-Name"] = uploadName
        uploadHeaders["X-Entity-Type"] = format.entityType
        uploadHeaders["X_FB_PHOTO_WATERFALL_ID"] = UUID().uuidString.lowercased()
        uploadHeaders["X-Instagram-Rupload-Params"] = ruploadParamsJSON
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

        let now = Int(Date().timeIntervalSince1970)
        let deviceIds = instagramDeviceIdentifiers(credentials: credentials)
        let signedBodyObject: [String: Any] = [
            "upload_id": uploadId,
            "configure_mode": "1",
            "source_type": "3",
            "async_publish": "1",
            "audience": "default",
            "original_media_type": "1",
            "original_width": String(width),
            "original_height": String(height),
            "camera_entry_point": "11",
            "camera_position": "back",
            "client_shared_at": String(now),
            "client_timestamp": String(now),
            "timezone_offset": String(TimeZone.current.secondsFromGMT()),
            "allow_multi_configures": "1",
            "has_camera_metadata": "1",
            "include_e2ee_mentioned_user_list": "1",
            "hide_from_profile_grid": "false",
            "scene_capture_type": "",
            "edits": [
                "crop_original_size": [Double(width), Double(height)],
                "filter_strength": 0.5,
                "filter_type": 0,
            ],
            "extra": [
                "source_width": width,
                "source_height": height,
            ],
            "media_transformation_info": jsonString([
                "width": String(width),
                "height": String(height),
                "x_transform": "0",
                "y_transform": "0",
                "zoom": "1.0",
                "rotation": "0.0",
                "background_coverage": "0.0",
            ]),
            "supported_capabilities_new": supportedCapabilitiesJSON,
            "bottom_camera_dial_selected": "2",
            "camera_make": "Apple",
            "camera_model": "NoFeedSocial",
            "camera_session_id": UUID().uuidString.lowercased(),
            "capture_type": "normal",
            "composition_id": UUID().uuidString.lowercased(),
            "creation_surface": "camera",
            "date_time_digitized": instagramDateTimeString(),
            "date_time_original": instagramDateTimeString(),
            "device": [
                "manufacturer": "Apple",
                "model": "NoFeedSocial",
            ],
            "nav_chain": "MainFeedFragment:feed_timeline:1:cold_start:\(now).000:::0.000",
            "private_mention_sharing_enabled": "1",
            "publish_id": "1",
            "_uid": credentials.dsUserId,
            "_uuid": deviceIds.uuid,
            "device_id": deviceIds.androidId,
        ]
        let body = try signedFormBody(object: signedBodyObject)

        var storyConfigureRequest = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/media/configure_to_story/")!)
        storyConfigureRequest.httpMethod = "POST"
        storyConfigureRequest.httpBody = body.data(using: .utf8)
        var configureHeaders = storyPostingHeaders(credentials: credentials)
        configureHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        configureHeaders["X-IG-Timezone-Offset"] = String(TimeZone.current.secondsFromGMT())
        configureHeaders["X-IG-Nav-Chain"] = "MainFeedFragment:feed_timeline:1:cold_start:\(now).000:::0.000"
        configureHeaders["X-IG-CLIENT-ENDPOINT"] = "MainFeedFragment:feed_timeline"
        configureHeaders["retry_context"] = jsonString([
            "num_reupload": 0,
            "num_step_manual_retry": 0,
            "num_step_auto_retry": 0,
        ])
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

    public func deleteStory(mediaId: String, isVideo: Bool) async throws {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }

        let mediaType = isVideo ? "VIDEO" : "PHOTO"
        let signedBodyObject: [String: Any] = [
            "igtv_feed_preview": "false",
            "media_id": mediaId,
            "_uuid": credentials.igDid ?? credentials.dsUserId,
            "_uid": credentials.dsUserId,
            "_csrftoken": credentials.csrfToken,
        ]
        let body = try signedFormBody(object: signedBodyObject)

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/v1/media/\(mediaId)/delete/?media_type=\(mediaType)")!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        var hdrs = headers(credentials: credentials)
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        request.allHTTPHeaderFields = hdrs
        configureRequest(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.invalidResponse
        }
    }

    private static let instagramSignatureKey = "9193488027538fd3450b83b7d05286d4ca9599a0f7eeed90d8c85925698a05dc"

    private struct StoryPhotoFormat {
        let entityType: String
        let compressionLibrary: String
        let compressionVersion: String
    }

    private func storyPhotoFormat(mimeType: String) -> StoryPhotoFormat {
        if mimeType == "image/webp" {
            return StoryPhotoFormat(entityType: "image/webp", compressionLibrary: "libwebp", compressionVersion: "30")
        }
        return StoryPhotoFormat(entityType: "image/jpeg", compressionLibrary: "libjpeg", compressionVersion: "9")
    }

    private func imageCompressionJSON(format: StoryPhotoFormat, width: Int, height: Int) -> String {
        jsonString([
            "lib_name": format.compressionLibrary,
            "lib_version": format.compressionVersion,
            "quality": "86",
            "original_width": width,
            "original_height": height,
        ])
    }

    private var supportedCapabilitiesJSON: String {
        let sdkVersions = (149 ... 202).map { "\($0).0" }.joined(separator: ",")
        let betaVersions = (182 ... 202).map { "\($0).0-beta" }.joined(separator: ",")
        return jsonString([
            ["name": "SUPPORTED_SDK_VERSIONS", "value": sdkVersions],
            ["name": "SUPPORTED_BETA_SDK_VERSIONS", "value": betaVersions],
            ["name": "FACE_TRACKER_VERSION", "value": "14"],
            ["name": "COMPRESSION", "value": "ETC2_COMPRESSION"],
            ["name": "gyroscope", "value": "gyroscope_enabled"],
        ])
    }

    private func signedFormBody(object: [String: Any]) throws -> String {
        let signedBodyJSON = jsonString(object)
        let signatureData = signedBodyJSON.data(using: .utf8)!
        let hmacKey = Self.instagramSignatureKey.data(using: .utf8)!
        let hmac = HMAC<SHA256>.authenticationCode(for: signatureData, using: SymmetricKey(data: hmacKey))
        let signatureHex = hmac.map { String(format: "%02x", $0) }.joined()
        return formURLEncoded([
            "signed_body": "\(signatureHex).\(signedBodyJSON)",
            "ig_sig_key_version": "4",
        ])
    }

    private func headers(credentials: InstagramCredentials) -> [String: String] {
        let deviceId = credentials.dsUserId

        var cookieParts = [
            "ds_user_id=\(credentials.dsUserId)",
            "csrftoken=\(credentials.csrfToken)",
            "sessionid=\(credentials.sessionId)",
        ]
        if let mid = credentials.mid { cookieParts.append("mid=\(mid)") }
        if let rur = credentials.rur { cookieParts.append("rur=\(rur)") }
        if let igDid = credentials.igDid { cookieParts.append("ig_did=\(igDid)") }

        return [
            "Cookie": cookieParts.joined(separator: "; "),
            "X-CSRFToken": credentials.csrfToken,
            "User-Agent": Self.androidUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "X-IG-Capabilities": "3brTv10=",
            "X-IG-App-ID": "567067343352427",
            "X-IG-Device-ID": deviceId,
            "X-IG-Android-ID": "android-\(String(deviceId.suffix(16)))",
            "X-IG-Connection-Type": "WIFI",
            "X-FB-HTTP-Engine": "Liger",
        ]
    }

    private func storyPostingHeaders(credentials: InstagramCredentials) -> [String: String] {
        let deviceIds = instagramDeviceIdentifiers(credentials: credentials)
        var headers = [
            "Authorization": instagramAuthorizationHeader(credentials: credentials),
            "X-CSRFToken": credentials.csrfToken,
            "User-Agent": Self.androidUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "X-IG-App-Locale": "en_US",
            "X-IG-Device-Locale": "en_US",
            "X-IG-Mapped-Locale": "en_US",
            "X-IG-Capabilities": "3brTv10=",
            "X-IG-App-ID": "567067343352427",
            "X-IG-WWW-Claim": "0",
            "X-IG-Device-ID": deviceIds.uuid,
            "X-IG-Android-ID": deviceIds.androidId,
            "X-IG-Connection-Type": "WIFI",
            "X-FB-Connection-Type": "WIFI",
            "X-FB-HTTP-Engine": "Liger",
        ]
        if let mid = credentials.mid {
            headers["X-MID"] = mid
        }
        return headers
    }

    private func storyUploadHeaders(credentials: InstagramCredentials) -> [String: String] {
        var uploadHeaders = headers(credentials: credentials)
        let deviceIds = instagramDeviceIdentifiers(credentials: credentials)
        uploadHeaders["X-IG-Device-ID"] = deviceIds.uuid
        uploadHeaders["X-IG-Android-ID"] = deviceIds.androidId
        uploadHeaders["X-IG-App-Locale"] = "en_US"
        uploadHeaders["X-IG-Device-Locale"] = "en_US"
        uploadHeaders["X-IG-Mapped-Locale"] = "en_US"
        uploadHeaders["X-IG-WWW-Claim"] = "0"
        uploadHeaders["X-FB-Connection-Type"] = "WIFI"
        if let mid = credentials.mid {
            uploadHeaders["X-MID"] = mid
        }
        return uploadHeaders
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

    private func instagramAuthorizationHeader(credentials: InstagramCredentials) -> String {
        let payload = jsonString([
            "ds_user_id": credentials.dsUserId,
            "sessionid": credentials.sessionId,
        ])
        let encoded = Data(payload.utf8).base64EncodedString()
        return "Bearer IGT:2:\(encoded)"
    }

    private func instagramDeviceIdentifiers(credentials: InstagramCredentials) -> (uuid: String, androidId: String) {
        let uuid = (credentials.igDid ?? credentials.dsUserId).lowercased()
        let digest = SHA256.hash(data: Data(uuid.utf8))
        let androidSuffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return (uuid: uuid, androidId: "android-\(androidSuffix)")
    }

    private func webHeaders(credentials: InstagramCredentials, referer: String) -> [String: String] {
        [
            "Cookie": cookieHeader(credentials: credentials),
            "Referer": referer,
            "Origin": "https://www.instagram.com",
            "User-Agent": Self.webUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "X-IG-App-ID": "1217981644879628",
            "X-ASBD-ID": "359341",
            "X-IG-Max-Touch-Points": "5",
            "X-Web-Session-ID": webSessionId(),
            "X-Instagram-AJAX": "1039660005",
        ]
    }

    private func cookieHeader(credentials: InstagramCredentials) -> String {
        var cookieParts = [
            "ds_user_id=\(credentials.dsUserId)",
            "csrftoken=\(credentials.csrfToken)",
            "sessionid=\(credentials.sessionId)",
        ]
        if let mid = credentials.mid { cookieParts.append("mid=\(mid)") }
        if let rur = credentials.rur { cookieParts.append("rur=\(rur)") }
        if let igDid = credentials.igDid { cookieParts.append("ig_did=\(igDid)") }
        return cookieParts.joined(separator: "; ")
    }

    private func webSessionId() -> String {
        func segment() -> String {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            return String((0 ..< 6).compactMap { _ in alphabet.randomElement() })
        }
        return "\(segment()):\(segment()):\(segment())"
    }

    private func jazoest(csrfToken: String) -> String {
        "2\(csrfToken.unicodeScalars.reduce(0) { $0 + Int($1.value) })"
    }

    private func instagramDateTimeString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static var acceptLanguageHeader: String {
        let preferred = Locale.preferredLanguages.prefix(2)
        guard !preferred.isEmpty else { return "en-US,en;q=0.9" }
        return preferred.enumerated().map { index, language in
            index == 0 ? language : "\(language);q=0.9"
        }.joined(separator: ",")
    }

    private func configureRequest(_ request: inout URLRequest) {
        request.httpShouldHandleCookies = false
    }

    private func formURLEncoded(_ fields: [String: String]) -> String {
        fields
            .map { key, value in
                "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
            }
            .joined(separator: "&")
    }

    private func jsonString(_ value: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    private func jsonString(_ value: [[String: String]]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    private func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .instagramFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let instagramFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}

// MARK: - Response models

public struct InstagramVerifiedUser {
    public let pk: UInt64
    public let username: String
    public let fullName: String
    public let profilePicURL: URL?
}

private struct InstagramCurrentUserResponse: Decodable {
    struct User: Decodable {
        let pk: UInt64
        let username: String
        let fullName: String
        let profilePicUrl: String?

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
        }
    }

    let user: User
    let status: String
}

struct InstagramNewsInboxResponse: Decodable {
    let newStories: [InstagramNewsStory]?
    let oldStories: [InstagramNewsStory]?
    let priorityStories: [InstagramNewsStory]?

    enum CodingKeys: String, CodingKey {
        case newStories = "new_stories"
        case oldStories = "old_stories"
        case priorityStories = "priority_stories"
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

struct InstagramStatusResponse: Decodable {
    let status: String?
}

private struct InstagramErrorResponse: Decodable {
    let message: String?
    let status: String?
}

public struct InstagramUserInfoResponse: Decodable {
    public struct InfoUser: Decodable {
        public let pk: UInt64?
        public let username: String?
        public let fullName: String?
        public let profilePicUrl: String?
        public let followerCount: Int?
        public let followingCount: Int?
        public let biography: String?
        public let mediaCount: Int?
        public let isVerified: Bool?
        public let isPrivate: Bool?
        public let externalUrl: String?
        public let friendshipStatus: InstagramFriendshipStatus?

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
            case followerCount = "follower_count"
            case followingCount = "following_count"
            case biography
            case mediaCount = "media_count"
            case isVerified = "is_verified"
            case isPrivate = "is_private"
            case externalUrl = "external_url"
            case friendshipStatus = "friendship_status"
        }
    }

    public struct InstagramFriendshipStatus: Decodable {
        public let following: Bool?
        public let followedBy: Bool?
        public let isBestie: Bool?
    }

    public let user: InfoUser
    public let status: String?
}

struct InstagramMediaInfoResponse: Decodable {
    let items: [InstagramMediaInfoItem]
    let status: String?
}

struct InstagramMediaInfoItem: Decodable {
    let id: String
    let takenAt: Double?
    let likeCount: Int?
    let caption: InstagramMediaCaption?
    let imageVersions2: InstagramImageVersions?
    let carouselMedia: [InstagramMediaInfoItem]?
    let user: InstagramMediaUser?

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case likeCount = "like_count"
        case caption
        case imageVersions2 = "image_versions2"
        case carouselMedia = "carousel_media"
        case user
    }

    var bestImageURLs: [URL] {
        let ownURLString = imageVersions2?.candidates?
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first?
            .url
        let ownURL = ownURLString.flatMap { URL(string: $0) }
        let own = ownURL.map { [$0] } ?? []
        let carousel = carouselMedia?.flatMap(\.bestImageURLs) ?? []
        return carousel.isEmpty ? own : carousel
    }
}

struct InstagramMediaCaption: Decodable {
    let text: String?
}

struct InstagramMediaUser: Decodable {
    let pk: UInt64?
    let username: String?
    let fullName: String?
    let profilePicUrl: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
    }
}

struct InstagramReelsTrayResponse: Decodable {
    let tray: [InstagramTrayItem]
    let status: String?
}

struct InstagramTrayItem: Decodable {
    let id: String
    let latestReelMedia: Double?
    let hasBestiesMedia: Bool
    let expiringAt: Double?
    let mediaCount: Int?
    let seen: Int
    let muted: Bool?
    let user: InstagramTrayUser
    let reelType: String?

    var isMuted: Bool {
        muted == true || user.friendshipStatus?.isMutingReel == true || user.friendshipStatus?.muting == true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case latestReelMedia = "latest_reel_media"
        case hasBestiesMedia = "has_besties_media"
        case expiringAt = "expiring_at"
        case mediaCount = "media_count"
        case seen
        case muted
        case user
        case reelType = "reel_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? container.decode(UInt64.self, forKey: .id) {
            id = String(intId)
        } else {
            id = try container.decode(String.self, forKey: .id)
        }
        latestReelMedia = try container.decodeIfPresent(Double.self, forKey: .latestReelMedia)
        hasBestiesMedia = try container.decodeIfPresent(Bool.self, forKey: .hasBestiesMedia) ?? false
        expiringAt = try container.decodeIfPresent(Double.self, forKey: .expiringAt)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        seen = try container.decodeIfPresent(Int.self, forKey: .seen) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        user = try container.decode(InstagramTrayUser.self, forKey: .user)
        reelType = try container.decodeIfPresent(String.self, forKey: .reelType)
    }
}

struct InstagramTrayUser: Decodable {
    let pk: UInt64
    let username: String?
    let fullName: String?
    let profilePicUrl: String?
    let isPrivate: Bool?
    let isVerified: Bool?
    let friendshipStatus: InstagramTrayFriendshipStatus?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
        case isPrivate = "is_private"
        case isVerified = "is_verified"
        case friendshipStatus = "friendship_status"
    }
}

struct InstagramTrayFriendshipStatus: Decodable {
    let muting: Bool?
    let isMutingReel: Bool?

    enum CodingKeys: String, CodingKey {
        case muting
        case isMutingReel = "is_muting_reel"
    }
}

struct InstagramUserStoryResponse: Decodable {
    let reel: InstagramReel?
    let status: String?
}

struct InstagramReelsMediaResponse: Decodable {
    let reels: [String: InstagramReel]
    let status: String?
}

struct InstagramReel: Decodable {
    let id: UInt64
    let latestReelMedia: Double?
    let expiringAt: Double?
    let mediaCount: Int?
    let items: [InstagramStoryMedia]?
    let user: InstagramTrayUser?

    enum CodingKeys: String, CodingKey {
        case id
        case latestReelMedia = "latest_reel_media"
        case expiringAt = "expiring_at"
        case mediaCount = "media_count"
        case items
        case user
    }
}

struct InstagramStoryMedia: Decodable {
    let id: String
    let takenAt: Double?
    let mediaType: Int?
    let imageVersions2: InstagramImageVersions?
    let videoVersions: [InstagramVideoVersion]?
    let videoDuration: Double?
    let storyFeedMedia: [InstagramStoryFeedMedia]?
    let storyMusicStickers: [InstagramStoryMusicSticker]?
    let reelMentions: [InstagramStoryMentionSticker]?
    let storyLinkStickers: [InstagramStoryLinkSticker]?
    let hasLiked: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case mediaType = "media_type"
        case imageVersions2 = "image_versions2"
        case videoVersions = "video_versions"
        case videoDuration = "video_duration"
        case storyFeedMedia = "story_feed_media"
        case storyMusicStickers = "story_music_stickers"
        case reelMentions = "reel_mentions"
        case storyLinkStickers = "story_link_stickers"
        case hasLiked = "has_liked"
    }
}

struct InstagramImageVersions: Decodable {
    let candidates: [InstagramMediaCandidate]?
}

struct InstagramMediaCandidate: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct InstagramVideoVersion: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct InstagramStoryFeedMedia: Decodable {
    let mediaCode: String?
    let mediaType: String?
    let productType: String?

    enum CodingKeys: String, CodingKey {
        case mediaCode = "media_code"
        case mediaType = "media_type"
        case productType = "product_type"
    }

    var url: URL? {
        guard let mediaCode, !mediaCode.isEmpty else { return nil }
        if productType == "clips" || mediaType == "clips" {
            return URL(string: "https://www.instagram.com/reel/\(mediaCode)/")
        }
        return URL(string: "https://www.instagram.com/p/\(mediaCode)/")
    }

    var label: String {
        if productType == "clips" || mediaType == "clips" {
            return "Open reel"
        }
        return "Open post"
    }
}

struct InstagramStoryMusicSticker: Decodable {
    let attribution: String?
    let musicAssetInfo: InstagramStoryMusicAssetInfo?
    let startTimeMs: Double?
    let endTimeMs: Double?

    enum CodingKeys: String, CodingKey {
        case attribution
        case musicAssetInfo = "music_asset_info"
        case startTimeMs = "start_time_ms"
        case endTimeMs = "end_time_ms"
    }

    var music: InstagramStoryMusic? {
        guard let musicAssetInfo else { return nil }
        let title = musicAssetInfo.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        let artist = musicAssetInfo.displayArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = musicAssetInfo.coverArtworkThumbnailURI ?? musicAssetInfo.coverArtworkURI
        return InstagramStoryMusic(
            title: title,
            artist: artist?.isEmpty == true ? nil : artist,
            artworkURL: artwork.flatMap(URL.init),
            duration: clipDuration ?? musicAssetInfo.duration,
        )
    }

    private var clipDuration: Double? {
        guard let startTimeMs, let endTimeMs, endTimeMs > startTimeMs else { return nil }
        return (endTimeMs - startTimeMs) / 1000
    }
}

struct InstagramStoryMusicAssetInfo: Decodable {
    let title: String?
    let displayArtist: String?
    let coverArtworkThumbnailURI: String?
    let coverArtworkURI: String?
    let durationInMs: Double?
    let durationMs: Double?
    let audioAssetDurationMs: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case displayArtist = "display_artist"
        case coverArtworkThumbnailURI = "cover_artwork_thumbnail_uri"
        case coverArtworkURI = "cover_artwork_uri"
        case durationInMs = "duration_in_ms"
        case durationMs = "duration_ms"
        case audioAssetDurationMs = "audio_asset_duration_ms"
    }

    var duration: Double? {
        let milliseconds = durationInMs ?? durationMs ?? audioAssetDurationMs
        guard let milliseconds, milliseconds > 0 else { return nil }
        return milliseconds / 1000
    }
}

struct InstagramStoryMentionSticker: Decodable {
    let user: InstagramStoryMentionUser?

    var mention: InstagramStoryMention? {
        guard let username = user?.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return nil
        }
        return InstagramStoryMention(
            username: username,
            userId: user?.pk.map(String.init),
            url: URL(string: "https://www.instagram.com/\(username)/"),
        )
    }
}

struct InstagramStoryMentionUser: Decodable {
    let pk: UInt64?
    let username: String?
}

struct InstagramStoryLinkSticker: Decodable {
    let url: String?
    let linkTitle: String?
    let displayURL: String?

    enum CodingKeys: String, CodingKey {
        case url
        case linkTitle = "link_title"
        case displayURL = "display_url"
    }

    var link: InstagramStoryLink? {
        guard let url, let parsedURL = URL(string: url) else { return nil }
        let title = linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = displayURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels: [String?] = [title, display, parsedURL.host]
        let label = labels.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
        return InstagramStoryLink(
            title: label ?? "Open link",
            url: parsedURL,
        )
    }
}

// MARK: - Parser

private enum InstagramNotificationParser {
    static func parse(
        stories: [InstagramNewsStory],
        accountId: String,
        accountUsername: String?,
        enabledCategories: Set<InstagramNotificationCategory>,
    ) -> [NotificationItem] {
        stories.compactMap { story in
            parseSingle(story: story, accountId: accountId, accountUsername: accountUsername, enabledCategories: enabledCategories)
        }
    }

    private static func parseSingle(
        story: InstagramNewsStory,
        accountId: String,
        accountUsername: String?,
        enabledCategories: Set<InstagramNotificationCategory>,
    ) -> NotificationItem? {
        guard let category = InstagramNotificationCategory.category(for: story.notifName),
              enabledCategories.contains(category)
        else {
            return nil
        }
        let type = notificationType(from: story.notifName)
        let timestamp = story.args.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let actionText = actionText(for: story.notifName)

        let parsedBlocks = parseRichTextBlocks(from: story.args.richText ?? "")
        let contentAfterColon = parseContentAfterColon(from: story.args.richText ?? "")
        let storyLikeCount = parseStoryLikeCount(notifName: story.notifName, richText: story.args.richText ?? "", blocks: parsedBlocks)

        let actors = buildActors(from: story.args, blocks: parsedBlocks)
        let text = "\(buildActorSummary(actors: actors)) \(actionText)"

        let mediaImageUrl = story.args.media?.first?.image ?? story.args.images?.first?.image
        let imageURL = mediaImageUrl.flatMap(URL.init)
        let storyURL = parseStoryURL(from: story.args.destination, accountId: accountId, accountUsername: accountUsername)
        let linkURL = storyURL ?? imageURL

        let target: NotificationTarget?
        let targetId = story.args.media?.first?.id ?? story.pk
        if let content = contentAfterColon, !content.isEmpty {
            target = NotificationTarget(
                id: targetId,
                text: content,
                url: linkURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                author: actors.first,
                postedAt: timestamp,
                likeCount: storyLikeCount,
            )
        } else if linkURL != nil || imageURL != nil {
            target = NotificationTarget(
                id: targetId,
                text: nil,
                url: linkURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                postedAt: timestamp,
                likeCount: storyLikeCount,
            )
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
            parentTarget: nil,
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

    private static func parseStoryLikeCount(notifName: String, richText: String, blocks: [RichTextBlock]) -> Int? {
        guard notifName == "story_like", !blocks.isEmpty else { return nil }
        let stripped = stripRichTextBlocks(from: richText)
        let pattern = #"and\s+(\d+)\s+others?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let countRange = Range(match.range(at: 1), in: stripped),
              let otherCount = Int(stripped[countRange])
        else {
            return blocks.count
        }
        return blocks.count + otherCount
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
                    avatarURL: avatar.flatMap(URL.init),
                ))
            }
        }

        if actors.isEmpty, let id = args.profileId, let name = args.profileName {
            actors.append(NotificationActor(
                id: String(id),
                network: .instagram,
                username: name,
                displayName: nil,
                avatarURL: args.profileImage.flatMap(URL.init),
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

    private static func parseStoryURL(
        from destination: String?,
        accountId: String,
        accountUsername: String?,
    ) -> URL? {
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

        let mediaId = feedItemId.split(separator: "_").first.map(String.init) ?? feedItemId

        // Active stories: reel_id is the user's own numeric FID (e.g. "70150151668")
        if reelId == accountId {
            let profile = accountUsername ?? reelId
            return URL(string: "https://www.instagram.com/stories/\(profile)/\(mediaId)/")
        }

        // Archived stories: reel_id has "archiveDay:" prefix
        if reelId.hasPrefix("archiveDay:") {
            let hash = String(reelId.dropFirst("archiveDay:".count))
            return URL(string: "https://www.instagram.com/stories/archive/\(hash)/?initial_media_id=\(mediaId)")
        }

        // Highlight stories or other reel types
        return URL(string: "https://www.instagram.com/stories/archive/\(reelId)/?initial_media_id=\(mediaId)")
    }
}
