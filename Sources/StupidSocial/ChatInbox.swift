import StupidSocialCore
import StupidSocialPush
import UIKit

/// Moves the messages the notification extension leaves in the App Group inbox into the chat store: at launch,
/// on returning to the foreground (before a tapped notification opens its chat) and whenever the extension says it
/// left one while the app runs.
@MainActor
enum ChatInbox {
    private static var store: ChatStore?
    private static var foregroundObserver: (any NSObjectProtocol)?

    static func start(store: ChatStore) {
        self.store = store
        importInbox()
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { importInbox() }
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in ChatInbox.importInbox() }
        }, SharedChatStore.darwinNotificationName as CFString, nil, .deliverImmediately)
    }

    private static func importInbox() {
        guard let store else { return }
        do {
            try SharedChatStore.importInbox(into: store)
        } catch {
            AppMetrics.chatInboxImportFailed(error)
        }
    }
}
