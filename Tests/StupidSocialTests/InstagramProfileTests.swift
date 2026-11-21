import Foundation
@testable import StupidSocialCore
import XCTest

final class InstagramProfileTests: XCTestCase {
    func testRouteDoesNotMistakeViewerForProfile() {
        XCTAssertEqual(instagramProfileRouteID(html: profilePage), "99")
        XCTAssertNil(instagramProfileRouteID(html: #"<script data-sjs>{"viewer":{"id":"42"}}</script>"#))
    }

    func testQueriesTakeTheProvidersTheirBundlesNameFromEachProvidersTable() throws {
        let providers = instagramRelayProviders(source: profileAsset)
        XCTAssertEqual(providers["PolarisShortDramaEnabled"], InstagramRelayProvider(table: .justknobx, id: "14", isStrict: false))
        XCTAssertEqual(providers["PolarisMultiCaptionCarouselEnabled"], InstagramRelayProvider(table: .qex, id: "2404", isStrict: true))
        let names = try XCTUnwrap(instagramQueryProviders(source: profileAsset, operation: "PolarisProfilePostsQuery"))
        XCTAssertEqual(names, ["PolarisMultiCaptionCarouselEnabled", "PolarisProductTagIndicatorEnabled", "PolarisReelsRecoDebugOverlayEnabled", "PolarisShortDramaEnabled"])
        XCTAssertNil(instagramQueryProviders(source: profileAsset, operation: "PolarisSomethingElseQuery"))
        let variables = try instagramProvidedVariables(html: runtimePage, names: names, providers: providers)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider"] as? Bool, true)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisProductTagIndicatorEnabledrelayprovider"] as? Bool, true)
        XCTAssertEqual(variables["__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider"] as? Bool, false, "gate 684, not JustKnobs 684")
        XCTAssertEqual(variables["__relay_internal__pv__PolarisShortDramaEnabledrelayprovider"] as? Bool, true)
        XCTAssertThrowsError(try instagramProvidedVariables(html: "<html></html>", names: names, providers: providers))
    }

    func testSearchResultsDecodeFromTheSearchBoxQuery() throws {
        let response = try JSONDecoder().decode(InstagramSearchResponse.self, from: Data(searchResponse.utf8))
        let users = try XCTUnwrap(response.data?.connection?.users.map(\.user))
        XCTAssertEqual(users.map(\.username), ["example"])
        XCTAssertEqual(users.first?.fullName, "Example Person")
        let failed = try JSONDecoder().decode(InstagramSearchResponse.self, from: Data(#"{"data":null,"errors":[{"message":"login_required"}]}"#.utf8))
        XCTAssertNil(failed.data?.connection)
        XCTAssertEqual(failed.errors?.first?.message, "login_required")
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
                XCTAssertEqual(request.httpMethod, "POST")
                let form = formFields(request)
                let docID = try XCTUnwrap(form["doc_id"])
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-FB-Friendly-Name"), form["fb_api_req_friendly_name"])
                let variables = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(form["variables"]).utf8)) as! [String: Any]
                XCTAssertEqual(variables["__relay_internal__pv__PolarisShortDramaEnabledrelayprovider"] as? Bool, true)
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
    func testPostsFailOnlyWhenTheirDataIsMissing() async throws {
        let (store, suite, session) = try setup()
        defer { cleanup(store: store, suite: suite) }
        let client = InstagramClient(credentialStore: store, session: session)
        client.webState = InstagramWebState(html: runtimePage)
        client.docIds["PolarisProfilePostsQuery"] = "1002"
        client.queryProviders["PolarisProfilePostsQuery"] = []
        ProfileURLProtocol.handler = { _ in (200, failedPostsResponse) }
        do {
            _ = try await client.userPostsPage(uid: "example", cursor: nil)
            XCTFail("No posts came back")
        } catch let SourceError.serviceError(message) {
            XCTAssertTrue(message.contains("field_exception"), "says what Instagram said")
        }
    }

    @MainActor
    func testRejectsMismatchedProfileAndDoesNotRetryRateLimit() async throws {
        let (store, suite, session) = try setup()
        defer { cleanup(store: store, suite: suite) }
        let client = InstagramClient(credentialStore: store, session: session)
        client.webState = InstagramWebState(html: runtimePage)
        client.docIds["PolarisProfilePageContentQuery"] = "1001"
        client.queryProviders["PolarisProfilePageContentQuery"] = []
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

private let runtimePage = #"<script data-sjs>{"gkxData":{"684":{"result":false},"29816":{"result":true}},"qexData":{"2404":{"r":true,"l":"quoted } value"}},"justknobxData":{"14":{"r":true},"684":{"r":true}}}</script>"#
private let profilePage = #"<script src="https://static.cdninstagram.com/profile.js"></script><script data-sjs>{"viewer":{"id":"42"},"initialRouteInfo":{"route":{"rootView":{"props":{"id":"99","page_logging":{"params":{"profile_id":"99"}}}}}}}</script>"#
/// Shaped like Instagram's bundles (2026-11-21): operation ids, each query's providers, and the providers' definitions.
private let profileAsset = #"__d("PolarisProfilePageContentQuery_instagramRelayOperation",[],(function(a){a.exports="1001"}));__d("PolarisProfilePostsQuery_instagramRelayOperation",[],(function(a){a.exports="1002"}));__d("PolarisProfilePageContentQuery.graphql",["PolarisShortDramaEnabled.relayprovider"],(function(a,b){var e={params:{providedVariables:{"__relay_internal__pv__PolarisShortDramaEnabledrelayprovider":b("PolarisShortDramaEnabled.relayprovider")}}}}));__d("PolarisProfilePostsQuery.graphql",[],(function(a,b){var e={params:{providedVariables:{"__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider":1,"__relay_internal__pv__PolarisProductTagIndicatorEnabledrelayprovider":1,"__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider":1,"__relay_internal__pv__PolarisShortDramaEnabledrelayprovider":1}}}}));__d("PolarisShortDramaEnabled.relayprovider",["justknobx"],(function(t,n,r,o,a,i,l){"use strict";var e={get:function(){return r("justknobx")._("14")}}}));__d("PolarisMultiCaptionCarouselEnabled.relayprovider",["qex"],(function(t,n,r){var e={get:function(){return r("qex")._("2404")===!0}}}));__d("PolarisReelsRecoDebugOverlayEnabled.relayprovider",["gkx"],(function(t,n,r){var e={get:function(){return r("gkx")("684")===!0}}}));__d("PolarisProductTagIndicatorEnabled.relayprovider",["gkx"],(function(t,n,r){var e={get:function(){return r("gkx")("29816")===!0}}}));"#
private let profileResponse = #"{"data":{"user":{"pk":"99","username":"example","follower_count":12,"following_count":5,"media_count":3,"is_private":true,"friendship_status":{"following":false,"followed_by":true}}}}"#
/// With an error on one field, as Instagram sends `field_exception` for a post's location picture: the data still counts.
private let postsResponse = #"{"data":{"xdt_api__v1__feed__user_timeline_graphql_connection":{"edges":[],"page_info":{"has_next_page":false,"end_cursor":null}}},"errors":[{"message":"A server error field_exception occured.","severity":"ERROR","path":["xdt_api__v1__feed__user_timeline_graphql_connection","edges",0,"node","location","profile_pic_url"]}]}"#
private let searchResponse = #"{"data":{"xdt_api__v1__fbsearch__topsearch_connection":{"users":[{"position":0,"user":{"pk":"99","username":"example","full_name":"Example Person","is_verified":false,"profile_pic_url":"https://scontent.example/p.jpg"}}],"places":[],"hashtags":[],"rank_token":"r"}}}"#
private let failedPostsResponse = #"{"data":{"xdt_api__v1__feed__user_timeline_graphql_connection":null},"errors":[{"message":"A server error field_exception occured.","severity":"CRITICAL"}]}"#

/// A form POST's fields; URLProtocol sees the body as a stream.
private func formFields(_ request: URLRequest) -> [String: String] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
    }
    var components = URLComponents()
    components.percentEncodedQuery = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "+", with: "%20")
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

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
