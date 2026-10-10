import Foundation
@testable import NoFeedSocialCore
import XCTest

final class AccountIdentityTests: XCTestCase {
    @MainActor
    func testInstagramIdentityDoesNotDependOnProfileOrMessageDecoding() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        IdentityURLProtocol.handler = { request in
            switch request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "":
                return (200, instagramHomepage)
            default:
                XCTFail("Account identity must use only the authenticated homepage")
                return (429, "{}")
            }
        }

        let profile = try await InstagramClient(credentialStore: store, session: makeSession()).currentUserProfile()
        XCTAssertEqual(profile.pk, 42)
        XCTAssertEqual(profile.username, "example")
        XCTAssertEqual(profile.fullName, "Example")
        XCTAssertEqual(profile.profilePicURL?.absoluteString, "https://example.org/avatar.jpg")
    }

    @MainActor
    func testInstagramRejectsMissingViewerIdentity() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        IdentityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/")
            return (200, instagramHomepage.replacingOccurrences(of: #""username":"example""#, with: #""username":"""#))
        }
        do {
            _ = try await InstagramClient(credentialStore: store, session: makeSession()).currentUserProfile()
            XCTFail("An empty username must not become a valid identity")
        } catch {
            guard case SourceError.invalidResponse = error else {
                return XCTFail("Expected invalid viewer identity")
            }
        }
    }

    func testInstagramHomepageRejectsOtherAccountsAndLogoutButAcceptsEmptyTray() throws {
        XCTAssertTrue(try instagramHomepageTray(html: instagramHomepage, accountID: "42").tray.isEmpty)
        for html in [instagramHomepage.replacingOccurrences(of: #""id":"42""#, with: #""id":"99""#), instagramHomepage.replacingOccurrences(of: #""is_logged_out_user":false"#, with: #""is_logged_out_user":true"#)] {
            XCTAssertThrowsError(try instagramHomepageViewer(html: html, accountID: "42")) { error in
                guard case SourceError.notConfigured = error else { return XCTFail("Expected an authentication error") }
            }
        }
        XCTAssertThrowsError(try instagramHomepageViewer(html: #"<script data-sjs>{"user":{"id":"42","username":"unrelated"}}</script>"#, accountID: "42"))
        XCTAssertThrowsError(try instagramHomepageTray(html: instagramHomepage.replacingOccurrences(of: #""tray":[]"#, with: #""tray":null"#), accountID: "42"))
        XCTAssertThrowsError(try instagramHomepageTray(html: instagramHomepage.replacingOccurrences(of: "xdt_api__v1__feed__reels_tray", with: "unrelated"), accountID: "42"))
    }

    @MainActor
    func testInstagramConcurrentIdentityAndTrayShareOnePageAndLaterReadsAreFresh() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        IdentityURLProtocol.requestCount = 0
        IdentityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/")
            return (200, instagramHomepage)
        }
        let client = InstagramClient(credentialStore: store, session: makeSession())
        let identity = Task { @MainActor in
            let profile = try await client.currentUserProfile()
            XCTAssertEqual(profile.username, "example")
        }
        let tray = Task { @MainActor in
            let entries = try await client.reelsTray()
            XCTAssertTrue(entries.isEmpty)
        }
        try await identity.value
        try await tray.value
        XCTAssertEqual(IdentityURLProtocol.requestCount, 1)
        IdentityURLProtocol.handler = { _ in (200, instagramHomepage.replacingOccurrences(of: #""username":"example""#, with: #""username":"updated""#)) }
        let refreshed = try await client.currentUserProfile()
        XCTAssertEqual(refreshed.username, "updated")
        XCTAssertEqual(IdentityURLProtocol.requestCount, 2)
    }

    @MainActor
    func testInstagramServiceFailuresPreserveCredentialsIdentityAndPreferences() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        let metadata = try AccountMetadataStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        metadata.instagramAccount = InstagramAccountMetadata(accountId: "42", username: "example", status: .valid, enabledCategories: [.likes], storiesEnabled: false, directMediaSharesEnabled: false)
        let original = metadata.instagramAccount
        let source = InstagramNotificationSource(client: InstagramClient(credentialStore: store, session: makeSession()), metadataStore: metadata)
        IdentityURLProtocol.handler = { _ in (503, "unavailable") }
        do {
            _ = try await source.fetchStoryReels()
            XCTFail("Expected the page request to fail")
        } catch { XCTAssertEqual(metadata.instagramAccount, original) }
        guard case .serviceError = try await source.validateAccount() else { return XCTFail("Expected a service error rather than invalid credentials") }
        XCTAssertEqual(metadata.instagramAccount?.status, .serviceError)
        XCTAssertEqual(metadata.instagramAccount?.username, "example")
        XCTAssertEqual(metadata.instagramAccount?.enabledCategories, [.likes])
        XCTAssertEqual(metadata.instagramAccount?.storiesEnabled, false)
        XCTAssertEqual(metadata.instagramAccount?.directMediaSharesEnabled, false)
        XCTAssertNotNil(try store.loadInstagramCredentials())
        IdentityURLProtocol.handler = { _ in (200, instagramHomepage) }
        let status = try await source.validateAccount()
        XCTAssertEqual(status, .valid)
        XCTAssertEqual(metadata.instagramAccount?.status, .valid)
        XCTAssertEqual(metadata.instagramAccount?.enabledCategories, [.likes])
    }

    @MainActor
    func testSpotifyResolvesWithBrowserHeadersAndPersistsIdentityAfterTokenMint() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveSpotifyCredentials(SpotifyCredentials(bearerToken: "transport", clientToken: "", spDC: "session", username: nil))
        IdentityURLProtocol.handler = spotifyResponse

        let username = try await SpotifyClient(credentialStore: store, session: makeSession()).validateAccount()
        XCTAssertEqual(username, "example-listener")
        let saved = try XCTUnwrap(store.loadSpotifyCredentials())
        XCTAssertEqual(saved.username, username)
        XCTAssertEqual(saved.bearerToken, "transport")
        XCTAssertEqual(saved.clientToken, "minted-client")
        XCTAssertEqual(saved.initialBearerToken, "initial")
        XCTAssertEqual(saved.clientId, "client-id")
        XCTAssertEqual(saved.spDC, "session")
    }

    @MainActor
    func testSpotifyKeepsKnownUsernameWhenProfileServiceFails() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveSpotifyCredentials(SpotifyCredentials(bearerToken: "transport", clientToken: "client", spDC: "session", username: "known-listener"))
        IdentityURLProtocol.handler = { request in
            if request.url?.path == "/pathfinder/v2/query" { return (503, "{}") }
            return spotifyResponse(request: request)
        }
        let username = try await SpotifyClient(credentialStore: store, session: makeSession()).validateAccount()
        XCTAssertEqual(username, "known-listener")
        XCTAssertEqual(try store.loadSpotifyCredentials()?.username, "known-listener")
    }

    private func makeStore() throws -> (KeychainCredentialStore, String) {
        let suite = "AccountIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true), suite)
    }

    private func cleanUp(store: KeychainCredentialStore, suite: String) {
        try? store.deleteInstagramCredentials()
        try? store.deleteSpotifyCredentials()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        IdentityURLProtocol.handler = nil
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func spotifyResponse(request: URLRequest) -> (Int, String) {
    switch request.url?.path {
    case "/presence-view/v1/buddylist":
        return (200, #"{"friends":[]}"#)
    case "/api/server-time":
        return (200, #"{"serverTime":1800000000}"#)
    case "/api/token":
        return (200, #"{"accessToken":"initial","accessTokenExpirationTimestampMs":2100000000000,"clientId":"client-id"}"#)
    case "/v1/clienttoken":
        XCTAssertEqual(request.value(forHTTPHeaderField: "App-Platform"), "WebPlayer")
        return (200, #"{"granted_token":{"token":"minted-client"}}"#)
    case "/pathfinder/v2/query":
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://open.spotify.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://open.spotify.com/")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        guard request.value(forHTTPHeaderField: "Client-Token") == "minted-client" else { return (403, "{}") }
        return (200, #"{"data":{"me":{"profile":{"username":"example-listener"}}}}"#)
    default:
        XCTFail("Unexpected identity request")
        return (404, "{}")
    }
}

private final class IdentityURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            Self.requestCount += 1
            let handler = try XCTUnwrap(Self.handler)
            let (status, body) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private let instagramHomepage = #"<script data-sjs>{"require":[["PolarisViewer",[],{"data":{"id":"42","username":"example","full_name":"Example","profile_pic_url":"https://example.org/avatar.jpg"}},1]],"is_logged_out_user":false,"data":{"xdt_api__v1__feed__reels_tray":{"tray":[]}}}</script>"#
