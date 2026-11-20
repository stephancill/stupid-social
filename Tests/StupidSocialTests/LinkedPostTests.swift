import Foundation
@testable import StupidSocialCore
import XCTest

/// Links to posts draw as the post in every chat; posts chats have shown are kept on disk, so later launches draw them
/// without loading.
@MainActor
final class LinkedPostTests: XCTestCase {
    private let url = FileManager.default.temporaryDirectory.appending(path: "LinkedPostTests-\(UUID().uuidString).json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Resolver and cache

    func testAKeptPostDrawsOnTheNextLaunchWithoutLoading() async throws {
        let first = LinkedPostResolver(sources: [source(loads: LoadCounter())], cache: LinkedPostCache(url: url))
        XCTAssertNil(first.embed(for: link("1")), "nothing kept yet")
        try await waitForFile()

        let loads = LoadCounter()
        let next = LinkedPostResolver(sources: [source(loads: loads)], cache: LinkedPostCache(url: url))
        _ = next.embed(for: link("1"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(next.post("x:1"), .x(post("1")))
        let count = await loads.count
        XCTAssertEqual(count, 0)
    }

    func testAStalePostShowsAndLoadsAgainOnce() async throws {
        let cache = LinkedPostCache(url: url)
        await cache.ready()
        cache.insert(.x(post("1", text: "old")), id: "x:1", at: Date(timeIntervalSinceNow: -2 * LinkedPostCache.staleAfter))
        let loads = LoadCounter()
        let resolver = LinkedPostResolver(sources: [source(loads: loads, text: "new")], cache: cache)
        XCTAssertNotNil(resolver.embed(for: link("1")), "a stale post still shows")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resolver.post("x:1"), .x(post("1", text: "new")))
        cache.insert(.x(post("1", text: "old")), id: "x:1", at: Date(timeIntervalSinceNow: -2 * LinkedPostCache.staleAfter))
        _ = resolver.embed(for: link("1"))
        try await Task.sleep(for: .milliseconds(200))
        let count = await loads.count
        XCTAssertEqual(count, 1, "once a session")
    }

    func testLinksNoSourceKnowsAreLeftAlone() throws {
        let resolver = LinkedPostResolver(sources: [source(loads: LoadCounter())], cache: LinkedPostCache(url: url))
        XCTAssertNil(try resolver.embed(for: XCTUnwrap(URL(string: "https://example.com/status/1"))))
    }

    func testOldAndLeastRecentPostsAreDropped() {
        let now = Date()
        var entries: [String: LinkedPostCache.Entry] = [:]
        for index in 0 ..< LinkedPostCache.limit + 5 {
            entries["\(index)"] = .init(post: .x(post("\(index)")), loadedAt: now.addingTimeInterval(-Double(index)))
        }
        entries["old"] = .init(post: .x(post("old")), loadedAt: now.addingTimeInterval(-LinkedPostCache.maxAge - 1))
        let kept = LinkedPostCache.pruned(entries, now: now)
        XCTAssertEqual(kept.count, LinkedPostCache.limit)
        XCTAssertNil(kept["old"])
        XCTAssertNil(kept["\(LinkedPostCache.limit)"], "the least recently loaded go first")
        XCTAssertNotNil(kept["0"])
    }

    // MARK: Instagram

    func testInstagramShortcodesInLinks() throws {
        XCTAssertEqual(try InstagramPost.shortcode(in: XCTUnwrap(URL(string: "https://www.instagram.com/p/BsOGulcndj-/"))), "BsOGulcndj-")
        XCTAssertEqual(try InstagramPost.shortcode(in: XCTUnwrap(URL(string: "https://instagram.com/reel/C1a2b3c4d5e/?igsh=abc"))), "C1a2b3c4d5e")
        XCTAssertEqual(try InstagramPost.shortcode(in: XCTUnwrap(URL(string: "https://www.instagram.com/someone/p/BsOGulcndj-/"))), "BsOGulcndj-")
        XCTAssertNil(try InstagramPost.shortcode(in: XCTUnwrap(URL(string: "https://www.instagram.com/someone/"))))
        XCTAssertNil(try InstagramPost.shortcode(in: XCTUnwrap(URL(string: "https://example.com/p/BsOGulcndj-/"))))
    }

    func testInstagramMediaIdFromShortcode() {
        // As the probe computes it (scripts/instagram-web-client.py media_id_from_shortcode).
        XCTAssertEqual(InstagramPost.mediaId(shortcode: "BsOGulcndj-"), "1949525278281554174")
    }

    func testInstagramPhotoPost() throws {
        let post = try XCTUnwrap(InstagramPost.parse(data: Data(Self.instagramPhoto.utf8), shortcode: "BsOGulcndj-"))
        XCTAssertEqual(post.username, "world_record_egg")
        XCTAssertEqual(post.fullName, "Just An Egg")
        XCTAssertTrue(post.isVerified)
        XCTAssertEqual(post.caption, "Let's set a world record together")
        XCTAssertEqual(post.postedAt, Date(timeIntervalSince1970: 1_546_621_545))
        XCTAssertEqual(post.media.map(\.imageURL.absoluteString), ["https://scontent.example/egg-1080.jpg"], "the widest candidate")
        XCTAssertEqual(post.media.first?.aspectRatio, 1)
        XCTAssertEqual(post.likeCount, 60_225_293)
        XCTAssertEqual(post.commentCount, 3_763_534)
        guard case let .post(card) = post.chatEmbed(link: nil) else { return XCTFail("a post") }
        XCTAssertEqual(card.authorHandle, "@world_record_egg")
        XCTAssertEqual(card.link, URL(string: "https://www.instagram.com/p/BsOGulcndj-/"))
        XCTAssertEqual(card.counts, ChatPost.Counts(replies: 3_763_534, reposts: nil, likes: 60_225_293))
    }

    func testInstagramCarouselWithAVideoAndHiddenLikes() throws {
        let post = try XCTUnwrap(InstagramPost.parse(data: Data(Self.instagramCarousel.utf8), shortcode: "C1a2b3c4d5e"))
        XCTAssertEqual(post.media.count, 2)
        XCTAssertNil(post.media[0].videoURL)
        XCTAssertEqual(post.media[1].videoURL?.absoluteString, "https://scontent.example/clip.mp4")
        XCTAssertEqual(post.media[1].aspectRatio, 0.5625)
        XCTAssertNil(post.likeCount, "the author hides likes")
        XCTAssertEqual(post.fullName, nil, "an empty name shows the username")
    }

    // MARK: Bluesky

    func testBlueskyReferencesInLinks() throws {
        let reference = try BlueskyPost.reference(in: XCTUnwrap(URL(string: "https://bsky.app/profile/bsky.app/post/3n2m24be4e223")))
        XCTAssertEqual(reference?.actor, "bsky.app")
        XCTAssertEqual(reference?.rkey, "3n2m24be4e223")
        XCTAssertEqual(try BlueskyPost.reference(in: XCTUnwrap(URL(string: "https://bsky.app/profile/did:plc:abc/post/3abc")))?.actor, "did:plc:abc")
        XCTAssertNil(try BlueskyPost.reference(in: XCTUnwrap(URL(string: "https://bsky.app/profile/bsky.app"))))
    }

    func testBlueskyImagesPost() throws {
        let post = try XCTUnwrap(BlueskyPost.parse(data: Data(Self.blueskyImages.utf8)))
        XCTAssertEqual(post.handle, "bsky.app")
        XCTAssertEqual(post.displayName, "Bluesky")
        XCTAssertEqual(post.rkey, "3n2m24be4e223")
        XCTAssertFalse(post.isVerified)
        XCTAssertEqual(post.media.map(\.imageURL.absoluteString), ["https://cdn.bsky.app/img/feed_fullsize/plain/a"])
        XCTAssertEqual(post.media.first?.alt, "A graphic")
        XCTAssertEqual(post.media.first?.aspectRatio, 2)
        XCTAssertEqual(post.likeCount, 2417)
        XCTAssertNotNil(post.postedAt)
        guard case let .post(card) = post.chatEmbed(link: nil) else { return XCTFail("a post") }
        XCTAssertEqual(card.link, URL(string: "https://bsky.app/profile/bsky.app/post/3n2m24be4e223"))
        XCTAssertEqual(card.counts, ChatPost.Counts(replies: 134, reposts: 505, likes: 2417))
    }

    func testBlueskyVideoPost() throws {
        let post = try XCTUnwrap(BlueskyPost.parse(data: Data(Self.blueskyVideo.utf8)))
        XCTAssertEqual(post.media.first?.videoURL?.absoluteString, "https://video.bsky.app/watch/v/playlist.m3u8")
        XCTAssertEqual(post.media.first?.imageURL.absoluteString, "https://video.bsky.app/watch/v/thumbnail.jpg")
        XCTAssertTrue(post.isVerified)
    }

    func testBlueskyQuoteWithMedia() throws {
        let post = try XCTUnwrap(BlueskyPost.parse(data: Data(Self.blueskyQuoteWithMedia.utf8)))
        XCTAssertEqual(post.media.count, 1, "the post's own media")
        XCTAssertEqual(post.quoted?.handle, "alice.example")
        XCTAssertEqual(post.quoted?.text, "the quoted post")
        XCTAssertEqual(post.quoted?.media.first?.imageURL.absoluteString, "https://cdn.bsky.app/img/feed_fullsize/plain/q")
    }

    func testBlueskyQuoteOfAMissingPostHasNone() throws {
        let post = try XCTUnwrap(BlueskyPost.parse(data: Data(Self.blueskyQuoteNotFound.utf8)))
        XCTAssertNil(post.quoted)
    }

    // MARK: Helpers

    private func waitForFile() async throws {
        for _ in 0 ..< 40 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func link(_ id: String) -> URL {
        URL(string: "https://x.com/ada/status/\(id)")!
    }

    private func source(loads: LoadCounter, text: String? = nil) -> LinkedPostSource {
        LinkedPostSource(network: "x", key: { XPost.id(in: $0) }, load: { id in
            await loads.increment()
            return .x(post(id, text: text))
        })
    }

    // MARK: Fixtures (shapes from the probes' post-preview, values made up)

    private static let instagramPhoto = """
    {"status": "ok", "items": [{"code": "BsOGulcndj-", "taken_at": 1546621545, "media_type": 1, "like_count": 60225293,
     "comment_count": 3763534, "like_and_view_counts_disabled": false, "original_width": 584, "original_height": 584,
     "caption": {"text": "Let's set a world record together"},
     "image_versions2": {"candidates": [{"url": "https://scontent.example/egg-320.jpg", "width": 320, "height": 320},
                                        {"url": "https://scontent.example/egg-1080.jpg", "width": 1080, "height": 1080}]},
     "user": {"pk": "1", "username": "world_record_egg", "full_name": "Just An Egg", "is_verified": true,
              "profile_pic_url": "https://scontent.example/egg-avatar.jpg"}}]}
    """

    private static let instagramCarousel = """
    {"status": "ok", "items": [{"code": "C1a2b3c4d5e", "taken_at": 1700000000, "media_type": 8, "like_count": 10,
     "comment_count": 2, "like_and_view_counts_disabled": true, "caption": null,
     "carousel_media": [
       {"media_type": 1, "original_width": 1080, "original_height": 1350,
        "image_versions2": {"candidates": [{"url": "https://scontent.example/one.jpg", "width": 1080, "height": 1350}]}},
       {"media_type": 2, "original_width": 720, "original_height": 1280, "video_duration": 12.5,
        "image_versions2": {"candidates": [{"url": "https://scontent.example/clip.jpg", "width": 720, "height": 1280}]},
        "video_versions": [{"url": "https://scontent.example/clip.mp4", "width": 720, "height": 1280}]}],
     "user": {"pk": 2, "username": "someone", "full_name": "", "is_verified": false}}]}
    """

    private static let blueskyImages = """
    {"posts": [{"uri": "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3n2m24be4e223",
      "author": {"did": "did:plc:z72i7hdynmk6r22z27h6tvur", "handle": "bsky.app", "displayName": "Bluesky",
                 "avatar": "https://cdn.bsky.app/img/avatar/plain/b", "verification": {"verifiedStatus": "none"}},
      "record": {"$type": "app.bsky.feed.post", "text": "Something new", "createdAt": "2026-11-18T17:05:26.596Z"},
      "embed": {"$type": "app.bsky.embed.images#view", "images": [{"alt": "A graphic", "aspectRatio": {"width": 2400, "height": 1200},
                "fullsize": "https://cdn.bsky.app/img/feed_fullsize/plain/a", "thumb": "https://cdn.bsky.app/img/feed_thumbnail/plain/a"}]},
      "replyCount": 134, "repostCount": 505, "quoteCount": 139, "likeCount": 2417}]}
    """

    private static let blueskyVideo = """
    {"posts": [{"uri": "at://did:plc:a/app.bsky.feed.post/3n2opitysuc2j",
      "author": {"did": "did:plc:a", "handle": "news.example", "verification": {"verifiedStatus": "valid"}},
      "record": {"text": "Watch", "createdAt": "2026-11-19T18:33:36Z"},
      "embed": {"$type": "app.bsky.embed.video#view", "aspectRatio": {"height": 1620, "width": 1080}, "alt": "A video",
                "playlist": "https://video.bsky.app/watch/v/playlist.m3u8", "thumbnail": "https://video.bsky.app/watch/v/thumbnail.jpg"},
      "replyCount": 37, "repostCount": 84, "likeCount": 865}]}
    """

    private static let blueskyQuoteWithMedia = """
    {"posts": [{"uri": "at://did:plc:b/app.bsky.feed.post/3quote",
      "author": {"did": "did:plc:b", "handle": "bob.example", "displayName": "Bob"},
      "record": {"text": "Look at this", "createdAt": "2026-11-01T10:00:00Z"},
      "embed": {"$type": "app.bsky.embed.recordWithMedia#view",
        "media": {"$type": "app.bsky.embed.images#view", "images": [{"fullsize": "https://cdn.bsky.app/img/feed_fullsize/plain/m", "alt": ""}]},
        "record": {"record": {"$type": "app.bsky.embed.record#viewRecord", "uri": "at://did:plc:c/app.bsky.feed.post/3orig",
          "author": {"did": "did:plc:c", "handle": "alice.example"},
          "value": {"$type": "app.bsky.feed.post", "text": "the quoted post", "createdAt": "2026-10-31T09:00:00Z"},
          "embeds": [{"$type": "app.bsky.embed.images#view", "images": [{"fullsize": "https://cdn.bsky.app/img/feed_fullsize/plain/q"}]}],
          "likeCount": 3}}},
      "replyCount": 0, "repostCount": 1, "likeCount": 4}]}
    """

    private static let blueskyQuoteNotFound = """
    {"posts": [{"uri": "at://did:plc:b/app.bsky.feed.post/3gone",
      "author": {"did": "did:plc:b", "handle": "bob.example"},
      "record": {"text": "Quoting", "createdAt": "2026-11-01T10:00:00Z"},
      "embed": {"$type": "app.bsky.embed.record#view",
        "record": {"$type": "app.bsky.embed.record#viewNotFound", "uri": "at://did:plc:c/app.bsky.feed.post/3x", "notFound": true}}}]}
    """
}

private func post(_ id: String, text: String? = nil) -> XPost {
    XPost(id: id, authorName: "Ada", screenName: "ada", text: text ?? "post \(id)", quoted: XPost(id: "q", authorName: "Bo", screenName: "bo", text: "quoted"))
}

private actor LoadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
