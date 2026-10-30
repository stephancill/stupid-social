import Foundation
import NoFeedSocialPush
import Synchronization

/// When private chats and groups are muted until by default, as Unix times.
struct TelegramMuteDefaults {
    let users: TimeInterval
    let groups: TimeInterval
}

/// A user, basic group or supergroup, with the access hash its input peer needs.
public struct TelegramPeer: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user
        case chat
        case channel
    }

    public let kind: Kind
    public let id: Int64
    public let accessHash: Int64

    public init(kind: Kind, id: Int64, accessHash: Int64) {
        self.kind = kind
        self.id = id
        self.accessHash = accessHash
    }

    public var key: String {
        "\(kind.rawValue):\(id)"
    }

    var inputPeer: TLObject {
        switch kind {
        case .user: TLObject("inputPeerUser", ["user_id": .long(id), "access_hash": .long(accessHash)])
        case .chat: TLObject("inputPeerChat", ["chat_id": .long(id)])
        case .channel: TLObject("inputPeerChannel", ["channel_id": .long(id), "access_hash": .long(accessHash)])
        }
    }
}

public struct TelegramAccount: Codable, Sendable, Equatable {
    public let userId: Int64
    public let name: String
    public let username: String?
}

/// One message as the chat shows it, already reduced from Telegram's `Message`.
public struct TelegramMessage: Codable, Sendable, Hashable {
    public let id: Int32
    public let date: Date
    /// One line for previews: the text, with what was sent before it, such as "Photo · caption".
    public let text: String
    /// The message's own text, empty for media without a caption.
    public var caption: String = ""
    /// Hidden parts of `caption` (UTF-16 ranges): spoiler entities, and the login code in messages from Telegram's
    /// service account. Optional so chat snapshots saved before it existed still decode.
    public var spoilers: [NSRange]?
    /// Mentions in `caption`. Optional so chat snapshots saved before it existed still decode.
    public var mentions: [TelegramMention]?
    /// Custom emoji entities in `caption`. Optional so chat snapshots saved before it existed still decode.
    public var customEmojis: [TelegramCustomEmoji]?
    /// Shared by the messages of one album, which Telegram sends as separate messages.
    public var groupedId: Int64?
    public var embeds: [TelegramEmbed] = []
    public var reactions: [TelegramReaction] = []
    public var reactors: [TelegramReactor] = []
    public let senderId: Int64?
    public let isOutgoing: Bool
    public let replyToId: Int32?
    /// A service message such as "joined the group", shown as a caption.
    public let isService: Bool

    /// `text` with its spoilers masked, for the Chats list.
    public var previewText: String {
        guard let spoilers, !spoilers.isEmpty, !caption.isEmpty, text.hasSuffix(caption) else { return text }
        // The caption ends the line, after a media label such as "Photo · ".
        let shift = text.utf16.count - caption.utf16.count
        return SpoilerText.mask(text, ranges: spoilers.map { NSRange(location: $0.location + shift, length: $0.length) })
    }
}

/// A mention in a message's text: `@username` (`messageEntityMention`), which Telegram marks by itself in text
/// that's sent, or a name tied to a user (`messageEntityMentionName`), for people without a username.
public struct TelegramMention: Codable, Sendable, Hashable {
    /// UTF-16 offset and length, as Telegram counts them.
    public let offset: Int
    public let length: Int
    public let userId: Int64?
    /// Without the `@`; set for `@username` mentions, whose user the chat may not have loaded.
    public let username: String?

    public init(offset: Int, length: Int, userId: Int64?, username: String?) {
        self.offset = offset
        self.length = length
        self.userId = userId
        self.username = username
    }

    public var range: NSRange {
        NSRange(location: offset, length: length)
    }
}

/// A custom emoji's picture, as `TelegramClient.customEmojiImages` finds it.
public struct TelegramCustomEmojiImage: Sendable, Hashable {
    public let url: URL
    /// The emoji it stands for.
    public let alt: String?
    public let aspectRatio: Double
}

/// A custom emoji in a message's text (`messageEntityCustomEmoji`): its document drawn over the fallback emoji at
/// the UTF-16 range.
public struct TelegramCustomEmoji: Codable, Sendable, Hashable {
    public let offset: Int
    public let length: Int
    public let documentId: Int64

    public var range: NSRange {
        NSRange(location: offset, length: length)
    }

    /// How reactions and the chat's emoji catalog name a custom emoji.
    public static func key(documentId: Int64) -> String {
        ":\(documentId):"
    }

    public static func documentId(fromKey key: String) -> Int64? {
        guard key.hasPrefix(":"), key.hasSuffix(":"), key.count > 2 else { return nil }
        return Int64(key.dropFirst().dropLast())
    }
}

/// A Telegram user's profile page: who they are, their bio and last seen, and their private chat.
public struct TelegramProfile: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let username: String?
    public let about: String?
    public let avatarURL: URL?
    /// Last seen; `nil` for yourself and bots.
    public let status: ChatPresence?
    public let isBot: Bool
    public let isYou: Bool
    /// The private chat with them; `nil` when Telegram gave no usable access hash.
    public let peer: TelegramPeer?
}

/// Someone in a group, as its member list shows them.
public struct TelegramMember: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case owner, admin, member
    }

    public let id: Int64
    public let name: String
    public let username: String?
    public let avatarURL: URL?
    public let role: Role
    public let status: ChatPresence
    public let isYou: Bool
    public let isBot: Bool
}

public struct TelegramMemberList: Sendable {
    public let members: [TelegramMember]
    /// The group's member count, which can be more than are listed.
    public let count: Int
}

public struct TelegramHistoryPage: Sendable {
    public let messages: [TelegramMessage]
    /// User and chat id → display name, for senders.
    public let names: [Int64: String]
    /// User and chat id → profile photo (a `tgfile:` URL).
    public let avatars: [Int64: URL]
    /// Lowercased username → user id, for `@username` mentions of users in the response.
    public var usernames: [String: Int64] = [:]
    public let hasMore: Bool
}

public struct TelegramDialogState: Sendable {
    public let title: String
    public let isGroup: Bool
    public let memberCount: Int?
    /// The other person's last-seen status in a private chat; `nil` in groups, Saved Messages and with bots.
    public let userStatus: ChatPresence?
    public let readInboxMaxId: Int32
    public let readOutboxMaxId: Int32
    /// The user's messages with reactions they haven't seen.
    public let unreadReactionsCount: Int
}

public enum TelegramSignInResult: Sendable, Equatable {
    case signedIn
    case passwordNeeded(hint: String?)
}

/// `TELEGRAM_APP_ID` and `TELEGRAM_APP_API_HASH`, written to `Resources/TelegramAPI.json` by
/// `scripts/telegram-api-config.py` and never committed; builds without it have no Telegram.
struct TelegramAPIConfig: Decodable {
    let apiId: Int32
    let apiHash: String

    static let bundled: TelegramAPIConfig? = Bundle.module.url(forResource: "TelegramAPI", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(TelegramAPIConfig.self, from: $0) }
}

/// The signed-in Telegram account over MTProto: one session on the account's home DC, following
/// `*_MIGRATE_X` to another DC during sign-in, with the auth keys kept in this device's Keychain.
public actor TelegramClient: ChatListProvider {
    public nonisolated let network: SocialNetwork = .telegram

    private struct Stored: Codable {
        var homeDC = 2
        var keys: [Int: TelegramDCKey] = [:]
        var account: TelegramAccount?
        /// Other DCs this account's authorization was imported into, for files stored there.
        var authorizedDCs: Set<Int> = []
        /// The APNs token registered for Telegram's pushes, unregistered on sign-out.
        var pushToken: String?

        init() {}

        /// Missing fields take their defaults, so a session saved by an earlier build still loads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            homeDC = try container.decodeIfPresent(Int.self, forKey: .homeDC) ?? 2
            keys = try container.decodeIfPresent([Int: TelegramDCKey].self, forKey: .keys) ?? [:]
            account = try container.decodeIfPresent(TelegramAccount.self, forKey: .account)
            authorizedDCs = try container.decodeIfPresent(Set<Int>.self, forKey: .authorizedDCs) ?? []
            pushToken = try container.decodeIfPresent(String.self, forKey: .pushToken)
        }
    }

    public static var isAvailable: Bool {
        TelegramAPIConfig.bundled != nil
    }

    /// Scoped to the account; its sign-in stays on this device.
    private let keychain: KeychainCredentialStore
    private var stored: Stored
    private var current: MTProtoSession?
    private var opening: Task<MTProtoSession, Error>?
    private var phoneLogin: (phone: String, hash: String)?
    private var observers: [UUID: @Sendable (TLObject) -> Void] = [:]
    /// Sessions on other DCs, for downloading files stored there.
    private var fileSessions: [Int: MTProtoSession] = [:]
    private var openingFileSessions: [Int: Task<MTProtoSession, Error>] = [:]
    /// Downloads in flight by cache key, so a file shown twice downloads once.
    private var downloads: [String: Task<Data, Error>] = [:]
    private var customEmojiImages: [Int64: TelegramCustomEmojiImage] = [:]
    /// How to name each user seen in a history, member list or lookup to Telegram (`InputUser`), for profiles and
    /// name mentions: with their access hash, or through a message they sent when Telegram gave a "min" user.
    private var inputUsers: [Int64: TLObject] = [:]
    /// Names of people whose profile opened, so a private chat opened from it can be titled before it loads.
    private nonisolated let profileNames = Mutex<[Int64: String]>([:])
    private let mediaDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "telegram-media", directoryHint: .isDirectory)

    public init(keychain: KeychainCredentialStore) {
        self.keychain = keychain
        stored = keychain.loadTelegramSession().flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// The account signed in on a saved session, for migrating sessions saved before accounts were scoped.
    static func signedInAccount(sessionData: Data) -> TelegramAccount? {
        (try? JSONDecoder().decode(Stored.self, from: sessionData))?.account
    }

    /// Moves this sign-in to another account id on this device, such as when a new sign-in is an account
    /// already listed. This client stays signed out.
    public func moveSession(to other: KeychainCredentialStore) async {
        await current?.close()
        current = nil
        for session in fileSessions.values {
            await session.close()
        }
        fileSessions = [:]
        stored = Stored()
        keychain.moveTelegramSession(to: other)
    }

    /// Loads the sign-in saved for this account, such as one another client moved here.
    public func reloadSession() async {
        await current?.close()
        current = nil
        stored = keychain.loadTelegramSession().flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public var account: TelegramAccount? {
        stored.account
    }

    // MARK: Sessions

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? keychain.saveTelegramSession(data)
    }

    private func store(key: TelegramDCKey, dc: Int) {
        stored.keys[dc] = key
        save()
    }

    private func session() async throws -> MTProtoSession {
        if let current, await !current.isClosed {
            return current
        }
        if let opening {
            return try await opening.value
        }
        let task = Task { try await openSession(dc: stored.homeDC) }
        opening = task
        defer { opening = nil }
        let session = try await task.value
        current = session
        return session
    }

    /// Opens a session on `dc`. The first call, wrapped in `initConnection`, is `help.getConfig` on the home
    /// DC and `auth.importAuthorization` (`firstQuery`) when signing in to another DC for files.
    private func openSession(dc: Int, firstQuery: TLObject = TLObject("help.getConfig"), retryingKey: Bool = true) async throws -> MTProtoSession {
        guard let config = TelegramAPIConfig.bundled else { throw TelegramError.notConfigured }
        let session = try await MTProtoSession.open(
            dc: dc,
            key: stored.keys[dc],
            onUpdate: { [weak self] update in
                Task { await self?.dispatch(update) }
            },
            onKeyChange: { [weak self] dc, key in
                Task { await self?.store(key: key, dc: dc) }
            },
        )
        let info = ProcessInfo.processInfo
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let initConnection = TLObject("invokeWithLayer", [
            "layer": .int(Int32(TLSchema.shared.layer)),
            "query": .object(TLObject("initConnection", [
                "api_id": .int(config.apiId),
                "device_model": .string("iPhone"),
                "system_version": .string("iOS \(info.operatingSystemVersion.majorVersion).\(info.operatingSystemVersion.minorVersion)"),
                "app_version": .string(appVersion),
                "system_lang_code": .string(Locale.current.language.languageCode?.identifier ?? "en"),
                "lang_pack": .string(""),
                "lang_code": .string(Locale.current.language.languageCode?.identifier ?? "en"),
                "query": .object(firstQuery),
            ])),
        ])
        do {
            _ = try await session.call(initConnection)
            if stored.account != nil, dc == stored.homeDC {
                // Telegram pushes updates only to sessions that have asked for the update state.
                _ = try await session.call(TLObject("updates.getState"))
            }
            return session
        } catch TelegramError.authKeyInvalid where retryingKey {
            await session.close()
            stored.keys[dc] = nil
            stored.authorizedDCs.remove(dc)
            save()
            return try await openSession(dc: dc, firstQuery: firstQuery, retryingKey: false)
        } catch {
            await session.close()
            throw error
        }
    }

    func invoke(_ method: TLObject) async throws -> TLValue {
        var attempts = 0
        while true {
            attempts += 1
            let session = try await session()
            do {
                return try await session.call(method)
            } catch TelegramError.connectionLost where attempts < 3 {
                await session.close()
                current = nil
            } catch let TelegramError.rpc(303, message) where message.contains("_MIGRATE_") && attempts < 3 {
                guard let dc = Int(message.split(separator: "_").last ?? "") else { throw TelegramError.rpc(code: 303, message: message) }
                await session.close()
                current = nil
                stored.homeDC = dc
                save()
            } catch let TelegramError.rpc(401, message) where stored.account != nil && ["AUTH_KEY_UNREGISTERED", "SESSION_REVOKED", "SESSION_EXPIRED", "USER_DEACTIVATED"].contains(message) {
                stored.account = nil
                save()
                throw TelegramError.notSignedIn
            }
        }
    }

    // MARK: Files

    /// A session on another DC, signed in there by exporting this account's authorization from the home DC
    /// (validated with the probe's `avatar`, which reads a DC 1 photo from a DC 4 account).
    private func fileSession(dc: Int) async throws -> MTProtoSession {
        if let session = fileSessions[dc], await !session.isClosed {
            return session
        }
        if let opening = openingFileSessions[dc] {
            return try await opening.value
        }
        let task = Task { try await openFileSession(dc: dc) }
        openingFileSessions[dc] = task
        defer { openingFileSessions[dc] = nil }
        let session = try await task.value
        fileSessions[dc] = session
        return session
    }

    private func openFileSession(dc: Int) async throws -> MTProtoSession {
        if stored.authorizedDCs.contains(dc), stored.keys[dc] != nil {
            return try await openSession(dc: dc)
        }
        guard let exported = try await invoke(TLObject("auth.exportAuthorization", ["dc_id": .int(Int32(dc))])).object,
              let id = exported["id"]?.long, let bytes = exported["bytes"]?.bytes
        else { throw TelegramError.protocolViolation("no exported authorization") }
        let session = try await openSession(dc: dc, firstQuery: TLObject("auth.importAuthorization", ["id": .long(id), "bytes": .bytes(bytes)]))
        stored.authorizedDCs.insert(dc)
        save()
        return session
    }

    /// A call on `dc`: the home session, or a file session on another DC, reconnecting once.
    private func invoke(_ method: TLObject, dc: Int) async throws -> TLValue {
        guard dc != stored.homeDC else { return try await invoke(method) }
        do {
            return try await fileSession(dc: dc).call(method)
        } catch TelegramError.connectionLost {
            fileSessions[dc] = nil
            return try await fileSession(dc: dc).call(method)
        } catch TelegramError.rpc(401, _) {
            // The DC forgot the imported authorization: import it again.
            await fileSessions.removeValue(forKey: dc)?.close()
            stored.authorizedDCs.remove(dc)
            save()
            return try await fileSession(dc: dc).call(method)
        }
    }

    /// A file behind a `tgfile:` URL, from the disk cache or Telegram.
    public func file(at url: URL) async throws -> Data {
        guard let file = TelegramMediaURL.parse(url) else { throw TelegramError.protocolViolation("bad media URL") }
        try requireAccount()
        let cached = mediaDirectory.appending(path: TelegramMediaURL.cacheName(file.key))
        if let data = try? Data(contentsOf: cached) {
            return data
        }
        if let running = downloads[file.key] {
            return try await running.value
        }
        let maxSize = TelegramMediaURL.maxSize(of: url)
        let task = Task { try await download(location: file.location, dc: file.dc, maxSize: maxSize) }
        downloads[file.key] = task
        defer { downloads[file.key] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// `upload.getFile` in 512 KB parts until a short one or `maxSize`, following `FILE_MIGRATE_X`. Larger parts
    /// aren't faster: a 3.4 MB video took 8 s in 512 KB parts and 10 s in 1 MB ones (observed 2026-10-30).
    private func download(location: TLObject, dc initialDC: Int, maxSize: Int) async throws -> Data {
        let limit = 512 * 1024
        var dc = initialDC
        var data = Data()
        var migrations = 0
        while true {
            let part: TLObject?
            do {
                part = try await invoke(TLObject("upload.getFile", [
                    "precise": .bool(true), "location": .object(location), "offset": .long(Int64(data.count)), "limit": .int(Int32(limit)),
                ]), dc: dc).object
            } catch let TelegramError.rpc(303, message) where message.hasPrefix("FILE_MIGRATE_") && migrations < 2 {
                guard let next = Int(message.dropFirst("FILE_MIGRATE_".count)) else { throw TelegramError.rpc(code: 303, message: message) }
                migrations += 1
                dc = next
                continue
            }
            // CDN redirects (`upload.fileCdnRedirect`) only come for large files, which the app doesn't download.
            guard let part, part.name == "upload.file", let bytes = part["bytes"]?.bytes else {
                throw TelegramError.protocolViolation("unsupported file reply \(part?.name ?? "")")
            }
            data.append(bytes)
            if bytes.count < limit || data.count >= maxSize {
                return data
            }
        }
    }

    // MARK: Updates

    /// Calls `observer` when Telegram pushes an update to `peer`'s messages (new, edited, deleted, read by
    /// the other side) while the session is open. Status and typing updates, which arrive constantly, don't count;
    /// typing has `addTypingObserver`.
    public func addUpdateObserver(peer: TelegramPeer, _ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = { update in
            if Self.update(update, concerns: peer) {
                observer()
            }
        }
        return id
    }

    static func update(_ update: TLObject, concerns peer: TelegramPeer) -> Bool {
        switch update.name {
        case "updatesTooLong":
            true
        case "updateShortMessage":
            peer.kind == .user && update["user_id"]?.long == peer.id
        case "updateShortChatMessage":
            peer.kind == .chat && update["chat_id"]?.long == peer.id
        case "updateShort":
            update["update"]?.object.map { self.update($0, concerns: peer) } ?? false
        case "updates", "updatesCombined":
            update.objects("updates").contains { self.update($0, concerns: peer) }
        case "updateNewMessage", "updateEditMessage", "updateNewChannelMessage", "updateEditChannelMessage":
            update["message"]?.object?["peer_id"]?.object.map(peerKey) == peer.key
        case "updateReadHistoryOutbox", "updateReadHistoryInbox":
            update["peer"]?.object.map(peerKey) == peer.key
        case "updateDeleteMessages":
            // Carries only message ids, which are per account outside channels.
            peer.kind != .channel
        case "updateDeleteChannelMessages", "updateReadChannelOutbox", "updateReadChannelInbox", "updateChannelTooLong":
            peer.kind == .channel && update["channel_id"]?.long == peer.id
        default:
            false
        }
    }

    /// Calls `observer` when Telegram pushes a change to the reactions on one of `peer`'s messages.
    public func addReactionObserver(peer: TelegramPeer, _ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = { update in
            if Self.reactionUpdate(update, concerns: peer) {
                observer()
            }
        }
        return id
    }

    static func reactionUpdate(_ update: TLObject, concerns peer: TelegramPeer) -> Bool {
        switch update.name {
        case "updateShort":
            update["update"]?.object.map { reactionUpdate($0, concerns: peer) } ?? false
        case "updates", "updatesCombined":
            update.objects("updates").contains { reactionUpdate($0, concerns: peer) }
        case "updateMessageReactions":
            update["peer"]?.object.map(peerKey) == peer.key
        default:
            false
        }
    }

    /// Calls `observer` with a user and whether they are now composing a message in `peer`, when Telegram pushes
    /// a typing update. An indication lasts 6 seconds unless repeated.
    public func addTypingObserver(peer: TelegramPeer, _ observer: @escaping @Sendable (_ userId: Int64, _ isTyping: Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = { update in
            for typing in Self.typingUpdates(update, concerns: peer) {
                observer(typing.userId, typing.isTyping)
            }
        }
        return id
    }

    static func typingUpdates(_ update: TLObject, concerns peer: TelegramPeer) -> [(userId: Int64, isTyping: Bool)] {
        switch update.name {
        case "updateShort":
            update["update"]?.object.map { typingUpdates($0, concerns: peer) } ?? []
        case "updates", "updatesCombined":
            update.objects("updates").flatMap { typingUpdates($0, concerns: peer) }
        case "updateUserTyping" where peer.kind == .user && update["user_id"]?.long == peer.id:
            typing(userId: peer.id, action: update["action"]?.object)
        case "updateChatUserTyping" where peer.kind == .chat && update["chat_id"]?.long == peer.id,
             "updateChannelUserTyping" where peer.kind == .channel && update["channel_id"]?.long == peer.id:
            typing(userId: update["from_id"]?.object.flatMap { $0.name == "peerUser" ? $0["user_id"]?.long : nil }, action: update["action"]?.object)
        default:
            []
        }
    }

    /// Typing, recording and uploading all mean a message is coming; cancel ends it. Emoji interactions and
    /// the like aren't messages.
    private static func typing(userId: Int64?, action: TLObject?) -> [(userId: Int64, isTyping: Bool)] {
        guard let userId, let action else { return [] }
        switch action.name {
        case "sendMessageCancelAction":
            return [(userId, false)]
        case "sendMessageEmojiInteraction", "sendMessageEmojiInteractionSeen", "speakingInGroupCallAction", "sendMessageHistoryImportAction", "sendMessageGamePlayAction":
            return []
        default:
            return [(userId, true)]
        }
    }

    /// Calls `observer` with a user's new status when Telegram pushes `updateUserStatus` for them.
    public func addStatusObserver(userId: Int64, _ observer: @escaping @Sendable (ChatPresence) -> Void) -> UUID {
        let id = UUID()
        observers[id] = { update in
            if let status = Self.statusUpdate(update, userId: userId) {
                observer(status)
            }
        }
        return id
    }

    static func statusUpdate(_ update: TLObject, userId: Int64) -> ChatPresence? {
        switch update.name {
        case "updateShort":
            update["update"]?.object.flatMap { statusUpdate($0, userId: userId) }
        case "updates", "updatesCombined":
            update.objects("updates").lazy.compactMap { statusUpdate($0, userId: userId) }.last
        case "updateUserStatus" where update["user_id"]?.long == userId:
            status(of: update["status"]?.object)
        default:
            nil
        }
    }

    public func removeUpdateObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func dispatch(_ update: TLObject) {
        for observer in observers.values {
            observer(update)
        }
    }

    // MARK: Sign-in

    /// Sends a login code, normally to the user's Telegram app; returns where it went.
    public func sendCode(phone: String) async throws -> String {
        guard let config = TelegramAPIConfig.bundled else { throw TelegramError.notConfigured }
        let result = try await invoke(TLObject("auth.sendCode", [
            "phone_number": .string(phone),
            "api_id": .int(config.apiId),
            "api_hash": .string(config.apiHash),
            "settings": .object(TLObject("codeSettings")),
        ])).object
        guard let result, let hash = result["phone_code_hash"]?.string else {
            throw TelegramError.protocolViolation("no phone_code_hash")
        }
        phoneLogin = (phone, hash)
        return switch result["type"]?.object?.name {
        case "auth.sentCodeTypeApp": "Telegram sent a code to your other Telegram app."
        case "auth.sentCodeTypeSms", "auth.sentCodeTypeSmsWord", "auth.sentCodeTypeSmsPhrase": "Telegram sent a code by SMS."
        case "auth.sentCodeTypeCall": "Telegram is calling with a code."
        case "auth.sentCodeTypeEmailCode": "Telegram sent a code to your email."
        case "auth.sentCodeTypeFragmentSms": "Telegram sent a code through Fragment."
        default: "Telegram sent a code."
        }
    }

    public func signIn(code: String) async throws -> TelegramSignInResult {
        guard let phoneLogin else { throw TelegramError.protocolViolation("no code was requested") }
        do {
            let result = try await invoke(TLObject("auth.signIn", [
                "phone_number": .string(phoneLogin.phone),
                "phone_code_hash": .string(phoneLogin.hash),
                "phone_code": .string(code),
            ]))
            try await finishSignIn(result)
            return .signedIn
        } catch TelegramError.rpc(_, "SESSION_PASSWORD_NEEDED") {
            let password = try await invoke(TLObject("account.getPassword")).object
            return .passwordNeeded(hint: password?["hint"]?.string)
        }
    }

    public func checkPassword(_ password: String) async throws {
        guard let info = try await invoke(TLObject("account.getPassword")).object,
              let algo = info["current_algo"]?.object,
              algo.name == "passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow",
              let salt1 = algo["salt1"]?.bytes, let salt2 = algo["salt2"]?.bytes, let g = algo["g"]?.int, let p = algo["p"]?.bytes,
              let srpB = info["srp_B"]?.bytes, let srpId = info["srp_id"]?.long
        else { throw TelegramError.protocolViolation("unsupported password settings") }
        let check = try await Task.detached {
            try TelegramCrypto.srp(password: password, salt1: salt1, salt2: salt2, g: Int(g), p: p, srpB: srpB)
        }.value
        let result = try await invoke(TLObject("auth.checkPassword", [
            "password": .object(TLObject("inputCheckPasswordSRP", ["srp_id": .long(srpId), "A": .bytes(check.a), "M1": .bytes(check.m1)])),
        ]))
        try await finishSignIn(result)
    }

    private func finishSignIn(_ result: TLValue) async throws {
        guard let authorization = result.object, authorization.name == "auth.authorization", let user = authorization["user"]?.object, let id = user["id"]?.long else {
            if result.object?.name == "auth.authorizationSignUpRequired" {
                throw TelegramError.rpc(code: 400, message: "PHONE_NUMBER_UNOCCUPIED")
            }
            throw TelegramError.protocolViolation("unexpected sign-in result")
        }
        phoneLogin = nil
        stored.account = TelegramAccount(userId: id, name: Self.name(of: user), username: user["username"]?.string)
        save()
        _ = try? await invoke(TLObject("updates.getState"))
    }

    // MARK: Push

    /// Registers this device's APNs token (hex) so Telegram pushes new messages straight to the app (token type 1,
    /// using the APNs certificate uploaded on my.telegram.org). Telegram suggests repeating it daily, so the app
    /// does at every launch. Muted chats aren't pushed.
    /// `otherUserIds` are the other Telegram accounts signed in on this device, which Telegram asks for so it
    /// can tell their pushes apart.
    public func registerPush(deviceToken: String, sandbox: Bool, otherUserIds: [Int64] = []) async throws {
        try requireAccount()
        _ = try await invoke(TLObject("account.registerDevice", [
            "no_muted": .bool(true),
            "token_type": .int(1),
            "token": .string(deviceToken),
            "app_sandbox": .bool(sandbox),
            "secret": .bytes(Data()),
            "other_uids": .vector(otherUserIds.map { .long($0) }),
        ]))
        stored.pushToken = deviceToken
        save()
    }

    private func unregisterPush() async {
        guard let token = stored.pushToken else { return }
        _ = try? await invoke(TLObject("account.unregisterDevice", ["token_type": .int(1), "token": .string(token), "other_uids": .vector([])]))
    }

    public func signOut() async {
        await unregisterPush()
        if stored.account != nil {
            _ = try? await invoke(TLObject("auth.logOut"))
        }
        await current?.close()
        current = nil
        for session in fileSessions.values {
            await session.close()
        }
        fileSessions = [:]
        stored = Stored()
        try? keychain.deleteTelegramSession()
        try? FileManager.default.removeItem(at: mediaDirectory)
    }

    // MARK: Chats

    private func requireAccount() throws {
        guard TelegramAPIConfig.bundled != nil, stored.account != nil else { throw SourceError.notConfigured }
    }

    /// The main chat list (folder 0), or the Archive (folder 1), without broadcast channels. Leaving out
    /// `folder_id` returns both folders mixed.
    /// The signed-in account's own profile photo as a `tgfile:` URL, `nil` without one
    /// (`scripts/telegram-client.py avatar --peer self`).
    public func ownAvatarURL() async throws -> URL? {
        try requireAccount()
        let users = try await invoke(TLObject("users.getUsers", ["id": .vector([.object(TLObject("inputUserSelf"))])])).vector ?? []
        guard let user = users.first?.object, let id = user["id"]?.long else { return nil }
        return TelegramMediaParser.avatarURL(photo: user["photo"]?.object, inputPeer: TLObject("inputPeerSelf"), key: "user:\(id)")
    }

    /// The main list and the Archive, loaded together; an Archive that fails keeps its listed rows.
    public func chatList() async throws -> ChatListPage {
        let defaults = try await muteDefaults()
        async let archived = try? chatSummaries(archived: true, muteDefaults: defaults)
        let chats = try await chatSummaries(muteDefaults: defaults)
        return await ChatListPage(chats: chats, archived: archived)
    }

    /// When private chats and groups are muted until by default; a chat without its own `mute_until` follows
    /// its kind's (`scripts/telegram-client.py notify-defaults`).
    func muteDefaults() async throws -> TelegramMuteDefaults {
        try requireAccount()
        async let users = invoke(TLObject("account.getNotifySettings", ["peer": .object(TLObject("inputNotifyUsers"))]))
        async let groups = invoke(TLObject("account.getNotifySettings", ["peer": .object(TLObject("inputNotifyChats"))]))
        return try await TelegramMuteDefaults(
            users: TimeInterval(users.object?["mute_until"]?.int ?? 0),
            groups: TimeInterval(groups.object?["mute_until"]?.int ?? 0),
        )
    }

    func chatSummaries(archived: Bool = false, limit: Int = 50, muteDefaults: TelegramMuteDefaults) async throws -> [ChatSummary] {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getDialogs", [
            "folder_id": .int(archived ? 1 : 0),
            "offset_date": .int(0), "offset_id": .int(0), "offset_peer": .object(TLObject("inputPeerEmpty")), "limit": .int(Int32(limit)), "hash": .long(0),
        ])).object else { return [] }
        let users = Dictionary(result.objects("users").compactMap { user in user["id"]?.long.map { ($0, user) } }, uniquingKeysWith: { $1 })
        let chats = Dictionary(result.objects("chats").compactMap { chat in chat["id"]?.long.map { ($0, chat) } }, uniquingKeysWith: { $1 })
        var messages: [String: TLObject] = [:]
        for message in result.objects("messages") {
            guard let peer = message["peer_id"]?.object, let id = message["id"]?.int else { continue }
            messages["\(Self.peerKey(peer)):\(id)"] = message
        }
        return result.objects("dialogs").compactMap { dialog -> ChatSummary? in
            guard dialog.name == "dialog", let peerObject = dialog["peer"]?.object,
                  let peer = Self.peer(peerObject, users: users, chats: chats)
            else { return nil }
            let title: String
            switch peer.kind {
            case .user:
                let user = users[peer.id]
                title = user?.flag("self") == true ? "Saved Messages" : user.map(Self.name(of:)) ?? "Telegram"
            case .chat, .channel:
                let chat = chats[peer.id]
                if chat?.flag("broadcast") == true || chat?.name == "channelForbidden" || chat?.name == "chatForbidden" {
                    return nil
                }
                title = chat?["title"]?.string ?? "Group"
            }
            let top = messages["\(Self.peerKey(peerObject)):\(dialog["top_message"]?.int ?? 0)"]
            let latest = top.map { Self.message($0, selfId: stored.account?.userId) }
            var preview = latest?.previewText.replacingOccurrences(of: "\n", with: " ")
            if let latest, let body = preview, !latest.isService {
                if latest.isOutgoing {
                    preview = "You: \(body)"
                } else if peer.kind != .user, let sender = latest.senderId {
                    let name = users[sender].map { $0["first_name"]?.string ?? Self.name(of: $0) } ?? chats[sender]?["title"]?.string
                    preview = name.map { "\($0): \(body)" } ?? body
                }
            }
            let photo = peer.kind == .user ? users[peer.id]?["photo"]?.object : chats[peer.id]?["photo"]?.object
            return ChatSummary(
                id: "telegram:\(peer.key)",
                network: .telegram,
                title: title,
                avatarURL: TelegramMediaParser.avatarURL(photo: photo, inputPeer: peer.inputPeer, key: peer.key),
                avatarColorKey: String(peer.id),
                preview: preview,
                timestamp: latest?.date,
                unreadCount: Int(dialog["unread_count"]?.int ?? 0),
                unseenReactionCount: Int(dialog["unread_reactions_count"]?.int ?? 0),
                destination: .telegram(peer: peer),
                namesSenderInPreview: peer.kind != .user,
                titleNamesPeople: peer.kind == .user,
                // Muted chats have `mute_until` in the future (2147483647 for "forever"); without one, the chat
                // follows the default for its kind.
                isMuted: (dialog["notify_settings"]?.object?["mute_until"]?.int.map(TimeInterval.init)
                    ?? (peer.kind == .user ? muteDefaults.users : muteDefaults.groups)) > Date().timeIntervalSince1970,
                presence: peer.kind == .user ? users[peer.id].flatMap(Self.userStatus) : nil,
            )
        }
    }

    public func dialogState(peer: TelegramPeer) async throws -> TelegramDialogState {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getPeerDialogs", [
            "peers": .vector([.object(TLObject("inputDialogPeer", ["peer": .object(peer.inputPeer)]))]),
        ])).object, let dialog = result.objects("dialogs").first
        else { throw TelegramError.protocolViolation("no dialog") }
        let title: String
        var memberCount: Int?
        var userStatus: ChatPresence?
        if peer.kind == .user {
            let user = result.objects("users").first { $0["id"]?.long == peer.id }
            title = user?.flag("self") == true ? "Saved Messages" : user.map(Self.name(of:)) ?? "Telegram"
            userStatus = user.flatMap(Self.userStatus)
        } else {
            let chat = result.objects("chats").first { $0["id"]?.long == peer.id }
            title = chat?["title"]?.string ?? "Group"
            memberCount = chat?["participants_count"]?.int.map(Int.init)
        }
        return TelegramDialogState(
            title: title,
            isGroup: peer.kind != .user,
            memberCount: memberCount,
            userStatus: userStatus,
            readInboxMaxId: dialog["read_inbox_max_id"]?.int ?? 0,
            readOutboxMaxId: dialog["read_outbox_max_id"]?.int ?? 0,
            unreadReactionsCount: Int(dialog["unread_reactions_count"]?.int ?? 0),
        )
    }

    /// Messages older than `offsetId` (the newest when 0), newest first as Telegram returns them.
    public func history(peer: TelegramPeer, offsetId: Int32 = 0, limit: Int = 40) async throws -> TelegramHistoryPage {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getHistory", [
            "peer": .object(peer.inputPeer), "offset_id": .int(offsetId), "offset_date": .int(0), "add_offset": .int(0),
            "limit": .int(Int32(limit)), "max_id": .int(0), "min_id": .int(0), "hash": .long(0),
        ])).object else { throw TelegramError.protocolViolation("no history") }
        let page = page(from: result, peer: peer)
        let hasMore = result.name == "messages.messages" ? false : page.messages.count >= limit
        return TelegramHistoryPage(messages: page.messages, names: page.names, avatars: page.avatars, usernames: page.usernames, hasMore: hasMore)
    }

    /// Specific messages, such as the ones replies quote that aren't loaded; missing ids are left out.
    public func messages(peer: TelegramPeer, ids: [Int32]) async throws -> TelegramHistoryPage {
        try requireAccount()
        let inputIds: TLValue = .vector(ids.map { .object(TLObject("inputMessageID", ["id": .int($0)])) })
        // Supergroup message ids are per channel, so they're fetched through the channel.
        let method = peer.kind == .channel
            ? TLObject("channels.getMessages", [
                "channel": .object(TLObject("inputChannel", ["channel_id": .long(peer.id), "access_hash": .long(peer.accessHash)])),
                "id": inputIds,
            ])
            : TLObject("messages.getMessages", ["id": inputIds])
        guard let result = try await invoke(method).object else { throw TelegramError.protocolViolation("no messages") }
        return page(from: result, peer: peer)
    }

    /// Messages with their senders' names and avatars, from any `messages.Messages`.
    private func page(from result: TLObject, peer: TelegramPeer) -> TelegramHistoryPage {
        let rawMessages = result.objects("messages").filter { $0.name != "messageEmpty" }
        var names: [Int64: String] = [:]
        var avatars: [Int64: URL] = [:]
        var usernames: [String: Int64] = [:]
        for user in result.objects("users") {
            guard let id = user["id"]?.long else { continue }
            names[id] = Self.name(of: user)
            for username in Self.usernames(of: user) {
                usernames[username.lowercased()] = id
            }
            // A "min" user's access hash can't be used; its photo is reached through a message it sent.
            let sent = rawMessages.first(where: { $0["from_id"]?.object?["user_id"]?.long == id })?["id"]?.int
            let inputPeer: TLObject? = if !user.flag("min"), let hash = user["access_hash"]?.long {
                TLObject("inputPeerUser", ["user_id": .long(id), "access_hash": .long(hash)])
            } else if let sent {
                TLObject("inputPeerUserFromMessage", ["peer": .object(peer.inputPeer), "msg_id": .int(sent), "user_id": .long(id)])
            } else {
                nil
            }
            remember(user, sentIn: sent.map { (peer, $0) })
            if let inputPeer, let url = TelegramMediaParser.avatarURL(photo: user["photo"]?.object, inputPeer: inputPeer, key: "user:\(id)") {
                avatars[id] = url
            }
        }
        for chat in result.objects("chats") {
            guard let id = chat["id"]?.long else { continue }
            if let title = chat["title"]?.string {
                names[id] = title
            }
            let inputPeer: TLObject? = if chat.name == "chat" {
                TLObject("inputPeerChat", ["chat_id": .long(id)])
            } else if chat.name == "channel", !chat.flag("min"), let hash = chat["access_hash"]?.long {
                TLObject("inputPeerChannel", ["channel_id": .long(id), "access_hash": .long(hash)])
            } else {
                nil
            }
            if let inputPeer, let url = TelegramMediaParser.avatarURL(photo: chat["photo"]?.object, inputPeer: inputPeer, key: "chat:\(id)") {
                avatars[id] = url
            }
        }
        let messages = rawMessages.map { Self.message($0, selfId: stored.account?.userId, names: names) }
        return TelegramHistoryPage(messages: messages, names: names, avatars: avatars, usernames: usernames, hasMore: false)
    }

    /// Keeps how to name `user` to Telegram: its access hash, or for a "min" user, whose hash can't be used, a
    /// message it sent (`sentIn`).
    private func remember(_ user: TLObject, sentIn message: (peer: TelegramPeer, id: Int32)?) {
        guard let id = user["id"]?.long else { return }
        if !user.flag("min"), let hash = user["access_hash"]?.long {
            inputUsers[id] = TLObject("inputUser", ["user_id": .long(id), "access_hash": .long(hash)])
        } else if inputUsers[id] == nil, let message {
            inputUsers[id] = TLObject("inputUserFromMessage", ["peer": .object(message.peer.inputPeer), "msg_id": .int(message.id), "user_id": .long(id)])
        }
    }

    /// A user's usernames, the main one first; collectible ones are in `usernames`.
    static func usernames(of user: TLObject) -> [String] {
        ([user["username"]?.string] + user.objects("usernames").map { $0["username"]?.string }).compactMap(\.self)
    }

    /// A user's profile with their bio (`users.getFullUser`), for someone seen in a chat or member list
    /// (validated with the probe's `profile`).
    public func profile(userId: Int64) async throws -> TelegramProfile {
        try requireAccount()
        let input = userId == stored.account?.userId ? TLObject("inputUserSelf") : inputUsers[userId]
        guard let input else { throw TelegramError.unknownUser }
        guard let result = try await invoke(TLObject("users.getFullUser", ["id": .object(input)])).object else {
            throw TelegramError.protocolViolation("no full user")
        }
        let user = result.objects("users").first { $0["id"]?.long == userId }
        if let user {
            remember(user, sentIn: nil)
        }
        let hash = user.flatMap { $0.flag("min") ? nil : $0["access_hash"]?.long }
        let name = user.map(Self.name(of:)) ?? "Telegram User"
        profileNames.withLock { $0[userId] = name }
        let avatar = hash.flatMap { hash in
            TelegramMediaParser.avatarURL(
                photo: user?["photo"]?.object,
                inputPeer: TLObject("inputPeerUser", ["user_id": .long(userId), "access_hash": .long(hash)]),
                key: "user:\(userId)",
            )
        }
        let about = result["full_user"]?.object?["about"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TelegramProfile(
            id: userId,
            name: name,
            username: user.flatMap { Self.usernames(of: $0).first },
            about: about?.isEmpty == false ? about : nil,
            avatarURL: avatar,
            status: user.flatMap(Self.userStatus),
            isBot: user?.flag("bot") ?? false,
            isYou: userId == stored.account?.userId,
            peer: hash.map { TelegramPeer(kind: .user, id: userId, accessHash: $0) },
        )
    }

    /// The profile an `@username` mention names (`contacts.resolveUsername`, validated with the probe's
    /// `resolve`); a username can also name a channel or group, which has no profile here.
    public func profile(username: String) async throws -> TelegramProfile {
        try requireAccount()
        guard let result = try await invoke(TLObject("contacts.resolveUsername", ["username": .string(username)])).object else {
            throw TelegramError.protocolViolation("no resolved peer")
        }
        for user in result.objects("users") {
            remember(user, sentIn: nil)
        }
        guard let userId = result["peer"]?.object?["user_id"]?.long else { throw TelegramError.notAPerson }
        return try await profile(userId: userId)
    }

    /// A group's members: `channels.getParticipants` (recent, up to 200) for supergroups, the full participant list
    /// of `messages.getFullChat` for basic groups. Groups that hide their members answer `CHAT_ADMIN_REQUIRED`.
    public func members(peer: TelegramPeer) async throws -> TelegramMemberList {
        try requireAccount()
        let result: TLObject
        let participants: [TLObject]
        let count: Int
        switch peer.kind {
        case .channel:
            guard let page = try await invoke(TLObject("channels.getParticipants", [
                "channel": .object(TLObject("inputChannel", ["channel_id": .long(peer.id), "access_hash": .long(peer.accessHash)])),
                "filter": .object(TLObject("channelParticipantsRecent")),
                "offset": .int(0),
                "limit": .int(200),
                "hash": .long(0),
            ])).object else { throw TelegramError.protocolViolation("no participants") }
            result = page
            participants = page.objects("participants")
            count = page["count"]?.int.map(Int.init) ?? participants.count
        case .chat:
            guard let full = try await invoke(TLObject("messages.getFullChat", ["chat_id": .long(peer.id)])).object else {
                throw TelegramError.protocolViolation("no full chat")
            }
            result = full
            participants = full["full_chat"]?.object?["participants"]?.object?.objects("participants") ?? []
            count = participants.count
        case .user:
            return TelegramMemberList(members: [], count: 0)
        }
        let users = Dictionary(result.objects("users").compactMap { user in user["id"]?.long.map { ($0, user) } }, uniquingKeysWith: { first, _ in first })
        for user in users.values {
            remember(user, sentIn: nil)
        }
        let selfId = stored.account?.userId
        let members: [TelegramMember] = participants.compactMap { participant in
            guard let id = participant["user_id"]?.long ?? participant["peer"]?.object?["user_id"]?.long, let user = users[id] else { return nil }
            let role: TelegramMember.Role = switch participant.name {
            case "channelParticipantCreator", "chatParticipantCreator": .owner
            case "channelParticipantAdmin", "chatParticipantAdmin": .admin
            default: .member
            }
            let avatar = (!user.flag("min") ? user["access_hash"]?.long : nil).flatMap { hash in
                TelegramMediaParser.avatarURL(
                    photo: user["photo"]?.object,
                    inputPeer: TLObject("inputPeerUser", ["user_id": .long(id), "access_hash": .long(hash)]),
                    key: "user:\(id)",
                )
            }
            return TelegramMember(
                id: id,
                name: Self.name(of: user),
                username: user["username"]?.string,
                avatarURL: avatar,
                role: role,
                status: id == selfId ? .online : Self.status(of: user["status"]?.object),
                isYou: id == selfId,
                isBot: user.flag("bot"),
            )
        }
        return TelegramMemberList(members: members, count: max(count, members.count))
    }

    /// A person's status as a private chat shows it; `nil` for yourself (Saved Messages) and bots.
    static func userStatus(_ user: TLObject) -> ChatPresence? {
        guard !user.flag("self"), !user.flag("bot") else { return nil }
        return status(of: user["status"]?.object)
    }

    static func status(of status: TLObject?) -> ChatPresence {
        switch status?.name {
        case "userStatusOnline": .online
        case "userStatusOffline": status?["was_online"]?.int.map { .lastSeen(Date(timeIntervalSince1970: TimeInterval($0))) } ?? .unknown
        case "userStatusRecently": .recently
        case "userStatusLastWeek": .lastWeek
        case "userStatusLastMonth": .lastMonth
        default: .unknown
        }
    }

    /// Sends text, returning the new message's id. `mentions` are name mentions of users this device can name;
    /// Telegram marks `@username`s in the text by itself (both validated with the probe's `send`).
    public func send(peer: TelegramPeer, text: String, mentions: [TelegramMention] = [], replyTo: Int32?) async throws -> Int32? {
        try requireAccount()
        let randomId = Int64.random(in: 1 ... .max)
        var method = TLObject("messages.sendMessage", ["peer": .object(peer.inputPeer), "message": .string(text), "random_id": .long(randomId)])
        if let replyTo {
            method["reply_to"] = .object(TLObject("inputReplyToMessage", ["reply_to_msg_id": .int(replyTo)]))
        }
        if let entities = mentionEntities(mentions) {
            method["entities"] = entities
        }
        return try await Self.sentMessageId(invoke(method).object, randomId: randomId)
    }

    /// `inputMessageEntityMentionName`s for the name mentions whose users this device can name.
    private func mentionEntities(_ mentions: [TelegramMention]) -> TLValue? {
        let entities: [TLValue] = mentions.compactMap { mention in
            guard let userId = mention.userId, let user = inputUsers[userId] else { return nil }
            return .object(TLObject("inputMessageEntityMentionName", [
                "offset": .int(Int32(mention.offset)), "length": .int(Int32(mention.length)), "user_id": .object(user),
            ]))
        }
        return entities.isEmpty ? nil : .vector(entities)
    }

    private static func sentMessageId(_ updates: TLObject?, randomId: Int64) -> Int32? {
        guard let updates else { return nil }
        if updates.name == "updateShortSentMessage" {
            return updates["id"]?.int
        }
        for update in updates.objects("updates") where update.name == "updateMessageID" && update["random_id"]?.long == randomId {
            return update["id"]?.int
        }
        return nil
    }

    /// Uploads a photo or file in 512 KB parts and sends it with `caption`, returning the new message's id
    /// (validated with the probe's `send-photo`).
    public func sendMedia(peer: TelegramPeer, data: Data, mimeType: String, filename: String, isImage: Bool, caption: String, mentions: [TelegramMention] = [], replyTo: Int32?) async throws -> Int32? {
        try requireAccount()
        let fileId = Int64.random(in: 1 ... .max)
        let partSize = 512 * 1024
        let parts = (data.count + partSize - 1) / partSize
        // Files over 10 MB go up as "big" files, which name their part count on every part.
        let isBig = data.count > 10 * 1024 * 1024
        for part in 0 ..< parts {
            let bytes = data.subdata(in: part * partSize ..< min(data.count, (part + 1) * partSize))
            let method = isBig
                ? TLObject("upload.saveBigFilePart", ["file_id": .long(fileId), "file_part": .int(Int32(part)), "file_total_parts": .int(Int32(parts)), "bytes": .bytes(bytes)])
                : TLObject("upload.saveFilePart", ["file_id": .long(fileId), "file_part": .int(Int32(part)), "bytes": .bytes(bytes)])
            guard try await invoke(method).bool == true else { throw TelegramError.protocolViolation("upload part refused") }
        }
        let file = isBig
            ? TLObject("inputFileBig", ["id": .long(fileId), "parts": .int(Int32(parts)), "name": .string(filename)])
            : TLObject("inputFile", ["id": .long(fileId), "parts": .int(Int32(parts)), "name": .string(filename), "md5_checksum": .string("")])
        let media = isImage
            ? TLObject("inputMediaUploadedPhoto", ["file": .object(file)])
            : TLObject("inputMediaUploadedDocument", [
                "file": .object(file),
                "mime_type": .string(mimeType),
                "attributes": .vector([.object(TLObject("documentAttributeFilename", ["file_name": .string(filename)]))]),
            ])
        let randomId = Int64.random(in: 1 ... .max)
        var method = TLObject("messages.sendMedia", ["peer": .object(peer.inputPeer), "media": .object(media), "message": .string(caption), "random_id": .long(randomId)])
        if let replyTo {
            method["reply_to"] = .object(TLObject("inputReplyToMessage", ["reply_to_msg_id": .int(replyTo)]))
        }
        if let entities = mentionEntities(mentions) {
            method["entities"] = entities
        }
        return try await Self.sentMessageId(invoke(method).object, randomId: randomId)
    }

    /// Custom emoji images by document id, from `messages.getCustomEmojiDocuments` (200 at most per call) and
    /// remembered for the session. Static WebP emoji load whole; animated ones (TGS, WebM) show their largest
    /// thumbnail, a WebP still (observed 2026-10-30; probe `custom-emoji`).
    public func customEmojiImages(documentIds: [Int64]) async throws -> [Int64: TelegramCustomEmojiImage] {
        try requireAccount()
        let missing = Array(Set(documentIds).subtracting(customEmojiImages.keys))
        for start in stride(from: 0, to: missing.count, by: 200) {
            let ids = missing[start ..< min(start + 200, missing.count)].map { TLValue.long($0) }
            let documents = try await invoke(TLObject("messages.getCustomEmojiDocuments", ["document_id": .vector(ids)])).vector ?? []
            for document in documents.compactMap(\.object) where document.name == "document" {
                guard let id = document["id"]?.long else { continue }
                let attributes = document.objects("attributes")
                let size = attributes.first { $0.name == "documentAttributeImageSize" || $0.name == "documentAttributeVideo" }
                let aspect = size.flatMap { size in size["w"]?.int.flatMap { w in size["h"]?.int.map { Double(w) / Double(max($0, 1)) } } } ?? 1
                let url = if document["mime_type"]?.string == "image/webp" {
                    TelegramMediaParser.documentURL(document, thumbSize: "")
                } else {
                    TelegramMediaParser.bestSize(document.objects("thumbs"), maxSide: 320).flatMap { TelegramMediaParser.documentURL(document, thumbSize: $0.type) }
                }
                guard let url else { continue }
                let alt = attributes.first { $0.name == "documentAttributeCustomEmoji" }?["alt"]?.string
                customEmojiImages[id] = TelegramCustomEmojiImage(url: url, alt: alt, aspectRatio: aspect)
            }
        }
        return customEmojiImages.filter { documentIds.contains($0.key) }
    }

    /// Sets the user's reaction (nil removes it), returning the message's new totals when Telegram sends them.
    public func setReaction(peer: TelegramPeer, messageId: Int32, emoji: String?) async throws -> (totals: [TelegramReaction], reactors: [TelegramReactor])? {
        try requireAccount()
        let reaction: [TLValue] = emoji.map { emoji in
            if let documentId = TelegramCustomEmoji.documentId(fromKey: emoji) {
                return [.object(TLObject("reactionCustomEmoji", ["document_id": .long(documentId)]))]
            }
            return [.object(TLObject("reactionEmoji", ["emoticon": .string(emoji)]))]
        } ?? []
        let updates = try await invoke(TLObject("messages.sendReaction", ["peer": .object(peer.inputPeer), "msg_id": .int(messageId), "reaction": .vector(reaction)])).object
        guard let update = updates?.objects("updates").first(where: { $0.name == "updateMessageReactions" }), let reactions = update["reactions"] else { return nil }
        return TelegramMediaParser.reactions(of: TLObject("message", ["reactions": reactions]))
    }

    /// The user's messages with reactions they haven't seen, newest first (`messages.getUnreadReactions`).
    public func unreadReactionMessageIds(peer: TelegramPeer, limit: Int = 100) async throws -> [Int32] {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getUnreadReactions", [
            "peer": .object(peer.inputPeer), "offset_id": .int(0), "add_offset": .int(0), "limit": .int(Int32(limit)),
            "max_id": .int(0), "min_id": .int(0),
        ])).object else { throw TelegramError.protocolViolation("no unread reactions") }
        return result.objects("messages").filter { $0.name != "messageEmpty" }.compactMap { $0["id"]?.int }
    }

    /// Marks the reactions on these messages seen, as Telegram's apps do when the messages show
    /// (`messages.readMessageContents`, or `channels.readMessageContents` in supergroups).
    public func markReactionsSeen(peer: TelegramPeer, messageIds: [Int32]) async throws {
        try requireAccount()
        let ids: TLValue = .vector(messageIds.map { .int($0) })
        if peer.kind == .channel {
            _ = try await invoke(TLObject("channels.readMessageContents", [
                "channel": .object(TLObject("inputChannel", ["channel_id": .long(peer.id), "access_hash": .long(peer.accessHash)])),
                "id": ids,
            ]))
        } else {
            _ = try await invoke(TLObject("messages.readMessageContents", ["id": ids]))
        }
    }

    /// Shows the account typing in `peer` for about 6 seconds, or stops it. Nobody sees typing in Saved Messages.
    public func setTyping(peer: TelegramPeer, isTyping: Bool) async throws {
        try requireAccount()
        guard peer.kind != .user || peer.id != account?.userId else { return }
        let action = TLObject(isTyping ? "sendMessageTypingAction" : "sendMessageCancelAction")
        _ = try await invoke(TLObject("messages.setTyping", ["peer": .object(peer.inputPeer), "action": .object(action)]))
    }

    public func markRead(peer: TelegramPeer, maxId: Int32) async throws {
        try requireAccount()
        if peer.kind == .channel {
            _ = try await invoke(TLObject("channels.readHistory", [
                "channel": .object(TLObject("inputChannel", ["channel_id": .long(peer.id), "access_hash": .long(peer.accessHash)])),
                "max_id": .int(maxId),
            ]))
        } else {
            _ = try await invoke(TLObject("messages.readHistory", ["peer": .object(peer.inputPeer), "max_id": .int(maxId)]))
        }
    }

    // MARK: Parsing

    static func peerKey(_ peer: TLObject) -> String {
        switch peer.name {
        case "peerUser": "user:\(peer["user_id"]?.long ?? 0)"
        case "peerChat": "chat:\(peer["chat_id"]?.long ?? 0)"
        default: "channel:\(peer["channel_id"]?.long ?? 0)"
        }
    }

    private static func peer(_ peer: TLObject, users: [Int64: TLObject], chats: [Int64: TLObject]) -> TelegramPeer? {
        switch peer.name {
        case "peerUser":
            guard let id = peer["user_id"]?.long, let user = users[id], user.name == "user" else { return nil }
            return TelegramPeer(kind: .user, id: id, accessHash: user["access_hash"]?.long ?? 0)
        case "peerChat":
            guard let id = peer["chat_id"]?.long else { return nil }
            return TelegramPeer(kind: .chat, id: id, accessHash: 0)
        case "peerChannel":
            guard let id = peer["channel_id"]?.long, let access = chats[id]?["access_hash"]?.long else { return nil }
            return TelegramPeer(kind: .channel, id: id, accessHash: access)
        default:
            return nil
        }
    }

    static func name(of user: TLObject) -> String {
        if user.flag("deleted") {
            return "Deleted Account"
        }
        let full = [user["first_name"]?.string, user["last_name"]?.string].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? user["username"]?.string ?? "Telegram User" : full
    }

    /// `selfId` marks the user's own messages where Telegram leaves out `out`, as in Saved Messages.
    /// `names` (user and chat id → name, from the same response) words service messages, such as who joined.
    static func message(_ message: TLObject, selfId: Int64? = nil, names: [Int64: String] = [:]) -> TelegramMessage {
        let isService = message.name == "messageService"
        let caption = message["message"]?.string ?? ""
        var text = caption
        var embeds: [TelegramEmbed] = []
        let from = message["from_id"]?.object
        let senderId: Int64? = from.flatMap { $0["user_id"]?.long ?? $0["channel_id"]?.long ?? $0["chat_id"]?.long }
            ?? message["peer_id"]?.object.flatMap { $0.name == "peerUser" ? $0["user_id"]?.long : nil }
        if isService {
            let name = { (id: Int64?) in id == selfId && selfId != nil ? "You" : id.flatMap { names[$0] } ?? "Someone" }
            text = message["action"]?.object.map { serviceText($0, actor: name(senderId), name: { name($0) }) } ?? "Service message"
        } else if let media = message["media"]?.object {
            let content = TelegramMediaParser.content(of: media)
            embeds = content.embeds
            if let label = content.label {
                text = caption.isEmpty ? label : "\(label) · \(caption)"
            }
        }
        let reactions = TelegramMediaParser.reactions(of: message)
        var spoilers: [NSRange] = message.objects("entities").filter { $0.name == "messageEntitySpoiler" }.compactMap { entity in
            guard let offset = entity["offset"]?.int, let length = entity["length"]?.int else { return nil }
            return NSRange(location: Int(offset), length: Int(length))
        }
        if senderId == SpoilerText.telegramServiceUserId, !isService {
            spoilers += SpoilerText.loginCodeRanges(in: caption)
        }
        let mentions: [TelegramMention] = isService ? [] : message.objects("entities").compactMap { entity in
            guard let offset = entity["offset"]?.int, let length = entity["length"]?.int else { return nil }
            let range = NSRange(location: Int(offset), length: Int(length))
            switch entity.name {
            case "messageEntityMentionName":
                guard let userId = entity["user_id"]?.long else { return nil }
                return TelegramMention(offset: range.location, length: range.length, userId: userId, username: nil)
            case "messageEntityMention":
                guard NSMaxRange(range) <= (caption as NSString).length else { return nil }
                let username = String((caption as NSString).substring(with: range).dropFirst())
                return TelegramMention(offset: range.location, length: range.length, userId: nil, username: username)
            default:
                return nil
            }
        }
        let customEmojis: [TelegramCustomEmoji] = isService ? [] : message.objects("entities").compactMap { entity in
            guard entity.name == "messageEntityCustomEmoji", let offset = entity["offset"]?.int, let length = entity["length"]?.int,
                  let documentId = entity["document_id"]?.long
            else { return nil }
            return TelegramCustomEmoji(offset: Int(offset), length: Int(length), documentId: documentId)
        }
        return TelegramMessage(
            id: message["id"]?.int ?? 0,
            date: Date(timeIntervalSince1970: TimeInterval(message["date"]?.int ?? 0)),
            text: text,
            caption: isService ? "" : caption,
            spoilers: spoilers.isEmpty ? nil : spoilers,
            mentions: mentions.isEmpty ? nil : mentions,
            customEmojis: customEmojis.isEmpty ? nil : customEmojis,
            groupedId: message["grouped_id"]?.long,
            embeds: embeds,
            reactions: reactions.totals,
            reactors: reactions.reactors,
            senderId: senderId,
            isOutgoing: message.flag("out") || (selfId != nil && senderId == selfId),
            replyToId: message["reply_to"]?.object?["reply_to_msg_id"]?.int,
            isService: isService,
        )
    }

    /// Worded like Telegram's own service messages, with `actor` the sender and `name` for other users.
    static func serviceText(_ action: TLObject, actor: String, name: (Int64) -> String) -> String {
        switch action.name {
        case "messageActionChatCreate": return "\(actor) created the group “\(action["title"]?.string ?? "")”"
        case "messageActionChatEditTitle": return "\(actor) changed the group name to “\(action["title"]?.string ?? "")”"
        case "messageActionChatEditPhoto": return "\(actor) changed the group photo"
        case "messageActionChatDeletePhoto": return "\(actor) removed the group photo"
        case "messageActionChatAddUser":
            let added = action["users"]?.vector?.compactMap(\.long) ?? []
            // Joining by yourself (through the public link of a supergroup) is an add of the sender.
            if added.isEmpty || added.allSatisfy({ name($0) == actor }) {
                return "\(actor) joined the group"
            }
            return "\(actor) added \(ListFormatter.localizedString(byJoining: added.map(name)))"
        case "messageActionChatJoinedByLink": return "\(actor) joined the group via invite link"
        case "messageActionChatJoinedByRequest": return "\(actor) was accepted to the group"
        case "messageActionChatDeleteUser":
            guard let removed = action["user_id"]?.long, name(removed) != actor else { return "\(actor) left the group" }
            return "\(actor) removed \(name(removed))"
        case "messageActionPinMessage": return "\(actor) pinned a message"
        case "messageActionPhoneCall": return action.flag("video") ? "Video call" : "Call"
        case "messageActionScreenshotTaken": return "\(actor) took a screenshot"
        case "messageActionContactSignUp": return "\(actor) joined Telegram"
        case "messageActionChannelMigrateFrom", "messageActionChatMigrateTo": return "Group upgraded"
        default: return action.name.replacingOccurrences(of: "messageAction", with: "")
        }
    }
}

extension TelegramClient: ChatListResolving {
    /// A notification names the chat without its access hash, so it matches on kind and id. A private chat opened
    /// from a profile, with its access hash, opens even before you've messaged them: it's titled by the name the
    /// profile showed until it loads.
    public nonisolated func chat(for destination: ChatSummary.Destination, in chats: [ChatSummary]) -> ChatSummary? {
        guard case let .telegram(peer) = destination else { return nil }
        if let listed = chats.first(where: { chat in
            guard case let .telegram(listed) = chat.destination else { return false }
            return listed.kind == peer.kind && listed.id == peer.id
        }) {
            return listed
        }
        guard peer.kind == .user, peer.accessHash != 0, let name = profileNames.withLock({ $0[peer.id] }) else { return nil }
        return ChatSummary(
            id: "telegram:\(peer.key)",
            network: .telegram,
            title: name,
            avatarURL: nil,
            avatarColorKey: String(peer.id),
            preview: nil,
            timestamp: nil,
            unreadCount: 0,
            destination: destination,
        )
    }
}
