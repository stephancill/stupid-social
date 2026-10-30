import Foundation

/// This device's registration for chat reminder pushes: reminders set on the user's other devices arrive through
/// `push.stupidtech.net` when they're due, encrypted to these keys. Shared with the Notification Service Extension
/// through the App Group so it can decrypt them while the app isn't running.
public struct ChatReminderPushRegistration: Codable, Hashable, Sendable {
    /// Names this device to the others; local to the device.
    public let deviceId: String
    public let keys: WebPushKeys
    /// The relay endpoint, and the APNs token and VAPID key it was made for; a change to either needs a new one.
    public var endpoint: URL?
    public var endpointDeviceToken: String?
    public var endpointVapidKey: String?

    public init(deviceId: String, keys: WebPushKeys) {
        self.deviceId = deviceId
        self.keys = keys
    }
}

/// The registration in a file in the App Group container. Both the app and the extension read it; only the app writes.
public struct ChatReminderPushStore: Sendable {
    private let fileURL: URL?

    public init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)) {
        fileURL = directory?.appending(path: "chat-reminder-push.json")
    }

    public func load() -> ChatReminderPushRegistration? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ChatReminderPushRegistration.self, from: data)
    }

    public func save(_ registration: ChatReminderPushRegistration) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(registration)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A due reminder's notification, the same whether this device scheduled it or another device's push brought it.
public struct ChatReminderNotification: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let body: String

    /// The reminder id in a reminder notification's `userInfo`.
    public static let userInfoKey = "chatReminder"
    /// The pushed reminder (its JSON), so a device that hasn't synced it yet can still open and list it.
    public static let reminderDataKey = "chatReminderData"

    public init(id: String, chatTitle: String, senderName: String?, text: String) {
        self.id = id
        title = chatTitle
        subtitle = "Reminder"
        body = [senderName, text.isEmpty ? nil : text].compactMap(\.self).joined(separator: ": ")
    }

    /// A pushed reminder's notification: the payload is the reminder's JSON, of which this reads only what it shows.
    public init(payload: Data) throws {
        struct Fields: Decodable {
            let id: String
            let chatTitle: String
            let senderName: String?
            let text: String
        }
        let fields = try JSONDecoder().decode(Fields.self, from: payload)
        self.init(id: fields.id, chatTitle: fields.chatTitle, senderName: fields.senderName, text: fields.text)
    }
}
