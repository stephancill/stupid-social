import Foundation
@testable import NoFeedSocialCore
import XCTest

/// Custom emoji (EXTENSIONS.md `ext:emoji`): the catalog, the server frame's `catalog_url`, and finding keys in text.
final class ApronEmojiTests: XCTestCase {
    private let party = ChatCustomEmoji(key: ":partyparrot:", url: URL(string: "https://chat.example/e/p")!)
    private let left = ChatCustomEmoji(key: ":party-left:", url: URL(string: "https://chat.example/e/l")!)
    private let right = ChatCustomEmoji(key: ":party-right:", url: URL(string: "https://chat.example/e/r")!)

    private var catalog: [String: ChatCustomEmoji] {
        Dictionary(uniqueKeysWithValues: [party, left, right].map { ($0.key, $0) })
    }

    private func keys(in text: String) -> [String] {
        ChatCustomEmoji.ranges(in: text, catalog: catalog).map { (text as NSString).substring(with: $0.range) }
    }

    func testScansLeftToRight() {
        XCTAssertEqual(keys(in: "Shipped :partyparrot:"), [":partyparrot:"])
        XCTAssertEqual(keys(in: ":party-left::party-right:"), [":party-left:", ":party-right:"])
        XCTAssertEqual(keys(in: "12:30:partyparrot:"), [":partyparrot:"])
        XCTAssertEqual(keys(in: ":nope: :partyparrot"), [])
        XCTAssertEqual(keys(in: "no keys"), [])
    }

    func testRangesAreUTF16() {
        let ranges = ChatCustomEmoji.ranges(in: "👍🏽 :partyparrot:", catalog: catalog)
        XCTAssertEqual(ranges.first?.range, NSRange(location: 5, length: 13))
    }

    func testSuggestionsPreferPrefixThenTagsAndSkipHidden() throws {
        let tagged = try ChatCustomEmoji(key: ":shipit:", url: XCTUnwrap(URL(string: "https://chat.example/e/s")), tags: ["party"])
        let hidden = try ChatCustomEmoji(key: ":partyold:", url: XCTUnwrap(URL(string: "https://chat.example/e/o")), isHidden: true)
        let catalog = Dictionary(uniqueKeysWithValues: [party, left, tagged, hidden].map { ($0.key, $0) })
        XCTAssertEqual(ChatCustomEmoji.suggestions(for: "party", in: catalog).map(\.key), [":party-left:", ":partyparrot:", ":shipit:"])
        XCTAssertEqual(ChatCustomEmoji.suggestions(for: "", in: catalog).map(\.key), [":party-left:", ":partyparrot:", ":shipit:"])
    }

    func testParsesCatalogLeniently() throws {
        let json = """
        {
          ":partyparrot:": {"url": "https://chat.example/e/p", "static_url": "https://chat.example/e/p/still", "category": "Parrots", "tags": ["party", 3]},
          ":shipit:": {"url": "https://chat.example/e/s", "width": 64, "height": 32, "alt": "Squirrel in a hat", "hidden": true},
          ":odd:": {"url": "https://chat.example/e/o", "width": "wide", "category": 4},
          "no-colons": {"url": "https://chat.example/e/n"},
          ":bad key:": {"url": "https://chat.example/e/b"},
          ":nourl:": {"alt": "missing"},
          ":script:": {"url": "javascript:alert(1)"}
        }
        """
        let catalog = try ApronEmojiCatalog.parse(Data(json.utf8))
        XCTAssertEqual(Set(catalog.keys), [":partyparrot:", ":shipit:", ":odd:"])
        let parrot = try XCTUnwrap(catalog[":partyparrot:"])
        XCTAssertEqual(parrot.imageURL.absoluteString, "https://chat.example/e/p/still")
        XCTAssertEqual(parrot.category, "Parrots")
        XCTAssertEqual(parrot.tags, ["party"])
        XCTAssertEqual(parrot.label, ":partyparrot:")
        let shipit = try XCTUnwrap(catalog[":shipit:"])
        XCTAssertEqual(shipit.aspectRatio, 2)
        XCTAssertEqual(shipit.label, "Squirrel in a hat")
        XCTAssertTrue(shipit.isHidden)
        let odd = try XCTUnwrap(catalog[":odd:"])
        XCTAssertEqual(odd.aspectRatio, 1)
        XCTAssertNil(odd.category)
    }

    func testReadsCatalogURLFromServerFrame() throws {
        func ext(_ catalogURL: String) throws -> ApronServerExt {
            try JSONDecoder().decode(ApronServerExt.self, from: Data(#"{"emoji": {"catalog_url": "\#(catalogURL)"}}"#.utf8))
        }
        XCTAssertEqual(try ext("https://chat.example/e/c.json").emojiCatalogURL?.absoluteString, "https://chat.example/e/c.json")
        XCTAssertNotNil(try ext("http://127.0.0.1:8080/e/c.json").emojiCatalogURL)
        XCTAssertNotNil(try ext("data:application/json,{}").emojiCatalogURL)
        XCTAssertNil(try ext("http://chat.example/e/c.json").emojiCatalogURL)
        XCTAssertNil(try ext("ftp://chat.example/c.json").emojiCatalogURL)
        let none = try JSONDecoder().decode(ApronServerExt.self, from: Data(#"{"emoji": {"catalog_url": 5}}"#.utf8))
        XCTAssertNil(none.emojiCatalogURL)
    }
}
