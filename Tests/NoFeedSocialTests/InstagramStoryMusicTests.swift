@testable import NoFeedSocialCore
import XCTest

final class InstagramStoryMusicTests: XCTestCase {
    func testMusicStickerDecodesWithoutArtwork() throws {
        let json = #"""
        {
          "music_asset_info": {
            "display_artist": "Olivia Rodrigo",
            "should_mute_audio": false,
            "should_mute_audio_reason": "",
            "title": "honeybee"
          }
        }
        """#.data(using: .utf8)!

        let sticker = try JSONDecoder().decode(InstagramStoryMusicSticker.self, from: json)

        XCTAssertEqual(sticker.music?.title, "honeybee")
        XCTAssertEqual(sticker.music?.artist, "Olivia Rodrigo")
        XCTAssertNil(sticker.music?.artworkURL)
    }

    func testMusicStickerDecodesArtworkURLVariant() throws {
        let json = #"""
        {
          "music_asset_info": {
            "display_artist": "Artist",
            "title": "Track",
            "cover_artwork_thumbnail_url": "https://example.com/art.jpg"
          }
        }
        """#.data(using: .utf8)!

        let sticker = try JSONDecoder().decode(InstagramStoryMusicSticker.self, from: json)

        XCTAssertEqual(sticker.music?.artworkURL, URL(string: "https://example.com/art.jpg"))
    }
}
