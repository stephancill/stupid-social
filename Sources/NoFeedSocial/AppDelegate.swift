import NoFeedSocialCore
import NoFeedSocialPush
import UIKit
import UserNotifications

/// Receives the APNs device token for Apron push, and routes notification taps, inline replies and foreground
/// presentation.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: ApronPushNotification.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message",
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ApronPushNotification.categoryIdentifier, actions: [reply], intentIdentifiers: []),
        ])
        // Issues a token without asking; alerts still need the user's permission, asked when a server offers push.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ApronPushService.setDeviceToken(deviceToken)
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError _: Error) {}

    /// The open room's notifications aren't shown; it shows the message itself.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        let thread = notification.request.content.threadIdentifier
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            completion(NotificationRouter.shared.openThreads.contains(thread) ? [] : [.banner, .list, .sound])
        }
    }

    /// Opens the chat, or sends the typed reply. The completion handler is called on the main thread: called off it,
    /// as the `async` form does, UIKit aborts while launching the app from a notification.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        nonisolated(unsafe) let completion = completionHandler
        let content = response.notification.request.content
        guard let info = content.userInfo[ApronPushNotification.userInfoKey] as? [String: String],
              let server = info["server"].flatMap(URL.init(string:)),
              let room = info["room"]
        else {
            Task { @MainActor in completion() }
            return
        }
        let destination = ChatSummary.Destination.apron(serverURL: server, roomId: room)
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // DMs get a plain message; in a room the reply quotes the message, so it is clear what it answers.
        let replyTo = info["direct"] == "1" ? nil : info["message"]
        let title = content.title
        Task { @MainActor in
            if action == ApronPushNotification.replyActionIdentifier {
                if !text.isEmpty {
                    await NotificationRouter.shared.sendReply(text, to: destination, replyTo: replyTo, title: title)
                }
            } else if action == UNNotificationDefaultActionIdentifier {
                NotificationRouter.shared.pendingChat = destination
            }
            completion()
        }
    }
}

/// Chats a notification asked to open, the Apron rooms on screen, and replies sent from notifications.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    @Published var pendingChat: ChatSummary.Destination?
    private(set) var openThreads: Set<String> = []
    /// The app's Apron service once the UI has built it. A reply that launches the app in the background,
    /// without a scene, makes its own.
    weak var apronService: ApronService?

    /// Marks a room on screen and clears its delivered notifications.
    func roomDidOpen(serverURL: URL, roomId: String) {
        let thread = ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId)
        openThreads.insert(thread)
        clearNotifications(thread: thread)
    }

    func roomDidClose(serverURL: URL, roomId: String) {
        openThreads.remove(ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId))
    }

    /// Posts a reply typed into a notification. On success the room's notifications are cleared; on failure a
    /// notification says so, since there is no screen to show it on.
    func sendReply(_ text: String, to destination: ChatSummary.Destination, replyTo: String?, title: String) async {
        guard case let .apron(serverURL, roomId) = destination else { return }
        let service = apronService ?? ApronService(metadataStore: AccountMetadataStore(), keychainStore: KeychainCredentialStore())
        do {
            try await service.send(text: text, serverURL: serverURL, roomId: roomId, replyTo: replyTo)
            clearNotifications(thread: ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId))
        } catch {
            let content = UNMutableNotificationContent()
            content.title = "Reply not sent"
            content.body = "Your reply to \(title) wasn't sent: \(error.localizedDescription)"
            content.threadIdentifier = ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId)
            content.userInfo = [ApronPushNotification.userInfoKey: ["server": serverURL.absoluteString, "room": roomId]]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        // In the background, go offline again so the server keeps pushing.
        if UIApplication.shared.applicationState != .active {
            service.closeSessions(for: serverURL)
        }
    }

    private func clearNotifications(thread: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
