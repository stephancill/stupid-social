import Foundation
import NoFeedSocialPush
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
    /// The devices a push from the relay will remind (`ChatReminderPush`), so they don't schedule a notification too.
    public let pushedTo: [String]?

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
    public static let userInfoKey = ChatReminderNotification.userInfoKey

    var notification: ChatReminderNotification {
        ChatReminderNotification(id: id, chatTitle: chatTitle, senderName: senderName, text: text)
    }

    func pushed(to devices: [String]) -> ChatReminder {
        ChatReminder(
            id: id, destination: destination, accountId: accountId, network: network, chatTitle: chatTitle, messageId: messageId,
            senderName: senderName, senderAvatarURL: senderAvatarURL, text: text, dueDate: dueDate, pushedTo: devices.isEmpty ? nil : devices,
        )
    }

    /// The reminder with its text cut to whole characters within `maxTextBytes` of UTF-8, to fit a push.
    func truncatedForPush(maxTextBytes: Int) -> ChatReminder {
        var cut = ""
        for character in text {
            guard cut.utf8.count + String(character).utf8.count <= maxTextBytes else {
                cut += "…"
                break
            }
            cut.append(character)
        }
        return ChatReminder(
            id: id, destination: destination, accountId: accountId, network: network, chatTitle: chatTitle, messageId: messageId,
            senderName: senderName, senderAvatarURL: senderAvatarURL, text: cut, dueDate: dueDate, pushedTo: nil,
        )
    }
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

/// Reminders, kept in `UserDefaults` and synced across the user's devices through iCloud Key-Value storage, each
/// with a local notification at its due date on every device that has heard of it. A due reminder stays in the
/// feed until the user removes it there.
///
/// Reminders never change once made, so syncing is a union of reminders minus a union of removed ids. Removals
/// stay as tombstones (pruned after `tombstoneLifetime`) so a device that hasn't heard of one can't bring the
/// reminder back.
@MainActor
public enum ChatReminderStore {
    public enum Delay: CaseIterable, Sendable {
        case fiveMinutes, thirtyMinutes, oneHour, threeHours, tomorrow

        var metricName: String {
            switch self {
            case .fiveMinutes: "5m"
            case .thirtyMinutes: "30m"
            case .oneHour: "1h"
            case .threeHours: "3h"
            case .tomorrow: "tomorrow"
            }
        }

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
    private static let removedKey = "tech.stupid.StupidSocial.chatReminders.removed"
    private static let cloudKey = "com.stupid.chatreminders"
    nonisolated static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60

    /// What syncs: every live reminder, and when each removed one was removed (seconds since 1970).
    public struct SyncState: Codable, Equatable, Sendable {
        public var reminders: [ChatReminder]
        public var removed: [String: Double]

        public init(reminders: [ChatReminder], removed: [String: Double]) {
            self.reminders = reminders
            self.removed = removed
        }

        /// Both sides' reminders, oldest due first, without any either side removed.
        public static func merged(_ local: SyncState, _ remote: SyncState, now: Date = Date()) -> SyncState {
            let cutoff = now.timeIntervalSince1970 - ChatReminderStore.tombstoneLifetime
            let removed = local.removed.merging(remote.removed) { max($0, $1) }.filter { $0.value > cutoff }
            var seen = Set<String>()
            let reminders = (local.reminders + remote.reminders)
                .filter { removed[$0.id] == nil && seen.insert($0.id).inserted }
                .sorted { ($0.dueDate, $0.id) < ($1.dueDate, $1.id) }
            return SyncState(reminders: reminders, removed: removed)
        }
    }

    private static var kvStore: NSUbiquitousKeyValueStore?
    private static var syncObserver: NSObjectProtocol?

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

    /// Saves the reminder and schedules its notification, asking for permission the first time. `delay` is the preset
    /// the due date came from, `nil` for a custom date.
    public static func schedule(
        _ message: ChatMessage,
        in target: ChatReminderTarget,
        dueDate: Date,
        delay: Delay?,
        defaults: UserDefaults = .standard,
    ) async throws -> ChatReminder {
        var reminder = ChatReminder(
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
            pushedTo: nil,
        )
        // Pushed before it syncs, so the devices it reaches know not to schedule a notification of their own. When the
        // push can't be scheduled, they schedule one once they sync it.
        let delivery: String
        do {
            reminder = try await reminder.pushed(to: ChatReminderPush.schedule(reminder))
            delivery = reminder.pushedTo == nil ? "local_only" : "pushed"
        } catch {
            AppMetrics.chatReminderPushFailed(step: "schedule", error: error)
            delivery = "push_failed"
        }
        AppMetrics.chatReminderSet(network: target.network, delay: delay?.metricName ?? "custom", delivery: delivery)
        var state = localState(defaults: defaults)
        state.reminders.append(reminder)
        save(state, defaults: defaults)

        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        // The first reminder may be what granted permission, which this device needs to receive pushes too.
        ChatReminderPush.register()
        try await addNotification(for: reminder)
        return reminder
    }

    /// Adds a reminder another device pushed, when it arrives before iCloud syncs it; nothing if it's known or removed.
    public static func adopt(pushed data: Data, defaults: UserDefaults = .standard) {
        guard let reminder = try? JSONDecoder().decode(ChatReminder.self, from: data) else { return }
        var state = localState(defaults: defaults)
        guard state.removed[reminder.id] == nil, !state.reminders.contains(where: { $0.id == reminder.id }) else { return }
        state.reminders.append(reminder)
        save(state, defaults: defaults)
    }

    private static func addNotification(for reminder: ChatReminder) async throws {
        let notification = reminder.notification
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.userInfo = [ChatReminder.userInfoKey: reminder.id]
        let interval = max(1, reminder.dueDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ChatReminder.itemIdPrefix + reminder.id, content: content, trigger: trigger))
    }

    /// Drops the reminder and its notification, when the user removes it from the feed.
    public static func remove(id: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var state = localState(defaults: defaults)
        let removed = state.reminders.first { $0.id == id }
        state.reminders.removeAll { $0.id == id }
        state.removed[id] = date.timeIntervalSince1970
        save(state, defaults: defaults)
        removeNotifications(ids: [id])
        if let removed, removed.pushedTo != nil, removed.dueDate > date {
            Task {
                do {
                    try await ChatReminderPush.cancel(reminderId: id)
                } catch {
                    AppMetrics.chatReminderPushFailed(step: "cancel", error: error)
                }
            }
        }
    }

    // MARK: Sync

    /// Merges what other devices synced, then keeps merging as they change it, scheduling notifications for
    /// reminders made elsewhere and cancelling those removed elsewhere. Called once at launch.
    public static func startSync(kvStore: NSUbiquitousKeyValueStore = .default) {
        guard syncObserver == nil else { return }
        self.kvStore = kvStore
        ChatReminderPush.start(kvStore: kvStore)
        kvStore.synchronize()
        syncObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { mergeRemote(defaults: .standard) }
        }
        mergeRemote(defaults: .standard)
    }

    private static func mergeRemote(defaults: UserDefaults) {
        guard let kvStore else { return }
        let local = localState(defaults: defaults)
        let remote = kvStore.data(forKey: cloudKey).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
            ?? SyncState(reminders: [], removed: [:])
        let merged = SyncState.merged(local, remote)
        if merged != local {
            save(merged, defaults: defaults)
        } else if merged != remote {
            push(merged)
        }
        Task { await syncNotifications(merged) }
    }

    /// Schedules the notification of every reminder not yet due that this device has none for and no push will
    /// bring, without asking for permission here, and clears those of removed reminders.
    private static func syncNotifications(_ state: SyncState) async {
        removeNotifications(ids: Array(state.removed.keys))
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
        let pending = await Set(center.pendingNotificationRequests().map(\.identifier))
        let delivered = await Set(center.deliveredNotifications().map(\.request.identifier))
        let now = Date()
        let deviceId = ChatReminderPush.deviceId
        for reminder in state.reminders where reminder.dueDate > now {
            if let deviceId, reminder.pushedTo?.contains(deviceId) == true { continue }
            let identifier = ChatReminder.itemIdPrefix + reminder.id
            guard !pending.contains(identifier), !delivered.contains(identifier) else { continue }
            try? await addNotification(for: reminder)
        }
    }

    private static func removeNotifications(ids: [String]) {
        guard !ids.isEmpty else { return }
        let identifiers = ids.map { ChatReminder.itemIdPrefix + $0 }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        // A pushed reminder's notification has the push's identifier; its id is in `userInfo`.
        let removed = Set(ids)
        Task {
            let pushed = await center.deliveredNotifications()
                .filter { ($0.request.content.userInfo[ChatReminder.userInfoKey] as? String).map(removed.contains) == true }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: pushed)
        }
    }

    private static func localState(defaults: UserDefaults) -> SyncState {
        let removed = defaults.data(forKey: removedKey).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        return SyncState(reminders: all(defaults: defaults), removed: removed)
    }

    private static func save(_ state: SyncState, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(state.reminders), forKey: defaultsKey)
        defaults.set(try? JSONEncoder().encode(state.removed), forKey: removedKey)
        push(state)
        NotificationCenter.default.post(name: remindersDidChange, object: nil)
    }

    private static func push(_ state: SyncState) {
        guard let kvStore, let data = try? JSONEncoder().encode(state) else { return }
        kvStore.set(data, forKey: cloudKey)
        kvStore.synchronize()
    }
}
