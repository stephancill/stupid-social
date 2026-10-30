import Combine
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
        ChatReminderStore.startSync()
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
        let content = notification.request.content
        if content.userInfo[ChatReminder.userInfoKey] != nil {
            let pushed = content.userInfo[ChatReminderNotification.reminderDataKey] as? Data
            Task { @MainActor in
                if let pushed {
                    ChatReminderStore.adopt(pushed: pushed)
                }
                NotificationCenter.default.post(name: ChatReminderStore.reminderDidFire, object: nil)
            }
        }
        let thread = Self.telegramPeer(content.userInfo).map { NotificationRouter.telegramThread($0) } ?? content.threadIdentifier
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
        if let reminderId = content.userInfo[ChatReminder.userInfoKey] as? String {
            let opens = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            let pushed = content.userInfo[ChatReminderNotification.reminderDataKey] as? Data
            Task { @MainActor in
                if let pushed {
                    ChatReminderStore.adopt(pushed: pushed)
                }
                if opens {
                    AppMetrics.chatReminderOpened(source: pushed == nil ? "local" : "push")
                    NotificationRouter.shared.openReminder(id: reminderId)
                }
                completion()
            }
            return
        }
        if let peer = Self.telegramPeer(content.userInfo) {
            let opens = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            Task { @MainActor in
                if opens {
                    AppMetrics.notificationOpened(network: .telegram)
                    NotificationRouter.shared.pendingChat = .telegram(peer: peer)
                }
                completion()
            }
            return
        }
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
                AppMetrics.notificationOpened(network: .apron)
                NotificationRouter.shared.pendingChat = destination
            }
            completion()
        }
    }
}

extension AppDelegate {
    /// The chat a Telegram push is about. The access hash comes from the Chats list when the chat opens.
    nonisolated static func telegramPeer(_ userInfo: [AnyHashable: Any]) -> TelegramPeer? {
        switch TelegramPushChat(userInfo: userInfo) {
        case let .user(id): TelegramPeer(kind: .user, id: id, accessHash: 0)
        case let .chat(id): TelegramPeer(kind: .chat, id: id, accessHash: 0)
        case let .channel(id): TelegramPeer(kind: .channel, id: id, accessHash: 0)
        case nil: nil
        }
    }
}

/// Chats a notification or link asked to open, the Apron rooms on screen, and replies sent from notifications.
@MainActor
final class NotificationRouter: ObservableObject {
    /// An Apron link waiting for the user to confirm it, or why it can't be opened.
    enum LinkRequest: Identifiable, Equatable {
        case link(ApronLink)
        case invalid(String)

        var id: String {
            switch self {
            case let .link(link): "link:\(link.webURL.absoluteString)|\(link.token ?? "")"
            case let .invalid(message): "invalid:\(message)"
            }
        }
    }

    /// A message or member to show once a linked Apron room opens.
    struct ChatFocus: Equatable {
        var messageId: String?
        var userId: String?
    }

    static let shared = NotificationRouter()

    @Published var pendingChat: ChatSummary.Destination?
    /// Read with `pendingChat` when it opens.
    var pendingFocus: ChatFocus?
    @Published var linkRequest: LinkRequest?
    private(set) var openThreads: Set<String> = []
    /// The app's Apron service once the UI has built it. A reply that launches the app in the background,
    /// without a scene, makes its own.
    weak var apronService: ApronService?
    weak var chatList: ChatListViewModel? {
        didSet { routeWaitingLink() }
    }

    /// A link opened before the Chats list could say which rooms are joined.
    private var waitingLink: ApronLink?
    private var chatListLoad: AnyCancellable?

    /// Opens an Apron link in the app, never in a browser (SPEC.md §6). A room the user has joined opens directly;
    /// anything else waits for the user to confirm. `contentServer` is the server that sent the text holding the
    /// link, which relative links refer to. Returns false for URLs that aren't Apron links.
    func open(_ url: URL, contentServer: URL? = nil) -> Bool {
        guard ApronLink.isLink(url) else { return false }
        do {
            waitingLink = try ApronLink(url: url, contentServer: contentServer)
            routeWaitingLink()
        } catch {
            linkRequest = .invalid(error.localizedDescription)
        }
        return true
    }

    /// Joined rooms are the ones in the Chats list, so a link waits for the list: at launch, before the UI has
    /// built it, and until its first load when there was no saved list or the saved one didn't decode.
    private func routeWaitingLink() {
        guard let link = waitingLink, let chatList else { return }
        guard chatList.hasLoaded else {
            // `@Published` emits before the value is stored, so the check runs again on the next turn.
            chatListLoad = chatList.$hasLoaded.first(where: \.self).sink { [weak self] _ in
                Task { @MainActor in self?.routeWaitingLink() }
            }
            return
        }
        waitingLink = nil
        chatListLoad = nil
        if link.token == nil, let room = link.room, chatList.contains(.apron(serverURL: link.serverURL, roomId: room)) {
            openRoom(of: link)
        } else {
            linkRequest = .link(link)
        }
    }

    /// Opens a reminder's chat at its message. The reminder stays in the feed until the user removes it there.
    func openReminder(id: String) {
        guard let reminder = ChatReminderStore.reminder(id: id) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ChatReminder.itemIdPrefix + id])
        pendingFocus = ChatFocus(messageId: reminder.messageId)
        pendingChat = reminder.destination
    }

    func openRoom(of link: ApronLink) {
        guard let room = link.room else { return }
        pendingFocus = ChatFocus(messageId: link.message, userId: link.user)
        pendingChat = .apron(serverURL: link.serverURL, roomId: room)
    }

    /// Marks a room on screen and clears its delivered notifications.
    func roomDidOpen(serverURL: URL, roomId: String) {
        let thread = ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId)
        openThreads.insert(thread)
        clearNotifications(thread: thread)
    }

    func roomDidClose(serverURL: URL, roomId: String) {
        openThreads.remove(ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId))
    }

    /// Marks a Telegram chat on screen and clears its delivered notifications, matched by the chat they name
    /// rather than their thread, which Telegram sets when the extension doesn't run.
    func telegramChatDidOpen(_ peer: TelegramPeer) {
        let thread = Self.telegramThread(peer)
        openThreads.insert(thread)
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { AppDelegate.telegramPeer($0.request.content.userInfo).map(Self.telegramThread) == thread }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func telegramChatDidClose(_ peer: TelegramPeer) {
        openThreads.remove(Self.telegramThread(peer))
    }

    /// The access hash isn't in pushes, so chats match on kind and id.
    nonisolated static func telegramThread(_ peer: TelegramPeer) -> String {
        "telegram|\(peer.kind.rawValue):\(peer.id)"
    }

    /// Posts a reply typed into a notification. On success the room's notifications are cleared; on failure a
    /// notification says so, since there is no screen to show it on.
    func sendReply(_ text: String, to destination: ChatSummary.Destination, replyTo: String?, title: String) async {
        guard case let .apron(serverURL, roomId) = destination else { return }
        let service = apronService ?? ApronService(accountStore: AccountStore(), keychainStore: KeychainCredentialStore())
        do {
            try await service.send(text: text, serverURL: serverURL, roomId: roomId, replyTo: replyTo)
            AppMetrics.notificationReplied(network: .apron, error: nil)
            clearNotifications(thread: ApronPushNotification.threadIdentifier(serverURL: serverURL, roomId: roomId))
        } catch {
            AppMetrics.notificationReplied(network: .apron, error: error)
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
