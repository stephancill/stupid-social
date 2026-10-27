import Foundation
import NoFeedSocialCore

enum DebugRedaction {
    /// The "Redact names" setting, for UIKit code that can't use `@AppStorage("redactionEnabled")`.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "redactionEnabled")
    }

    /// A chat participant's name.
    static func name(_ value: String, enabled: Bool = isEnabled) -> String {
        enabled ? "Redacted" : value
    }

    /// Text with each `@` mention shown as `@Redacted`.
    static func mentions(in text: String, pattern: NSRegularExpression?, enabled: Bool = isEnabled) -> String {
        guard enabled, let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "@Redacted")
    }

    static func username(_ value: String?, fallback: String = "user", enabled: Bool) -> String {
        guard enabled else { return value ?? fallback }
        return "Redacted"
    }

    static func actorName(_ actor: NotificationActor, enabled: Bool) -> String {
        guard enabled else { return actor.username ?? actor.displayName ?? actor.id }
        return "Redacted"
    }

    /// Every Chats row title: people's names, and group and room names, which can identify them too.
    static func chatTitle(_ chat: ChatSummary, enabled: Bool) -> String {
        enabled ? "Redacted" : chat.title
    }

    /// A Chats row preview: the sender before ": " in groups, mentions, and in a DM the person's name.
    static func chatPreview(_ preview: String, chat: ChatSummary, enabled: Bool) -> String {
        guard enabled else { return preview }
        var text = mentions(in: preview, pattern: ApronMention.pattern)
        if chat.namesSenderInPreview, !text.hasPrefix("You: "), let separator = text.range(of: ": ") {
            text = "Redacted" + text[separator.lowerBound...]
        }
        if chat.titleNamesPeople, !chat.namesSenderInPreview {
            // Such as "Dylan sent an attachment." in a DM titled with Dylan's full name.
            let names = [chat.title] + chat.title.split(separator: " ").map(String.init).filter { $0.count > 1 }
            for name in names {
                text = text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", with: "Redacted", options: .regularExpression)
            }
        }
        return text
    }

    static func text(_ value: String, actors: [NotificationActor], enabled: Bool) -> String {
        guard enabled else { return value }
        return actors.reduce(value) { text, actor in
            var redacted = text
            if let username = actor.username {
                redacted = redacted.replacingOccurrences(of: "@\(username)", with: "Redacted")
                redacted = redacted.replacingOccurrences(of: username, with: "Redacted")
            }
            if let displayName = actor.displayName {
                redacted = redacted.replacingOccurrences(of: displayName, with: "Redacted")
            }
            return redacted.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
