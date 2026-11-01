import Foundation
@testable import StupidSocialCore
import XCTest

/// `TweetDetail` pages in the shape `scripts/x-web-client.py thread` records (observed 2026-10-31).
final class XThreadParserTests: XCTestCase {
    func testTakesAncestorsAndFocalAndLeavesOutReplies() throws {
        let page = page(entries: [
            item("tweet-1", tweet(id: "1", user: "alice", text: "Root post")),
            item("tweet-2", tweet(id: "2", user: "bob", text: "@alice Middle", range: [7, 13])),
            item("tweet-3", tweet(id: "3", user: "carol", text: "@bob Focal &amp; more https://t.co/media", range: [5, 21], liked: true)),
            module("conversationthread-4", [
                tweet(id: "4", user: "dave", text: "First reply"),
                tweet(id: "5", user: "carol", text: "Answer"),
            ]),
            module("conversationthread-6", [tweet(id: "6", user: "erin", text: "Second reply")]),
            cursor("cursor-bottom-7", type: "Bottom", value: "next-page"),
        ])

        let thread = try XThreadParser.parse(data: page, focalId: "3")

        XCTAssertEqual(thread.ancestors.map(\.target.id), ["1", "2"])
        XCTAssertEqual(thread.ancestors[1].target.text, "Middle")
        XCTAssertEqual(thread.focal?.target.id, "3")
        XCTAssertEqual(thread.focal?.target.text, "Focal & more")
        XCTAssertEqual(thread.focal?.target.author?.username, "carol")
        XCTAssertEqual(thread.focal?.engagement?.isLiked, true)
        XCTAssertEqual(thread.focal?.engagement?.likeCount, 7)
    }

    func testPostWithoutAncestorsHasNone() throws {
        let page = page(entries: [
            item("tweet-3", tweet(id: "3", user: "carol", text: "Standalone")),
            module("conversationthread-4", [tweet(id: "4", user: "dave", text: "Reply")]),
        ])

        let thread = try XThreadParser.parse(data: page, focalId: "3")

        XCTAssertTrue(thread.ancestors.isEmpty)
        XCTAssertEqual(thread.focal?.target.text, "Standalone")
    }

    func testLongPostUsesNoteText() throws {
        var long = tweet(id: "9", user: "gina", text: "Truncated…")
        long["note_tweet"] = ["note_tweet_results": ["result": ["text": "The whole long post"]]]
        let thread = try XThreadParser.parse(data: page(entries: [item("tweet-9", long)]), focalId: "9")

        XCTAssertEqual(thread.focal?.target.text, "The whole long post")
    }

    func testUnwrapsPostsWithVisibilityResults() throws {
        let wrapped: [String: Any] = ["__typename": "TweetWithVisibilityResults", "tweet": tweet(id: "10", user: "hal", text: "Limited")]
        let thread = try XThreadParser.parse(data: page(entries: [item("tweet-10", wrapped)]), focalId: "10")

        XCTAssertEqual(thread.focal?.target.text, "Limited")
    }

    // MARK: Fixtures

    private func page(entries: [[String: Any]]) -> Data {
        let response: [String: Any] = [
            "data": [
                "threaded_conversation_with_injections_v2": [
                    "instructions": [
                        ["type": "TimelineClearCache"],
                        ["type": "TimelineAddEntries", "entries": entries],
                    ],
                ],
            ],
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

    private func cursor(_ entryId: String, type: String, value: String) -> [String: Any] {
        ["entryId": entryId, "content": ["entryType": "TimelineTimelineCursor", "cursorType": type, "value": value]]
    }

    private func tweet(id: String, user: String, text: String, range: [Int]? = nil, liked: Bool = false) -> [String: Any] {
        [
            "__typename": "Tweet",
            "rest_id": id,
            "core": ["user_results": ["result": [
                "rest_id": "u-\(user)",
                "core": ["screen_name": user, "name": user.capitalized],
                "avatar": ["image_url": "https://pbs.twimg.com/profile_images/1/\(user)_normal.jpg"],
            ]]],
            "legacy": [
                "full_text": text,
                "display_text_range": range ?? [0, text.unicodeScalars.count],
                "created_at": "Mon Oct 26 10:00:00 +0000 2026",
                "favorite_count": 7,
                "retweet_count": 1,
                "reply_count": 2,
                "quote_count": 0,
                "favorited": liked,
                "retweeted": false,
            ],
        ]
    }
}
