@testable import NoFeedSocialCore
import XCTest

final class InstagramNotificationDecodingTests: XCTestCase {
    func testDecodesNewsStoryWithStringProfileIds() throws {
        let json = #"""
        {
          "old_stories": [
            {
              "pk": "6810e562229487cc55184f369b248bef",
              "notif_name": "story_like",
              "story_type": 651,
              "args": {
                "rich_text": "{alice|#|bold|user?id=123} and {bob|#|bold|user?id=456} liked your story.",
                "profile_id": "123",
                "profile_name": "alice",
                "profile_image": "https://example.com/alice.jpg",
                "second_profile_id": "456",
                "second_profile_image": "https://example.com/bob.jpg",
                "timestamp": 1784028955.3639514,
                "media": [
                  {
                    "id": "3940978710857393634_3022481654",
                    "image": "https://example.com/story.jpg"
                  }
                ]
              },
              "counts": {}
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(InstagramNewsInboxResponse.self, from: json)
        let items = InstagramNotificationParser.parse(
            stories: response.oldStories ?? [],
            accountId: "70150151668",
            accountUsername: "stephancill",
            accountAvatarURL: URL(string: "https://example.com/me.jpg"),
            enabledCategories: Set(InstagramNotificationCategory.allCases),
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].network, .instagram)
        XCTAssertEqual(items[0].actors.map(\.id), ["123", "456"])
        XCTAssertEqual(items[0].text, "alice and 1 other liked your story")
        XCTAssertEqual(items[0].target?.author?.id, "70150151668")
        XCTAssertEqual(items[0].target?.author?.username, "stephancill")
        XCTAssertEqual(items[0].target?.author?.avatarURL, URL(string: "https://example.com/me.jpg"))
    }
}
