import CryptoKit
import Foundation
import Security

public struct BlueskyOAuthCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var did: String
    public var handle: String?
    public var pdsURL: URL
    public var authServerURL: URL
    public var scope: String
    public var expiresAt: Date?
    public var dpopPrivateKey: Data
    public var authNonce: String?
    public var resourceNonce: String?

    public init(accessToken: String, refreshToken: String, did: String, handle: String?, pdsURL: URL, authServerURL: URL, scope: String, expiresAt: Date?, dpopPrivateKey: Data, authNonce: String? = nil, resourceNonce: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.authServerURL = authServerURL
        self.scope = scope
        self.expiresAt = expiresAt
        self.dpopPrivateKey = dpopPrivateKey
        self.authNonce = authNonce
        self.resourceNonce = resourceNonce
    }
}

public struct BlueskyOAuthSession: Sendable {
    public let authorizationURL: URL
    public let state: String
    public let codeVerifier: String
    public let dpopPrivateKey: Data
    public let authServerURL: URL
    public let tokenEndpoint: URL
    public let authNonce: String?
    public let pdsURL: URL
    public let loginHint: String?
}

public final class BlueskyClient: @unchecked Sendable {
    public static let clientID = "https://stupidtech.net/stupid-social/oauth/client-metadata.json"
    public static let redirectURI = "net.stupidtech:/oauth/bluesky/callback"
    public static let authServerURL = URL(string: "https://bsky.social")!
    public static let pdsURL = URL(string: "https://bsky.social")!
    /// `transition:chat.bsky` lets the PDS forward `chat.bsky.*` calls to the chat service.
    static let scope = "atproto transition:generic transition:chat.bsky"

    private static let refreshes = RefreshCoalescer()

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    let decoder: JSONDecoder

    public init(credentialStore: KeychainCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatterWithFractionalSeconds = ISO8601DateFormatter()
            formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatterWithFractionalSeconds.date(from: value) ?? formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Bluesky date: \(value)")
        }
    }

    public func hasCredentials() throws -> Bool {
        try credentialStore.loadBlueskyCredentials() != nil
    }

    public func startOAuth(loginHint: String?) async throws -> BlueskyOAuthSession {
        let normalizedLoginHint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = try await oauthContext(loginHint: normalizedLoginHint)
        let metadata = try await authorizationServerMetadata(authServerURL: context.authServerURL)
        let verifier = randomBase64URL(byteCount: 48)
        let state = randomBase64URL(byteCount: 32)
        let privateKey = P256.Signing.PrivateKey()
        let keyData = privateKey.rawRepresentation
        let form: [String: String] = [
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "response_type": "code",
            "scope": Self.scope,
            "state": state,
            "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
            "code_challenge_method": "S256",
            "login_hint": normalizedLoginHint ?? "",
        ].filter { !$0.value.isEmpty }

        var nonce: String?
        let par = try await pushedAuthorizationRequest(endpoint: metadata.pushedAuthorizationRequestEndpoint, issuer: metadata.issuer, form: form, privateKey: privateKey, nonce: nil)
        let requestURI: String
        switch par {
        case let .success(value, responseNonce):
            requestURI = value
            nonce = responseNonce
        case let .needsNonce(responseNonce):
            nonce = responseNonce
            requestURI = try await pushedAuthorizationRequest(endpoint: metadata.pushedAuthorizationRequestEndpoint, issuer: metadata.issuer, form: form, privateKey: privateKey, nonce: responseNonce).requestURI
        }

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "request_uri", value: requestURI),
        ]
        guard let authorizationURL = components.url else { throw SourceError.invalidResponse }
        return BlueskyOAuthSession(authorizationURL: authorizationURL, state: state, codeVerifier: verifier, dpopPrivateKey: keyData, authServerURL: metadata.issuer, tokenEndpoint: metadata.tokenEndpoint, authNonce: nonce, pdsURL: context.pdsURL, loginHint: normalizedLoginHint)
    }

    public func finishOAuth(callbackURL: URL, session oauthSession: BlueskyOAuthSession) async throws -> BlueskyOAuthCredentials {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              components.queryItems?.first(where: { $0.name == "state" })?.value == oauthSession.state
        else { throw SourceError.invalidResponse }

        let (token, nonce) = try await tokenRequest(
            endpoint: oauthSession.tokenEndpoint,
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": Self.clientID,
                "code_verifier": oauthSession.codeVerifier,
            ],
            privateKeyData: oauthSession.dpopPrivateKey,
            nonce: oauthSession.authNonce,
        )
        var credentials = credentials(from: token, session: oauthSession)
        credentials.authNonce = nonce
        let profile = try? await profile(did: credentials.did, credentials: &credentials)
        credentials.handle = profile?.handle ?? oauthSession.loginHint
        _ = try credentialStore.saveBlueskyCredentials(credentials)
        return credentials
    }

    public func validateAccount() async throws -> BlueskyProfileViewDetailed {
        var credentials = try await validCredentials()
        return try await profile(did: credentials.did, credentials: &credentials)
    }

    public func notifications(limit: Int = 50) async throws -> [BlueskyNotification] {
        var credentials = try await validCredentials()
        var components = URLComponents(url: credentials.pdsURL.appending(path: "/xrpc/app.bsky.notification.listNotifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let notifications = try await authorizedRequest(url: components.url!, credentials: &credentials, response: BlueskyNotificationsResponse.self).notifications
        try await markNotificationsSeen(at: Date(), credentials: &credentials)
        return notifications
    }

    public func profile(did: String) async throws -> BlueskyProfileViewDetailed {
        var credentials = try await validCredentials()
        return try await profile(did: did, credentials: &credentials)
    }

    public func searchProfiles(query: String) async throws -> [BlueskyProfileViewBasic] {
        var credentials = try await validCredentials()
        var components = URLComponents(url: credentials.pdsURL.appending(path: "/xrpc/app.bsky.actor.searchActors"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "10")]
        return try await authorizedRequest(url: components.url!, credentials: &credentials, response: BlueskySearchActorsResponse.self).actors
    }

    public func postThread(uri: String) async throws -> BlueskyThreadPost? {
        var credentials = try await validCredentials()
        var components = URLComponents(url: credentials.pdsURL.appending(path: "/xrpc/app.bsky.feed.getPostThread"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "depth", value: "0")]
        return try await authorizedRequest(url: components.url!, credentials: &credentials, response: BlueskyPostThreadResponse.self).thread.post
    }

    private func oauthContext(loginHint: String?) async throws -> BlueskyOAuthContext {
        guard let loginHint, !loginHint.isEmpty, !loginHint.contains("@") else {
            return BlueskyOAuthContext(pdsURL: Self.pdsURL, authServerURL: Self.authServerURL)
        }

        let did = loginHint.hasPrefix("did:") ? loginHint : try await resolveHandle(String(loginHint.trimmingPrefix("@")))
        let document = try await didDocument(did: did)
        guard let pdsURL = document.pdsURL else {
            return BlueskyOAuthContext(pdsURL: Self.pdsURL, authServerURL: Self.authServerURL)
        }
        let protectedResource = try await protectedResourceMetadata(pdsURL: pdsURL)
        return BlueskyOAuthContext(pdsURL: pdsURL, authServerURL: protectedResource.authorizationServers.first ?? pdsURL)
    }

    private func resolveHandle(_ handle: String) async throws -> String {
        var components = URLComponents(url: Self.pdsURL.appending(path: "/xrpc/com.atproto.identity.resolveHandle"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.invalidResponse }
        return try decoder.decode(BlueskyHandleResolutionResponse.self, from: data).did
    }

    private func didDocument(did: String) async throws -> BlueskyDIDDocument {
        let url: URL
        if did.hasPrefix("did:plc:") {
            url = URL(string: "https://plc.directory/\(did)")!
        } else if did.hasPrefix("did:web:") {
            let identifier = String(did.dropFirst("did:web:".count))
            let parts = identifier.split(separator: ":").map(String.init)
            guard let host = parts.first else { throw SourceError.invalidResponse }
            let path = parts.dropFirst().joined(separator: "/")
            url = URL(string: "https://\(host)/\(path.isEmpty ? ".well-known" : path)/did.json")!
        } else {
            throw SourceError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.invalidResponse }
        return try decoder.decode(BlueskyDIDDocument.self, from: data)
    }

    private func protectedResourceMetadata(pdsURL: URL) async throws -> BlueskyProtectedResourceMetadata {
        let url = pdsURL.appending(path: "/.well-known/oauth-protected-resource")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.invalidResponse }
        return try decoder.decode(BlueskyProtectedResourceMetadata.self, from: data)
    }

    private func authorizationServerMetadata(authServerURL: URL) async throws -> BlueskyAuthorizationServerMetadata {
        let url = authServerURL.appending(path: "/.well-known/oauth-authorization-server")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.invalidResponse }
        return try decoder.decode(BlueskyAuthorizationServerMetadata.self, from: data)
    }

    private enum PARResult {
        case success(String, String?)
        case needsNonce(String)

        var requestURI: String {
            get throws {
                if case let .success(uri, _) = self { return uri }
                throw SourceError.invalidResponse
            }
        }
    }

    private func pushedAuthorizationRequest(endpoint: URL, issuer _: URL, form: [String: String], privateKey: P256.Signing.PrivateKey, nonce: String?) async throws -> PARResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue(dpopProof(method: "POST", url: endpoint, privateKey: privateKey, nonce: nonce, accessToken: nil), forHTTPHeaderField: "DPoP")
        request.httpBody = formURLEncoded(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if http.statusCode == 400 || http.statusCode == 401, let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce") { return .needsNonce(nonce) }
        guard http.statusCode == 201 || http.statusCode == 200 else { throw SourceError.serviceError("OAuth PAR failed") }
        let decoded = try decoder.decode(BlueskyPARResponse.self, from: data)
        return .success(decoded.requestURI, http.value(forHTTPHeaderField: "DPoP-Nonce"))
    }

    /// Returns the token and the authorization server's latest DPoP nonce, to send with the next token request.
    /// The server rotates nonces within minutes and answers a stale one with `use_dpop_nonce` and a fresh nonce,
    /// so a refresh made long after sign-in retries once with it.
    private func tokenRequest(endpoint: URL, form: [String: String], privateKeyData: Data, nonce: String?, retryingNonce: Bool = true) async throws -> (BlueskyTokenResponse, String?) {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue(dpopProof(method: "POST", url: endpoint, privateKey: privateKey, nonce: nonce, accessToken: nil), forHTTPHeaderField: "DPoP")
        request.httpBody = formURLEncoded(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        let freshNonce = http.value(forHTTPHeaderField: "DPoP-Nonce")
        if retryingNonce, http.statusCode == 400 || http.statusCode == 401, let freshNonce,
           (try? decoder.decode(BlueskyOAuthError.self, from: data))?.error == "use_dpop_nonce"
        {
            return try await tokenRequest(endpoint: endpoint, form: form, privateKeyData: privateKeyData, nonce: freshNonce, retryingNonce: false)
        }
        guard http.statusCode == 200 else {
            throw BlueskyClientError.tokenRequestFailed(status: http.statusCode, error: (try? decoder.decode(BlueskyOAuthError.self, from: data))?.error)
        }
        return try (decoder.decode(BlueskyTokenResponse.self, from: data), freshNonce ?? nonce)
    }

    func validCredentials() async throws -> BlueskyOAuthCredentials {
        guard let credentials = try credentialStore.loadBlueskyCredentials() else { throw SourceError.notConfigured }
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
            return try await refresh(credentials: credentials)
        }
        return credentials
    }

    /// Refreshes once per refresh token: concurrent callers, in any client for the account, share one request,
    /// since servers that rotate refresh tokens (the Cirrus PDS) reject the second use with `invalid_grant`.
    private func refresh(credentials: BlueskyOAuthCredentials) async throws -> BlueskyOAuthCredentials {
        try await Self.refreshes.run(key: credentials.refreshToken) { [self] in
            try await refreshOrAdoptStored(credentials, adoptingStored: true)
        }
    }

    /// When the server refuses the refresh token, another device (through iCloud Keychain) or client may already
    /// have rotated it: use the tokens it saved, refreshing them if they're expiring too.
    private func refreshOrAdoptStored(_ credentials: BlueskyOAuthCredentials, adoptingStored: Bool) async throws -> BlueskyOAuthCredentials {
        do {
            return try await performRefresh(credentials)
        } catch BlueskyClientError.tokenRequestFailed(_, "invalid_grant") {
            guard adoptingStored,
                  let stored = try credentialStore.loadBlueskyCredentials(),
                  stored.refreshToken != credentials.refreshToken
            else { throw BlueskyClientError.refreshTokenRejected }
            if let expiresAt = stored.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
                return try await refreshOrAdoptStored(stored, adoptingStored: false)
            }
            return stored
        }
    }

    private func performRefresh(_ credentials: BlueskyOAuthCredentials) async throws -> BlueskyOAuthCredentials {
        let (token, nonce) = try await tokenRequest(endpoint: credentials.authServerURL.appending(path: "/oauth/token"), form: ["grant_type": "refresh_token", "refresh_token": credentials.refreshToken, "client_id": Self.clientID], privateKeyData: credentials.dpopPrivateKey, nonce: credentials.authNonce)
        var refreshed = credentials
        refreshed.authNonce = nonce
        refreshed.accessToken = token.accessToken
        refreshed.refreshToken = token.refreshToken
        refreshed.scope = token.scope
        refreshed.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        _ = try credentialStore.saveBlueskyCredentials(refreshed)
        return refreshed
    }

    private func profile(did: String, credentials: inout BlueskyOAuthCredentials) async throws -> BlueskyProfileViewDetailed {
        var components = URLComponents(url: credentials.pdsURL.appending(path: "/xrpc/app.bsky.actor.getProfile"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "actor", value: did)]
        return try await authorizedRequest(url: components.url!, credentials: &credentials, response: BlueskyProfileViewDetailed.self)
    }

    private func markNotificationsSeen(at date: Date, credentials: inout BlueskyOAuthCredentials) async throws {
        let url = credentials.pdsURL.appending(path: "/xrpc/app.bsky.notification.updateSeen")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = try JSONSerialization.data(withJSONObject: ["seenAt": formatter.string(from: date)])
        try await authorizedWrite(url: url, body: body, credentials: &credentials)
    }

    private func authorizedRequest<T: Decodable>(url: URL, credentials: inout BlueskyOAuthCredentials, response _: T.Type) async throws -> T {
        let data = try await authorizedData(method: "GET", url: url, body: nil, credentials: &credentials)
        return try decoder.decode(T.self, from: data)
    }

    private func authorizedWrite(url: URL, body: Data, credentials: inout BlueskyOAuthCredentials) async throws {
        _ = try await authorizedData(method: "POST", url: url, body: body, credentials: &credentials)
    }

    /// A DPoP-authenticated PDS request. Retries once with the server's nonce on `use_dpop_nonce`, and once with
    /// fresh tokens on any other 401: the Cirrus PDS revokes an access token as soon as anyone refreshes the
    /// session, so a token that hasn't expired yet can still be dead. `proxy` names the service the PDS forwards
    /// the call to (`atproto-proxy`).
    func authorizedData(
        method: String,
        url: URL,
        body: Data?,
        proxy: String? = nil,
        credentials: inout BlueskyOAuthCredentials,
        retryingNonce: Bool = true,
        recoveringToken: Bool = true,
    ) async throws -> Data {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: credentials.dpopPrivateKey)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let proxy {
            request.setValue(proxy, forHTTPHeaderField: "atproto-proxy")
        }
        request.setValue("DPoP \(credentials.accessToken)", forHTTPHeaderField: "authorization")
        request.setValue(dpopProof(method: method, url: url, privateKey: privateKey, nonce: credentials.resourceNonce, accessToken: credentials.accessToken), forHTTPHeaderField: "DPoP")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce"), nonce != credentials.resourceNonce {
            credentials.resourceNonce = nonce
            _ = try? credentialStore.saveBlueskyCredentials(credentials)
        }
        if http.statusCode == 200 {
            return data
        }
        guard http.statusCode == 401 else {
            // XRPC errors carry a readable `message`, such as why someone can't be messaged.
            if let message = (try? decoder.decode(BlueskyXRPCError.self, from: data))?.message, !message.isEmpty {
                throw SourceError.serviceError(message)
            }
            throw BlueskyClientError.requestFailed(status: http.statusCode)
        }
        if retryingNonce, http.value(forHTTPHeaderField: "DPoP-Nonce") != nil, Self.isNonceChallenge(http: http, data: data, decoder: decoder) {
            return try await authorizedData(method: method, url: url, body: body, proxy: proxy, credentials: &credentials, retryingNonce: false, recoveringToken: recoveringToken)
        }
        guard recoveringToken else { throw BlueskyClientError.unauthorized }
        credentials = try await recoveredCredentials(after: credentials)
        return try await authorizedData(method: method, url: url, body: body, proxy: proxy, credentials: &credentials, retryingNonce: retryingNonce, recoveringToken: false)
    }

    /// Tokens to retry with after a 401: those another device or client saved since, or a refresh.
    private func recoveredCredentials(after rejected: BlueskyOAuthCredentials) async throws -> BlueskyOAuthCredentials {
        if let stored = try credentialStore.loadBlueskyCredentials(), stored.accessToken != rejected.accessToken {
            return stored
        }
        return try await refresh(credentials: rejected)
    }

    /// Resource servers signal a nonce challenge in `WWW-Authenticate` (RFC 9449) or, like token endpoints, a JSON
    /// `use_dpop_nonce` error.
    private static func isNonceChallenge(http: HTTPURLResponse, data: Data, decoder: JSONDecoder) -> Bool {
        if http.value(forHTTPHeaderField: "WWW-Authenticate")?.contains("use_dpop_nonce") == true { return true }
        return (try? decoder.decode(BlueskyOAuthError.self, from: data))?.error == "use_dpop_nonce"
    }

    private func credentials(from token: BlueskyTokenResponse, session oauthSession: BlueskyOAuthSession) -> BlueskyOAuthCredentials {
        BlueskyOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            did: token.sub,
            handle: nil,
            pdsURL: oauthSession.pdsURL,
            authServerURL: oauthSession.authServerURL,
            scope: token.scope,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            dpopPrivateKey: oauthSession.dpopPrivateKey,
            authNonce: oauthSession.authNonce,
        )
    }
}

private func dpopProof(method: String, url: URL, privateKey: P256.Signing.PrivateKey, nonce: String?, accessToken: String?) -> String {
    let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": jwk(from: privateKey.publicKey)]
    var payload: [String: Any] = ["jti": randomBase64URL(byteCount: 16), "htm": method, "htu": url.absoluteString, "iat": Int(Date().timeIntervalSince1970)]
    if let nonce { payload["nonce"] = nonce }
    if let accessToken { payload["ath"] = base64URL(Data(SHA256.hash(data: Data(accessToken.utf8)))) }
    let signingInput = "\(jsonBase64URL(header)).\(jsonBase64URL(payload))"
    let signature = try! privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
    return "\(signingInput).\(base64URL(signature))"
}

private func jwk(from publicKey: P256.Signing.PublicKey) -> [String: String] {
    let raw = publicKey.rawRepresentation
    return ["kty": "EC", "crv": "P-256", "x": base64URL(raw.prefix(32)), "y": base64URL(raw.suffix(32))]
}

private func randomBase64URL(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
}

private func jsonBase64URL(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return base64URL(data)
}

private func base64URL(_ data: some DataProtocol) -> String {
    Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func formURLEncoded(_ values: [String: String]) -> Data {
    values.map { key, value in
        "\(key.blueskyURLFormEncoded)=\(value.blueskyURLFormEncoded)"
    }.joined(separator: "&").data(using: .utf8)!
}

private extension String {
    var blueskyURLFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "+", with: "%2B") ?? self
    }
}

private struct BlueskyXRPCError: Decodable {
    let message: String?
}

private struct BlueskyAuthorizationServerMetadata: Decodable {
    let issuer: URL
    let pushedAuthorizationRequestEndpoint: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case issuer
        case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

private struct BlueskyOAuthContext {
    let pdsURL: URL
    let authServerURL: URL
}

private struct BlueskyHandleResolutionResponse: Decodable {
    let did: String
}

private struct BlueskyProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]

    enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

private struct BlueskyDIDDocument: Decodable {
    let service: [BlueskyDIDService]?

    var pdsURL: URL? {
        service?.first { $0.id == "#atproto_pds" || $0.type == "AtprotoPersonalDataServer" }?.serviceEndpoint
    }
}

private struct BlueskyDIDService: Decodable {
    let id: String
    let type: String
    let serviceEndpoint: URL
}

private struct BlueskyPARResponse: Decodable {
    let requestURI: String

    enum CodingKeys: String, CodingKey { case requestURI = "request_uri" }
}

private struct BlueskyTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let sub: String
    let scope: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case sub, scope
    }
}

public enum BlueskyClientError: LocalizedError, Equatable {
    /// The authorization server refused the refresh token and no newer tokens were saved: the session was
    /// revoked or used up elsewhere. The user signs in again.
    case refreshTokenRejected
    case tokenRequestFailed(status: Int, error: String?)
    /// The PDS refused the access token even after fresh tokens.
    case unauthorized
    case requestFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .refreshTokenRejected: "Bluesky signed this app out. Log in again."
        case let .tokenRequestFailed(status, _): "Bluesky sign-in request failed (HTTP \(status))."
        case .unauthorized: "Bluesky didn't accept this app's sign-in."
        case let .requestFailed(status): "Bluesky request failed (HTTP \(status))."
        }
    }
}

/// One refresh in flight per refresh token, shared by every caller.
private final class RefreshCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<BlueskyOAuthCredentials, Error>] = [:]

    func run(key: String, _ work: @escaping @Sendable () async throws -> BlueskyOAuthCredentials) async throws -> BlueskyOAuthCredentials {
        let task = lock.withLock {
            if let running = tasks[key] { return running }
            let task = Task { try await work() }
            tasks[key] = task
            return task
        }
        defer {
            lock.withLock {
                if tasks[key] == task { tasks[key] = nil }
            }
        }
        return try await task.value
    }
}

private struct BlueskyOAuthError: Decodable {
    let error: String
}

public struct BlueskyNotificationsResponse: Decodable, Sendable {
    public let notifications: [BlueskyNotification]
}

public struct BlueskyNotification: Decodable, Sendable {
    public let uri: String
    public let cid: String
    public let author: BlueskyProfileViewBasic
    public let reason: String
    public let reasonSubject: String?
    public let record: BlueskyPostRecord?
    public let indexedAt: Date
    public let isRead: Bool?
}

public struct BlueskyPostRecord: Decodable, Sendable {
    public let text: String?
    public let createdAt: Date?
}

public struct BlueskyProfileViewBasic: Decodable, Sendable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatar: URL?
}

public struct BlueskyProfileViewDetailed: Decodable, Sendable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let description: String?
    public let avatar: URL?
    public let followersCount: Int?
    public let followsCount: Int?
    public let postsCount: Int?
}

public struct BlueskySearchActorsResponse: Decodable, Sendable {
    public let actors: [BlueskyProfileViewBasic]
}

public struct BlueskyPostThreadResponse: Decodable, Sendable {
    public let thread: BlueskyThreadPostContainer
}

public struct BlueskyThreadPostContainer: Decodable, Sendable {
    public let post: BlueskyThreadPost?
}

public struct BlueskyThreadPost: Decodable, Sendable {
    public let uri: String
    public let author: BlueskyProfileViewBasic
    public let record: BlueskyPostRecord?
    public let likeCount: Int?
    public let indexedAt: Date?
}
