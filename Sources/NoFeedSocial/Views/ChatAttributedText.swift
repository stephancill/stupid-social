import NoFeedSocialCore
import UIKit

/// Converts parsed inline Markdown into UIKit attributes; `AttributedString`'s presentation intents carry no fonts.
@MainActor
enum ChatAttributedText {
    static func make(
        _ text: AttributedString,
        color: UIColor,
        linkColor: UIColor,
        codeBackground: UIColor,
        underlinesMentions: Bool,
        mentionPattern: NSRegularExpression?,
        mentionNames: [String: String],
        redactsMentions: Bool,
        customEmojis: [String: ChatCustomEmoji] = [:],
        emojiImageDidLoad: @escaping () -> Void = {},
        places: ChatPlaces = ChatPlaces(),
        font base: UIFont,
        formatsQuotes: Bool,
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var isCode = false
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    isCode = true
                    font = .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
                    attributes[.backgroundColor] = codeBackground
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty {
                    font = font.withTraits(traits)
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.chatLink] = link
            }
            attributes[.font] = font
            let segment = NSMutableAttributedString(string: String(text[run.range].characters), attributes: attributes)
            if !isCode {
                if run.link == nil {
                    detectLinks(in: segment, color: linkColor)
                }
                // Before mentions, so a mention can't claim part of a link's URL that a label replaces.
                labelPlaces(in: segment, writtenAsURL: run.link.map { String(text[run.range].characters) == $0.absoluteString } ?? true, places: places, color: color, linkColor: linkColor)
                if let mentionPattern {
                    highlightMentions(in: segment, pattern: mentionPattern, color: linkColor, underline: underlinesMentions, names: mentionNames, redacts: redactsMentions)
                }
                insertCustomEmojis(in: segment, catalog: customEmojis, onLoad: emojiImageDidLoad)
            }
            result.append(segment)
        }
        if formatsQuotes {
            formatQuotes(in: result, color: color)
        }
        return result
    }

    static let quoteIndent: CGFloat = 12

    /// Lines starting with `>` lose the marker and are indented and dimmed; `ChatLinkLabel` draws the bar.
    /// Messages are parsed as inline Markdown only, so block quotes are found here, line by line.
    private static func formatQuotes(in text: NSMutableAttributedString, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        var lines: [NSRange] = []
        (text.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
            lines.append(range)
        }
        // Back to front, so removing a marker doesn't move the lines before it.
        for line in lines.reversed() {
            let string = (text.string as NSString).substring(with: line)
            guard string.hasPrefix(">") else { continue }
            let marker = string.hasPrefix("> ") ? 2 : 1
            text.deleteCharacters(in: NSRange(location: line.location, length: marker))
            let quoted = NSRange(location: line.location, length: line.length - marker)
            guard quoted.length > 0 else { continue }
            text.addAttribute(.paragraphStyle, value: style, range: quoted)
            text.addAttribute(.chatQuote, value: true, range: quoted)
            text.enumerateAttribute(.foregroundColor, in: quoted) { value, range, _ in
                // Links and mentions keep their color.
                guard (value as? UIColor) == color else { return }
                text.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.7), range: range)
            }
        }
    }

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// `apron:?…` links, which the data detector doesn't find. Trailing punctuation ends a sentence, not the link.
    private static let apronLinkPattern = try! NSRegularExpression(pattern: #"\bapron:\?[^\s<>"'`]*[^\s<>"'`.,;:!?)\]]"#, options: .caseInsensitive)

    /// Bare URLs in plain text (and any Markdown left unlinked) become tappable links too.
    private static func detectLinks(in segment: NSMutableAttributedString, color: UIColor) {
        let range = NSRange(location: 0, length: segment.length)
        let web = linkDetector.matches(in: segment.string, range: range).compactMap { match in
            match.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? (match.range, $0) : nil }
        }
        let apron = apronLinkPattern.matches(in: segment.string, range: range).compactMap { match in
            URL(string: (segment.string as NSString).substring(with: match.range)).map { (match.range, $0) }
        }
        for (range, url) in web + apron {
            segment.addAttributes([
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .chatLink: url,
            ], range: range)
        }
    }

    /// Mentions render in the link color, or underlined where that color isn't available, and show the user's
    /// name where it is known; code spans hold no mentions. A mention inside a link keeps its text.
    private static func highlightMentions(in segment: NSMutableAttributedString, pattern: NSRegularExpression, color: UIColor, underline: Bool, names: [String: String], redacts: Bool) {
        let range = NSRange(location: 0, length: segment.length)
        // Back to front, so replacing a mention's text doesn't move the ones before it.
        for match in pattern.matches(in: segment.string, range: range).reversed() {
            let userId = String((segment.string as NSString).substring(with: match.range).dropFirst())
            segment.addAttribute(.foregroundColor, value: color, range: match.range)
            segment.addAttribute(.chatMention, value: userId, range: match.range)
            if underline {
                segment.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
            if let name = redacts ? "Redacted" : names[userId], segment.attribute(.chatLink, at: match.range.location, effectiveRange: nil) == nil {
                segment.replaceCharacters(in: match.range, with: "@\(name)")
            }
        }
    }
}

/// What the chat knows about places in its network, for links and references in messages to read as names.
struct ChatPlaces {
    var label: (URL) -> ChatPlaceLabel? = { _ in nil }
    var referencePattern: NSRegularExpression?
    var referenceLabel: (String) -> ChatPlaceLabel? = { _ in nil }
}

extension ChatAttributedText {
    /// Links written as their URL, and references such as `#room_id`, become what they name, led by their kind's
    /// icon; a place elsewhere is in the text's color with an arrow after. Each keeps opening its place. Code spans
    /// hold none, and a link written with its own text keeps it.
    private static func labelPlaces(in segment: NSMutableAttributedString, writtenAsURL: Bool, places: ChatPlaces, color: UIColor, linkColor: UIColor) {
        var labels: [(NSRange, ChatPlaceLabel)] = []
        if writtenAsURL {
            segment.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: segment.length)) { value, range, _ in
                if let url = value as? URL, let label = places.label(url) {
                    labels.append((range, label))
                }
            }
        }
        if let pattern = places.referencePattern {
            for match in pattern.matches(in: segment.string, range: NSRange(location: 0, length: segment.length)) {
                guard segment.attribute(.chatLink, at: match.range.location, effectiveRange: nil) == nil,
                      let label = places.referenceLabel((segment.string as NSString).substring(with: match.range(at: 1)))
                else { continue }
                labels.append((match.range, label))
            }
        }
        // Back to front, so replacing a place's text doesn't move the ones before it.
        for (range, label) in labels.sorted(by: { $0.0.location > $1.0.location }) {
            var attributes = segment.attributes(at: range.location, effectiveRange: nil)
            let tint = label.isElsewhere ? color : linkColor
            attributes[.foregroundColor] = tint
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.chatLink] = label.url
            let font = attributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
            let replacement = NSMutableAttributedString()
            if let icon = label.systemImage {
                replacement.append(symbol(icon, font: font, tint: tint, attributes: attributes))
                replacement.append(NSAttributedString(string: "\u{202F}", attributes: attributes))
            }
            replacement.append(NSAttributedString(string: label.text, attributes: attributes))
            if label.isElsewhere {
                replacement.append(NSAttributedString(string: "\u{202F}", attributes: attributes))
                replacement.append(symbol("arrow.up.right", font: font, tint: tint, attributes: attributes))
            }
            segment.replaceCharacters(in: range, with: replacement)
        }
    }

    private static func symbol(_ name: String, font: UIFont, tint: UIColor, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let configuration = UIImage.SymbolConfiguration(font: font, scale: .small)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(tint, renderingMode: .alwaysOriginal) else {
            return NSAttributedString()
        }
        let symbol = NSMutableAttributedString(attachment: NSTextAttachment(image: image))
        symbol.addAttributes(attributes, range: NSRange(location: 0, length: symbol.length))
        return symbol
    }

    /// Custom emoji keys become inline images the height of the line; code spans keep them as text, and so do
    /// links and mentions, whose text can hold a `:`.
    private static func insertCustomEmojis(in segment: NSMutableAttributedString, catalog: [String: ChatCustomEmoji], onLoad: @escaping () -> Void) {
        // Back to front, so replacing a key doesn't move the ones before it.
        for (range, emoji) in ChatCustomEmoji.ranges(in: segment.string, catalog: catalog).reversed() {
            var attributes = segment.attributes(at: range.location, effectiveRange: nil)
            guard attributes[.chatLink] == nil, attributes[.chatMention] == nil else { continue }
            let font = attributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
            attributes[.attachment] = ChatCustomEmojiImages.shared.attachment(for: emoji, font: font, onLoad: onLoad)
            segment.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
    }
}

extension NSAttributedString.Key {
    /// A link's URL. Not `.link`, which `UILabel` would restyle; `ChatLinkLabel` opens it on tap.
    static let chatLink = NSAttributedString.Key("ChatLink")
    /// The `user_id` of an `@` mention, which opens their profile on tap.
    static let chatMention = NSAttributedString.Key("ChatMention")
    /// A block quote line, drawn with a bar at its leading edge.
    static let chatQuote = NSAttributedString.Key("ChatQuote")
    /// Hidden spoiler text, drawn as dots in the attribute's color until tapped.
    static let chatSpoiler = NSAttributedString.Key("ChatSpoiler")
}
