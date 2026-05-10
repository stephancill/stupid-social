@testable import NoFeedSocialCore
import XCTest

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
        XCTAssertEqual(n.user?.fid, 806_935)
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

    func testDecodesRealUserByFidResponse() throws {
        let json = #"""
        {
          "user": {
            "object": "user",
            "fid": 806935,
            "username": "l1ghtyear18",
            "display_name": "L1ghtyear18",
            "custody_address": "0x5da30d2c3ffa0745fb0f8492527c7d8c9c8461b3",
            "pfp_url": "https://imagedelivery.net/BXluQx4ige9GuW0Ia56BHw/97c51567-81f7-4d4b-a562-fc136ed7e500/original",
            "registered_at": "2024-07-24T12:36:35.000Z",
            "profile": {
              "bio": {
                "text": "Investment guru and gamer. I trade and play."
              }
            },
            "follower_count": 535,
            "following_count": 1818,
            "verifications": [],
            "auth_addresses": [],
            "verified_addresses": { "eth_addresses": [], "sol_addresses": [], "primary": {} },
            "verified_accounts": []
          }
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)!
        }

        let wrapper = try decoder.decode(_FarcasterUserWrapperTest.self, from: json)
        let user = wrapper.user

        XCTAssertEqual(user.fid, 806_935)
        XCTAssertEqual(user.username, "l1ghtyear18")
        XCTAssertEqual(user.displayName, "L1ghtyear18")
        XCTAssertEqual(user.bio, "Investment guru and gamer. I trade and play.")
        XCTAssertNotNil(user.pfpUrl)
        XCTAssertTrue(user.pfpUrl?.absoluteString.contains("imagedelivery.net") ?? false)
        XCTAssertEqual(user.followerCount, 535)
        XCTAssertEqual(user.followingCount, 1818)
        XCTAssertNotNil(user.registeredAt)
    }

    func testDecodesNotificationUserWithPfpAndCounts() throws {
        let json = #"""
        {
          "notifications": [
            {
              "object": "notification",
              "type": "likes",
              "cast": {
                "object": "cast",
                "hash": "0xd034edc1c0e1d137c3c084461c693897d01399e0",
                "parent_author": { "fid": null },
                "author": {
                  "object": "user",
                  "fid": 1689,
                  "username": "stephancill",
                  "display_name": "Stephan",
                  "pfp_url": "https://imagedelivery.net/BXluQx4ige9GuW0Ia56BHw/64c851c0-2036-4629-ead7-ae60bfc62500/original",
                  "follower_count": 359641,
                  "following_count": 2620
                },
                "text": "hello world",
                "timestamp": "2026-05-08T00:00:00.000Z",
                "type": "cast"
              },
              "user": {
                "object": "user",
                "fid": 2023878,
                "username": "lasm",
                "display_name": null,
                "pfp_url": "https://imagedelivery.net/BXluQx4ige9GuW0Ia56BHw/somehash/original",
                "follower_count": 42,
                "following_count": 99
              },
              "timestamp": "2026-05-08T00:00:00.000Z"
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
        let n = response.notifications[0]

        // Notification user (actor)
        XCTAssertEqual(n.user?.fid, 2_023_878)
        XCTAssertEqual(n.user?.username, "lasm")
        XCTAssertNotNil(n.user?.pfpUrl)
        XCTAssertEqual(n.user?.followerCount, 42)
        XCTAssertEqual(n.user?.followingCount, 99)

        // Cast author (target cast owner)
        XCTAssertEqual(n.cast?.author?.fid, 1689)
        XCTAssertEqual(n.cast?.author?.username, "stephancill")
        XCTAssertNotNil(n.cast?.author?.pfpUrl)
        XCTAssertEqual(n.cast?.author?.followerCount, 359_641)
        XCTAssertEqual(n.cast?.author?.followingCount, 2620)
    }
}

private struct _FarcasterUserWrapperTest: Decodable {
    let user: FarcasterUserResponse
}
