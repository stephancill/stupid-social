import NoFeedSocialCore

enum DebugRedaction {
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
