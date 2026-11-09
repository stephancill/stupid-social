import Foundation
@testable import StupidChatKit
import XCTest

final class ChatReactionGridTests: XCTestCase {
    private let cooking = ChatCustomEmoji(key: ":cooking:", url: URL(string: "https://example.com/cooking.png")!, category: "Food")
    private let hidden = ChatCustomEmoji(key: ":secret:", url: URL(string: "https://example.com/secret.png")!, isHidden: true)

    func testCatalogHasTheKeyboardsCategoriesInOrder() {
        let titles = EmojiCatalog.categories.map(\.title)
        XCTAssertEqual(titles.first, "Smileys & Emotion")
        XCTAssertEqual(titles.last, "Flags")
        XCTAssertEqual(EmojiCatalog.categories.first?.entries.first?.emoji, "😀")
    }

    func testSearchPutsTheEmojiNamedExactlyFirst() {
        let found = EmojiCatalog.search("fire").map(\.emoji)
        XCTAssertEqual(found.first, "🔥")
        XCTAssertTrue(found.contains("🚒"), "a word starting with the query matches too")
        XCTAssertEqual(EmojiCatalog.search("  ").count, 0)
    }

    func testCustomEmojiComeFirstThenEveryCategory() {
        let sections = ChatReactionGrid.sections(customEmojis: [cooking.key: cooking, hidden.key: hidden], choices: nil, query: "")
        XCTAssertEqual(sections.first?.title, "Food")
        XCTAssertEqual(sections.first?.items, [.custom(cooking)], "hidden custom emoji aren't offered")
        XCTAssertEqual(sections.dropFirst().map(\.title), EmojiCatalog.categories.map(\.title))
    }

    func testChoicesReplaceTheCatalog() {
        let sections = ChatReactionGrid.sections(customEmojis: [:], choices: ["❤", "👍"], query: "")
        XCTAssertEqual(sections.map(\.title), ["Reactions"])
        XCTAssertEqual(sections.first?.items, [.emoji("❤"), .emoji("👍")])
    }

    func testSearchKeepsToTheChoicesAsTheNetworkWritesThem() {
        let sections = ChatReactionGrid.sections(customEmojis: [:], choices: ["❤", "🔥"], query: "heart")
        XCTAssertEqual(sections.first?.items.map(\.key), ["❤"], "Telegram's ❤ matches the catalog's ❤️")
    }

    func testSearchFindsCustomEmojiBeforeUnicode() {
        let sections = ChatReactionGrid.sections(customEmojis: [cooking.key: cooking], choices: nil, query: "cook")
        XCTAssertEqual(sections.map(\.title), ["Results"])
        XCTAssertEqual(sections.first?.items.first, .custom(cooking))
        XCTAssertTrue(sections.first?.items.contains(.emoji("🧑‍🍳")) == true)
    }
}
