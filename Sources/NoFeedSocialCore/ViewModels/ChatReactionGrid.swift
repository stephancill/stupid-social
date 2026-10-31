import Foundation

/// Every Unicode emoji this iOS can draw, by category, with names and keywords to search by. The data is
/// `Resources/Emoji.json`, from Elegant Emoji Picker (see THIRD_PARTY_NOTICES.md).
public enum EmojiCatalog {
    public struct Entry: Decodable, Hashable, Sendable {
        public let emoji: String
        public let description: String
        public let category: String
        public let aliases: [String]
        public let tags: [String]
        let iosVersion: String

        enum CodingKeys: String, CodingKey {
            case emoji, description, category, aliases, tags
            case iosVersion = "ios_version"
        }

        /// Lowercased words to match a search against.
        var words: [String] {
            description.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                + aliases.flatMap { $0.lowercased().split(separator: "_").map(String.init) }
                + tags.map { $0.lowercased() }
        }
    }

    public struct Category: Hashable, Sendable {
        public let title: String
        /// An SF Symbol for the category.
        public let symbol: String
        public let entries: [Entry]
    }

    /// In the data's order, which is the emoji keyboard's.
    public static let categories: [Category] = {
        guard let url = Bundle.module.url(forResource: "Emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Newer emoji draw as an empty box on an older iOS.
        let drawable = entries.filter { entry in
            let parts = entry.iosVersion.split(separator: ".").compactMap { Int($0) }
            let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
            return (major, minor) <= (os.majorVersion, os.minorVersion)
        }
        var order: [String] = []
        var byCategory: [String: [Entry]] = [:]
        for entry in drawable {
            if byCategory[entry.category] == nil {
                order.append(entry.category)
            }
            byCategory[entry.category, default: []].append(entry)
        }
        return order.map { Category(title: $0, symbol: symbol(for: $0), entries: byCategory[$0] ?? []) }
    }()

    /// Emoji with a word starting with the query: named exactly that first, then with it as a whole word, then the
    /// rest, each in catalog order.
    public static func search(_ query: String) -> [Entry] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var named: [Entry] = []
        var word: [Entry] = []
        var prefix: [Entry] = []
        for entry in categories.flatMap(\.entries) {
            let description = entry.description.lowercased()
            let words = entry.words
            if description == query || entry.aliases.contains(query) {
                named.append(entry)
            } else if words.contains(query) {
                word.append(entry)
            } else if description.hasPrefix(query) || words.contains(where: { $0.hasPrefix(query) }) {
                prefix.append(entry)
            }
        }
        return named + word + prefix
    }

    private static func symbol(for category: String) -> String {
        switch category {
        case "Smileys & Emotion": "face.smiling"
        case "People & Body": "hand.wave"
        case "Animals & Nature": "pawprint"
        case "Food & Drink": "fork.knife"
        case "Travel & Places": "car"
        case "Activities": "soccerball"
        case "Objects": "lightbulb"
        case "Symbols": "number"
        case "Flags": "flag"
        default: "circle"
        }
    }
}

/// The grid a message's reactions expand into: the chat's custom emoji, then every emoji by category, or for a
/// network that takes only some emoji, just those; searching narrows both into one section.
public enum ChatReactionGrid {
    public enum Item: Hashable, Sendable {
        case custom(ChatCustomEmoji)
        case emoji(String)

        /// What a reaction with it sends.
        public var key: String {
            switch self {
            case let .custom(emoji): emoji.key
            case let .emoji(emoji): emoji
            }
        }
    }

    public struct Section: Hashable, Sendable {
        public let title: String
        public let items: [Item]
    }

    public static func sections(customEmojis: [String: ChatCustomEmoji], choices: [String]?, query: String) -> [Section] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            let custom = ChatCustomEmoji.suggestions(for: query, in: customEmojis, limit: .max).map(Item.custom)
            let found = EmojiCatalog.search(query).map(\.emoji)
            let emoji = choices.map { choices in choices.filter { choice in found.contains { bare($0) == bare(choice) } } } ?? found
            let items = custom + emoji.map(Item.emoji)
            return items.isEmpty ? [] : [Section(title: "Results", items: items)]
        }
        let offered = customEmojis.values.filter { !$0.isHidden }
        let byCategory = Dictionary(grouping: offered) { $0.category ?? "" }
        // Uncategorized custom emoji first under the generic title, then categories alphabetically.
        let categories = byCategory.keys.sorted { lhs, rhs in
            lhs.isEmpty != rhs.isEmpty ? lhs.isEmpty : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let custom = categories.map { category in
            Section(
                title: category.isEmpty ? "Custom" : category,
                items: (byCategory[category] ?? []).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(Item.custom),
            )
        }
        if let choices {
            return custom + (choices.isEmpty ? [] : [Section(title: "Reactions", items: choices.map(Item.emoji))])
        }
        return custom + EmojiCatalog.categories.map { Section(title: $0.title, items: $0.entries.map { .emoji($0.emoji) }) }
    }

    /// Without variation selectors, so Telegram's ❤ matches the catalog's ❤️.
    private static func bare(_ emoji: String) -> String {
        emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
    }
}
