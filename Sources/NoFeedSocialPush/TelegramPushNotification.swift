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
        guard let chat = TelegramPushChat(userInfo: userInfo) else { return nil }
        let fields = TelegramPushChat.fields(userInfo)
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        let key = alert?["loc-key"] as? String ?? userInfo["loc_key"] as? String
        let args = alert?["loc-args"] as? [String] ?? userInfo["loc_args"] as? [String] ?? []
        func id(_ name: String) -> Int64? {
            TelegramPushChat.id(fields[name])
        }

        let senderId: Int64
        let title: String
        switch chat {
        case let .user(id):
            senderId = id
            guard let sender = key?.hasPrefix("MESSAGE_") == true ? args.first : alert?["title"] as? String else { return nil }
            title = sender
        case .chat, .channel:
            // A group message from a person; posts and messages sent as a channel or group have no person.
            guard id("chat_from_broadcast_id") == nil, id("chat_from_group_id") == nil, let from = id("chat_from_id") else { return nil }
            senderId = from
            if let key {
                guard key.hasPrefix("CHAT_"), args.count >= 2 else { return nil }
                title = "\(args[0]) in \(args[1])"
            } else {
                guard let group = alert?["title"] as? String else { return nil }
                title = group
            }
        }
        // The text alone for text messages, since the title already names the sender; otherwise Telegram's line,
        // such as "Ann sent you a photo".
        var body: String
        if key == "MESSAGE_TEXT" || key == "CHAT_MESSAGE_TEXT", let text = args.last {
            body = text
        } else if let key, let line = localized(key, args) {
            body = line
        } else if let line = alert?["body"] as? String {
            body = line
        } else {
            return nil
        }
        // Pushes carry no entities, but the service account's login code is found by shape.
        if senderId == SpoilerText.telegramServiceUserId {
            body = SpoilerText.mask(body, ranges: SpoilerText.loginCodeRanges(in: body))
        }
        return TelegramPushNotification(title: title, body: body, senderId: senderId, conversationId: chat.key)
    }
}

/// The chat a Telegram push is about, from its `custom` fields (core.telegram.org/api/push-updates), which may
/// also come at the top level, as strings or numbers: a supergroup, a basic group, or else the sender of a private
/// message. Apron pushes and the app's own notifications aren't Telegram's.
public enum TelegramPushChat: Hashable, Sendable {
    case user(Int64)
    case chat(Int64)
    case channel(Int64)

    public init?(userInfo: [AnyHashable: Any]) {
        guard userInfo[ApronPushNotification.userInfoKey] == nil, userInfo["webpush"] == nil else { return nil }
        let fields = Self.fields(userInfo)
        if let id = Self.id(fields["channel_id"]) {
            self = .channel(id)
        } else if let id = Self.id(fields["chat_id"]) {
            self = .chat(id)
        } else if let id = Self.id(fields["from_id"]) {
            self = .user(id)
        } else {
            return nil
        }
    }

    /// The peer key the app uses (`user:…`, `chat:…`, `channel:…`).
    public var key: String {
        switch self {
        case let .user(id): "user:\(id)"
        case let .chat(id): "chat:\(id)"
        case let .channel(id): "channel:\(id)"
        }
    }

    static func fields(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        if let custom = userInfo["custom"] as? [String: Any] { return custom }
        return Dictionary(userInfo.compactMap { key, value in (key as? String).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    static func id(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return (value as? String).flatMap { Int64($0) }
    }
}

/// Telegram users' avatars, saved by the app as it loads them so the notification extension, which has no
/// Telegram session, can show them. Files in the App Group container, named by user id.
public struct TelegramAvatarStore: Sendable {
    private let directory: URL?

    public init(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)) {
        directory = container?.appending(path: "telegram-avatars", directoryHint: .isDirectory)
    }

    /// The users whose avatars are saved, for Settings → Debug.
    public var userIds: [Int64] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else { return [] }
        return files.compactMap { Int64($0.replacingOccurrences(of: ".jpg", with: "")) }.sorted()
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
