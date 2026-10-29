import Foundation
@preconcurrency import Intents
@preconcurrency import UserNotifications

/// Turns notification content into a Communication Notification from a person, which shows their avatar. Used
/// by the notification extension, and by Settings → Debug to post the same thing locally.
public enum CommunicationNotification {
    /// A Telegram message from its sender, with the photos the app saved: the sender's in a private chat, and the
    /// group's in a group, shown as a group conversation. A group push that names only the group shows the group as
    /// the sender, as Telegram's own app does, since a group conversation would show its name twice.
    public static func telegram(_ notification: TelegramPushNotification, content: UNMutableNotificationContent) async -> UNNotificationContent? {
        let store = TelegramAvatarStore()
        let groupImage = notification.group.flatMap { store.load(groupId: $0.id) }.map { INImage(imageData: $0) }
        let sender: INPerson
        var group: (name: String, image: INImage?)?
        if let chat = notification.group, notification.senderName == nil {
            sender = INPerson(
                personHandle: INPersonHandle(value: "group-\(chat.id)", type: .unknown),
                nameComponents: nil,
                displayName: chat.name,
                image: groupImage,
                contactIdentifier: nil,
                customIdentifier: "telegram|group-\(chat.id)",
            )
        } else {
            sender = INPerson(
                personHandle: INPersonHandle(value: String(notification.senderId), type: .unknown),
                nameComponents: nil,
                displayName: notification.senderName ?? notification.title,
                image: store.load(userId: notification.senderId).map { INImage(imageData: $0) },
                contactIdentifier: nil,
                customIdentifier: "telegram|\(notification.senderId)",
            )
            group = notification.group.map { (name: $0.name, image: groupImage) }
        }
        return await self.content(
            content,
            sender: sender,
            body: notification.body,
            conversation: notification.conversationId,
            group: group,
            log: PushExtensionLog.Entry(
                network: "telegram",
                chat: notification.conversationId,
                hasAvatar: notification.group == nil ? sender.image != nil : groupImage != nil,
            ),
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
        group: (name: String, image: INImage?)? = nil,
        log: PushExtensionLog.Entry,
    ) async -> UNNotificationContent? {
        // iOS shows a group conversation, titled with the group and pictured with its image, for an intent with a
        // group name and more than one recipient.
        let recipients = group.map { _ in
            [sender, INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)]
        }
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: group.map { INSpeakableString(spokenPhrase: $0.name) },
            conversationIdentifier: conversation,
            serviceName: nil,
            sender: sender,
            attachments: nil,
        )
        if let image = group?.image {
            intent.setImage(image, forParameterNamed: \.speakableGroupName)
        }
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
