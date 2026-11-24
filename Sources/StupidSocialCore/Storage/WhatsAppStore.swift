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
    /// Reactions by the reactor's JID (the user's own under their own JID), each the emoji.
    public var reactions: [String: String]
    /// The photo, video, voice message, sticker or file, with what downloading it takes.
    public var media: WhatsAppMedia?
    /// The quoted message's sender, for drawing and sending replies.
    public var quotedSender: String?
    /// A business message's buttons, such as a link to open.
    public var buttons: [WhatsAppButton]?

    public init(id: String, sender: String, isFromMe: Bool, timestamp: Date, text: String?, label: String?, quotedId: String? = nil, isDeleted: Bool = false, editedAt: Date? = nil, reactions: [String: String] = [:], media: WhatsAppMedia? = nil, quotedSender: String? = nil, buttons: [WhatsAppButton]? = nil) {
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
        self.media = media
        self.quotedSender = quotedSender
        self.buttons = buttons
    }
}

/// A button under a business message: a link, a number to call, a code to copy, or a reply to the business,
/// which the app shows but doesn't send.
public struct WhatsAppButton: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case url, call, copy, reply
    }

    public let title: String
    public let action: Action
    /// The URL, phone number or code; nil for a reply.
    public let value: String?

    public init(title: String, action: Action, value: String?) {
        self.title = title
        self.action = action
        self.value = value
    }
}

/// A message's file on WhatsApp's media servers: where it is, the key that decrypts it and the hashes that check
/// it, and what showing it needs (size, length, waveform, thumbnail). Stored with the message, like WhatsApp
/// Web keeps it, so the file downloads only when shown.
public struct WhatsAppMedia: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image, video, audio, document, sticker

        /// The HKDF info for the file's keys (whatsmeow `MediaType`); stickers use the image keys.
        var keyInfo: String {
            switch self {
            case .image, .sticker: "WhatsApp Image Keys"
            case .video: "WhatsApp Video Keys"
            case .audio: "WhatsApp Audio Keys"
            case .document: "WhatsApp Document Keys"
            }
        }

        /// The download URL's `mms-type`.
        var mmsType: String {
            switch self {
            case .image, .sticker: "image"
            case .video: "video"
            case .audio: "audio"
            case .document: "document"
            }
        }
    }

    public var kind: Kind
    public var mimetype: String?
    /// The path on WhatsApp's media hosts; replaced when the phone uploads an expired file again.
    public var directPath: String?
    public var mediaKey: Data?
    public var fileEncSHA256: Data?
    public var fileSHA256: Data?
    public var fileLength: UInt64?
    public var width: UInt32?
    public var height: UInt32?
    public var seconds: UInt32?
    /// A voice message rather than an audio file.
    public var isVoice: Bool
    /// A GIF (a video played muted and looped) or an animated sticker.
    public var isAnimated: Bool
    public var fileName: String?
    /// The voice message's levels, one byte each (0–100), as WhatsApp sends 64 of them.
    public var waveform: Data?
    /// The inline JPEG preview, when the message carries one.
    public var thumbnail: Data?

    /// Whether there is anything to download: messages still uploading, or whose upload failed, have no path.
    public var isDownloadable: Bool {
        directPath?.isEmpty == false && mediaKey != nil && fileEncSHA256 != nil && fileSHA256 != nil
    }

    /// The file's extension, for the cache file and players that need the type.
    public var fileExtension: String {
        if let fileName, !(fileName as NSString).pathExtension.isEmpty {
            return (fileName as NSString).pathExtension.lowercased()
        }
        let type = (mimetype ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch type {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/ogg": return "ogg"
        case "audio/mp4", "audio/aac": return "m4a"
        case "audio/mpeg": return "mp3"
        case "application/pdf": return "pdf"
        default:
            switch kind {
            case .image: return "jpg"
            case .video: return "mp4"
            case .audio: return "ogg"
            case .sticker: return "webp"
            case .document: return "bin"
            }
        }
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
    /// Locked in WhatsApp, which hides it behind a passcode, so it's left out of Chats. Optional so older
    /// directories decode.
    public var isLocked: Bool?
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

/// How far the phone got sending history after linking, and when app state last synced. WhatsApp Web's rule
/// (as Baileys ports it): history is complete when a RECENT chunk reports progress 100, and paused when no RECENT
/// chunk has come for two minutes before that.
public struct WhatsAppSyncState: Codable, Equatable, Sendable {
    public enum History: Equatable, Sendable {
        /// No history has arrived yet.
        case waiting
        /// The phone is sending history; the percentage once a RECENT chunk reports one.
        case syncing(progress: Int?)
        /// The phone stopped sending before it finished.
        case paused(progress: Int?)
        case complete
    }

    static let pausedAfter: TimeInterval = 120

    /// The latest RECENT chunk's progress, 0–100.
    public var historyProgress: Int?
    public var historyComplete: Bool?
    /// When the latest initial or RECENT chunk arrived.
    public var historyChunkAt: Date?
    /// When every app state collection (contact names, mute, archive, pin, read) last synced.
    public var appStateSyncedAt: Date?

    public init(historyProgress: Int? = nil, historyComplete: Bool? = nil, historyChunkAt: Date? = nil, appStateSyncedAt: Date? = nil) {
        self.historyProgress = historyProgress
        self.historyComplete = historyComplete
        self.historyChunkAt = historyChunkAt
        self.appStateSyncedAt = appStateSyncedAt
    }

    public func history(at date: Date = Date()) -> History {
        if historyComplete == true { return .complete }
        guard let historyChunkAt else { return .waiting }
        return date.timeIntervalSince(historyChunkAt) < Self.pausedAfter ? .syncing(progress: historyProgress) : .paused(progress: historyProgress)
    }

    /// Records a history chunk other than an on-demand one.
    mutating func received(_ syncType: WhatsAppProto.HistorySync.SyncType?, progress: UInt32, at date: Date = Date()) {
        switch syncType {
        case .initialBootstrap:
            historyChunkAt = date
        case .recent:
            historyChunkAt = date
            historyProgress = Int(min(progress, 100))
            if progress >= 100 { historyComplete = true }
        default:
            break
        }
    }
}

/// What Settings shows about an account's sync.
public struct WhatsAppSyncStatus: Equatable, Sendable {
    /// Nil until anything synced, and for accounts linked before the app tracked it.
    public let state: WhatsAppSyncState?
    public let chatCount: Int

    /// Nil when it can't be known: an account linked before the app tracked it, which already has chats.
    public func history(at date: Date = Date()) -> WhatsAppSyncState.History? {
        if let state { return state.history(at: date) }
        return chatCount == 0 ? .waiting : nil
    }
}

/// The account's chats, messages and the names that title them, in files under Application Support
/// (`WhatsApp/<account id>/`), excluded from backup and readable only after first unlock. Not thread-safe:
/// `WhatsAppClient` owns it.
final class WhatsAppStore {
    /// Enough for older pages fetched on demand to stay, not only what arrived after linking.
    static let messageLimit = 5000

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
        /// Group JID → members, from `<participating>`. Optional so directories from before them still decode.
        var groupMembers: [String: [GroupMember]]?
        /// Group JID → description.
        var groupDescriptions: [String: String]?
        /// Group JID → `addressing_mode` ("lid" or "pn").
        var groupAddressing: [String: String]?
        /// Groups where only admins can send.
        var announcementGroups: Set<String>?
        /// How far WhatsApp's sync after linking got. Optional so directories from before it still decode.
        var sync: WhatsAppSyncState?
    }

    struct GroupMember: Codable, Hashable {
        /// The member's JID as the group lists it (LID or phone number).
        var jid: String
        /// `admin` or `superadmin` (the creator), else nil.
        var role: String?
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
        for var message in incoming {
            if let existing = index[message.id] {
                // A message delivered again (history on demand) keeps the reactions and media path this device has.
                if message.reactions.isEmpty {
                    message.reactions = list[existing].reactions
                }
                if let stored = list[existing].media, message.media?.mediaKey == stored.mediaKey {
                    message.media = stored
                }
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
                // App state that named the LID before the phone-number chat existed.
                if merged.isArchived { target.isArchived = true }
                if merged.isPinned { target.isPinned = true }
                if merged.isLocked == true { target.isLocked = true }
                if let muteEnd = merged.muteEnd, target.muteEnd == nil { target.muteEnd = muteEnd }
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
