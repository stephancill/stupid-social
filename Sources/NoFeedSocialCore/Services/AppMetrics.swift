import Foundation
import StupidMetrics

/// Every anonymous usage event and error the app reports to metrics.stupidtech.net, in one place.
/// Properties are networks, triggers and outcomes only: never names, handles, message text, URLs or ids.
/// Errors are sent as their type and case (`StupidMetrics.describe`), never `localizedDescription`.
public enum AppMetrics {
    /// Public client key for the app's metrics; it only allows sending events.
    private static let appKey = "smk_kqG6iIy-ZQgg-oq-Xcr80LI8QrujEldP"

    @MainActor
    public static func configure() {
        StupidMetrics.configure(appKey: appKey)
    }

    /// Whether the user shares anonymous usage data (Settings → Privacy).
    public static var isEnabled: Bool {
        get { StupidMetrics.isEnabled }
        set { StupidMetrics.isEnabled = newValue }
    }

    // MARK: Feed

    static func sourceRefreshed(network: SocialNetwork, trigger: String, duration: Duration, error: (any Error)?) {
        let props = ["network": network.rawValue, "trigger": trigger]
        StupidMetrics.track("refresh", properties: props.merging(["outcome": error == nil ? "ok" : "error"]) { $1 }, value: milliseconds(duration))
        if let error {
            StupidMetrics.error("source_error", error: error, properties: props)
        }
    }

    static func sourceRefreshCancelled(network: SocialNetwork, trigger: String, duration: Duration) {
        StupidMetrics.track("refresh", properties: ["network": network.rawValue, "trigger": trigger, "outcome": "cancelled"], value: milliseconds(duration))
    }

    static func storySourceFailed(network: SocialNetwork, error: any Error) {
        StupidMetrics.error("story_source_error", error: error, properties: ["network": network.rawValue])
    }

    /// Connected accounts per network, once per launch.
    public static func accounts(_ accounts: [Account]) {
        for (network, accounts) in Dictionary(grouping: accounts, by: \.network) {
            StupidMetrics.track("accounts", properties: ["network": network.rawValue], value: Double(accounts.count))
        }
    }

    // MARK: Chats

    public static func chatOpened(network: SocialNetwork) {
        StupidMetrics.track("chat_open", properties: ["network": network.rawValue])
    }

    /// Search was opened in a chat (long-pressing its title).
    static func chatSearched(network: SocialNetwork) {
        StupidMetrics.track("chat_search", properties: ["network": network.rawValue])
    }

    static func messageSent(network: SocialNetwork, hasAttachment: Bool, isReply: Bool, error: (any Error)?) {
        StupidMetrics.track("message_send", properties: [
            "network": network.rawValue,
            "attachment": hasAttachment ? "yes" : "no",
            "reply": isReply ? "yes" : "no",
            "outcome": error == nil ? "ok" : "error",
        ])
        if let error {
            StupidMetrics.error("message_send_failed", error: error, properties: ["network": network.rawValue])
        }
    }

    // MARK: Notifications

    public static func notificationOpened(network: SocialNetwork) {
        StupidMetrics.track("notification_open", properties: ["network": network.rawValue])
    }

    public static func notificationReplied(network: SocialNetwork, error: (any Error)?) {
        StupidMetrics.track("notification_reply", properties: ["network": network.rawValue, "outcome": error == nil ? "ok" : "error"])
        if let error {
            StupidMetrics.error("notification_reply_failed", error: error, properties: ["network": network.rawValue])
        }
    }

    // MARK: Chat reminders

    /// A reminder was set: `delay` is the preset or `custom`, `delivery` whether it was pushed to other devices
    /// (`pushed`), there were none (`local_only`) or scheduling the push failed (`push_failed`).
    static func chatReminderSet(network: SocialNetwork, delay: String, delivery: String) {
        StupidMetrics.track("chat_reminder_set", properties: ["network": network.rawValue, "delay": delay, "delivery": delivery])
    }

    /// A reminder was opened: from its notification, set here (`local`) or pushed by another device (`push`), or the feed.
    public static func chatReminderOpened(source: String) {
        StupidMetrics.track("chat_reminder_open", properties: ["source": source])
    }

    /// A reminder was cleared: Mark as Done in the chat (`chat`) or Remove Reminder in the feed (`feed`).
    public static func chatReminderDone(via: String) {
        StupidMetrics.track("chat_reminder_done", properties: ["via": via])
    }

    /// Registering for, scheduling or cancelling reminder pushes to the user's other devices failed.
    static func chatReminderPushFailed(step: String, error: any Error) {
        StupidMetrics.error("chat_reminder_push_failed", error: error, properties: ["step": step])
    }

    // MARK: Accounts

    static func accountConnected(network: SocialNetwork, isReconnect: Bool) {
        StupidMetrics.track("account_connect", properties: ["network": network.rawValue, "reconnect": isReconnect ? "yes" : "no"])
    }

    static func accountConnectFailed(network: SocialNetwork, error: any Error) {
        StupidMetrics.error("account_connect_failed", error: error, properties: ["network": network.rawValue])
    }

    static func accountRemoved(network: SocialNetwork) {
        StupidMetrics.track("account_remove", properties: ["network": network.rawValue])
    }

    // MARK: Stories

    public static func storyOpened(network: SocialNetwork) {
        StupidMetrics.track("story_open", properties: ["network": network.rawValue])
    }

    static func storyPosted(error: (any Error)?) {
        StupidMetrics.track("story_post", properties: ["network": SocialNetwork.instagram.rawValue, "outcome": error == nil ? "ok" : "error"])
        if let error {
            StupidMetrics.error("story_post_failed", error: error, properties: ["network": SocialNetwork.instagram.rawValue])
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
