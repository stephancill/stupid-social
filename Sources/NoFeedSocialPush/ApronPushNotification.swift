import Foundation

/// What a decrypted Apron push shows (§4.9.3), worked out apart from UserNotifications so it can be tested.
/// The title is the sender in a DM and "<sender> in <room>" in a room; the subtitle is the server.
public struct ApronPushNotification: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let body: String
    /// Groups a room's notifications, and lets the app find them to clear when the room is opened.
    public let threadIdentifier: String
    public let serverURL: URL
    public let roomId: String
    public let messageId: String
    public let senderId: String
    public let senderAvatarURL: URL?
    /// A room named for its members, such as a DM.
    public let isDirect: Bool

    /// `apron` in a notification's `userInfo`: the server, room and message, to open or reply to.
    public static let userInfoKey = "apron"
    /// The category with the inline Reply action.
    public static let categoryIdentifier = "apron.message"
    public static let replyActionIdentifier = "apron.reply"

    public var userInfo: [String: [String: String]] {
        [Self.userInfoKey: ["server": serverURL.absoluteString, "room": roomId, "message": messageId, "direct": isDirect ? "1" : "0"]]
    }

    public static func threadIdentifier(serverURL: URL, roomId: String) -> String {
        "apron|\(serverURL.absoluteString)|\(roomId)"
    }

    /// The notification for a payload, or `nil` when it carries no message or names an unknown `push_id`.
    public static func make(payload: Data, registrations: [String: ApronPushRegistration]) -> ApronPushNotification? {
        guard let push = try? JSONDecoder().decode(Payload.self, from: payload),
              let pushId = push.pushId,
              let registration = registrations[pushId],
              let message = push.message
        else { return nil }
        let sender = message.from.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? registration.userNames[message.from.userId]
            ?? message.from.userId
        let text = message.body?.text.map { ApronPushText.plain($0, names: registration.userNames) }?.nilIfEmpty ?? "New message"
        let isDirect = registration.directRooms.contains(message.roomId)
        let roomTitle = registration.roomTitles[message.roomId] ?? message.roomId

        return ApronPushNotification(
            title: isDirect ? sender : "\(sender) in \(roomTitle)",
            subtitle: registration.serverURL.host() ?? registration.serverURL.absoluteString,
            body: text,
            threadIdentifier: threadIdentifier(serverURL: registration.serverURL, roomId: message.roomId),
            serverURL: registration.serverURL,
            roomId: message.roomId,
            messageId: message.messageId,
            senderId: message.from.userId,
            senderAvatarURL: registration.avatarURLs[message.from.userId],
            isDirect: isDirect,
        )
    }

    private struct Payload: Decodable {
        let pushId: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case pushId = "push_id"
            case message
        }
    }

    private struct Message: Decodable {
        let messageId: String
        let roomId: String
        let from: From
        let body: Body?

        enum CodingKeys: String, CodingKey {
            case messageId = "message_id"
            case roomId = "room_id"
            case from
            case body
        }
    }

    private struct From: Decodable {
        let userId: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case name
        }
    }

    private struct Body: Decodable {
        let text: String?
    }
}

/// Message text as a notification shows it: Markdown reduced to its words, and mentions of known users by name.
public enum ApronPushText {
    /// A mention is `@` and the longest run of `[A-Za-z0-9_.+@:-]` that starts and ends with a letter, digit or
    /// `_`, not preceded by a letter or digit (Appendix A.3).
    private static let mention = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])@([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)")
    private static let markdown: [(NSRegularExpression, String)] = [
        ("^```[^\\n]*$\\n?", ""),
        ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
        ("\\*\\*(.+?)\\*\\*", "$1"),
        ("__(.+?)__", "$1"),
        ("~~(.+?)~~", "$1"),
        ("`+([^`]+)`+", "$1"),
        ("^#{1,6}\\s+", ""),
        ("^>\\s?", ""),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.anchorsMatchLines]), $0.1) }

    public static func plain(_ text: String, names: [String: String]) -> String {
        var result = text
        for (expression, template) in markdown {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        let nsResult = result as NSString
        for match in mention.matches(in: result, range: NSRange(location: 0, length: nsResult.length)).reversed() {
            let userId = nsResult.substring(with: match.range(at: 1))
            if let name = names[userId] {
                result = (result as NSString).replacingCharacters(in: match.range, with: "@\(name)")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
