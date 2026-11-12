import Foundation
@testable import StupidSocialCore
import XCTest

/// `TweetResultByRestId` pages in the shape `scripts/x-web-client.py post-preview` reads (observed 2026-11-11).
final class XPostTests: XCTestCase {
    func testParsesAuthorTextAndVideo() throws {
        let video: [String: Any] = [
            "type": "video",
            "media_url_https": "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/poster.jpg",
            "original_info": ["width": 1280, "height": 720],
            "video_info": [
                "duration_millis": 38966,
                "variants": [
                    ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/1.m3u8"],
                    ["content_type": "video/mp4", "bitrate": 2_176_000, "url": "https://video.twimg.com/high.mp4"],
                    ["content_type": "video/mp4", "bitrate": 256_000, "url": "https://video.twimg.com/low.mp4"],
                    ["content_type": "video/mp4", "bitrate": 832_000, "url": "https://video.twimg.com/mid.mp4"],
                ],
            ],
        ]
        let post = try XCTUnwrap(XPostParser.parse(data: page(tweet(text: "Look &amp; see https://t.co/v", range: [0, 14], media: [video]))))

        XCTAssertEqual(post.id, "42")
        XCTAssertEqual(post.authorName, "Alice")
        XCTAssertEqual(post.screenName, "alice")
        XCTAssertEqual(post.text, "Look & see")
        XCTAssertEqual(post.avatarURL?.absoluteString, "https://pbs.twimg.com/profile_images/1/a_200x200.jpg")
        XCTAssertTrue(post.isVerified)
        XCTAssertEqual(post.postedAt, Date(timeIntervalSince1970: 1_666_940_433))
        XCTAssertEqual(post.media.count, 1)
        XCTAssertEqual(post.media[0].kind, .video)
        XCTAssertEqual(post.media[0].videoURL?.absoluteString, "https://video.twimg.com/mid.mp4")
        XCTAssertEqual(post.media[0].aspectRatio ?? 0, 1280.0 / 720, accuracy: 0.001)
        XCTAssertEqual(post.media[0].durationMillis, 38966)

        let card = try XCTUnwrap(chatPost(post.chatEmbed(link: nil)))
        XCTAssertEqual(card.authorName, "Alice")
        XCTAssertEqual(card.authorHandle, "@alice")
        XCTAssertTrue(card.isVerified)
        XCTAssertEqual(card.counts, ChatPost.Counts(replies: 3, reposts: 5, likes: 1))
        XCTAssertEqual(card.text, "Look & see")
        XCTAssertEqual(card.link?.absoluteString, "https://x.com/alice/status/42")
        guard case let .video(url, poster, _, duration, isGIF) = card.media.first else { return XCTFail("Expected a video") }
        XCTAssertEqual(url.absoluteString, "https://video.twimg.com/mid.mp4")
        XCTAssertEqual(poster?.absoluteString, "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/poster.jpg")
        XCTAssertEqual(duration, "0:38")
        XCTAssertFalse(isGIF)
    }

    func testPhotosAndGIFs() throws {
        let photo: [String: Any] = ["type": "photo", "media_url_https": "https://pbs.twimg.com/media/a.jpg", "original_info": ["width": 2048, "height": 1364], "ext_alt_text": "A cat"]
        let gif: [String: Any] = [
            "type": "animated_gif",
            "media_url_https": "https://pbs.twimg.com/tweet_video_thumb/b.jpg",
            "video_info": ["variants": [["content_type": "video/mp4", "bitrate": 0, "url": "https://video.twimg.com/b.mp4"]]],
        ]
        let post = try XCTUnwrap(XPostParser.parse(data: page(tweet(text: "", media: [photo, gif]))))

        let card = try XCTUnwrap(chatPost(post.chatEmbed(link: URL(string: "https://x.com/i/status/42"))))
        XCTAssertEqual(card.text, "")
        XCTAssertEqual(card.link?.absoluteString, "https://x.com/i/status/42")
        guard case let .image(url, _, alt, _, opensViewer) = card.media[0] else { return XCTFail("Expected a photo") }
        XCTAssertEqual(url.absoluteString, "https://pbs.twimg.com/media/a.jpg")
        XCTAssertEqual(alt, "A cat")
        XCTAssertTrue(opensViewer)
        guard case let .video(url, _, _, duration, isGIF) = card.media[1] else { return XCTFail("Expected a GIF") }
        XCTAssertEqual(url.absoluteString, "https://video.twimg.com/b.mp4")
        XCTAssertNil(duration)
        XCTAssertTrue(isGIF)
    }

    func testLongPostsUseTheirWholeText() throws {
        var long = tweet(text: "Truncated…")
        long["note_tweet"] = ["note_tweet_results": ["result": ["text": "The whole long post"]]]
        let wrapped: [String: Any] = ["__typename": "TweetWithVisibilityResults", "tweet": long]
        let post = try XCTUnwrap(XPostParser.parse(data: page(wrapped)))

        XCTAssertEqual(try XCTUnwrap(chatPost(post.chatEmbed(link: nil))).text, "The whole long post")
    }

    /// The quoted post's t.co link leaves the text, which the quote shows instead; other links show as X shows them.
    func testQuotedPostAndLinks() throws {
        var quoting = tweet(text: "Read https://t.co/a then this https://t.co/q")
        var legacy = try XCTUnwrap(quoting["legacy"] as? [String: Any])
        legacy["entities"] = ["urls": [["url": "https://t.co/a", "display_url": "example.com/a…", "expanded_url": "https://example.com/a/long"]]]
        legacy["quoted_status_permalink"] = ["url": "https://t.co/q", "expanded": "https://twitter.com/bob/status/9"]
        quoting["legacy"] = legacy
        var quoted = tweet(text: "Original", media: [["type": "photo", "media_url_https": "https://pbs.twimg.com/media/q.jpg"]])
        quoted["rest_id"] = "9"
        quoted["core"] = ["user_results": ["result": ["rest_id": "8", "core": ["name": "Bob", "screen_name": "bob"]]]]
        quoting["quoted_status_result"] = ["result": ["__typename": "TweetWithVisibilityResults", "tweet": quoted]]
        let post = try XCTUnwrap(XPostParser.parse(data: page(quoting)))

        XCTAssertEqual(post.text, "Read example.com/a… then this")
        let card = try XCTUnwrap(chatPost(post.chatEmbed(link: nil)))
        XCTAssertEqual(card.quoted?.authorName, "Bob")
        XCTAssertEqual(card.quoted?.authorHandle, "@bob")
        XCTAssertEqual(card.quoted?.text, "Original")
        XCTAssertEqual(card.quoted?.link?.absoluteString, "https://x.com/bob/status/9")
        XCTAssertEqual(card.quoted?.media.count, 1)
        XCTAssertEqual(card.quoted?.isVerified, false)
    }

    func testUnavailablePostIsNil() throws {
        let tombstone = try JSONSerialization.data(withJSONObject: ["data": ["tweetResult": ["result": ["__typename": "TweetTombstone"]]]])
        XCTAssertNil(try XPostParser.parse(data: tombstone))
        let empty = try JSONSerialization.data(withJSONObject: ["data": ["tweetResult": [:]]])
        XCTAssertNil(try XPostParser.parse(data: empty))
    }

    func testIdInPostLinks() throws {
        let ids = [
            "https://x.com/alice/status/42",
            "https://twitter.com/alice/status/42?s=20",
            "https://x.com/i/status/42",
            "https://x.com/i/web/status/42",
            "https://mobile.twitter.com/alice/status/42/photo/1",
        ].map { XPost.id(in: URL(string: $0)!) }
        XCTAssertEqual(ids, Array(repeating: "42", count: 5))
        XCTAssertNil(try XPost.id(in: XCTUnwrap(URL(string: "https://x.com/alice"))))
        XCTAssertNil(try XPost.id(in: XCTUnwrap(URL(string: "https://example.com/alice/status/42"))))
        XCTAssertNil(try XPost.id(in: XCTUnwrap(URL(string: "https://x.com/alice/status/abc"))))
    }

    // MARK: Fixtures

    private func chatPost(_ embed: ChatEmbed) -> ChatPost? {
        if case let .post(post) = embed { post } else { nil }
    }

    private func page(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["tweetResult": ["result": result]]])
    }

    private func tweet(text: String, range: [Int]? = nil, media: [[String: Any]] = []) -> [String: Any] {
        var legacy: [String: Any] = ["full_text": text, "favorite_count": 1, "reply_count": 3, "retweet_count": 5, "quote_count": 2, "created_at": "Fri Oct 28 07:00:33 +0000 2022"]
        if let range {
            legacy["display_text_range"] = range
        }
        if !media.isEmpty {
            legacy["extended_entities"] = ["media": media]
        }
        return [
            "__typename": "Tweet",
            "rest_id": "42",
            "core": ["user_results": ["result": [
                "rest_id": "7",
                "core": ["name": "Alice", "screen_name": "alice"],
                "avatar": ["image_url": "https://pbs.twimg.com/profile_images/1/a_normal.jpg"],
                "is_blue_verified": true,
            ]]],
            "legacy": legacy,
        ]
    }
}
