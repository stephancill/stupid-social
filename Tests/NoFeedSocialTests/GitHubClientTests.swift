import Foundation
@testable import NoFeedSocialCore
import XCTest

final class GitHubClientTests: XCTestCase {
    override func tearDown() {
        GitHubURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetchesHTMLWithSelectedCookiesAndConditionalHeaders() async throws {
        GitHubURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/conduit/for_you_feed")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), #"W/"old""#)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "user_session=session; __Host-user_session_same_site=same-site; logged_in=yes",
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Fetch-Nonce"),
                request.value(forHTTPHeaderField: "X-Fetch-Nonce-To-Validate"),
            )
            return (200, ["Content-Type": "text/html; charset=utf-8", "ETag": #"W/"new""#], Data("<div>feed</div>".utf8))
        }

        let result = try await makeClient().forYouFeed(
            credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
            etag: #"W/"old""#,
        )

        XCTAssertEqual(result, .feed(GitHubForYouFeedResponse(html: "<div>feed</div>", etag: #"W/"new""#)))
    }

    func testReturnsNotModified() async throws {
        GitHubURLProtocolStub.handler = { _ in (304, [:], Data()) }

        let result = try await makeClient().forYouFeed(
            credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
        )

        XCTAssertEqual(result, .notModified)
    }

    func testTreatsUnauthorizedResponseAsNotConfigured() async {
        GitHubURLProtocolStub.handler = { _ in (401, ["Content-Type": "text/html"], Data()) }

        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().forYouFeed(
                credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
            )
        } verify: { error in
            guard case SourceError.notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        }
    }

    func testRejectsNonHTMLResponse() async {
        GitHubURLProtocolStub.handler = { _ in
            (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().forYouFeed(
                credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
            )
        } verify: { error in
            guard case SourceError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testAuthenticatedUserReadsUserMenuLogin() async throws {
        GitHubURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "user_session=session; __Host-user_session_same_site=same-site; logged_in=yes",
            )
            let html = #"<script>{"userMenu":{"owner":{"login":"stephancill","name":"Stephan Cilliers"}}}</script>"#
            return (200, ["Content-Type": "text/html; charset=utf-8"], Data(html.utf8))
        }

        let username = try await makeClient().authenticatedUser(
            credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
        )

        XCTAssertEqual(username, "stephancill")
    }

    func testAuthenticatedUserReturnsNilWhenNoUserMenu() async throws {
        GitHubURLProtocolStub.handler = { _ in
            (200, ["Content-Type": "text/html; charset=utf-8"], Data("<html>logged out</html>".utf8))
        }

        let username = try await makeClient().authenticatedUser(
            credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
        )

        XCTAssertNil(username)
    }

    func testAuthenticatedUserThrowsNotConfiguredOnExpiredSession() async {
        GitHubURLProtocolStub.handler = { _ in (403, ["Content-Type": "text/html"], Data()) }

        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().authenticatedUser(
                credentials: GitHubCredentials(userSession: "session", sameSiteUserSession: "same-site"),
            )
        } verify: { error in
            guard case SourceError.notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        }
    }

    private func makeClient() -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubURLProtocolStub.self]
        return GitHubClient(session: URLSession(configuration: configuration))
    }
}

private final class GitHubURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (statusCode, headers, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers,
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
