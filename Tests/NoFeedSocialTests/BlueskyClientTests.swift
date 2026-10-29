import CryptoKit
import Foundation
@testable import NoFeedSocialCore
import XCTest

final class BlueskyClientTests: XCTestCase {
    /// The authorization server rotates DPoP nonces within minutes, so the nonce saved at sign-in is stale by the
    /// first refresh: it answers `use_dpop_nonce` with a fresh one (scripts/bluesky-web-client.py token-nonce).
    func testRefreshRetriesWithTheServersNonceAndKeepsTheLatest() async throws {
        let suite = "BlueskyClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true)
        defer {
            try? store.deleteBlueskyCredentials()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            BlueskyURLProtocol.handler = nil
        }
        _ = try store.saveBlueskyCredentials(BlueskyOAuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            did: "did:plc:example",
            handle: "example.test",
            pdsURL: XCTUnwrap(URL(string: "https://pds.example")),
            authServerURL: XCTUnwrap(URL(string: "https://auth.example")),
            scope: "atproto",
            expiresAt: Date().addingTimeInterval(-60),
            dpopPrivateKey: P256.Signing.PrivateKey().rawRepresentation,
            authNonce: "nonce-from-sign-in",
        ))

        let tokenNonces = NonceLog()
        BlueskyURLProtocol.handler = { request in
            switch request.url?.path() {
            case "/oauth/token":
                let nonce = try dpopNonce(request)
                tokenNonces.append(nonce)
                if nonce == "fresh-nonce" {
                    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","sub":"did:plc:example","scope":"atproto","expires_in":3600}"#
                    return (200, ["DPoP-Nonce": "next-nonce"], token)
                }
                return (400, ["DPoP-Nonce": "fresh-nonce"], #"{"error":"use_dpop_nonce","error_description":"DPoP \"nonce\" mismatch"}"#)
            case "/xrpc/app.bsky.notification.listNotifications":
                return (200, [:], #"{"notifications":[]}"#)
            default:
                return (200, [:], "{}")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlueskyURLProtocol.self]
        let client = BlueskyClient(credentialStore: store, session: URLSession(configuration: configuration))

        let notifications = try await client.notifications()

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(tokenNonces.values, ["nonce-from-sign-in", "fresh-nonce"])
        let saved = try XCTUnwrap(store.loadBlueskyCredentials())
        XCTAssertEqual(saved.refreshToken, "new-refresh")
        XCTAssertEqual(saved.authNonce, "next-nonce")
    }
}

/// The `nonce` claim of a request's DPoP proof.
private func dpopNonce(_ request: URLRequest) throws -> String? {
    let proof = try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP"))
    var payload = String(proof.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: payload))) as? [String: Any])
    return claims["nonce"] as? String
}

private final class NonceLog: @unchecked Sendable {
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
