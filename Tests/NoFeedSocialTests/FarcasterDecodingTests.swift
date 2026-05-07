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

    func testDecodesPrLikesWithHydratedCast() throws {
        let json = #"""
        {
          "notifications": [
            {
              "object": "notification",
              "type": "likes",
              "cast": {
                "object": "cast",
                "hash": "0x49bfa72e6d453ccf38f47048fdd5745f8b2a18ec",
                "author": {
                  "object": "user",
                  "fid": 1689,
                  "username": "stephancill",
                  "display_name": "Stephan"
                },
                "text": "deepseek v4 pro is good",
                "timestamp": "2026-04-28T11:47:36.000Z",
                "type": "cast"
              },
              "user": {
                "object": "user",
                "fid": 806935,
                "username": "l1ghtyear18",
                "display_name": "L1ghtyear18",
                "pfp_url": "https://example.com/avatar.jpg",
                "follower_count": 535,
                "following_count": 1818
              },
              "timestamp": "2026-05-07T16:57:41.000Z"
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
        let n = response.notifications[0]
        XCTAssertEqual(n.type, "likes")
        XCTAssertEqual(n.user?.fid, 806935)
        XCTAssertEqual(n.user?.username, "l1ghtyear18")
        XCTAssertEqual(n.cast?.hash, "0x49bfa72e6d453ccf38f47048fdd5745f8b2a18ec")
        XCTAssertEqual(n.cast?.text, "deepseek v4 pro is good")
        XCTAssertEqual(n.cast?.author?.fid, 1689)
        XCTAssertEqual(n.cast?.author?.username, "stephancill")
    }

    func testDecodesPrFollowsWithNullCast() throws {
        let json = #"""
        {
          "notifications": [
            {
              "object": "notification",
              "type": "follows",
              "cast": null,
              "user": {
                "object": "user",
                "fid": 12345,
                "username": "newfollower",
                "display_name": "New Follower",
                "pfp_url": "https://example.com/avatar.jpg",
                "follower_count": 10,
                "following_count": 20
              },
              "timestamp": "2026-05-07T05:14:37.000Z"
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
        let n = response.notifications[0]
        XCTAssertEqual(n.type, "follows")
        XCTAssertEqual(n.user?.fid, 12345)
        XCTAssertEqual(n.user?.username, "newfollower")
        XCTAssertNil(n.cast)
    }
}
