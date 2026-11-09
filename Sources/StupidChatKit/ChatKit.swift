import SwiftUI

/// What an app sets once at launch for the chat framework: its network icons and where its usage events go.
@MainActor
public enum ChatKit {
    /// Each thing the user does in a chat, for usage metrics.
    public static var onEvent: (ChatEvent) -> Void = { _ in }
    /// A network's icon at a size in points, beside a chat's title; none by default.
    public static var networkIcon: (ChatNetwork, CGFloat) -> AnyView = { _, _ in AnyView(EmptyView()) }
    /// Opens a link the app handles itself, such as its own universal links, and returns whether it did; others
    /// open in the browser. The second URL is what relative links in the message resolve against
    /// (`ChatViewModel.linkBaseURL`).
    public static var openAppLink: (URL, URL?) -> Bool = { _, _ in false }
}

/// A chat network, named by its id (such as "telegram"). The framework only compares networks; an app adds its
/// networks as static members (`static let telegram = ChatNetwork(rawValue: "telegram")`).
public struct ChatNetwork: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Something the user did in a chat, reported through `ChatKit.onEvent`. An `error` is set when it failed.
public enum ChatEvent {
    case opened(network: ChatNetwork)
    case searched(network: ChatNetwork)
    case messageSent(network: ChatNetwork, hasAttachment: Bool, isVoice: Bool, isReply: Bool, error: (any Error)?)
    case messageEdited(network: ChatNetwork, error: (any Error)?)
    case messageDeleted(network: ChatNetwork, error: (any Error)?)
    case messageForwarded(network: ChatNetwork, from: ChatNetwork, isNative: Bool, error: (any Error)?)
    case messageButtonPressed(network: ChatNetwork, error: (any Error)?)
}

/// An error a `ChatListProvider` throws when its network isn't connected: when `isNotConnected`, the provider
/// lists no chats and shows no error.
public protocol ChatNotConnectedError: Error {
    var isNotConnected: Bool { get }
}

/// Reminders of messages in one chat, offered in a message's long-press menu when the chat's view model has
/// them (`ChatViewModel.reminders`). The app keeps and delivers them.
@MainActor
public protocol ChatReminders {
    /// Posted when the chat's reminders change.
    var didChange: Notification.Name { get }
    /// Message id → when its reminder is due, the earliest when it has several.
    func dueDates() -> [String: Date]
    /// Drops the message's reminders.
    func markDone(messageId: String)
    /// `delay` is the preset `dueDate` came from; `nil` for a date the user picked.
    func schedule(_ message: ChatMessage, dueDate: Date, delay: ChatReminderDelay?) async throws
}

/// The presets a message's "Remind Me" offers.
public enum ChatReminderDelay: CaseIterable, Sendable {
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

/// "Redact names": people's names in chats show as "Redacted", such as for screenshots. On while the bool in
/// `UserDefaults.standard` at `defaultsKey` is true.
public enum ChatRedaction {
    public static let defaultsKey = "redactionEnabled"

    /// For UIKit code that can't use `@AppStorage(ChatRedaction.defaultsKey)`.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// A chat participant's name.
    public static func name(_ value: String, enabled: Bool = isEnabled) -> String {
        enabled ? "Redacted" : value
    }

    /// Text with each `@` mention shown as `@Redacted`.
    public static func mentions(in text: String, pattern: NSRegularExpression?, enabled: Bool = isEnabled) -> String {
        guard enabled, let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "@Redacted")
    }
}
