@testable import StupidSocialCore
import XCTest

final class FarcasterDecodingTests: XCTestCase {
    func testFarcasterNotificationCategoryDefaultsToAllForExistingMetadata() throws {
        let json = #"{"username":"alice","fid":123,"status":"valid"}"#.data(using: .utf8)!

        let account = try JSONDecoder().decode(FarcasterAccountMetadata.self, from: json)

        XCTAssertEqual(account.enabledCategories, Set(FarcasterNotificationCategory.allCases))
    }

    func testFarcasterNotificationCategoryMapsNormalizedTypes() {
        XCTAssertEqual(FarcasterNotificationCategory.category(for: .mention), .mentions)
        XCTAssertEqual(FarcasterNotificationCategory.category(for: .reply), .replies)
        XCTAssertEqual(FarcasterNotificationCategory.category(for: .reaction), .reactions)
        XCTAssertEqual(FarcasterNotificationCategory.category(for: .follow), .follows)
        XCTAssertNil(FarcasterNotificationCategory.category(for: .unknown))
    }

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

/// Hypersnap notifications as sent with `include_quotes_and_deep_replies=true` (shapes observed 2026-11-09).
@MainActor
final class FarcasterNotificationNormalizingTests: XCTestCase {
    private let account = FarcasterAccountMetadata(username: "me", fid: 194, status: .valid)

    func testQuoteIsAReplyNotification() throws {
        let items = try normalize(#"""
        {"object": "notification", "type": "quote", "timestamp": "2026-11-08T10:00:00.000Z",
         "user": {"fid": 5818, "username": "quoter"},
         "cast": {"hash": "002cb8788b", "text": "look", "author": {"fid": 5818, "username": "quoter"},
                  "parent_author": {"fid": null},
                  "embeds": [{"cast_id": {"fid": 194, "hash": "fa953421fd"}}, {"url": "https://example.com/a.png"}]}}
        """#)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].type, .reply)
        XCTAssertEqual(items[0].text, "@quoter quoted your cast")
        XCTAssertEqual(items[0].target?.id, "002cb8788b")
        XCTAssertEqual(items[0].target?.imageURLs, try [XCTUnwrap(URL(string: "https://example.com/a.png"))])
        XCTAssertNil(items[0].parentTarget)
    }

    func testRecastsGroupApartFromLikesOfTheSameCast() throws {
        let cast = #""cast": {"hash": "fa953421fd", "text": "mine", "author": {"fid": 194}, "parent_author": {"fid": null}}"#
        let items = try normalize(
            #"{"type": "likes", "timestamp": "2026-11-08T10:00:00.000Z", "user": {"fid": 1, "username": "a"}, \#(cast)}"#,
            #"{"type": "likes", "timestamp": "2026-11-08T11:00:00.000Z", "user": {"fid": 2, "username": "b"}, \#(cast)}"#,
            #"{"type": "recasts", "timestamp": "2026-11-08T12:00:00.000Z", "user": {"fid": 3, "username": "c"}, \#(cast)}"#,
        )

        XCTAssertEqual(items.map(\.text), ["@c recast your cast", "@a and 1 other reacted to your cast"])
        XCTAssertEqual(items.map(\.type), [.reaction, .reaction])
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testCastsAreRepliesOrMentionsByParentAndMentions() throws {
        let items = try normalize(
            // A reply to the user's cast.
            #"{"type": "reply", "timestamp": "2026-11-08T14:00:00.000Z", "user": {"fid": 1, "username": "a"}, "cast": {"hash": "c1", "author": {"fid": 1}, "parent_hash": "p1", "parent_author": {"fid": 194}}}"#,
            // A reply deeper in the user's thread.
            #"{"type": "reply", "timestamp": "2026-11-08T13:00:00.000Z", "user": {"fid": 2, "username": "b"}, "cast": {"hash": "c2", "author": {"fid": 2}, "parent_hash": "p2", "parent_author": {"fid": 3642}}}"#,
            // A reply deeper down that mentions the user.
            #"{"type": "reply", "timestamp": "2026-11-08T12:00:00.000Z", "user": {"fid": 3, "username": "c"}, "cast": {"hash": "c3", "author": {"fid": 3}, "parent_hash": "p3", "parent_author": {"fid": 3642}, "mentioned_profiles": [{"fid": 194}]}}"#,
            // A new cast mentioning the user.
            #"{"type": "reply", "timestamp": "2026-11-08T11:00:00.000Z", "user": {"fid": 4, "username": "d"}, "cast": {"hash": "c4", "author": {"fid": 4}, "parent_author": {"fid": null}, "mentioned_profiles": [{"fid": 194}]}}"#,
        )

        XCTAssertEqual(items.map(\.type), [.reply, .reply, .mention, .mention])
        XCTAssertEqual(items.map(\.text), [
            "@a replied to you",
            "@b replied in your thread",
            "@c mentioned you",
            "@d mentioned you",
        ])
        XCTAssertEqual(items[1].parentTarget?.id, "p2")
    }

    private func normalize(_ notifications: String...) throws -> [NotificationItem] {
        let json = #"{"notifications": [\#(notifications.joined(separator: ","))], "next": {}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try XCTUnwrap(Date.iso8601(value))
        }
        let response = try decoder.decode(FarcasterNotificationsResponse.self, from: Data(json.utf8))
        return FarcasterNotificationSource.items(from: response.notifications, account: account)
    }
}
