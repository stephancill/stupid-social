import Foundation
@preconcurrency import UserNotifications

/// The sound every notification plays, chosen in Settings. Kept in the App Group's defaults so the notification
/// extension applies it to pushes; the bundled sounds are `Resources/Notification*.caf`
/// (`scripts/notification-sounds.sh`; Bamboo, as Telegram offers it, is the iOS tone from macOS), in the app bundle where the system looks for them.
public enum NotificationSound: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case bamboo
    case chime
    case ping
    case pop
    case bell
    case none

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .default: "Default"
        case .bamboo: "Bamboo"
        case .chime: "Chime"
        case .ping: "Ping"
        case .pop: "Pop"
        case .bell: "Bell"
        case .none: "None"
        }
    }

    /// The bundled file, for a sound that isn't the system's.
    public var fileName: String? {
        switch self {
        case .default, .none: nil
        case .bamboo: "NotificationBamboo.caf"
        case .chime: "NotificationChime.caf"
        case .ping: "NotificationPing.caf"
        case .pop: "NotificationPop.caf"
        case .bell: "NotificationBell.caf"
        }
    }

    public var notificationSound: UNNotificationSound? {
        switch self {
        case .default: .default
        case .none: nil
        default: fileName.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
        }
    }

    /// Swaps a push's sound for the chosen one; a push that came silent stays silent.
    public static func apply(to content: UNMutableNotificationContent) {
        guard content.sound != nil else { return }
        content.sound = current.notificationSound
    }

    private static let key = "notificationSound"
    private nonisolated(unsafe) static let defaults = UserDefaults(suiteName: ApronPushStore.appGroup)

    public static var current: NotificationSound {
        get { defaults?.string(forKey: key).flatMap(NotificationSound.init(rawValue:)) ?? .default }
        set { defaults?.set(newValue.rawValue, forKey: key) }
    }
}
