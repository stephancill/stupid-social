import Foundation

/// An emoji offered while typing a `:word` in the composer: the network's custom emoji, or a Unicode emoji found
/// by its name.
public enum ChatEmojiSuggestion: Hashable, Identifiable, Sendable {
    case custom(ChatCustomEmoji)
    case unicode(emoji: String, name: String)

    public var id: String {
        text
    }

    /// What replaces the `:word`: a custom emoji's key, or the emoji itself.
    public var text: String {
        switch self {
        case let .custom(emoji): emoji.key
        case let .unicode(emoji, _): emoji
        }
    }

    public var label: String {
        switch self {
        case let .custom(emoji): emoji.label
        case let .unicode(_, name): name
        }
    }
}

/// Unicode emoji by name, from the standard library's Unicode tables, so no emoji data ships with the app. Covers
/// single code point emoji; sequences (flags, skin tones, ZWJ families) have no names there. Names are Unicode's,
/// such as "face with tears of joy", rather than Slack's shortcodes.
public enum UnicodeEmojiSearch {
    /// Emoji and their lowercased names, in code point order.
    static let all: [(emoji: String, name: String)] = {
        var list: [(String, String)] = []
        for value in UInt32(0xA9) ... 0x1FAFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji, let name = scalar.properties.name else { continue }
            let properties = scalar.properties
            // Skin tone modifiers and regional indicators only make sense in sequences; below U+2000 only © and ®
            // are emoji rather than digits and symbols.
            let isPart = properties.isEmojiModifier || (0x1F1E6 ... 0x1F1FF).contains(value)
            let isSymbol = value < 0x2000 && value != 0xA9 && value != 0xAE
            guard !isPart, !isSymbol else { continue }
            // Text-style emoji, such as ❤, ask for emoji presentation.
            list.append((properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}", name.lowercased()))
        }
        return list
    }()

    /// Emoji whose name has a word starting with the query: the whole name, then a whole word, then a name
    /// starting with it, then a word starting with it.
    public static func matches(for query: String, limit: Int) -> [ChatEmojiSuggestion] {
        let query = query.lowercased().replacingOccurrences(of: "_", with: " ")
        guard !query.isEmpty else { return [] }
        let ranked = all.compactMap { entry -> (rank: Int, emoji: String, name: String)? in
            let words = entry.name.split(separator: " ")
            let rank = if entry.name == query {
                0
            } else if words.contains(where: { $0 == query }) {
                1
            } else if entry.name.hasPrefix(query) {
                2
            } else if words.contains(where: { $0.hasPrefix(query) }) {
                3
            } else {
                Int?.none
            }
            return rank.map { ($0, entry.emoji, entry.name) }
        }
        // Stable, so equal ranks keep code point order.
        let sorted = ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
        return sorted.prefix(limit).map { .unicode(emoji: $0.element.emoji, name: $0.element.name) }
    }
}
