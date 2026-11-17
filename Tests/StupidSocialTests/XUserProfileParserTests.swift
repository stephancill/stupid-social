import Foundation
@testable import StupidSocialCore
import XCTest

/// `UserByScreenName` as X's web client requests it, in the shape `scripts/x-web-client.py user` records
/// (observed 2026-11-17): no `legacy`, counts and bio in their own objects, the bell in `notifications_settings`.
final class XUserProfileParserTests: XCTestCase {
    func testMapsCurrentProfileShape() throws {
        let response: [String: Any] = ["data": ["user": ["result": [
            "__typename": "User",
            "rest_id": "42",
            "core": ["screen_name": "alice", "name": "Alice", "created_at": "Sun Nov 09 15:34:45 +0000 2025"],
            "avatar": ["image_url": "https://pbs.twimg.com/profile_images/1/a_normal.jpg"],
            "is_blue_verified": true,
            "relationship_perspectives": ["following": true, "followed_by": false],
            "notifications_settings": ["notifications_enabled": true],
            "relationship_counts": ["followers": 40, "following": 142],
            "tweet_counts": ["tweets": 301, "media_tweets": 33],
            "location": ["location": ""],
            "profile_bio": [
                "description": "Building things. https://t.co/abc",
                "entities": [
                    "description": ["urls": [["url": "https://t.co/abc", "expanded_url": "https://alice.dev", "display_url": "alice.dev"]]],
                    "url": ["urls": [["url": "https://t.co/xyz", "expanded_url": "https://alice.dev/home"]]],
                ],
            ],
        ]]]]

        let profile = try XUserProfileParser.parse(data: JSONSerialization.data(withJSONObject: response), screenName: "alice")

        XCTAssertEqual(profile.idStr, "42")
        XCTAssertEqual(profile.isNotifiedForPosts, true)
        XCTAssertEqual(profile.isFollowing, true)
        XCTAssertEqual(profile.followersCount, 40)
        XCTAssertEqual(profile.friendsCount, 142)
        XCTAssertEqual(profile.statusesCount, 301)
        XCTAssertEqual(profile.description, "Building things. https://alice.dev")
        XCTAssertEqual(profile.websiteURL, URL(string: "https://alice.dev/home"))
        XCTAssertNil(profile.location)
        XCTAssertNotNil(profile.createdAt)
    }

    func testMissingUserThrows() throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": ["user": [String: Any]()]])
        XCTAssertThrowsError(try XUserProfileParser.parse(data: data, screenName: "nobody"))
    }
}
