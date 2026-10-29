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

    func testInstagramDetectsExpiredSessionCookie() throws {
        func response(_ setCookie: String?) throws -> HTTPURLResponse {
            var headers = ["Location": "https://www.instagram.com/"]
            headers["Set-Cookie"] = setCookie
            return try XCTUnwrap(try HTTPURLResponse(url: XCTUnwrap(URL(string: "https://www.instagram.com/")), statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        XCTAssertTrue(try instagramResponseExpiresSession(response("sessionid=abc; expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=-1792943606; path=/; domain=.instagram.com; httponly")))
        XCTAssertTrue(try instagramResponseExpiresSession(response(#"sessionid=""; path=/; domain=.instagram.com"#)))
        XCTAssertFalse(try instagramResponseExpiresSession(response("sessionid=abc; expires=Thu, 01-Jan-2099 00:00:01 GMT; path=/; domain=.instagram.com")))
        XCTAssertFalse(try instagramResponseExpiresSession(response("csrftoken=abc; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/; domain=.instagram.com")))
        XCTAssertFalse(try instagramResponseExpiresSession(response(nil)))
    }

    func testInstagramDetectsLoginRequiredBodies() {
        XCTAssertTrue(instagramBodyRequiresLogin(Data(#"{"message":"checkpoint_required","checkpoint":"https://www.instagram.com/challenge/","status":"fail"}"#.utf8)))
        XCTAssertTrue(instagramBodyRequiresLogin(Data(#"{"message":"login_required","status":"fail"}"#.utf8)))
        XCTAssertTrue(instagramBodyRequiresLogin(Data(#"<!DOCTYPE html><html lang="None" class="no-js not-logged-in "><head></head></html>"#.utf8)))
        XCTAssertFalse(instagramBodyRequiresLogin(Data(#"{"message":"Please wait a few minutes","status":"fail"}"#.utf8)))
        XCTAssertFalse(instagramBodyRequiresLogin(Data(#"<!DOCTYPE html><html class="_9dls touch" lang="en"><body>login</body></html>"#.utf8)))
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
        let accounts = makeTestAccountStore(suite: suite).store
        accounts.save(Account(id: "instagram", network: .instagram, remoteId: "42"))
        let metadata = accounts.metadata(for: "instagram")
        metadata.instagramAccount = InstagramAccountMetadata(accountId: "42", username: "example", status: .valid, enabledCategories: [.likes], storiesEnabled: false, directMediaSharesEnabled: false)
        let original = metadata.instagramAccount
        let source = InstagramNotificationSource(client: InstagramClient(credentialStore: store, session: makeSession()), metadataStore: metadata)
        IdentityURLProtocol.handler = { _ in (503, "unavailable") }
        do {
            _ = try await source.fetchStoryReels()
            XCTFail("Expected the page request to fail")
        } catch { XCTAssertEqual(metadata.instagramAccount, original) }
        XCTAssertNotNil(try store.loadInstagramCredentials())
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

    @MainActor
    func testInstagramStorySeenSendsActorAndFailsWhenIgnored() async throws {
        let (store, suite) = try makeStore()
        defer { cleanUp(store: store, suite: suite) }
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        let homepage = #"<script>{"USER_ID":"0","actorID":"17841400000000042"}</script><script>__d("PolarisStoriesV3SeenMutation_instagramRelayOperation",[],(function(t,n,r,o,a,i){a.exports="123"}),null);</script>"#
        let exchange = SeenMutationExchange()
        IdentityURLProtocol.handler = { @Sendable request in
            guard request.url?.path == "/api/graphql" else { return (200, homepage) }
            let body = try XCTUnwrap(request.httpBodyStream.map(readAll))
            return (200, exchange.record(form: body))
        }
        let client = InstagramClient(credentialStore: store, session: makeSession())
        let item = (mediaId: "4015104032613070661", ownerId: "751322505", takenAt: 1_792_857_720.0)

        try await client.markStorySeen(mediaItems: [item])
        let form = exchange.form
        XCTAssertEqual(form["doc_id"], "123")
        XCTAssertEqual(form["av"], "17841400000000042")
        XCTAssertEqual(form["__user"], "0")
        XCTAssertEqual(form["fb_api_req_friendly_name"], "PolarisStoriesV3SeenMutation")

        exchange.result = #"{"data":{"xdt_mark_story_reel_seen":null},"status":"ok"}"#
        do {
            try await client.markStorySeen(mediaItems: [item])
            XCTFail("Expected an ignored seen mutation to throw")
        } catch {
            guard case SourceError.serviceError = error else { return XCTFail("Expected a service error, got \(error)") }
        }
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

private final class SeenMutationExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult = #"{"data":{"xdt_mark_story_reel_seen":{"__typename":"XDTMarkSeenResponse"}}}"#
    private var storedForm: [String: String] = [:]

    var result: String {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    var form: [String: String] {
        lock.withLock { storedForm }
    }

    func record(form body: String) -> String {
        let items = URLComponents(string: "?" + body)?.queryItems ?? []
        return lock.withLock {
            storedForm = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
            return storedResult
        }
    }
}

private func readAll(_ stream: InputStream) -> String {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}
