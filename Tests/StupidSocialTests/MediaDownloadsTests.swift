import Foundation
@testable import StupidSocialCore
import XCTest

/// The media viewer saves the original file: a video as its MP4, named for its type.
final class MediaDownloadsTests: XCTestCase {
    func testABlueskyPlaylistStandsForItsUploadedVideo() throws {
        let playlist = try XCTUnwrap(URL(string: "https://video.bsky.app/watch/did%3Aplc%3Az72i7hdynmk6r22z27h6tvur/bafkreiapzm/playlist.m3u8"))
        let video = try XCTUnwrap(MediaDownloads.blueskyVideo(playlist))
        XCTAssertEqual(video.did, "did:plc:z72i7hdynmk6r22z27h6tvur")
        XCTAssertEqual(video.cid, "bafkreiapzm")
        XCTAssertNil(try MediaDownloads.blueskyVideo(XCTUnwrap(URL(string: "https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/a.mp4"))))
    }

    func testFilesAreNamedForTheirType() throws {
        let mp4 = try URLResponse(url: XCTUnwrap(URL(string: "https://example.com/blob")), mimeType: "video/mp4", expectedContentLength: 1, textEncodingName: nil)
        XCTAssertEqual(try MediaDownloads.fileExtension(response: mp4, source: XCTUnwrap(URL(string: "https://example.com/xrpc/com.atproto.sync.getBlob"))), "mp4")
        let unknown = try URLResponse(url: XCTUnwrap(URL(string: "https://example.com/a")), mimeType: "application/octet-stream", expectedContentLength: 1, textEncodingName: nil)
        XCTAssertEqual(try MediaDownloads.fileExtension(response: unknown, source: XCTUnwrap(URL(string: "https://example.com/clip.MP4"))), "mp4")
        XCTAssertEqual(try MediaDownloads.fileExtension(response: unknown, source: XCTUnwrap(URL(string: "https://example.com/photo"))), "jpg")
    }

    func testAnyPostIdMakesAFileName() {
        XCTAssertEqual(MediaDownloads.fileName("bluesky-https://bsky.app/profile/a/post/3x-1"), "bluesky-https---bsky-app-profile-a-post-3x-1")
        XCTAssertEqual(MediaDownloads.fileName(""), "media")
    }
}
