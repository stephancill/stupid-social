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
        XCTAssertEqual(post.media.count, 1)
        XCTAssertEqual(post.media[0].kind, .video)
        XCTAssertEqual(post.media[0].videoURL?.absoluteString, "https://video.twimg.com/mid.mp4")
        XCTAssertEqual(post.media[0].aspectRatio ?? 0, 1280.0 / 720, accuracy: 0.001)
        XCTAssertEqual(post.media[0].durationMillis, 38966)

        guard case let .linkPreview(title, subtitle, link, media) = post.chatEmbed(link: nil) else { return XCTFail("Expected a link preview") }
        XCTAssertEqual(title, "Alice (@alice)")
        XCTAssertEqual(subtitle, "Look & see")
        XCTAssertEqual(link?.absoluteString, "https://x.com/alice/status/42")
        guard case let .video(url, poster, _, duration, isGIF) = media.first else { return XCTFail("Expected a video") }
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

        guard case let .linkPreview(_, subtitle, _, media) = post.chatEmbed(link: URL(string: "https://x.com/i/status/42")) else { return XCTFail("Expected a link preview") }
        XCTAssertNil(subtitle)
        guard case let .image(url, _, alt, _, opensViewer) = media[0] else { return XCTFail("Expected a photo") }
        XCTAssertEqual(url.absoluteString, "https://pbs.twimg.com/media/a.jpg")
        XCTAssertEqual(alt, "A cat")
        XCTAssertTrue(opensViewer)
        guard case let .video(url, _, _, duration, isGIF) = media[1] else { return XCTFail("Expected a GIF") }
        XCTAssertEqual(url.absoluteString, "https://video.twimg.com/b.mp4")
        XCTAssertNil(duration)
        XCTAssertTrue(isGIF)
    }

    func testTextOnlyPostIsACard() throws {
        var long = tweet(text: "Truncated…")
        long["note_tweet"] = ["note_tweet_results": ["result": ["text": "The whole long post"]]]
        let wrapped: [String: Any] = ["__typename": "TweetWithVisibilityResults", "tweet": long]
        let post = try XCTUnwrap(XPostParser.parse(data: page(wrapped)))

        guard case let .card(title, subtitle, _, _, link) = post.chatEmbed(link: URL(string: "https://x.com/i/status/42")) else { return XCTFail("Expected a card") }
        XCTAssertEqual(title, "Alice (@alice)")
        XCTAssertEqual(subtitle, "The whole long post")
        XCTAssertEqual(link?.absoluteString, "https://x.com/i/status/42")
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

    private func page(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["tweetResult": ["result": result]]])
    }

    private func tweet(text: String, range: [Int]? = nil, media: [[String: Any]] = []) -> [String: Any] {
        var legacy: [String: Any] = ["full_text": text, "favorite_count": 1]
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
            ]]],
            "legacy": legacy,
        ]
    }
}
