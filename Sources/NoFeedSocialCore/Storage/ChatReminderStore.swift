import Foundation
import UserNotifications

/// A chat message the user asked to be reminded of, from its long-press menu.
public struct ChatReminder: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let destination: ChatSummary.Destination
    public let accountId: String
    public let network: SocialNetwork
    public let chatTitle: String
    public let messageId: String
    public let senderName: String?
    public let senderAvatarURL: URL?
    public let text: String
    public let dueDate: Date

    /// The feed item a due reminder shows as; its id starts with `itemIdPrefix`. Its summary names the sender and
    /// chat, and the message is its target, which the feed shows muted below.
    public var feedItem: NotificationItem {
        let sender = senderName ?? chatTitle
        return NotificationItem(
            id: Self.itemIdPrefix + id,
            network: network,
            accountId: accountId,
            sourceId: messageId,
            type: .message,
            timestamp: dueDate,
            text: sender == chatTitle ? sender : "\(sender) in \(chatTitle)",
            actors: [NotificationActor(id: messageId, network: network, username: nil, displayName: sender, avatarURL: senderAvatarURL)],
            target: text.isEmpty ? nil : NotificationTarget(id: messageId, text: text, url: nil),
        )
    }

    public static let itemIdPrefix = "reminder:"
    /// The reminder id in a reminder notification's `userInfo`.
    public static let userInfoKey = "chatReminder"
}

/// Where a chat can be reopened from a reminder: set on a chat's view model when it opens from the Chats list.
public struct ChatReminderTarget: Sendable {
    public let destination: ChatSummary.Destination
    public let accountId: String
    public let network: SocialNetwork
    public let chatTitle: String

    public init(destination: ChatSummary.Destination, accountId: String, network: SocialNetwork, chatTitle: String) {
        self.destination = destination
        self.accountId = accountId
        self.network = network
        self.chatTitle = chatTitle
    }
}

/// Reminders on this device, kept in `UserDefaults`, each with a local notification at its due date. A due
/// reminder stays in the feed until the user removes it there.
@MainActor
public enum ChatReminderStore {
    public enum Delay: CaseIterable, Sendable {
        case fiveMinutes, thirtyMinutes, oneHour, threeHours, tomorrow

        public var title: String {
            switch self {
            case .fiveMinutes: "In 5 Minutes"
            case .thirtyMinutes: "In 30 Minutes"
            case .oneHour: "In 1 Hour"
            case .threeHours: "In 3 Hours"
            case .tomorrow: "Tomorrow"
            }
        }

        /// Tomorrow is 9 AM local time.
        public func dueDate(from now: Date = Date(), calendar: Calendar = .current) -> Date {
            switch self {
            case .fiveMinutes: now.addingTimeInterval(5 * 60)
            case .thirtyMinutes: now.addingTimeInterval(30 * 60)
            case .oneHour: now.addingTimeInterval(60 * 60)
            case .threeHours: now.addingTimeInterval(3 * 60 * 60)
            case .tomorrow:
                calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
            }
        }
    }

    /// Posted when reminders are added or removed, so chats and the feed show the change.
    public static let remindersDidChange = Notification.Name("tech.stupid.StupidSocial.chatRemindersDidChange")
    /// Posted when a reminder's notification arrives with the app open, so the feed shows it.
    public static let reminderDidFire = Notification.Name("tech.stupid.StupidSocial.chatReminderDidFire")

    private static let defaultsKey = "tech.stupid.StupidSocial.chatReminders"

    public static func all(defaults: UserDefaults = .standard) -> [ChatReminder] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ChatReminder].self, from: data)) ?? []
    }

    public static func reminder(id: String, defaults: UserDefaults = .standard) -> ChatReminder? {
        all(defaults: defaults).first { $0.id == id }
    }

    /// The chat's reminders by message id, the earliest when a message has several.
    public static func dueDates(in target: ChatReminderTarget, defaults: UserDefaults = .standard) -> [String: Date] {
        all(defaults: defaults)
            .filter { $0.destination == target.destination && $0.accountId == target.accountId }
            .reduce(into: [:]) { dates, reminder in
                dates[reminder.messageId] = min(dates[reminder.messageId] ?? reminder.dueDate, reminder.dueDate)
            }
    }

    /// Drops every reminder on a message, when the user marks it done in the chat.
    public static func markDone(messageId: String, in target: ChatReminderTarget, defaults: UserDefaults = .standard) {
        let done = all(defaults: defaults).filter { $0.messageId == messageId && $0.destination == target.destination && $0.accountId == target.accountId }
        for reminder in done {
            remove(id: reminder.id, defaults: defaults)
        }
    }

    public static func due(now: Date = Date(), defaults: UserDefaults = .standard) -> [ChatReminder] {
        all(defaults: defaults).filter { $0.dueDate <= now }
    }

    /// Saves the reminder and schedules its notification, asking for permission the first time.
    public static func schedule(_ message: ChatMessage, in target: ChatReminderTarget, dueDate: Date, defaults: UserDefaults = .standard) async throws -> ChatReminder {
        let reminder = ChatReminder(
            id: UUID().uuidString,
            destination: target.destination,
            accountId: target.accountId,
            network: target.network,
            chatTitle: target.chatTitle,
            messageId: message.id,
            senderName: message.isOwn ? "You" : message.sender.name,
            senderAvatarURL: message.sender.avatarURL,
            text: message.text ?? "",
            dueDate: dueDate,
        )
        save(all(defaults: defaults) + [reminder], defaults: defaults)

        let center = UNUserNotificationCenter.current()
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        let content = UNMutableNotificationContent()
        content.title = reminder.chatTitle
        content.subtitle = "Reminder"
        content.body = [reminder.senderName, reminder.text.isEmpty ? nil : reminder.text].compactMap(\.self).joined(separator: ": ")
        content.sound = .default
        content.userInfo = [ChatReminder.userInfoKey: reminder.id]
        let interval = max(1, reminder.dueDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: ChatReminder.itemIdPrefix + reminder.id, content: content, trigger: trigger))
        return reminder
    }

    /// Drops the reminder and its notification, when the user removes it from the feed.
    public static func remove(id: String, defaults: UserDefaults = .standard) {
        save(all(defaults: defaults).filter { $0.id != id }, defaults: defaults)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [ChatReminder.itemIdPrefix + id])
        center.removeDeliveredNotifications(withIdentifiers: [ChatReminder.itemIdPrefix + id])
    }

    private static func save(_ reminders: [ChatReminder], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(reminders), forKey: defaultsKey)
        NotificationCenter.default.post(name: remindersDidChange, object: nil)
    }
}
