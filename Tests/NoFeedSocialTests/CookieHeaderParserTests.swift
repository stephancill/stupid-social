import XCTest
@testable import NoFeedSocialCore

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
}
