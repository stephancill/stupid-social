import Foundation

/// A message as the app keeps it. WhatsApp keeps no history for linked devices beyond the sync after linking,
/// so these are the app's own record of what it received and sent.
public struct WhatsAppMessage: Codable, Hashable, Sendable {
    public let id: String
    /// The sender's JID as a string (LID or phone number); the user's own messages have `isFromMe`.
    public let sender: String
    public let isFromMe: Bool
    public let timestamp: Date
    public var text: String?
    /// What stands in for content the app doesn't show, such as "Photo" or "Voice message".
    public var label: String?
    public var quotedId: String?
    public var isDeleted: Bool
    /// The latest edit's time, when the message was edited.
    public var editedAt: Date?
    /// Others' reactions by emoji, keyed by the reactor's JID.
    public var reactions: [String: String]

    public init(id: String, sender: String, isFromMe: Bool, timestamp: Date, text: String?, label: String?, quotedId: String? = nil, isDeleted: Bool = false, editedAt: Date? = nil, reactions: [String: String] = [:]) {
        self.id = id
        self.sender = sender
        self.isFromMe = isFromMe
        self.timestamp = timestamp
        self.text = text
        self.label = label
        self.quotedId = quotedId
        self.isDeleted = isDeleted
        self.editedAt = editedAt
        self.reactions = reactions
    }
}

/// A chat as the app keeps it, from history sync, app state and live messages.
public struct WhatsAppChat: Codable, Hashable, Sendable {
    /// The chat's JID: a group, or the other person's LID or phone number.
    public let jid: String
    /// The group subject or WhatsApp's name for the chat from history sync; contact names come from app state.
    public var name: String?
    public var unreadCount: Int
    public var markedUnread: Bool
    /// The mute end; `-1` mutes until unmuted, as WhatsApp stores it.
    public var muteEnd: Int64?
    public var isArchived: Bool
    public var isPinned: Bool
    public var lastTimestamp: Date?
    /// The phone-number JID of a one-to-one chat addressed by LID, from history sync.
    public var phoneNumberJID: String?
    /// Others' messages up to this time are read, once the app knows; until then `unreadCount` (from history
    /// sync) counts them.
    public var readUpTo: Date?

    public init(jid: String, name: String? = nil, unreadCount: Int = 0, markedUnread: Bool = false, muteEnd: Int64? = nil, isArchived: Bool = false, isPinned: Bool = false, lastTimestamp: Date? = nil, phoneNumberJID: String? = nil, readUpTo: Date? = nil) {
        self.jid = jid
        self.name = name
        self.unreadCount = unreadCount
        self.markedUnread = markedUnread
        self.muteEnd = muteEnd
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.lastTimestamp = lastTimestamp
        self.phoneNumberJID = phoneNumberJID
        self.readUpTo = readUpTo
    }

    public var isGroup: Bool {
        jid.hasSuffix("@g.us")
    }

    public func isMuted(at date: Date = Date()) -> Bool {
        guard let muteEnd, muteEnd != 0 else { return false }
        if muteEnd < 0 { return true }
        // History sync stores seconds, app state milliseconds.
        let seconds = muteEnd > 1_000_000_000_000 ? Double(muteEnd) / 1000 : Double(muteEnd)
        return seconds > date.timeIntervalSince1970
    }
}

/// The account's chats, messages and the names that title them, in files under Application Support
/// (`WhatsApp/<account id>/`), excluded from backup and readable only after first unlock. Not thread-safe:
/// `WhatsAppClient` owns it.
final class WhatsAppStore {
    static let messageLimit = 1000

    /// A profile picture lookup: a signed `pps.whatsapp.net` URL that expires (its `oe` parameter), or none when
    /// the person or group has no picture or doesn't show it.
    struct Avatar: Codable {
        var url: URL?
        var checkedAt: Date
        var expires: Date
    }

    struct Directory: Codable {
        var chats: [String: WhatsAppChat] = [:]
        /// Contact names from app state, by JID (phone number or LID).
        var contactNames: [String: String] = [:]
        /// WhatsApp names people gave themselves, by user (the part before `@`).
        var pushNames: [String: String] = [:]
        /// Phone number user → LID user.
        var lidByPhoneNumber: [String: String] = [:]
        /// Group JID → subject.
        var groupSubjects: [String: String] = [:]
        /// By chat or user JID.
        var avatars: [String: Avatar] = [:]
    }

    let directoryURL: URL
    private(set) var directory: Directory
    private var messages: [String: [WhatsAppMessage]] = [:]
    private var dirtyChats: Set<String> = []
    private var directoryDirty = false

    init(accountId: String, root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        directoryURL = root.appending(path: "WhatsApp", directoryHint: .isDirectory).appending(path: accountId, directoryHint: .isDirectory)
        directory = Self.loadDirectory(directoryURL)
    }

    /// The directory, with an entry for every chat that has messages, so a directory saved without them (as two
    /// clients writing it once did) still lists them.
    private static func loadDirectory(_ url: URL) -> Directory {
        var directory = (try? Data(contentsOf: url.appending(path: "directory.json"))).flatMap { try? JSONDecoder().decode(Directory.self, from: $0) } ?? Directory()
        let files = (try? FileManager.default.contentsOfDirectory(at: url.appending(path: "messages", directoryHint: .isDirectory), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let jid = file.deletingPathExtension().lastPathComponent
            guard directory.chats[jid] == nil,
                  let messages = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([WhatsAppMessage].self, from: $0) }),
                  let last = messages.last
            else { continue }
            directory.chats[jid] = WhatsAppChat(jid: jid, lastTimestamp: last.timestamp, readUpTo: last.timestamp)
        }
        return directory
    }

    func reload() {
        directory = Self.loadDirectory(directoryURL)
        messages.removeAll()
        dirtyChats.removeAll()
        directoryDirty = false
    }

    // MARK: Chats and names

    var chats: [WhatsAppChat] {
        Array(directory.chats.values)
    }

    func chat(_ jid: String) -> WhatsAppChat? {
        directory.chats[jid]
    }

    func updateChat(_ jid: String, _ change: (inout WhatsAppChat) -> Void) {
        var chat = directory.chats[jid] ?? WhatsAppChat(jid: jid)
        change(&chat)
        directory.chats[jid] = chat
        directoryDirty = true
    }

    func update(_ change: (inout Directory) -> Void) {
        change(&directory)
        directoryDirty = true
    }

    func lid(forPhoneNumberUser user: String) -> String? {
        directory.lidByPhoneNumber[user]
    }

    func phoneNumberUser(forLIDUser lid: String) -> String? {
        directory.lidByPhoneNumber.first { $0.value == lid }?.key
    }

    /// The name to show for a person: the user's contact name, else their WhatsApp name, else their number.
    func name(forUserJID jid: String) -> String? {
        guard let parsed = WhatsAppJID(string: jid) else { return nil }
        let user = parsed.user
        let phoneUser = parsed.server == WhatsAppJID.Server.lid ? phoneNumberUser(forLIDUser: user) : user
        let lidUser = parsed.server == WhatsAppJID.Server.lid ? user : lid(forPhoneNumberUser: user)
        let candidates = [
            phoneUser.map { "\($0)@\(WhatsAppJID.Server.user)" },
            lidUser.map { "\($0)@\(WhatsAppJID.Server.lid)" },
        ].compactMap(\.self)
        if let contact = candidates.lazy.compactMap({ self.directory.contactNames[$0] }).first(where: { !$0.isEmpty }) {
            return contact
        }
        if let pushName = [user, phoneUser, lidUser].compactMap(\.self).lazy.compactMap({ self.directory.pushNames[$0] }).first(where: { !$0.isEmpty }) {
            return pushName
        }
        return phoneUser.flatMap { $0.allSatisfy(\.isNumber) ? "+\($0)" : nil }
    }

    func avatarURL(for jid: String) -> URL? {
        guard let avatar = directory.avatars[jid], avatar.expires > Date() else { return nil }
        return avatar.url
    }

    /// Whether the picture should be looked up again: never looked up, its URL is about to expire, or a week
    /// has passed since finding none.
    func needsAvatar(_ jid: String) -> Bool {
        guard let avatar = directory.avatars[jid] else { return true }
        return avatar.expires < Date().addingTimeInterval(24 * 3600)
    }

    func title(for chat: WhatsAppChat) -> String {
        if chat.isGroup {
            return directory.groupSubjects[chat.jid].flatMap { $0.isEmpty ? nil : $0 } ?? chat.name ?? "Group"
        }
        return name(forUserJID: chat.jid) ?? chat.phoneNumberJID.flatMap { name(forUserJID: $0) } ?? chat.name ?? "Unknown"
    }

    // MARK: Messages

    func messages(in chat: String) -> [WhatsAppMessage] {
        if let loaded = messages[chat] { return loaded }
        let loaded = (try? Data(contentsOf: messagesURL(chat))).flatMap { try? JSONDecoder().decode([WhatsAppMessage].self, from: $0) } ?? []
        messages[chat] = loaded
        return loaded
    }

    /// Adds or replaces messages by id, keeping the chat's newest `messageLimit` in time order. Returns whether
    /// anything changed.
    @discardableResult
    func upsert(_ incoming: [WhatsAppMessage], in chat: String) -> Bool {
        guard !incoming.isEmpty else { return false }
        var list = messages(in: chat)
        var index = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
        var changed = false
        for message in incoming {
            if let existing = index[message.id] {
                if list[existing] != message {
                    list[existing] = message
                    changed = true
                }
            } else {
                index[message.id] = list.count
                list.append(message)
                changed = true
            }
        }
        guard changed else { return false }
        list.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        if list.count > Self.messageLimit {
            list.removeFirst(list.count - Self.messageLimit)
        }
        messages[chat] = list
        dirtyChats.insert(chat)
        if let last = list.last, (directory.chats[chat]?.lastTimestamp ?? .distantPast) < last.timestamp {
            updateChat(chat) { $0.lastTimestamp = last.timestamp }
        }
        return true
    }

    func modifyMessage(_ id: String, in chat: String, _ change: (inout WhatsAppMessage) -> Void) -> Bool {
        var list = messages(in: chat)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        change(&list[index])
        messages[chat] = list
        dirtyChats.insert(chat)
        return true
    }

    /// Folds a person's LID chat into their phone-number chat once the two are known to be the same person, so
    /// messages that arrived under either address show in one chat.
    func mergeDuplicateChats() {
        for chat in directory.chats.values where chat.jid.hasSuffix("@\(WhatsAppJID.Server.lid)") {
            let lid = String(chat.jid.prefix { $0 != "@" })
            guard let phone = phoneNumberUser(forLIDUser: lid) else { continue }
            let phoneChat = "\(phone)@\(WhatsAppJID.Server.user)"
            guard directory.chats[phoneChat] != nil else { continue }
            upsert(messages(in: chat.jid), in: phoneChat)
            let merged = chat
            updateChat(phoneChat) { target in
                target.lastTimestamp = max(target.lastTimestamp ?? .distantPast, merged.lastTimestamp ?? .distantPast)
                if let readUpTo = merged.readUpTo {
                    target.readUpTo = max(target.readUpTo ?? .distantPast, readUpTo)
                }
            }
            directory.chats[chat.jid] = nil
            messages[chat.jid] = nil
            dirtyChats.remove(chat.jid)
            try? FileManager.default.removeItem(at: messagesURL(chat.jid))
        }
    }

    // MARK: Persistence

    func save() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directoryURL.appending(path: "messages", directoryHint: .isDirectory), withIntermediateDirectories: true)
        var root = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        if directoryDirty, let data = try? JSONEncoder().encode(directory) {
            write(data, to: directoryURL.appending(path: "directory.json"))
            directoryDirty = false
        }
        for chat in dirtyChats {
            if let list = messages[chat], let data = try? JSONEncoder().encode(list) {
                write(data, to: messagesURL(chat))
            }
        }
        dirtyChats.removeAll()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        directory = Directory()
        messages.removeAll()
        dirtyChats.removeAll()
    }

    private func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func messagesURL(_ chat: String) -> URL {
        let safe = chat.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appending(path: "messages", directoryHint: .isDirectory).appending(path: safe + ".json")
    }
}
