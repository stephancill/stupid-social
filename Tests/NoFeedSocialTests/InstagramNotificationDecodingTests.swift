@testable import NoFeedSocialCore
import XCTest

final class InstagramNotificationDecodingTests: XCTestCase {
    func testDecodesTopSearchUserWithStringPk() throws {
        let json = #"""
        {
          "status": "ok",
          "users": [
            {
              "position": 0,
              "user": {
                "id": "70150151668",
                "pk": "70150151668",
                "username": "stephancill",
                "full_name": "Stephan Cilliers",
                "profile_pic_url": "https://example.com/avatar.jpg",
                "is_verified": false,
                "is_private": true
              }
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(InstagramTopSearchResponse.self, from: json)

        XCTAssertEqual(response.users.count, 1)
        XCTAssertEqual(response.users[0].user.pk, 70_150_151_668)
        XCTAssertEqual(response.users[0].user.username, "stephancill")
        XCTAssertEqual(response.users[0].user.fullName, "Stephan Cilliers")
    }

    func testDecodesUserFeedPostsWithStringAndNumericIds() throws {
        let json = #"""
        {
          "status": "ok",
          "more_available": true,
          "next_max_id": "3924926324435168551_300947541",
          "items": [
            {
              "id": "3940978710857393634_300947541",
              "pk": "3940978710857393634",
              "code": "DapRPZHCe1A",
              "taken_at": 1784028955,
              "media_type": 8,
              "caption": { "text": "hello" },
              "user": {
                "pk": "300947541",
                "username": "stephaniekeenan_",
                "full_name": "Stephanie Keenan",
                "profile_pic_url": "https://example.com/avatar.jpg"
              },
              "carousel_media": [
                {
                  "id": 3940978710857393635,
                  "pk": 3940978710857393635,
                  "media_type": 1,
                  "image_versions2": {
                    "candidates": [
                      { "url": "https://example.com/small.jpg", "width": 320, "height": 320 },
                      { "url": "https://example.com/large.jpg", "width": 1080, "height": 1080 }
                    ]
                  }
                },
                {
                  "id": "3940978710857393636",
                  "pk": "3940978710857393636",
                  "media_type": 2,
                  "image_versions2": {
                    "candidates": [
                      { "url": "https://example.com/video-cover.jpg", "width": 640, "height": 640 }
                    ]
                  },
                  "video_versions": [
                    { "url": "https://example.com/video-low.mp4", "width": 360, "height": 360 },
                    { "url": "https://example.com/video-high.mp4", "width": 720, "height": 720 }
                  ]
                }
              ]
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(InstagramUserFeedResponse.self, from: json)
        let post = try XCTUnwrap(response.items.first?.profilePost)

        XCTAssertEqual(response.nextMaxId, "3924926324435168551_300947541")
        XCTAssertEqual(response.moreAvailable, true)
        XCTAssertEqual(post.id, "3940978710857393634_300947541")
        XCTAssertEqual(post.imageURL, URL(string: "https://example.com/large.jpg"))
        XCTAssertEqual(post.thumbnailURL, URL(string: "https://example.com/small.jpg"))
        XCTAssertEqual(post.url, URL(string: "https://www.instagram.com/p/DapRPZHCe1A/"))
        XCTAssertEqual(post.caption, "hello")
        XCTAssertFalse(post.isVideo)
        XCTAssertTrue(post.isCarousel)
        XCTAssertEqual(post.media.count, 2)
        XCTAssertEqual(post.media[0].imageURL, URL(string: "https://example.com/large.jpg"))
        XCTAssertFalse(post.media[0].isVideo)
        XCTAssertEqual(post.media[1].imageURL, URL(string: "https://example.com/video-cover.jpg"))
        XCTAssertEqual(post.media[1].videoURL, URL(string: "https://example.com/video-high.mp4"))
        XCTAssertTrue(post.media[1].isVideo)
    }

    func testDecodesUserFeedPostWhenOptionalVideoMetadataIsMalformed() throws {
        let json = #"""
        {
          "status": "ok",
          "items": [
            {
              "id": "3940978710857393634_300947541",
              "pk": "3940978710857393634",
              "code": "DapRPZHCe1A",
              "media_type": 1,
              "image_versions2": {
                "candidates": [
                  { "url": "https://example.com/post.jpg", "width": 1080, "height": 1080 }
                ]
              },
              "video_versions": [
                { "width": 720, "height": 720 }
              ]
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(InstagramUserFeedResponse.self, from: json)
        let post = try XCTUnwrap(response.items.first?.profilePost)

        XCTAssertEqual(post.imageURL, URL(string: "https://example.com/post.jpg"))
        XCTAssertEqual(post.media.count, 1)
    }

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
