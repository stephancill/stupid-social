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
    public static let clientID = "https://stupid-social-oauth-metadata.stephan-cloudflare.workers.dev/stupid-social/oauth/client-metadata.json"
    public static let redirectURI = "dev.workers.stephan-cloudflare.stupid-social-oauth-metadata:/oauth/bluesky/callback"
    public static let authServerURL = URL(string: "https://bsky.social")!
    public static let pdsURL = URL(string: "https://bsky.social")!

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    private let decoder: JSONDecoder

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
            "scope": "atproto transition:generic",
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

        let token = try await tokenRequest(
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
        return try await authorizedRequest(url: components.url!, credentials: &credentials, response: BlueskyNotificationsResponse.self).notifications
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

    private func tokenRequest(endpoint: URL, form: [String: String], privateKeyData: Data, nonce: String?) async throws -> BlueskyTokenResponse {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue(dpopProof(method: "POST", url: endpoint, privateKey: privateKey, nonce: nonce, accessToken: nil), forHTTPHeaderField: "DPoP")
        request.httpBody = formURLEncoded(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        guard http.statusCode == 200 else { throw SourceError.serviceError("OAuth token request failed") }
        return try decoder.decode(BlueskyTokenResponse.self, from: data)
    }

    private func validCredentials() async throws -> BlueskyOAuthCredentials {
        guard var credentials = try credentialStore.loadBlueskyCredentials() else { throw SourceError.notConfigured }
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
            credentials = try await refresh(credentials: credentials)
        }
        return credentials
    }

    private func refresh(credentials: BlueskyOAuthCredentials) async throws -> BlueskyOAuthCredentials {
        let token = try await tokenRequest(endpoint: credentials.authServerURL.appending(path: "/oauth/token"), form: ["grant_type": "refresh_token", "refresh_token": credentials.refreshToken, "client_id": Self.clientID], privateKeyData: credentials.dpopPrivateKey, nonce: credentials.authNonce)
        var refreshed = credentials
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

    private func authorizedRequest<T: Decodable>(url: URL, credentials: inout BlueskyOAuthCredentials, response type: T.Type) async throws -> T {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: credentials.dpopPrivateKey)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("DPoP \(credentials.accessToken)", forHTTPHeaderField: "authorization")
        request.setValue(dpopProof(method: "GET", url: url, privateKey: privateKey, nonce: credentials.resourceNonce, accessToken: credentials.accessToken), forHTTPHeaderField: "DPoP")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce"), nonce != credentials.resourceNonce {
            credentials.resourceNonce = nonce
            _ = try? credentialStore.saveBlueskyCredentials(credentials)
        }
        if http.statusCode == 401, let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce") {
            credentials.resourceNonce = nonce
            _ = try? credentialStore.saveBlueskyCredentials(credentials)
            return try await authorizedRequest(url: url, credentials: &credentials, response: type)
        }
        guard http.statusCode == 200 else { throw SourceError.serviceError("Bluesky request failed") }
        return try decoder.decode(T.self, from: data)
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
