import Foundation
@preconcurrency import Intents
import NoFeedSocialPush
@preconcurrency import UserNotifications

/// Decrypts Apron pushes the relay forwards as `webpush` ciphertext and shows them as messages from the sender,
/// with their avatar, through an `INSendMessageIntent` (Communication Notifications). A push it can't read keeps
/// the relay's generic alert, since dropping a notification needs an entitlement.
@objc(NotificationService)
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // The system calls in on one thread at a time: `didReceive`, then possibly `serviceExtensionTimeWillExpire`.
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let ciphertext = request.content.userInfo["webpush"] as? String,
              let body = Data(base64URLEncoded: ciphertext),
              let notification = Self.notification(for: body),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else {
            contentHandler(request.content)
            return
        }
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.threadIdentifier = notification.threadIdentifier
        content.categoryIdentifier = ApronPushNotification.categoryIdentifier
        content.userInfo = notification.userInfo
        self.contentHandler = contentHandler
        fallback = content

        nonisolated(unsafe) let prepared = content
        Task {
            let communication = await Self.communicationContent(for: notification, content: prepared)
            self.finish(communication ?? prepared)
        }
    }

    /// Delivers what is ready before the system ends the extension.
    override func serviceExtensionTimeWillExpire() {
        if let fallback {
            finish(fallback)
        }
    }

    private func finish(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    /// Tries each registration's keys, since the `push_id` that names one is inside the ciphertext.
    private static func notification(for body: Data) -> ApronPushNotification? {
        let registrations = ApronPushStore().load()
        for registration in registrations.values {
            guard let payload = try? WebPushDecryptor.decrypt(body, keys: registration.keys) else { continue }
            return ApronPushNotification.make(payload: payload, registrations: registrations)
        }
        return nil
    }

    /// The content updated from a donated incoming-message intent, so it shows the sender's avatar; `nil` when the
    /// donation or update fails.
    private static func communicationContent(for notification: ApronPushNotification, content: UNMutableNotificationContent) async -> UNNotificationContent? {
        // A one-to-one message from "<sender> in <room>" rather than a group conversation, which iOS would title
        // with the room alone. The person stays per sender, so their avatar is the same in every room.
        let sender = await INPerson(
            personHandle: INPersonHandle(value: notification.senderId, type: .unknown),
            nameComponents: nil,
            displayName: notification.title,
            image: avatar(notification.senderAvatarURL),
            contactIdentifier: nil,
            customIdentifier: "\(notification.serverURL.absoluteString)|\(notification.senderId)",
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: notification.body,
            speakableGroupName: nil,
            conversationIdentifier: notification.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil,
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try content.updating(from: intent)
        } catch {
            return nil
        }
    }

    /// The avatar's image, or `nil` when there is none or it doesn't load quickly.
    private static func avatar(_ url: URL?) async -> INImage? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true,
              !data.isEmpty
        else { return nil }
        return INImage(imageData: data)
    }
}
