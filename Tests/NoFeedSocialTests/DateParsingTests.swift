import Foundation
@testable import NoFeedSocialCore
import XCTest

final class DateParsingTests: XCTestCase {
    func testParsesXDates() {
        XCTAssertEqual(Date.twitter("Wed Oct 10 20:19:24 +0000 2018"), Date(timeIntervalSince1970: 1_539_202_764))
        XCTAssertNil(Date.twitter("2018-10-10T20:19:24Z"))
    }

    func testParsesISO8601WithOrWithoutFractionalSeconds() {
        XCTAssertEqual(Date.iso8601("2018-10-10T20:19:24Z"), Date(timeIntervalSince1970: 1_539_202_764))
        XCTAssertEqual(Date.iso8601("2018-10-10T20:19:24.500Z"), Date(timeIntervalSince1970: 1_539_202_764.5))
        XCTAssertNil(Date.iso8601("Wed Oct 10 20:19:24 +0000 2018"))
    }

    @MainActor
    func testXAPIHeadersAreOnlyWhatTheAPINeeds() {
        let headers = XClient.apiHeaders(credentials: XCredentials(authToken: "token", ct0: "csrf"))
        XCTAssertEqual(Set(headers.keys), ["Authorization", "Cookie", "X-Csrf-Token", "User-Agent"])
        XCTAssertEqual(headers["Cookie"], "auth_token=token; ct0=csrf")
        XCTAssertEqual(headers["X-Csrf-Token"], "csrf")
    }
}
