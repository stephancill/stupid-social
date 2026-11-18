import Foundation
import StupidChatKit
import Synchronization

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

    /// Raised whenever an adapter's records change shape (how `TelegramMessage` parses media, say): stored messages
    /// keep the shape they were stored in, so a new format clears stored history and chats load again.
    public static let recordFormat = 1
    private static let recordFormatKey = "chatStoreRecordFormat"

    /// The store as the extension opens it: it only adds messages, so it never clears history, even where it can't
    /// read the app's record format (it read none on the simulator and cleared every chat, observed 2026-11-13).
    public static func open() throws -> ChatStore {
        try ChatStore(url: url ?? ChatStore.defaultURL(), darwinNotificationName: darwinNotificationName)
    }

    private static let extensionStore = Mutex<ChatStore?>(nil)

    /// The extension's store, opened on its first push and kept for the process: each store posts a Darwin
    /// notification on writing that arrives after a store opened for one write is gone, which crashed the extension
    /// before it showed the push (observed 2026-11-18), and reopening the database for every push is slow.
    public static func openForExtension() throws -> ChatStore {
        try extensionStore.withLock { store in
            if let store { return store }
            let opened = try open()
            store = opened
            return opened
        }
    }

    /// The store as the app opens it at launch, clearing stored history when the record format changed.
    public static func openForApp() throws -> ChatStore {
        let store = try open()
        if UserDefaults.standard.integer(forKey: recordFormatKey) != recordFormat {
            try store.removeHistory()
            UserDefaults.standard.set(recordFormat, forKey: recordFormatKey)
        }
        return store
    }

    /// An Apron account's chat key for a room, as `ApronChatAdapter` names it (`Account.apronId`).
    public static func apronChatKey(serverURL: URL, roomId: String) -> String {
        "apron.\(serverURL.absoluteString)|apron:\(roomId)"
    }
}
