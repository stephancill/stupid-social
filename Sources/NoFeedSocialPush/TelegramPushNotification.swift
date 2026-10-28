import Foundation

/// What a Telegram push (core.telegram.org/api/push-updates) shows as a Communication Notification: the sender,
/// with their avatar when the app has saved it, and the message. Worked out apart from UserNotifications so it can
/// be tested. Channel posts have no person to show and are left as Telegram sent them.
public struct TelegramPushNotification: Equatable, Sendable {
    /// The sender's name in a private chat, "<sender> in <group>" in a group.
    public let title: String
    public let body: String
    public let senderId: Int64
    /// The chat's peer key (`user:…`, `chat:…`, `channel:…`), so a chat's notifications are one conversation.
    public let conversationId: String

    /// The notification for a push's `userInfo`, or `nil` for one that isn't from a person. `localized` formats a
    /// `loc-key` with its arguments, from the app's strings.
    public static func make(userInfo: [AnyHashable: Any], localized: (String, [String]) -> String?) -> TelegramPushNotification? {
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        guard let key = alert?["loc-key"] as? String ?? userInfo["loc_key"] as? String else { return nil }
        let args = alert?["loc-args"] as? [String] ?? userInfo["loc_args"] as? [String] ?? []
        let custom = userInfo["custom"] as? [String: Any] ?? [:]
        func id(_ name: String) -> Int64? {
            if let number = custom[name] as? NSNumber { return number.int64Value }
            return (custom[name] as? String).flatMap { Int64($0) }
        }

        let conversationId: String
        let senderId: Int64
        let title: String
        if let chat = id("channel_id").map({ "channel:\($0)" }) ?? id("chat_id").map({ "chat:\($0)" }) {
            // A group message from a person; posts and messages sent as a channel or group have no person.
            guard key.hasPrefix("CHAT_"), id("chat_from_broadcast_id") == nil, id("chat_from_group_id") == nil,
                  let from = id("chat_from_id"), args.count >= 2
            else { return nil }
            conversationId = chat
            senderId = from
            title = "\(args[0]) in \(args[1])"
        } else if let from = id("from_id"), key.hasPrefix("MESSAGE_"), let sender = args.first {
            conversationId = "user:\(from)"
            senderId = from
            title = sender
        } else {
            return nil
        }
        // The text alone for text messages, since the title already names the sender; otherwise Telegram's line,
        // such as "Ann sent you a photo".
        let body: String
        if key == "MESSAGE_TEXT" || key == "CHAT_MESSAGE_TEXT", let text = args.last {
            body = text
        } else if let line = localized(key, args) {
            body = line
        } else {
            return nil
        }
        return TelegramPushNotification(title: title, body: body, senderId: senderId, conversationId: conversationId)
    }
}

/// Telegram users' avatars, saved by the app as it loads them so the notification extension, which has no
/// Telegram session, can show them. Files in the App Group container, named by user id.
public struct TelegramAvatarStore: Sendable {
    private let directory: URL?

    public init(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)) {
        directory = container?.appending(path: "telegram-avatars", directoryHint: .isDirectory)
    }

    public func load(userId: Int64) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appending(path: "\(userId).jpg"))
    }

    public func save(_ data: Data, userId: Int64) {
        guard let directory else { return }
        let file = directory.appending(path: "\(userId).jpg")
        if (try? Data(contentsOf: file)) == data { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable by the extension after the first unlock, when a push may arrive with the phone locked.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
