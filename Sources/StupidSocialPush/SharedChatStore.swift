import Foundation
import StupidChatKit

/// The app's chat store, and the inbox the notification extension leaves pushed messages in so a chat opens on
/// them before its network's copy loads.
///
/// The store stays in the app's own container: iOS kills an app that is suspended while it holds a SQLite lock in
/// the App Group container (`0xdead10cc`, build 214 while a chat-store read ran). The extension never opens it;
/// it writes each pushed message as its own JSON file to `chat-inbox/` in the App Group, atomically, and posts
/// `darwinNotificationName`. The app moves the inbox into the store at launch, on returning to the foreground and
/// on that notification.
public enum SharedChatStore {
    /// Tells the app that the extension left a message in the inbox.
    public static let darwinNotificationName = "tech.stupid.StupidSocial.chatStoreDidChange"

    /// Raised whenever an adapter's records change shape (how `TelegramMessage` parses media, say): stored messages
    /// keep the shape they were stored in, so a new format clears stored history and chats load again.
    public static let recordFormat = 1
    private static let recordFormatKey = "chatStoreRecordFormat"

    private static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)
    }

    /// Ad-hoc simulator builds have no App Group, so the extension leaves nothing there.
    public static var inboxURL: URL? {
        groupContainer?.appending(path: "chat-inbox", directoryHint: .isDirectory)
    }

    /// The store as the app opens it at launch, clearing stored history when the record format changed.
    public static func openForApp() throws -> ChatStore {
        removeGroupStore()
        let store = try ChatStore()
        if UserDefaults.standard.integer(forKey: recordFormatKey) != recordFormat {
            try store.removeHistory()
            UserDefaults.standard.set(recordFormat, forKey: recordFormatKey)
        }
        return store
    }

    /// Builds 204–216 kept the store in the App Group. Removing a file takes no lock, so this is safe even if an
    /// older extension still has it open; the history it held loads again from each network.
    private static func removeGroupStore() {
        guard let directory = groupContainer?.appending(path: "Library/Application Support") else { return }
        for name in ["chat-store.sqlite", "chat-store.sqlite-wal", "chat-store.sqlite-shm"] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// An Apron account's chat key for a room, as `ApronChatAdapter` names it (`Account.apronId`).
    public static func apronChatKey(serverURL: URL, roomId: String) -> String {
        "apron.\(serverURL.absoluteString)|apron:\(roomId)"
    }

    // MARK: Inbox

    /// One pushed message waiting for the app.
    struct InboxEntry: Codable, Equatable {
        /// Either way the message is written provisional: a push says nothing about what came before it, and stored as
        /// history it started a chunk of its own, so the chat counted as current, loading ahead skipped it, and it
        /// opened on the pushed messages alone with earlier ones filling in above.
        enum Target: Codable, Equatable {
            /// To this chat.
            case chat(String)
            /// To every stored chat whose key ends with this, since the push doesn't say which account it is for.
            case provisional(chatKeySuffix: String)
        }

        let target: Target
        let id: String
        let sortKey: Int64
        let relatesTo: String?
        let version: Int64
        let data: Data

        init(target: Target, record: ChatRecord) {
            self.target = target
            id = record.id
            sortKey = record.sortKey
            relatesTo = record.relatesTo
            version = record.version
            data = record.data
        }

        var record: ChatRecord {
            ChatRecord(id: id, sortKey: sortKey, relatesTo: relatesTo, version: version, data: data)
        }
    }

    /// From the extension: a pushed message for one chat.
    public static func leave(_ record: ChatRecord, chatKey: String, inbox: URL? = inboxURL) throws {
        try leave(InboxEntry(target: .chat(chatKey), record: record), inbox: inbox)
    }

    /// From the extension: a pushed message shown provisionally in each stored chat whose key ends with the suffix.
    public static func leaveProvisional(_ record: ChatRecord, chatKeySuffix: String, inbox: URL? = inboxURL) throws {
        try leave(InboxEntry(target: .provisional(chatKeySuffix: chatKeySuffix), record: record), inbox: inbox)
    }

    private static func leave(_ entry: InboxEntry, inbox: URL?) throws {
        guard let inbox else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // Named by time so the app applies them in order; one file per message, so writers never share a file.
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let name = String(format: "%018lld-%@.json", micros, UUID().uuidString)
        // Readable after the first unlock, when a push may arrive with the phone locked.
        try JSONEncoder().encode(entry).write(to: inbox.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinNotificationName as CFString), nil, nil, true)
    }

    /// From the app: writes every message in the inbox to the store, oldest first, and removes it. Each file is
    /// removed even when its write fails, so one bad entry can't block the rest; the first failure is thrown after.
    @MainActor
    public static func importInbox(into store: ChatStore, inbox: URL? = inboxURL) throws {
        guard let inbox,
              let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path())
        else { return }
        var firstError: (any Error)?
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = inbox.appending(path: name)
            do {
                let entry = try JSONDecoder().decode(InboxEntry.self, from: Data(contentsOf: url))
                switch entry.target {
                case let .chat(chatKey):
                    try store.writeProvisional([entry.record], chatKey: chatKey)
                case let .provisional(suffix):
                    for chatKey in try store.chatKeys(endingWith: suffix) {
                        try store.writeProvisional([entry.record], chatKey: chatKey)
                    }
                }
            } catch {
                firstError = firstError ?? error
            }
            try? FileManager.default.removeItem(at: url)
        }
        if let firstError { throw firstError }
    }
}
