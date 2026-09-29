import Foundation
@testable import NoFeedSocialCore
import XCTest

final class InstagramProfileTests: XCTestCase {
    func testRouteDoesNotMistakeViewerForProfile() {
        XCTAssertEqual(instagramProfileRouteID(html: profilePage), "99")
        XCTAssertNil(instagramProfileRouteID(html: #"<script data-sjs>{"viewer":{"id":"42"}}</script>"#))
    }

    func testProvidedVariablesRespectGateAndExperimentNamespaces() throws {
        let variables = try instagramProfileVariables(html: runtimePage, posts: true)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider"] as? Bool, true)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider"] as? Bool, false)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisShortDramaEnabledrelayprovider"] as? Bool, false)
        let experiment = runtimePage.replacingOccurrences(of: #""r":null"#, with: #""r":true"#)
        XCTAssertEqual(try instagramProfileVariables(html: experiment, posts: false)["__relay_internal__pv__PolarisShortDramaEnabledrelayprovider"] as? Bool, true)
        XCTAssertThrowsError(try instagramProfileVariables(html: "<html></html>", posts: false))
    }

    func testPrivateProfileAndEmptyPostsDecode() throws {
        let profile = try JSONDecoder().decode(InstagramProfileQueryResponse.self, from: Data(profileResponse.utf8))
        XCTAssertEqual(profile.data.user?.isPrivate, true)
        XCTAssertEqual(profile.data.user?.friendshipStatus?.followedBy, true)
        XCTAssertEqual(profile.data.user?.followerCount, 12)
        let response = try JSONDecoder().decode(InstagramProfilePostsResponse.self, from: Data(postsResponse.utf8))
        XCTAssertTrue(response.data.connection.edges.isEmpty)
        XCTAssertFalse(response.data.connection.pageInfo.hasNextPage)
    }

    @MainActor
    func testProfileDiscoversCurrentQueriesAndPostsUseUsernameAndCursor() async throws {
        let (store, suite, session) = try setup()
        defer { cleanup(store: store, suite: suite) }
        ProfileURLProtocol.handler = { request in
            switch request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "": return (200, runtimePage)
            case "example": return (200, profilePage)
            case "profile.js":
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (200, profileAsset)
            case "graphql/query":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let docID = query.first { $0.name == "doc_id" }!.value!
                let variables = try JSONSerialization.jsonObject(with: Data(query.first { $0.name == "variables" }!.value!.utf8)) as! [String: Any]
                if docID == "1001" {
                    XCTAssertEqual(variables["id"] as? String, "99")
                    XCTAssertEqual(variables["enable_integrity_filters"] as? Bool, true)
                    return (200, profileResponse)
                }
                XCTAssertEqual(docID, "1002")
                XCTAssertEqual(variables["username"] as? String, "example")
                XCTAssertEqual(variables["after"] as? String, "opaque+cursor/==")
                XCTAssertEqual((variables["data"] as? [String: Any])?["count"] as? Int, 12)
                return (200, postsResponse)
            default:
                XCTFail("Unexpected profile request, including deprecated REST endpoints")
                return (429, "{}")
            }
        }
        let client = InstagramClient(credentialStore: store, session: session)
        let profile = try await client.userInfo(uid: "example")
        XCTAssertEqual(profile.user.pk, 99)
        XCTAssertEqual(profile.user.friendshipStatus?.followedBy, true)
        let posts = try await client.userPostsPage(uid: "example", cursor: "opaque+cursor/==")
        XCTAssertTrue(posts.posts.isEmpty)
        XCTAssertFalse(posts.hasMore)
    }

    @MainActor
    func testRejectsMismatchedProfileAndDoesNotRetryRateLimit() async throws {
        let (store, suite, session) = try setup()
        defer { cleanup(store: store, suite: suite) }
        let client = InstagramClient(credentialStore: store, session: session)
        client.webState = InstagramWebState(html: runtimePage)
        client.docIds["PolarisProfilePageContentQuery"] = "1001"
        ProfileURLProtocol.handler = { _ in (200, profileResponse) }
        do {
            _ = try await client.userInfo(uid: "100")
            XCTFail("Must reject a different account")
        } catch { XCTAssertTrue(error is SourceError) }
        ProfileURLProtocol.requestCount = 0
        ProfileURLProtocol.handler = { _ in (429, "{}") }
        do {
            _ = try await client.userInfo(uid: "99")
            XCTFail("Must surface rate limiting")
        } catch { XCTAssertEqual(ProfileURLProtocol.requestCount, 1) }
    }

    private func setup() throws -> (KeychainCredentialStore, String, URLSession) {
        let suite = "InstagramProfileTests.\(UUID().uuidString)"
        let store = try KeychainCredentialStore(service: suite, fallbackStore: XCTUnwrap(UserDefaults(suiteName: suite)), prefersSynchronizable: false, allowsInsecureFallback: true)
        _ = try store.saveInstagramCredentials(InstagramCredentials(sessionId: "session", csrfToken: "csrf", dsUserId: "42", mid: nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileURLProtocol.self]
        return (store, suite, URLSession(configuration: configuration))
    }

    private func cleanup(store: KeychainCredentialStore, suite: String) {
        try? store.deleteInstagramCredentials()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        ProfileURLProtocol.handler = nil
    }
}

private let runtimePage = #"<script data-sjs>{"gkx":{"17028":{"result":false},"6793":{"result":true},"17363":{"result":false},"9448":{"result":true},"12774":{"result":false},"684":{"result":false}},"qex":{"1697":{"r":null},"3668":{"r":null},"2404":{"r":true,"l":"quoted } value"},"684":{"r":true}}}</script>"#
private let profilePage = #"<script src="https://static.cdninstagram.com/profile.js"></script><script data-sjs>{"viewer":{"id":"42"},"initialRouteInfo":{"route":{"rootView":{"props":{"id":"99","page_logging":{"params":{"profile_id":"99"}}}}}}}</script>"#
private let profileAsset = #"__d("PolarisProfilePageContentQuery_instagramRelayOperation",[],(function(a){a.exports="1001"}));__d("PolarisProfilePostsQuery_instagramRelayOperation",[],(function(a){a.exports="1002"}));"#
private let profileResponse = #"{"data":{"user":{"pk":"99","username":"example","follower_count":12,"following_count":5,"media_count":3,"is_private":true,"friendship_status":{"following":false,"followed_by":true}}}}"#
private let postsResponse = #"{"data":{"xdt_api__v1__feed__user_timeline_graphql_connection":{"edges":[],"page_info":{"has_next_page":false,"end_cursor":null}}}}"#

private final class ProfileURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String))?
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
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
