import CryptoKit
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
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    fileprivate static let baseURL = "https://www.instagram.com"
    private static let uploadBaseURL = "https://i.instagram.com"
    private static let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    private static let webAppID = "1217981644879628"
    private static let asbdID = "359341"
    private var webState: InstagramWebState?
    private var docIds: [String: String] = [:]
    private var requestCount = 0
    private let webSessionID = InstagramClient.randomBase36(length: 6)
    private var wwwClaim: String?

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
            "User-Agent": Self.webUserAgent,
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

    private func directInboxHeaders(credentials: InstagramCredentials) -> [String: String] {
        let deviceIds = instagramDeviceIdentifiers(credentials: credentials)
        var directHeaders = headers(credentials: credentials)
        directHeaders["Authorization"] = instagramAuthorizationHeader(credentials: credentials)
        directHeaders["X-Ads-Opt-Out"] = "0"
        directHeaders["X-CM-Bandwidth-KBPS"] = "-1.000"
        directHeaders["X-CM-Latency"] = "-1.000"
        directHeaders["X-IG-App-Locale"] = "en_US"
        directHeaders["X-IG-Device-Locale"] = "en_US"
        directHeaders["X-Pigeon-Session-Id"] = UUID().uuidString.lowercased()
        directHeaders["X-Pigeon-Rawclienttime"] = String(format: "%.3f", Date().timeIntervalSince1970)
        directHeaders["X-IG-Connection-Speed"] = "2500kbps"
        directHeaders["X-IG-Bandwidth-Speed-KBPS"] = "-1.000"
        directHeaders["X-IG-Bandwidth-TotalBytes-B"] = "0"
        directHeaders["X-IG-Bandwidth-TotalTime-MS"] = "0"
        directHeaders["X-IG-Extended-CDN-Thumbnail-Cache-Busting-Value"] = "1000"
        directHeaders["X-Bloks-Version-Id"] = "388ece79ebc0e70e87873505ed1b0ff335ae2868a978cc951b6721c41d46a30a"
        directHeaders["X-IG-WWW-Claim"] = "0"
        directHeaders["X-Bloks-Is-Layout-RTL"] = "false"
        directHeaders["X-IG-Device-ID"] = deviceIds.uuid
        directHeaders["X-IG-Android-ID"] = deviceIds.androidId
        if let mid = credentials.mid {
            directHeaders["X-MID"] = mid
        }
        return directHeaders
    }

    private func storyPostingHeaders(credentials: InstagramCredentials) -> [String: String] {
        let deviceIds = instagramDeviceIdentifiers(credentials: credentials)
        var headers = [
            "Authorization": instagramAuthorizationHeader(credentials: credentials),
            "X-CSRFToken": credentials.csrfToken,
            "User-Agent": Self.webUserAgent,
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
        var headers = [
            "Cookie": cookieHeader(credentials: credentials),
            "Referer": referer,
            "Origin": "https://www.instagram.com",
            "User-Agent": Self.webUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "X-IG-App-ID": Self.webAppID,
            "X-ASBD-ID": Self.asbdID,
            "X-IG-Max-Touch-Points": "5",
            "X-Web-Session-ID": webSessionID,
        ]
        let state = webState
        headers["X-CSRFToken"] = state?.csrfToken ?? credentials.csrfToken
        if let lsd = state?.lsd { headers["X-FB-LSD"] = lsd }
        if let deviceID = state?.deviceID ?? credentials.igDid { headers["X-Web-Device-Id"] = deviceID }
        if let mid = state?.machineID ?? credentials.mid { headers["X-Mid"] = mid }
        if let wwwClaim { headers["X-IG-WWW-Claim"] = wwwClaim }
        if let bloks = state?.bloksVersionID { headers["X-BLOKS-VERSION-ID"] = bloks }
        return headers
    }

    private func basePageHeaders(credentials: InstagramCredentials) -> [String: String] {
        [
            "Cookie": cookieHeader(credentials: credentials),
            "User-Agent": Self.webUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": Self.acceptLanguageHeader,
        ]
    }

    private func baseAssetHeaders(credentials: InstagramCredentials) -> [String: String] {
        [
            "Cookie": cookieHeader(credentials: credentials),
            "User-Agent": Self.webUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "Referer": Self.baseURL + "/",
        ]
    }

    private func ensureBootstrapped(credentials: InstagramCredentials) async throws {
        if webState == nil {
            _ = try await refreshState(credentials: credentials)
        }
    }

    @discardableResult
    private func refreshState(credentials: InstagramCredentials) async throws -> InstagramWebState {
        let html = try await webTextRequest(credentials: credentials, method: "GET", url: URL(string: Self.baseURL + "/")!, headers: basePageHeaders(credentials: credentials))
        var state = InstagramWebState(html: html)
        state.csrfToken = firstMatch(html, pattern: #""csrf_token"\s*:\s*"([^"]+)""#) ?? credentials.csrfToken
        state.lsd = firstMatch(html, pattern: #""LSD"[^\n]*?"token"\s*:\s*"([^"]+)""#)
            ?? firstMatch(html, pattern: #""token"\s*:\s*"([A-Za-z0-9_\-]+)"[^\n]{0,120}"LSD""#)
        state.fbDtsg = firstMatch(html, pattern: #""DTSGInitialData"[^\n]*?"token"\s*:\s*"([^"]*)""#)
        state.userID = firstMatch(html, pattern: #""USER_ID"\s*:\s*"([0-9]+)""#) ?? credentials.dsUserId
        state.revision = firstMatch(html, pattern: #""rev"\s*:\s*(\d+)"#)
        state.hsi = firstMatch(html, pattern: #""hsi"\s*:\s*"?([0-9]+)"?"#)
        state.hasteSession = firstMatch(html, pattern: #""haste_session"\s*:\s*"([^"]+)""#)
        state.deviceID = firstMatch(html, pattern: #""device_id"\s*:\s*"([^"]+)""#) ?? credentials.igDid
        state.machineID = firstMatch(html, pattern: #""machine_id"\s*:\s*"([^"]+)""#) ?? credentials.mid
        state.bloksVersionID = firstMatch(html, pattern: #""WebBloksVersioningID"[^\n]*?"versioningID"\s*:\s*"([^"]+)""#)
        webState = state
        docIds.merge(parseDocIds(source: html)) { _, new in new }
        return state
    }

    private func storiesTrayResponse(credentials: InstagramCredentials) async throws -> InstagramReelsTrayResponse {
        let state = try await ensureBootstrappedState(credentials: credentials)
        let fields = [
            "_csrftoken": state.csrfToken ?? credentials.csrfToken,
            "jazoest": jazoest(csrfToken: state.csrfToken ?? credentials.csrfToken),
        ]
        let data = try await webJSONRequest(
            credentials: credentials,
            method: "POST",
            path: "/api/v1/feed/reels_tray/",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formURLEncoded(fields).data(using: .utf8),
        )
        return try JSONDecoder().decode(InstagramReelsTrayResponse.self, from: data)
    }

    private func directInboxViewer(credentials: InstagramCredentials) async throws -> InstagramDirectViewer {
        var components = URLComponents(string: Self.baseURL + "/api/v1/direct_v2/inbox/")!
        components.queryItems = [
            URLQueryItem(name: "visual_message_return_type", value: "unseen"),
            URLQueryItem(name: "thread_message_limit", value: "1"),
            URLQueryItem(name: "persistentBadging", value: "true"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let data = try await webJSONRequest(credentials: credentials, method: "GET", url: components.url!)
        let decoded = try JSONDecoder().decode(InstagramDirectInboxResponse.self, from: data)
        guard let viewer = decoded.viewer else { throw SourceError.invalidResponse }
        return viewer
    }

    @discardableResult
    private func ensureBootstrappedState(credentials: InstagramCredentials) async throws -> InstagramWebState {
        try await ensureBootstrapped(credentials: credentials)
        if let webState { return webState }
        return try await refreshState(credentials: credentials)
    }

    private func docId(credentials: InstagramCredentials, command: String) async throws -> String {
        let operation = try operationName(command: command)
        if let docID = docIds[operation] { return docID }
        try await discoverDocIds(credentials: credentials)
        if let docID = docIds[operation] { return docID }
        throw SourceError.serviceError("Could not discover Instagram operation.")
    }

    private func discoverDocIds(credentials: InstagramCredentials) async throws {
        let state = try await refreshState(credentials: credentials)
        var discovered = parseDocIds(source: state.html)
        for scriptURL in scriptURLs(html: state.html) {
            do {
                let source = try await webTextRequest(credentials: credentials, method: "GET", url: scriptURL, headers: baseAssetHeaders(credentials: credentials))
                discovered.merge(parseDocIds(source: source)) { _, new in new }
            } catch {
                continue
            }
        }
        docIds.merge(discovered) { _, new in new }
    }

    private func mergeStoryPageDocIds(html: String, credentials: InstagramCredentials) async throws {
        var discovered = parseDocIds(source: html)
        for scriptURL in scriptURLs(html: html) {
            do {
                let source = try await webTextRequest(credentials: credentials, method: "GET", url: scriptURL, headers: baseAssetHeaders(credentials: credentials))
                discovered.merge(parseDocIds(source: source)) { _, new in new }
            } catch {
                continue
            }
        }
        docIds.merge(discovered) { _, new in new }
    }

    private func graphqlGet(credentials: InstagramCredentials, docID: String, variables: [String: Any]) async throws -> Data {
        let variablesData = try JSONSerialization.data(withJSONObject: variables, options: [])
        guard let variablesJSON = String(data: variablesData, encoding: .utf8) else { throw SourceError.invalidResponse }
        var components = URLComponents(string: Self.baseURL + "/graphql/query/")!
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: docID),
            URLQueryItem(name: "variables", value: variablesJSON),
        ]
        return try await webJSONRequest(credentials: credentials, method: "GET", url: components.url!)
    }

    private func graphqlPost(
        credentials: InstagramCredentials,
        docID: String,
        variables: [String: Any],
        friendlyName: String? = nil,
        rootFieldName: String? = nil,
        endpoint: String = "/api/graphql",
    ) async throws -> Data {
        try await ensureBootstrapped(credentials: credentials)
        let state = webState
        let variablesData = try JSONSerialization.data(withJSONObject: variables, options: [])
        guard let variablesJSON = String(data: variablesData, encoding: .utf8) else { throw SourceError.invalidResponse }
        var fields = [
            "doc_id": docID,
            "variables": variablesJSON,
            "server_timestamps": "true",
            "__user": state?.userID ?? credentials.dsUserId,
            "__a": "1",
            "__req": Self.requestID(count: requestCount),
        ]
        if let revision = state?.revision { fields["__rev"] = revision }
        if let hsi = state?.hsi { fields["__hsi"] = hsi }
        if let haste = state?.hasteSession { fields["__hs"] = haste }
        if let lsd = state?.lsd { fields["lsd"] = lsd }
        if let fbDtsg = state?.fbDtsg { fields["fb_dtsg"] = fbDtsg }
        fields["jazoest"] = jazoest(csrfToken: state?.csrfToken ?? credentials.csrfToken)
        if let friendlyName {
            fields["fb_api_caller_class"] = "RelayModern"
            fields["fb_api_req_friendly_name"] = friendlyName
        }
        requestCount += 1
        var headers = ["Content-Type": "application/x-www-form-urlencoded"]
        if let friendlyName { headers["X-FB-Friendly-Name"] = friendlyName }
        if let rootFieldName { headers["X-Root-Field-Name"] = rootFieldName }
        return try await webJSONRequest(credentials: credentials, method: "POST", path: endpoint, headers: headers, body: formURLEncoded(fields).data(using: .utf8))
    }

    private func webJSONRequest(credentials: InstagramCredentials, method: String, path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await webJSONRequest(credentials: credentials, method: method, url: URL(string: Self.baseURL + path)!, headers: headers, body: body)
    }

    private func webJSONRequest(credentials: InstagramCredentials, method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await ensureBootstrapped(credentials: credentials)
        do {
            return try await webDataRequest(credentials: credentials, method: method, url: url, headers: headers, body: body)
        } catch SourceError.notConfigured {
            _ = try await refreshState(credentials: credentials)
            return try await webDataRequest(credentials: credentials, method: method, url: url, headers: headers, body: body)
        }
    }

    private func webDataRequest(credentials: InstagramCredentials, method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.allHTTPHeaderFields = webHeaders(credentials: credentials, referer: Self.baseURL + "/").merging(headers) { _, new in new }
        configureRequest(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if let claim = http.value(forHTTPHeaderField: "x-ig-set-www-claim") ?? http.value(forHTTPHeaderField: "x-ig-www-claim") {
            wwwClaim = claim
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.notConfigured }
        guard (200 ..< 300).contains(http.statusCode) else { throw SourceError.invalidResponse }
        return data
    }

    private func webTextRequest(credentials _: InstagramCredentials, method: String, url: URL, headers: [String: String], body: Data? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.allHTTPHeaderFields = headers
        configureRequest(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if let claim = http.value(forHTTPHeaderField: "x-ig-set-www-claim") ?? http.value(forHTTPHeaderField: "x-ig-www-claim") {
            wwwClaim = claim
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.notConfigured }
        guard (200 ..< 300).contains(http.statusCode) else { throw SourceError.invalidResponse }
        return String(data: data, encoding: .utf8) ?? ""
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

    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private let operationNames = [
    "stories-tray": "PolarisStoriesV3TrayContainerQuery",
    "delete-story": "usePolarisStoriesV3DeleteMediaMutation",
    "story-seen": "PolarisAPIReelSeenMutation",
    "like-story": "usePolarisLikeMediaXIGLikeMutation",
    "unlike-story": "usePolarisLikeMediaXIGUnlikeMutation",
]

private func operationName(command: String) throws -> String {
    guard let name = operationNames[command] else { throw SourceError.unsupported }
    return name
}

private func parseDocIds(source: String) -> [String: String] {
    let pattern = #"__d\("([^"]+?)_instagramRelayOperation",\[\],\(function\([^)]*\)\{.*?\.exports="(\d+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [:] }
    let range = NSRange(source.startIndex..., in: source)
    var result: [String: String] = [:]
    for match in regex.matches(in: source, range: range) {
        guard let nameRange = Range(match.range(at: 1), in: source),
              let idRange = Range(match.range(at: 2), in: source) else { continue }
        result[String(source[nameRange])] = String(source[idRange])
    }
    return result
}

private func scriptURLs(html: String) -> [URL] {
    let pattern = #"<script\b[^>]*\bsrc="([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(html.startIndex..., in: html)
    var urls: [URL] = []
    var seen: Set<URL> = []
    for match in regex.matches(in: html, range: range) {
        guard let urlRange = Range(match.range(at: 1), in: html) else { continue }
        let raw = String(html[urlRange]).replacingOccurrences(of: "&amp;", with: "&")
        guard raw.contains("static.cdninstagram.com") else { continue }
        let absolute = URL(string: raw, relativeTo: URL(string: "https://www.instagram.com/")!)!.absoluteURL
        if seen.insert(absolute).inserted { urls.append(absolute) }
    }
    return urls
}

private func extractStoryPayloadData(from html: String) -> Data? {
    let pattern = #"<script\b[^>]*\bdata-sjs[^>]*>(.*?)</script>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    for match in regex.matches(in: html, range: range) {
        guard let sourceRange = Range(match.range(at: 1), in: html) else { continue }
        let source = String(html[sourceRange]).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        guard let data = source.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let payload = findStoryPayload(json),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        else { continue }
        return payloadData
    }
    return nil
}

private func findStoryPayload(_ value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] {
        if dict["xdt_api__v1__feed__reels_media"] != nil { return dict }
        for child in dict.values {
            if let found = findStoryPayload(child) { return found }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let found = findStoryPayload(child) { return found }
        }
    }
    return nil
}

private func firstMatch(_ text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

private extension InstagramClient {
    static func randomBase36(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< length).compactMap { _ in alphabet.randomElement() })
    }

    static func requestID(count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var value = count + 1
        var result = ""
        while value > 0 {
            let remainder = value % alphabet.count
            value /= alphabet.count
            result = String(alphabet[remainder]) + result
        }
        return result.isEmpty ? "1" : result
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

public struct InstagramCurrentUserProfile {
    public let pk: UInt64
    public let username: String
    public let fullName: String?
    public let profilePicURL: URL?
    public let followerCount: Int?
    public let followingCount: Int?
    public let postsCount: Int?
    public let bio: String?
    public let websiteURL: URL?
    public let isVerified: Bool?
    public let isPrivate: Bool?
}

private struct InstagramWebState {
    let html: String
    var csrfToken: String?
    var lsd: String?
    var fbDtsg: String?
    var userID: String?
    var revision: String?
    var hsi: String?
    var hasteSession: String?
    var deviceID: String?
    var machineID: String?
    var bloksVersionID: String?
}

private struct InstagramWebStoriesTrayResponse: Decodable {
    struct Payload: Decodable {
        let reelsTray: InstagramReelsTrayResponse?
        let xdtViewer: InstagramWebViewer?

        enum CodingKeys: String, CodingKey {
            case reelsTray = "xdt_api__v1__feed__reels_tray"
            case xdtViewer = "xdt_viewer"
        }
    }

    let data: Payload
    let status: String?
}

private struct InstagramWebViewer: Decodable {
    struct User: Decodable {
        let id: String
        let username: String
        let profilePicUrl: String?

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case profilePicUrl = "profile_pic_url"
        }
    }

    let user: User
}

private struct InstagramStoryPagePayload: Decodable {
    let xdtAPIReelsMedia: InstagramStoryPageReelsMedia

    enum CodingKeys: String, CodingKey {
        case xdtAPIReelsMedia = "xdt_api__v1__feed__reels_media"
    }
}

private struct InstagramStoryPageReelsMedia: Decodable {
    let reelsMedia: [InstagramReel]

    enum CodingKeys: String, CodingKey {
        case reelsMedia = "reels_media"
    }
}

private struct InstagramWebProfileInfoResponse: Decodable {
    struct Payload: Decodable {
        let user: User
    }

    struct User: Decodable {
        let id: String?
        let username: String?
        let fullName: String?
        let profilePicUrl: String?
        let edgeFollowedBy: CountEdge?
        let edgeFollow: CountEdge?
        let biography: String?
        let edgeOwnerToTimelineMedia: CountEdge?
        let isVerified: Bool?
        let isPrivate: Bool?
        let externalUrl: String?

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
            case edgeFollowedBy = "edge_followed_by"
            case edgeFollow = "edge_follow"
            case biography
            case edgeOwnerToTimelineMedia = "edge_owner_to_timeline_media"
            case isVerified = "is_verified"
            case isPrivate = "is_private"
            case externalUrl = "external_url"
        }

        var asInfoUser: InstagramUserInfoResponse.InfoUser {
            InstagramUserInfoResponse.InfoUser(
                pk: id.flatMap(UInt64.init),
                username: username,
                fullName: fullName,
                profilePicUrl: profilePicUrl,
                followerCount: edgeFollowedBy?.count,
                followingCount: edgeFollow?.count,
                biography: biography,
                mediaCount: edgeOwnerToTimelineMedia?.count,
                isVerified: isVerified,
                isPrivate: isPrivate,
                externalUrl: externalUrl,
                friendshipStatus: nil,
            )
        }
    }

    struct CountEdge: Decodable {
        let count: Int?
    }

    let data: Payload
    let status: String?
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

private struct InstagramDirectInboxResponse: Decodable {
    let inbox: InstagramDirectInbox
    let viewer: InstagramDirectViewer?
    let status: String?
}

private struct InstagramDirectViewer: Decodable {
    let pk: String
    let username: String
    let fullName: String?
    let profilePicUrl: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pk = try container.decodeFlexibleStringIfPresent(forKey: .pk) {
            self.pk = pk
        } else {
            pk = try container.decodeFlexibleString(forKey: .id)
        }
        username = try container.decode(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
    }
}

private struct InstagramDirectInbox: Decodable {
    let threads: [InstagramDirectThread]
    let unseenCount: Int?

    enum CodingKeys: String, CodingKey {
        case threads
        case unseenCount = "unseen_count"
    }
}

private struct InstagramDirectThread: Decodable {
    let threadId: String
    let threadV2Id: String?
    let threadTitle: String?
    let users: [InstagramDirectUser]
    let lastActivityAt: Int64?
    let markedAsUnread: Bool?
    let viewerId: String?
    let lastSeenAt: [String: InstagramDirectSeen]?
    let lastPermanentItem: InstagramDirectItem?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case threadV2Id = "thread_v2_id"
        case threadTitle = "thread_title"
        case users
        case lastActivityAt = "last_activity_at"
        case markedAsUnread = "marked_as_unread"
        case viewerId = "viewer_id"
        case lastSeenAt = "last_seen_at"
        case lastPermanentItem = "last_permanent_item"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decodeFlexibleString(forKey: .threadId)
        threadV2Id = try container.decodeFlexibleStringIfPresent(forKey: .threadV2Id)
        threadTitle = try container.decodeIfPresent(String.self, forKey: .threadTitle)
        users = try container.decodeIfPresent([InstagramDirectUser].self, forKey: .users) ?? []
        lastActivityAt = try container.decodeFlexibleInt64IfPresent(forKey: .lastActivityAt)
        markedAsUnread = try container.decodeIfPresent(Bool.self, forKey: .markedAsUnread)
        viewerId = try container.decodeFlexibleStringIfPresent(forKey: .viewerId)
        lastSeenAt = try container.decodeIfPresent([String: InstagramDirectSeen].self, forKey: .lastSeenAt)
        lastPermanentItem = try container.decodeIfPresent(InstagramDirectItem.self, forKey: .lastPermanentItem)
    }
}

private struct InstagramDirectUser: Decodable {
    let pk: String
    let username: String?
    let fullName: String?
    let profilePicURL: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicURL = "profile_pic_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pk = try container.decodeFlexibleString(forKey: .pk)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicURL = try container.decodeIfPresent(String.self, forKey: .profilePicURL)
    }
}

private struct InstagramDirectSeen: Decodable {
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
    }
}

private struct InstagramDirectItem: Decodable {
    let itemId: String
    let userId: String?
    let timestamp: Int64?
    let itemType: String?
    let text: String?
    let auxiliaryText: String?
    let xmaReelShare: [InstagramDirectXMA]?
    let xmaReelMention: [InstagramDirectXMA]?
    let xmaClip: [InstagramDirectXMA]?
    let xmaMediaShare: [InstagramDirectXMA]?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case userId = "user_id"
        case timestamp
        case itemType = "item_type"
        case text
        case auxiliaryText = "auxiliary_text"
        case xmaReelShare = "xma_reel_share"
        case xmaReelMention = "xma_reel_mention"
        case xmaClip = "xma_clip"
        case xmaMediaShare = "xma_media_share"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decodeFlexibleString(forKey: .itemId)
        userId = try container.decodeFlexibleStringIfPresent(forKey: .userId)
        timestamp = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
        itemType = try container.decodeIfPresent(String.self, forKey: .itemType)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        auxiliaryText = try container.decodeIfPresent(String.self, forKey: .auxiliaryText)
        xmaReelShare = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaReelShare)
        xmaReelMention = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaReelMention)
        xmaClip = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaClip)
        xmaMediaShare = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaMediaShare)
    }
}

private struct InstagramDirectXMA: Decodable {
    let previewURL: String?
    let targetURL: String?
    let titleText: String?
    let subtitleText: String?
    let headerTitleText: String?
    let captionBodyText: String?

    enum CodingKeys: String, CodingKey {
        case previewURL = "preview_url"
        case targetURL = "target_url"
        case titleText = "title_text"
        case subtitleText = "subtitle_text"
        case headerTitleText = "header_title_text"
        case captionBodyText = "caption_body_text"
    }
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
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uint = try? container.decode(UInt64.self, forKey: .pk) {
            pk = uint
        } else if let string = try? container.decode(String.self, forKey: .pk), let uint = UInt64(string) {
            pk = uint
        } else if let string = try? container.decode(String.self, forKey: .id), let uint = UInt64(string) {
            pk = uint
        } else {
            throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Instagram user pk"))
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified)
        friendshipStatus = try container.decodeIfPresent(InstagramTrayFriendshipStatus.self, forKey: .friendshipStatus)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uint = try? container.decode(UInt64.self, forKey: .id) {
            id = uint
        } else if let string = try? container.decode(String.self, forKey: .id), let uint = UInt64(string) {
            id = uint
        } else {
            throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Instagram reel id"))
        }
        latestReelMedia = try container.decodeIfPresent(Double.self, forKey: .latestReelMedia)
        expiringAt = try container.decodeIfPresent(Double.self, forKey: .expiringAt)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        items = try container.decodeIfPresent([InstagramStoryMedia].self, forKey: .items)
        user = try container.decodeIfPresent(InstagramTrayUser.self, forKey: .user)
    }
}

struct InstagramStoryMedia: Decodable {
    let id: String
    let pk: String?
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
        case pk
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

private enum InstagramDirectMessageParser {
    static func parse(response: InstagramDirectInboxResponse, accountId: String, includeMediaShares: Bool) -> [NotificationItem] {
        response.inbox.threads.compactMap { thread in
            parse(thread: thread, accountId: accountId, includeMediaShares: includeMediaShares)
        }
    }

    private static func parse(thread: InstagramDirectThread, accountId: String, includeMediaShares: Bool) -> NotificationItem? {
        guard let item = thread.lastPermanentItem else { return nil }
        let viewerId = thread.viewerId ?? accountId
        guard item.userId != viewerId else { return nil }
        guard includeMediaShares || !item.isMediaShare else { return nil }

        let itemTimestamp = item.timestamp ?? thread.lastActivityAt ?? 0
        let seenTimestamp = thread.lastSeenAt?[viewerId]?.timestamp ?? 0
        guard thread.markedAsUnread == true || itemTimestamp > seenTimestamp else { return nil }

        let actors = buildActors(thread: thread, senderId: item.userId, viewerId: viewerId)
        let senderName = actors.first?.username ?? actors.first?.displayName ?? thread.threadTitle ?? "Someone"
        let timestamp = Date(timeIntervalSince1970: TimeInterval(itemTimestamp) / 1_000_000)
        let preview = messagePreview(from: item)
        let text = notificationText(senderName: senderName, item: item)
        let xma = primaryXMA(from: item)
        let imageURL = xma?.previewURL.flatMap(URL.init)
        let targetURL = xma?.targetURL.flatMap(URL.init) ?? URL(string: "https://www.instagram.com/direct/t/\(thread.threadV2Id ?? thread.threadId)/")

        return NotificationItem(
            id: "instagram:direct:\(thread.threadId):\(item.itemId)",
            network: .instagram,
            accountId: accountId,
            sourceId: item.itemId,
            type: .message,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: NotificationTarget(
                id: thread.threadV2Id ?? thread.threadId,
                text: preview,
                url: targetURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                author: actors.first,
                postedAt: timestamp,
            ),
            parentTarget: nil,
        )
    }

    private static func buildActors(thread: InstagramDirectThread, senderId: String?, viewerId: String) -> [NotificationActor] {
        let users = thread.users.filter { $0.pk != viewerId }
        let sortedUsers: [InstagramDirectUser] = if let senderId, let sender = users.first(where: { $0.pk == senderId }) {
            [sender] + users.filter { $0.pk != senderId }
        } else {
            users
        }

        return sortedUsers.prefix(5).map { user in
            NotificationActor(
                id: user.pk,
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicURL.flatMap(URL.init),
            )
        }
    }

    private static func messagePreview(from item: InstagramDirectItem) -> String? {
        if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let auxiliary = item.auxiliaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !auxiliary.isEmpty {
            return auxiliary
        }
        if let xma = primaryXMA(from: item) {
            let values = [xma.titleText, xma.captionBodyText, xma.subtitleText]
            if let value = values.compactMap({ cleaned($0) }).first {
                return value
            }

            if item.itemType == "xma_clip", let username = cleaned(xma.headerTitleText) {
                return "Sent a reel by \(username)"
            }
            if item.itemType == "xma_media_share", let username = cleaned(xma.headerTitleText) {
                return "Sent a post by \(username)"
            }
        }
        switch item.itemType {
        case "xma_reel_mention":
            return "Mentioned you in a story"
        case "xma_reel_share":
            return "Replied to a story"
        case "xma_clip":
            return "Sent a reel"
        case "xma_media_share":
            return "Sent a post"
        case "voice_media":
            return "Sent a voice message"
        case "media", "raven_media":
            return "Sent media"
        case "animated_media":
            return "Sent an animation"
        default:
            return "Sent a message"
        }
    }

    private static func notificationText(senderName: String, item: InstagramDirectItem) -> String {
        switch item.itemType {
        case "xma_reel_share":
            "\(senderName) replied to your story"
        case "xma_reel_mention":
            "\(senderName) mentioned you in their story"
        case "xma_clip":
            "\(senderName) sent you a reel"
        case "xma_media_share":
            "\(senderName) sent you a post"
        default:
            "\(senderName) sent you a message"
        }
    }

    private static func primaryXMA(from item: InstagramDirectItem) -> InstagramDirectXMA? {
        item.xmaReelMention?.first
            ?? item.xmaReelShare?.first
            ?? item.xmaClip?.first
            ?? item.xmaMediaShare?.first
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func buildActorSummary(actors: [NotificationActor]) -> String {
        guard let first = actors.first, let firstName = first.username ?? first.displayName else { return "Someone" }
        let remainingCount = actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let int = try? decode(Int64.self, forKey: key) { return String(int) }
        if let uint = try? decode(UInt64.self, forKey: key) { return String(uint) }
        throw DecodingError.typeMismatch(String.self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string-like value"))
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFlexibleString(forKey: key)
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let int = try? decode(Int64.self, forKey: key) { return int }
        if let string = try? decode(String.self, forKey: key) { return Int64(string) }
        return nil
    }
}

private extension InstagramDirectItem {
    var isMediaShare: Bool {
        itemType == "xma_clip" || itemType == "xma_media_share"
    }
}
