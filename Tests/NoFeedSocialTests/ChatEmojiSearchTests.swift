import Foundation
@testable import NoFeedSocialCore
import XCTest

/// Emoji offered while typing a `:word`: Unicode emoji by name, after the network's custom emoji.
final class ChatEmojiSearchTests: XCTestCase {
    private func emojis(_ query: String, limit: Int = 40) -> [String] {
        UnicodeEmojiSearch.matches(for: query, limit: limit).map(\.text)
    }

    func testFindsEmojiByAWordOfTheirName() {
        XCTAssertEqual(emojis("joy").first, "😂")
        XCTAssertTrue(emojis("thumbs").contains("👍"))
        XCTAssertTrue(emojis("fire").contains("🔥"))
        XCTAssertTrue(emojis("thumbs_up").contains("👍"))
    }

    func testWholeWordsRankBeforePrefixes() throws {
        let results = emojis("joy")
        XCTAssertLessThan(try XCTUnwrap(results.firstIndex(of: "😂")), try XCTUnwrap(results.firstIndex(of: "🕹️")))
    }

    func testTextStyleEmojiAskForEmojiPresentation() {
        XCTAssertTrue(emojis("heavy black heart").contains("❤️"))
    }

    func testLeavesOutSequencePartsAndPlainSymbols() {
        let all = UnicodeEmojiSearch.all.map(\.emoji)
        XCTAssertFalse(all.contains("🏽"))
        XCTAssertFalse(all.contains("🇿"))
        XCTAssertFalse(all.contains { $0.unicodeScalars.first!.isASCII })
        XCTAssertEqual(emojis(""), [])
        XCTAssertEqual(emojis("smil", limit: 3).count, 3)
    }

    @MainActor
    func testCustomEmojiComeFirstAndUnicodeNeedsTwoCharacters() throws {
        let viewModel = try ChatViewModel(network: .apron, chatKey: "test:emoji", title: "Chat", subtitle: "", canReply: false, draftStore: ChatDraftStore(defaults: XCTUnwrap(UserDefaults(suiteName: "ChatEmojiSearchTests"))))
        viewModel.customEmojis = try [":fireparrot:": ChatCustomEmoji(key: ":fireparrot:", url: XCTUnwrap(URL(string: "https://chat.example/e/f")))]
        let suggestions = viewModel.emojiSuggestions(for: "fire")
        XCTAssertEqual(suggestions.first?.text, ":fireparrot:")
        XCTAssertTrue(suggestions.contains(.unicode(emoji: "🔥", name: "fire")))
        XCTAssertEqual(viewModel.emojiSuggestions(for: "f").map(\.text), [":fireparrot:"])
        XCTAssertEqual(viewModel.emojiSuggestions(for: "").map(\.text), [":fireparrot:"])
    }
}
