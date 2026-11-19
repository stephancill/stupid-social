import Foundation
@testable import StupidSocialCore
import XCTest

/// `UserTweets` and `UserMedia` pages in the shape `scripts/x-web-client.py user-tweets` / `user-media` record
/// (observed 2026-11-17).
final class XUserTimelineParserTests: XCTestCase {
    func testPostsPageTakesPinnedPostRepostsAndThreadsAndLeavesOutPromotedAndSuggestions() throws {
        let page = page([
            ["type": "TimelineClearCache"],
            ["type": "TimelinePinEntry", "entry": item("tweet-1", tweet(id: "1", user: "jack", text: "Pinned"))],
            ["type": "TimelineAddEntries", "entries": [
                item("tweet-2", repost(id: "2", by: "jack", of: tweet(id: "20", user: "alice", text: "Original", media: ["photo"]))),
                item("promoted-tweet-3", tweet(id: "3", user: "brand", text: "Ad")),
                ["entryId": "who-to-follow-4", "content": ["entryType": "TimelineTimelineModule", "items": [[String: Any]]()]],
                module("profile-conversation-5", [
                    tweet(id: "5", user: "jack", text: "Thread start"),
                    tweet(id: "6", user: "jack", text: "Thread end"),
                ]),
                item("tweet-1", tweet(id: "1", user: "jack", text: "Pinned")),
                cursor(type: "Top", value: "top"),
                cursor(type: "Bottom", value: "next"),
            ]],
        ])

        let timeline = try XUserTimelineParser.parse(data: page)

        XCTAssertEqual(timeline.items.map(\.id), ["1", "20", "5", "6"])
        XCTAssertTrue(timeline.items[0].isPinned)
        XCTAssertEqual(timeline.items[1].repostedBy, "Jack")
        XCTAssertEqual(timeline.items[1].post.target.author?.username, "alice")
        XCTAssertEqual(timeline.items[1].thumbnailURL, URL(string: "https://pbs.twimg.com/media/20-0.jpg"))
        XCTAssertNil(timeline.items[2].repostedBy)
        XCTAssertEqual(timeline.nextCursor, "next")
    }

    func testEngagementTakesBookmarks() throws {
        var post = tweet(id: "10", user: "jack", text: "Saved")
        var legacy = try XCTUnwrap(post["legacy"] as? [String: Any])
        legacy["bookmark_count"] = 26
        legacy["bookmarked"] = true
        post["legacy"] = legacy
        let page = page([["type": "TimelineAddEntries", "entries": [item("tweet-10", post)]]])

        let engagement = try XCTUnwrap(XUserTimelineParser.parse(data: page).items.first?.post.engagement)

        XCTAssertEqual(engagement.bookmarkCount, 26)
        XCTAssertTrue(engagement.isBookmarked)
        XCTAssertEqual(engagement.likeCount, 3)
    }

    func testLaterMediaPageAddsToTheGridAndUsesCardImages() throws {
        var card = tweet(id: "8", user: "jack", text: "A link")
        card["card"] = ["legacy": ["binding_values": [
            ["key": "player_image_large", "value": ["image_value": ["url": "https://pbs.twimg.com/card/8.jpg"]]],
        ]]]
        let page = page([
            ["type": "TimelineAddToModule", "moduleItems": [
                ["entryId": "profile-grid-0-tweet-7", "item": ["itemContent": ["tweet_results": ["result": tweet(id: "7", user: "jack", text: "Video", media: ["video", "photo"])]]]],
                ["entryId": "profile-grid-0-tweet-8", "item": ["itemContent": ["tweet_results": ["result": card]]]],
            ]],
            ["type": "TimelineAddEntries", "entries": [cursor(type: "Bottom", value: "more")]],
        ])

        let timeline = try XUserTimelineParser.parse(data: page)

        XCTAssertEqual(timeline.items.map(\.id), ["7", "8"])
        XCTAssertTrue(timeline.items[0].isVideo)
        XCTAssertTrue(timeline.items[0].hasMultipleMedia)
        XCTAssertEqual(timeline.items[1].thumbnailURL, URL(string: "https://pbs.twimg.com/card/8.jpg"))
        XCTAssertTrue(timeline.items[1].media.isEmpty)
        XCTAssertEqual(timeline.nextCursor, "more")
    }

    /// The viewer shows photos at X's large size and plays the best MP4 up to the full-screen bitrate.
    func testMediaTakesLargePhotosAndVideoVariants() throws {
        var post = tweet(id: "9", user: "jack", text: "Both")
        var legacy = try XCTUnwrap(post["legacy"] as? [String: Any])
        legacy["extended_entities"] = ["media": [
            ["type": "photo", "media_url_https": "https://pbs.twimg.com/media/9a.jpg", "original_info": ["width": 2000, "height": 1000], "ext_alt_text": "A view"],
            ["type": "video", "media_url_https": "https://pbs.twimg.com/ext_tw_video_thumb/9/pu/img/9b.jpg", "video_info": ["duration_millis": 5000, "variants": [
                ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/9.m3u8"],
                ["content_type": "video/mp4", "bitrate": 832_000, "url": "https://video.twimg.com/9-low.mp4"],
                ["content_type": "video/mp4", "bitrate": 2_176_000, "url": "https://video.twimg.com/9-high.mp4"],
                ["content_type": "video/mp4", "bitrate": 10_368_000, "url": "https://video.twimg.com/9-max.mp4"],
            ]]],
        ]]
        post["legacy"] = legacy
        let page = page([["type": "TimelineAddEntries", "entries": [item("tweet-9", post)]]])

        let media = try XCTUnwrap(XUserTimelineParser.parse(data: page).items.first?.media)

        XCTAssertEqual(media.count, 2)
        XCTAssertEqual(media[0].imageURL, URL(string: "https://pbs.twimg.com/media/9a.jpg?name=large"))
        XCTAssertNil(media[0].videoURL)
        XCTAssertEqual(media[0].aspectRatio, 2)
        XCTAssertEqual(media[0].altText, "A view")
        XCTAssertEqual(media[1].imageURL, URL(string: "https://pbs.twimg.com/ext_tw_video_thumb/9/pu/img/9b.jpg"))
        XCTAssertEqual(media[1].videoURL, URL(string: "https://video.twimg.com/9-high.mp4"))
        XCTAssertFalse(media[1].isGIF)
    }

    /// X returns a bottom cursor even past the last post.
    func testPageWithoutPostsEndsTheTimeline() throws {
        let page = page([["type": "TimelineAddEntries", "entries": [cursor(type: "Bottom", value: "again")]]])

        let timeline = try XUserTimelineParser.parse(data: page)

        XCTAssertTrue(timeline.items.isEmpty)
        XCTAssertNil(timeline.nextCursor)
    }

    // MARK: Fixtures

    private func page(_ instructions: [[String: Any]]) -> Data {
        let response: [String: Any] = [
            "data": ["user": ["result": ["__typename": "User", "timeline": ["timeline": ["instructions": instructions]]]]],
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private func item(_ entryId: String, _ tweet: [String: Any]) -> [String: Any] {
        ["entryId": entryId, "content": ["entryType": "TimelineTimelineItem", "itemContent": ["tweet_results": ["result": tweet]]]]
    }

    private func module(_ entryId: String, _ tweets: [[String: Any]]) -> [String: Any] {
        let items = tweets.enumerated().map { index, tweet in
            ["entryId": "\(entryId)-tweet-\(index)", "item": ["itemContent": ["tweet_results": ["result": tweet]]]]
        }
        return ["entryId": entryId, "content": ["entryType": "TimelineTimelineModule", "items": items]]
    }

    private func cursor(type: String, value: String) -> [String: Any] {
        ["entryId": "cursor-\(type.lowercased())-1", "content": ["entryType": "TimelineTimelineCursor", "cursorType": type, "value": value]]
    }

    private func repost(id: String, by user: String, of original: [String: Any]) -> [String: Any] {
        var post = tweet(id: id, user: user, text: "RT")
        var legacy = post["legacy"] as! [String: Any]
        legacy["retweeted_status_result"] = ["result": original]
        post["legacy"] = legacy
        return post
    }

    private func tweet(id: String, user: String, text: String, media: [String] = []) -> [String: Any] {
        var legacy: [String: Any] = [
            "full_text": text,
            "created_at": "Mon Nov 16 10:00:00 +0000 2026",
            "favorite_count": 3,
            "retweet_count": 1,
            "reply_count": 0,
            "quote_count": 0,
            "favorited": false,
            "retweeted": false,
        ]
        if !media.isEmpty {
            legacy["extended_entities"] = ["media": media.enumerated().map { index, type in
                ["type": type, "media_url_https": "https://pbs.twimg.com/media/\(id)-\(index).jpg"]
            }]
        }
        return [
            "__typename": "Tweet",
            "rest_id": id,
            "core": ["user_results": ["result": [
                "rest_id": "u-\(user)",
                "core": ["screen_name": user, "name": user.capitalized],
            ]]],
            "legacy": legacy,
        ]
    }
}
