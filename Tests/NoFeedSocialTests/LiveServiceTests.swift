import XCTest
@testable import NoFeedSocialCore

@MainActor
final class LiveServiceTests: XCTestCase {
    func testFarcasterStephancillLookupAndNotifications() async throws {
        let client = FarcasterClient()

        let user = try await client.user(byUsername: "stephancill")
        XCTAssertEqual(user.fid, 1689)

        let notifications = try await client.notifications(fid: user.fid, limit: 5)
        XCTAssertFalse(notifications.notifications.isEmpty)
    }

    func testXUnreadCountWithEnvironmentCredentials() async throws {
        guard let authToken = ProcessInfo.processInfo.environment["TWITTER_AUTH_TOKEN"],
              let ct0 = ProcessInfo.processInfo.environment["TWITTER_CT0"],
              !authToken.isEmpty,
              !ct0.isEmpty else {
            throw XCTSkip("Set TWITTER_AUTH_TOKEN and TWITTER_CT0 to run the live X service test.")
        }

        let client = XClient(credentialStore: KeychainCredentialStore())
        let count = try await client.unreadCount(credentials: XCredentials(authToken: authToken, ct0: ct0))

        XCTAssertGreaterThanOrEqual(count, 0)
    }
}
