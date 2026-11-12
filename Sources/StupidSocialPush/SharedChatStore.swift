import Foundation
import StupidChatKit

/// The chat store the app and its notification extension share, in the App Group container, so a message a push
/// brings is stored before the user opens its chat.
public enum SharedChatStore {
    /// Tells the other process the file changed (`ChatStore`'s Darwin notification).
    public static let darwinNotificationName = "tech.stupid.StupidSocial.chatStoreDidChange"

    /// Ad-hoc simulator builds have no App Group, so the app keeps the store in its own container there; the
    /// extension then writes nowhere.
    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)?
            .appending(path: "Library/Application Support/chat-store.sqlite")
    }

    public static func open() throws -> ChatStore {
        try ChatStore(url: url ?? ChatStore.defaultURL(), darwinNotificationName: darwinNotificationName)
    }

    /// An Apron account's chat key for a room, as `ApronChatAdapter` names it (`Account.apronId`).
    public static func apronChatKey(serverURL: URL, roomId: String) -> String {
        "apron.\(serverURL.absoluteString)|apron:\(roomId)"
    }
}
