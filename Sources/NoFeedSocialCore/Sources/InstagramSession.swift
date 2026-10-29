import Foundation

struct InstagramWebState {
    let html: String
    var csrfToken: String?
    var lsd: String?
    var fbDtsg: String?
    var userID: String?
    /// Instagram actor FBID (`actorID`), sent as `av`. Relay mutations are rejected without it.
    var actorID: String?
    var revision: String?
    var hsi: String?
    var hasteSession: String?
    var deviceID: String?
    var machineID: String?
    var bloksVersionID: String?
}

let operationNames = [
    "stories-tray": "PolarisStoriesV3TrayContainerQuery",
    "story-seen": "PolarisStoriesV3SeenMutation",
    "like-story": "usePolarisLikeMediaXIGLikeMutation",
    "unlike-story": "usePolarisLikeMediaXIGUnlikeMutation",
    "follow": "usePolarisFollowUserFollowMutation",
    "unfollow": "usePolarisFollowUserUnfollowMutation",
]

@MainActor
extension InstagramClient {
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

    func instagramAuthorizationHeader(credentials: InstagramCredentials) -> String {
        let payload = jsonString([
            "ds_user_id": credentials.dsUserId,
            "sessionid": credentials.sessionId,
        ])
        let encoded = Data(payload.utf8).base64EncodedString()
        return "Bearer IGT:2:\(encoded)"
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
            _ = try await homepageState(credentials: credentials)
        }
    }

    func homepageState(credentials: InstagramCredentials) async throws -> InstagramWebState {
        if let inFlightBootstrap { return try await inFlightBootstrap.value }
        let task = Task { try await refreshState(credentials: credentials) }
        inFlightBootstrap = task
        defer { inFlightBootstrap = nil }
        return try await task.value
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
        state.actorID = firstMatch(html, pattern: #""actorID"\s*:\s*"([0-9]+)""#)
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
        let state = try await homepageState(credentials: credentials)
        return try await instagramHomepageTrayConcurrently(html: state.html, accountID: credentials.dsUserId)
    }

    func homepageViewer(credentials: InstagramCredentials) async throws -> InstagramDirectViewer {
        let state = try await homepageState(credentials: credentials)
        return try instagramHomepageViewer(html: state.html, accountID: credentials.dsUserId)
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
        try await discoverStoryPageDocIds(credentials: credentials)
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

    func recordStoryPageDocIds(html: String, credentials _: InstagramCredentials) {
        docIds.merge(parseDocIds(source: html)) { _, new in new }
        storyPageScriptURLs.formUnion(scriptURLs(html: html))
    }

    func discoverStoryPageDocIds(credentials: InstagramCredentials) async throws {
        guard !storyPageScriptURLs.isEmpty else { return }
        var discovered: [String: String] = [:]
        for scriptURL in storyPageScriptURLs {
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
        if let actorID = state?.actorID { fields["av"] = actorID }
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
        let (data, response) = try await session.data(for: request, delegate: InstagramSessionExpiryRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if instagramResponseExpiresSession(http) { throw SourceError.notConfigured }
        if let claim = http.value(forHTTPHeaderField: "x-ig-set-www-claim") ?? http.value(forHTTPHeaderField: "x-ig-www-claim") {
            wwwClaim = claim
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.notConfigured }
        guard (200 ..< 300).contains(http.statusCode) else {
            if instagramBodyRequiresLogin(data) { throw SourceError.notConfigured }
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        configureRequest(&request)
        let (data, response) = try await session.data(for: request, delegate: InstagramSessionExpiryRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if instagramResponseExpiresSession(http) { throw SourceError.notConfigured }
        if let claim = http.value(forHTTPHeaderField: "x-ig-set-www-claim") ?? http.value(forHTTPHeaderField: "x-ig-www-claim") {
            wwwClaim = claim
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.notConfigured }
        if let path = http.url?.path, path.hasPrefix("/accounts/login") || path.hasPrefix("/challenge/") {
            throw SourceError.notConfigured
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if instagramBodyRequiresLogin(data) { throw SourceError.notConfigured }
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

/// Instagram signals a dead session by expiring `sessionid`, usually on a 302 back to the same page.
/// Requests send cookies manually, so URLSession would otherwise follow that redirect with the dead
/// cookie until it fails with too many redirects.
func instagramResponseExpiresSession(_ response: HTTPURLResponse) -> Bool {
    guard let url = response.url,
          let fields = response.allHeaderFields as? [String: String] else { return false }
    return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).contains { cookie in
        guard cookie.name == "sessionid" else { return false }
        if let expiresDate = cookie.expiresDate, expiresDate <= Date() { return true }
        return cookie.value.isEmpty || cookie.value == "\"\""
    }
}

/// A failed response that means the user must log in again: a session under a security checkpoint answers API
/// calls with `checkpoint_required` JSON (HTTP 400), and some endpoints (such as `direct_v2`) with a 404 page
/// rendered for a logged-out visitor (`<html class="… not-logged-in …">`).
func instagramBodyRequiresLogin(_ data: Data) -> Bool {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return ["checkpoint_required", "challenge_required", "login_required"].contains(object["message"] as? String)
    }
    guard let head = String(data: data.prefix(4096), encoding: .utf8),
          let match = head.firstMatch(of: /<html[^>]*\bclass="([^"]*)"/)
    else { return false }
    return match.1.split(separator: " ").contains("not-logged-in")
}

final class InstagramSessionExpiryRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
    ) async -> URLRequest? {
        instagramResponseExpiresSession(response) ? nil : request
    }
}
