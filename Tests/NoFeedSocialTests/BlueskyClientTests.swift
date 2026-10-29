import CryptoKit
import Foundation
@testable import NoFeedSocialCore
import XCTest

final class BlueskyClientTests: XCTestCase {
    private var suite = ""
    private var store: KeychainCredentialStore!
    private var client: BlueskyClient!

    override func setUpWithError() throws {
        suite = "BlueskyClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlueskyURLProtocol.self]
        client = BlueskyClient(credentialStore: store, session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        try? store.deleteBlueskyCredentials()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        BlueskyURLProtocol.handler = nil
    }

    /// The authorization server rotates DPoP nonces within minutes, so the nonce saved at sign-in is stale by the
    /// first refresh: it answers `use_dpop_nonce` with a fresh one (scripts/bluesky-web-client.py token-nonce).
    func testRefreshRetriesWithTheServersNonceAndKeepsTheLatest() async throws {
        try save(credentials(access: "old-access", refresh: "old-refresh", expired: true))
        let tokenNonces = Log()
        BlueskyURLProtocol.handler = { request in
            switch request.url?.path() {
            case "/oauth/token":
                let nonce = try dpopNonce(request)
                tokenNonces.append(nonce)
                if nonce == "fresh-nonce" {
                    return (200, ["DPoP-Nonce": "next-nonce"], tokenResponse(access: "new-access", refresh: "new-refresh"))
                }
                return (400, ["DPoP-Nonce": "fresh-nonce"], #"{"error":"use_dpop_nonce","error_description":"DPoP \"nonce\" mismatch"}"#)
            default:
                return pdsResponse(request, acceptedToken: "new-access")
            }
        }

        let notifications = try await client.notifications()

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(tokenNonces.values, ["nonce-from-sign-in", "fresh-nonce"])
        let saved = try XCTUnwrap(store.loadBlueskyCredentials())
        XCTAssertEqual(saved.refreshToken, "new-refresh")
        XCTAssertEqual(saved.authNonce, "next-nonce")
    }

    /// The Cirrus PDS rotates refresh tokens, so one refresh token works once: concurrent fetches share a refresh.
    func testConcurrentFetchesRefreshOnce() async throws {
        try save(credentials(access: "old-access", refresh: "old-refresh", expired: true))
        let refreshTokens = Log()
        BlueskyURLProtocol.handler = { request in
            switch request.url?.path() {
            case "/oauth/token":
                let used = try formValue("refresh_token", in: request)
                refreshTokens.append(used)
                guard used == "old-refresh" else { return (400, [:], #"{"error":"invalid_grant"}"#) }
                Thread.sleep(forTimeInterval: 0.2)
                return (200, [:], tokenResponse(access: "new-access", refresh: "new-refresh"))
            default:
                return pdsResponse(request, acceptedToken: "new-access")
            }
        }

        let client = try XCTUnwrap(client)
        async let first = client.notifications()
        async let second = client.profile(did: "did:plc:example")
        _ = try await (first, second)

        XCTAssertEqual(refreshTokens.values, ["old-refresh"])
    }

    /// Another device refreshed the shared session first and its rotated tokens reached this device's keychain:
    /// the refused refresh token gives way to the saved tokens.
    func testRefusedRefreshTokenAdoptsTokensSavedSince() async throws {
        try save(credentials(access: "old-access", refresh: "old-refresh", expired: true))
        BlueskyURLProtocol.handler = { [store] request in
            switch request.url?.path() {
            case "/oauth/token":
                try _ = store!.saveBlueskyCredentials(credentials(access: "other-device-access", refresh: "other-device-refresh", expired: false))
                return (400, [:], #"{"error":"invalid_grant","error_description":"Invalid refresh token"}"#)
            default:
                return pdsResponse(request, acceptedToken: "other-device-access")
            }
        }

        let notifications = try await client.notifications()

        XCTAssertTrue(notifications.isEmpty)
    }

    func testRefusedRefreshTokenWithNothingNewerAsksToSignInAgain() async throws {
        try save(credentials(access: "old-access", refresh: "old-refresh", expired: true))
        BlueskyURLProtocol.handler = { _ in (400, [:], #"{"error":"invalid_grant","error_description":"Token has been revoked"}"#) }

        do {
            _ = try await client.notifications()
            XCTFail("Expected the refresh to be refused")
        } catch {
            XCTAssertEqual(error as? BlueskyClientError, .refreshTokenRejected)
            XCTAssertEqual(StupidMetricsDescription.of(error), "BlueskyClientError.refreshTokenRejected")
        }
    }

    /// The Cirrus PDS revokes an access token when anyone refreshes the session, before it expires.
    func testRevokedAccessTokenRefreshesAndRetries() async throws {
        try save(credentials(access: "revoked-access", refresh: "old-refresh", expired: false))
        let refreshes = Log()
        BlueskyURLProtocol.handler = { request in
            switch request.url?.path() {
            case "/oauth/token":
                try refreshes.append(formValue("refresh_token", in: request))
                return (200, [:], tokenResponse(access: "new-access", refresh: "new-refresh"))
            default:
                return pdsResponse(request, acceptedToken: "new-access")
            }
        }

        let notifications = try await client.notifications()

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(refreshes.values, ["old-refresh"])
    }

    func testAccessTokenRefusedAfterRecoveryFailsWithoutLooping() async throws {
        try save(credentials(access: "old-access", refresh: "old-refresh", expired: false))
        let requests = Log()
        BlueskyURLProtocol.handler = { request in
            requests.append(request.url?.path())
            if request.url?.path() == "/oauth/token" {
                return (200, [:], tokenResponse(access: "new-access", refresh: "new-refresh"))
            }
            // A PDS that sends a nonce with every response, on a 401 that isn't a nonce challenge.
            return (401, ["DPoP-Nonce": "n"], #"{"error":"InvalidToken"}"#)
        }

        do {
            _ = try await client.notifications()
            XCTFail("Expected the request to be refused")
        } catch {
            XCTAssertEqual(error as? BlueskyClientError, .unauthorized)
        }
        XCTAssertEqual(requests.values.count, 3)
    }

    private func save(_ credentials: BlueskyOAuthCredentials) throws {
        _ = try store.saveBlueskyCredentials(credentials)
    }
}

/// Mirrors what StupidMetrics reports for an error: its type and case, without the payload.
private enum StupidMetricsDescription {
    static func of(_ error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        let caseName = mirror.children.first?.label ?? String(describing: error)
        return "\(type(of: error)).\(caseName)"
    }
}

private let signingKey = P256.Signing.PrivateKey().rawRepresentation

private func credentials(access: String, refresh: String, expired: Bool) -> BlueskyOAuthCredentials {
    BlueskyOAuthCredentials(
        accessToken: access,
        refreshToken: refresh,
        did: "did:plc:example",
        handle: "example.test",
        pdsURL: URL(string: "https://pds.example")!,
        authServerURL: URL(string: "https://auth.example")!,
        scope: "atproto",
        expiresAt: Date().addingTimeInterval(expired ? -60 : 3600),
        dpopPrivateKey: signingKey,
        authNonce: "nonce-from-sign-in",
    )
}

private func tokenResponse(access: String, refresh: String) -> String {
    #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","sub":"did:plc:example","scope":"atproto","expires_in":3600}"#
}

/// The PDS: 200 for the accepted access token, 401 otherwise.
private func pdsResponse(_ request: URLRequest, acceptedToken: String) -> (Int, [String: String], String) {
    guard request.value(forHTTPHeaderField: "authorization") == "DPoP \(acceptedToken)" else {
        return (401, [:], #"{"error":"InvalidToken"}"#)
    }
    switch request.url?.path() {
    case "/xrpc/app.bsky.notification.listNotifications": return (200, [:], #"{"notifications":[]}"#)
    case "/xrpc/app.bsky.actor.getProfile": return (200, [:], #"{"did":"did:plc:example","handle":"example.test"}"#)
    default: return (200, [:], "{}")
    }
}

private func formValue(_ name: String, in request: URLRequest) throws -> String? {
    let body = try String(decoding: XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(readAll)), as: UTF8.self)
    return URLComponents(string: "?\(body)")?.queryItems?.first { $0.name == name }?.value
}

private func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

/// The `nonce` claim of a request's DPoP proof.
private func dpopNonce(_ request: URLRequest) throws -> String? {
    let proof = try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP"))
    var payload = String(proof.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: payload))) as? [String: Any])
    return claims["nonce"] as? String
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String?] = []
    var values: [String?] {
        lock.withLock { _values }
    }

    func append(_ value: String?) {
        lock.withLock { _values.append(value) }
    }
}

private final class BlueskyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], String))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (status, headers, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
