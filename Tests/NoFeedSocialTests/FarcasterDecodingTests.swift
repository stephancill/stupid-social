import XCTest
@testable import NoFeedSocialCore

final class FarcasterDecodingTests: XCTestCase {
    func testDecodesCurrentHypersnapNotificationShape() throws {
        let json = #"""
        {
          "notifications": [
            {
              "object": "notification",
              "type": "reply",
              "cast": null,
              "user": {
                "object": "user",
                "fid": 7759,
                "username": "example.eth",
                "display_name": "Example",
                "pfp_url": "https://example.com/avatar.jpg",
                "follower_count": 10,
                "following_count": 20
              },
              "timestamp": "2026-04-27T07:07:24.000Z"
            }
          ],
          "next": {}
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value)!
        }

        let response = try decoder.decode(FarcasterNotificationsResponse.self, from: json)

        XCTAssertEqual(response.notifications.count, 1)
        XCTAssertEqual(response.notifications[0].type, "reply")
        XCTAssertEqual(response.notifications[0].user?.username, "example.eth")
        XCTAssertEqual(response.notifications[0].notificationDate.timeIntervalSince1970, 1_777_273_644)
    }
}
