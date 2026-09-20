@testable import NoFeedSocialCore
import XCTest

final class CookieHeaderParserTests: XCTestCase {
    func testExtractsRequiredXCredentials() {
        let header = "guest_id=v1%3A1; auth_token=token-value; ct0=csrf-value; lang=en"

        let credentials = CookieHeaderParser.extractXCredentials(from: header)

        XCTAssertEqual(credentials?.authToken, "token-value")
        XCTAssertEqual(credentials?.ct0, "csrf-value")
    }

    func testExtractsArcCookieHeaderWithManyCookies() {
        let header = #"kdt=abc123; lang=en; dnt=1; __cuid=test123; guest_id=v1%3A1; personalization_id="v1_test=="; auth_token=test-auth-token-value; ct0=test-ct0-value; twid=u%3D1; night_mode=2"#

        let credentials = CookieHeaderParser.extractXCredentials(from: header)

        XCTAssertEqual(credentials?.authToken, "test-auth-token-value")
        XCTAssertEqual(credentials?.ct0, "test-ct0-value")
    }

    func testReturnsNilWhenRequiredCookieIsMissing() {
        let header = "auth_token=token-value; lang=en"

        XCTAssertNil(CookieHeaderParser.extractXCredentials(from: header))
    }

    func testExtractsRequiredGitHubSessionCookiesAndRetainsExtras() {
        let header = "_device_id=device; user_session=session; __Host-user_session_same_site=same-site; _gh_sess=ephemeral"

        let credentials = CookieHeaderParser.extractGitHubCredentials(from: header)

        XCTAssertEqual(credentials, GitHubCredentials(
            userSession: "session",
            sameSiteUserSession: "same-site",
            additionalCookies: ["_device_id": "device", "_gh_sess": "ephemeral"],
        ))
    }

    func testReturnsNilWhenGitHubSessionCookieIsMissing() {
        XCTAssertNil(CookieHeaderParser.extractGitHubCredentials(from: "user_session=session"))
    }

    func testSpotifyWebPlayerTokenMatchesCurrentWebPlayerAlgorithm() {
        let date = Date(timeIntervalSince1970: 1_777_993_436)

        XCTAssertEqual(SpotifyWebPlayerToken.current(date: date), "031750")
        XCTAssertEqual(SpotifyWebPlayerToken.version, "61")
    }

    func testSpotifyLoginCompletesFromSessionCookieWithoutPlayerTokens() throws {
        let credentials = try XCTUnwrap(CookieHeaderParser.extractSpotifyLoginCredentials(from: [
            spotifyCookie(name: "sp_dc", value: "session"),
        ]))

        XCTAssertEqual(credentials.spDC, "session")
        XCTAssertNil(credentials.spT)
        XCTAssertTrue(credentials.bearerToken.isEmpty)
        XCTAssertTrue(credentials.clientToken.isEmpty)
        XCTAssertEqual(credentials.accessTokenExpiresAt, .distantPast)
    }

    func testSpotifyLoginKeepsOnlySelectedCookies() throws {
        let credentials = try XCTUnwrap(CookieHeaderParser.extractSpotifyLoginCredentials(from: [
            spotifyCookie(name: "sp_dc", value: "session"),
            spotifyCookie(name: "sp_t", value: "tracking"),
            spotifyCookie(name: "sp_key", value: "key"),
            spotifyCookie(name: "unrelated", value: "discard"),
        ]))

        XCTAssertEqual(credentials.spT, "tracking")
        XCTAssertEqual(credentials.spKey, "key")
        XCTAssertNil(credentials.username)
    }

    func testSpotifyLoginRejectsMissingEmptyExpiredAndForeignSessionCookies() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for cookies in [
            [],
            [spotifyCookie(name: "sp_t", value: "tracking")],
            [spotifyCookie(name: "sp_dc", value: "")],
            [spotifyCookie(name: "sp_dc", value: "expired", expires: now.addingTimeInterval(-1))],
            [spotifyCookie(name: "sp_dc", value: "foreign", domain: ".spotify.com.example.org")],
            [spotifyCookie(name: "sp_dc", value: "host-only", domain: "accounts.spotify.com")],
        ] {
            XCTAssertNil(CookieHeaderParser.extractSpotifyLoginCredentials(from: cookies, now: now))
        }
    }

    private func spotifyCookie(name: String, value: String, domain: String = ".spotify.com", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
        ]
        properties[.expires] = expires
        return HTTPCookie(properties: properties)!
    }
}
