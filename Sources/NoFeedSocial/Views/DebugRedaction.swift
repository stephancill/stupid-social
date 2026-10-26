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
