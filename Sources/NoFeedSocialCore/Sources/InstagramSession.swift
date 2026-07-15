import CryptoKit
import Foundation

struct InstagramWebState {
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

let operationNames = [
    "stories-tray": "PolarisStoriesV3TrayContainerQuery",
    "delete-story": "usePolarisStoriesV3DeleteMediaMutation",
    "story-seen": "PolarisAPIReelSeenMutation",
    "like-story": "usePolarisLikeMediaXIGLikeMutation",
    "unlike-story": "usePolarisLikeMediaXIGUnlikeMutation",
]

@MainActor
extension InstagramClient {
    private static let instagramSignatureKey = "9193488027538fd3450b83b7d05286d4ca9599a0f7eeed90d8c85925698a05dc"

    struct StoryPhotoFormat {
        let entityType: String
        let compressionLibrary: String
        let compressionVersion: String
    }

    func storyPhotoFormat(mimeType: String) -> StoryPhotoFormat {
        if mimeType == "image/webp" {
            return StoryPhotoFormat(entityType: "image/webp", compressionLibrary: "libwebp", compressionVersion: "30")
        }
        return StoryPhotoFormat(entityType: "image/jpeg", compressionLibrary: "libjpeg", compressionVersion: "9")
    }

    func imageCompressionJSON(format: StoryPhotoFormat, width: Int, height: Int) -> String {
        jsonString([
            "lib_name": format.compressionLibrary,
            "lib_version": format.compressionVersion,
            "quality": "86",
            "original_width": width,
            "original_height": height,
        ])
    }

    var supportedCapabilitiesJSON: String {
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

    func signedFormBody(object: [String: Any]) throws -> String {
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

    func headers(credentials: InstagramCredentials) -> [String: String] {
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

    func directInboxHeaders(credentials: InstagramCredentials) -> [String: String] {
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

    func storyPostingHeaders(credentials: InstagramCredentials) -> [String: String] {
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

    func storyUploadHeaders(credentials: InstagramCredentials) -> [String: String] {
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

    func instagramAuthorizationHeader(credentials: InstagramCredentials) -> String {
        let payload = jsonString([
            "ds_user_id": credentials.dsUserId,
            "sessionid": credentials.sessionId,
        ])
        let encoded = Data(payload.utf8).base64EncodedString()
        return "Bearer IGT:2:\(encoded)"
    }

    func instagramDeviceIdentifiers(credentials: InstagramCredentials) -> (uuid: String, androidId: String) {
        let uuid = (credentials.igDid ?? credentials.dsUserId).lowercased()
        let digest = SHA256.hash(data: Data(uuid.utf8))
        let androidSuffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return (uuid: uuid, androidId: "android-\(androidSuffix)")
    }

    func webHeaders(credentials: InstagramCredentials, referer: String) -> [String: String] {
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

    func basePageHeaders(credentials: InstagramCredentials) -> [String: String] {
        [
            "Cookie": cookieHeader(credentials: credentials),
            "User-Agent": Self.webUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": Self.acceptLanguageHeader,
        ]
    }

    func baseAssetHeaders(credentials: InstagramCredentials) -> [String: String] {
        [
            "Cookie": cookieHeader(credentials: credentials),
            "User-Agent": Self.webUserAgent,
            "Accept": "*/*",
            "Accept-Language": Self.acceptLanguageHeader,
            "Referer": Self.baseURL + "/",
        ]
    }

    func ensureBootstrapped(credentials: InstagramCredentials) async throws {
        if webState == nil {
            _ = try await refreshState(credentials: credentials)
        }
    }

    @discardableResult
    func refreshState(credentials: InstagramCredentials) async throws -> InstagramWebState {
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

    func storiesTrayResponse(credentials: InstagramCredentials) async throws -> InstagramReelsTrayResponse {
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

    func directInboxViewer(credentials: InstagramCredentials) async throws -> InstagramDirectViewer {
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
    func ensureBootstrappedState(credentials: InstagramCredentials) async throws -> InstagramWebState {
        try await ensureBootstrapped(credentials: credentials)
        if let webState { return webState }
        return try await refreshState(credentials: credentials)
    }

    func docId(credentials: InstagramCredentials, command: String) async throws -> String {
        let operation = try operationName(command: command)
        if let docID = docIds[operation] { return docID }
        try await discoverDocIds(credentials: credentials)
        if let docID = docIds[operation] { return docID }
        throw SourceError.serviceError("Could not discover Instagram operation.")
    }

    func discoverDocIds(credentials: InstagramCredentials) async throws {
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

    func mergeStoryPageDocIds(html: String, credentials: InstagramCredentials) async throws {
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

    func graphqlGet(credentials: InstagramCredentials, docID: String, variables: [String: Any]) async throws -> Data {
        let variablesData = try JSONSerialization.data(withJSONObject: variables, options: [])
        guard let variablesJSON = String(data: variablesData, encoding: .utf8) else { throw SourceError.invalidResponse }
        var components = URLComponents(string: Self.baseURL + "/graphql/query/")!
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: docID),
            URLQueryItem(name: "variables", value: variablesJSON),
        ]
        return try await webJSONRequest(credentials: credentials, method: "GET", url: components.url!)
    }

    func graphqlPost(
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

    func webJSONRequest(credentials: InstagramCredentials, method: String, path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await webJSONRequest(credentials: credentials, method: method, url: URL(string: Self.baseURL + path)!, headers: headers, body: body)
    }

    func webJSONRequest(credentials: InstagramCredentials, method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await ensureBootstrapped(credentials: credentials)
        do {
            return try await webDataRequest(credentials: credentials, method: method, url: url, headers: headers, body: body)
        } catch SourceError.notConfigured {
            _ = try await refreshState(credentials: credentials)
            return try await webDataRequest(credentials: credentials, method: method, url: url, headers: headers, body: body)
        }
    }

    func webDataRequest(credentials: InstagramCredentials, method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
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
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.serviceError(instagramRequestError(statusCode: http.statusCode, data: data))
        }
        if isInstagramLoginOrChallengeHTML(data: data, response: http) {
            throw SourceError.notConfigured
        }
        return data
    }

    func webTextRequest(credentials _: InstagramCredentials, method: String, url: URL, headers: [String: String], body: Data? = nil) async throws -> String {
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
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.serviceError(instagramRequestError(statusCode: http.statusCode, data: data))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func cookieHeader(credentials: InstagramCredentials) -> String {
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

    func instagramRequestError(statusCode: Int, data: Data) -> String {
        let decoded = try? JSONDecoder().decode(InstagramErrorResponse.self, from: data)
        let rawBody = String(data: data, encoding: .utf8) ?? ""
        let message = decoded?.message?.isEmpty == false ? decoded?.message : nil
        let body = rawBody.isEmpty ? nil : String(rawBody.prefix(240))
        return "Instagram request failed (HTTP \(statusCode)): \(message ?? body ?? "invalid response")"
    }

    private func isInstagramLoginOrChallengeHTML(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "content-type")?.lowercased() ?? ""
        let htmlPrefix = data.starts(with: Data("<!DOCTYPE html".utf8)) || data.starts(with: Data("<html".utf8))
        guard contentType.contains("text/html") || htmlPrefix else { return false }
        guard let body = String(data: data.prefix(16384), encoding: .utf8)?.lowercased() else { return false }
        return body.contains("login") || body.contains("challenge")
    }

    func jazoest(csrfToken: String) -> String {
        "2\(csrfToken.unicodeScalars.reduce(0) { $0 + Int($1.value) })"
    }

    func instagramDateTimeString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static var acceptLanguageHeader: String {
        let preferred = Locale.preferredLanguages.prefix(2)
        guard !preferred.isEmpty else { return "en-US,en;q=0.9" }
        return preferred.enumerated().map { index, language in
            index == 0 ? language : "\(language);q=0.9"
        }.joined(separator: ",")
    }

    func configureRequest(_ request: inout URLRequest) {
        request.httpShouldHandleCookies = false
    }

    func formURLEncoded(_ fields: [String: String]) -> String {
        fields
            .map { key, value in
                "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
            }
            .joined(separator: "&")
    }

    func jsonString(_ value: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    func jsonString(_ value: [[String: String]]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

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

func operationName(command: String) throws -> String {
    guard let name = operationNames[command] else { throw SourceError.unsupported }
    return name
}

func parseDocIds(source: String) -> [String: String] {
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

func scriptURLs(html: String) -> [URL] {
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

func extractStoryPayloadData(from html: String) -> Data? {
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

func firstMatch(_ text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .instagramFormAllowed) ?? self
    }

    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private extension CharacterSet {
    static let instagramFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}
