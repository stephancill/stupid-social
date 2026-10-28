import Foundation
@preconcurrency import Intents
@preconcurrency import UserNotifications

/// Turns notification content into a Communication Notification from a person, which shows their avatar. Used
/// by the notification extension, and by Settings → Debug to post the same thing locally.
public enum CommunicationNotification {
    /// A Telegram message from its sender, with the avatar the app saved.
    public static func telegram(_ notification: TelegramPushNotification, content: UNMutableNotificationContent) async -> UNNotificationContent? {
        let sender = INPerson(
            personHandle: INPersonHandle(value: String(notification.senderId), type: .unknown),
            nameComponents: nil,
            displayName: notification.title,
            image: TelegramAvatarStore().load(userId: notification.senderId).map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: "telegram|\(notification.senderId)",
        )
        return await self.content(
            content,
            sender: sender,
            body: notification.body,
            conversation: notification.conversationId,
            log: PushExtensionLog.Entry(network: "telegram", chat: notification.conversationId, hasAvatar: sender.image != nil),
        )
    }

    /// Donates an incoming-message intent from `sender` and updates the content from it, recording the outcome in
    /// the extension log; `nil` when the update fails. The updated content is returned as it is: a mutable copy can
    /// lose the communication context, so anything else is set before.
    public static func content(
        _ content: UNMutableNotificationContent,
        sender: INPerson,
        body: String,
        conversation: String,
        log: PushExtensionLog.Entry,
    ) async -> UNNotificationContent? {
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: nil,
            conversationIdentifier: conversation,
            serviceName: nil,
            sender: sender,
            attachments: nil,
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        var log = log
        defer { PushExtensionLog().append(log) }
        do {
            try await interaction.donate()
        } catch {
            // The update can work without the donation, which only feeds Siri suggestions.
            log.donateError = error.localizedDescription
        }
        do {
            return try content.updating(from: intent)
        } catch {
            log.updateError = error.localizedDescription
            return nil
        }
    }
}

public extension TelegramPushNotification {
    /// Sets what shows even where the system doesn't apply the intent.
    func prepare(_ content: UNMutableNotificationContent) {
        content.title = title
        content.body = body
        content.threadIdentifier = "telegram|\(conversationId)"
    }
}
