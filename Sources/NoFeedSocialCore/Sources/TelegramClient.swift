import Foundation

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
    /// The text, or what was sent when there's none, such as "Photo".
    public let text: String
    public let senderId: Int64?
    public let isOutgoing: Bool
    public let replyToId: Int32?
    /// A service message such as "joined the group", shown as a caption.
    public let isService: Bool
}

public struct TelegramHistoryPage: Sendable {
    public let messages: [TelegramMessage]
    /// User and chat id → display name, for senders.
    public let names: [Int64: String]
    public let hasMore: Bool
}

public struct TelegramDialogState: Sendable {
    public let title: String
    public let isGroup: Bool
    public let memberCount: Int?
    public let readInboxMaxId: Int32
    public let readOutboxMaxId: Int32
}

public enum TelegramSignInResult: Sendable, Equatable {
    case signedIn
    case passwordNeeded(hint: String?)
}

/// `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`, written to `Resources/TelegramAPI.json` by
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
public actor TelegramClient {
    private struct Stored: Codable {
        var homeDC = 2
        var keys: [Int: TelegramDCKey] = [:]
        var account: TelegramAccount?
    }

    public static var isAvailable: Bool {
        TelegramAPIConfig.bundled != nil
    }

    private let keychain = KeychainCredentialStore()
    private var stored: Stored
    private var current: MTProtoSession?
    private var opening: Task<MTProtoSession, Error>?
    private var phoneLogin: (phone: String, hash: String)?
    private var observers: [UUID: @Sendable (TLObject) -> Void] = [:]

    public init() {
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

    private func openSession(dc: Int, retryingKey: Bool = true) async throws -> MTProtoSession {
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
                "query": .object(TLObject("help.getConfig")),
            ])),
        ])
        do {
            _ = try await session.call(initConnection)
            if stored.account != nil {
                // Telegram pushes updates only to sessions that have asked for the update state.
                _ = try await session.call(TLObject("updates.getState"))
            }
            return session
        } catch TelegramError.authKeyInvalid where retryingKey {
            await session.close()
            stored.keys[dc] = nil
            save()
            return try await openSession(dc: dc, retryingKey: false)
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

    // MARK: Updates

    /// Calls `observer` with each update Telegram pushes while the session is open.
    public func addUpdateObserver(_ observer: @escaping @Sendable (_ name: String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = { observer($0.name) }
        return id
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

    public func signOut() async {
        if stored.account != nil {
            _ = try? await invoke(TLObject("auth.logOut"))
        }
        await current?.close()
        current = nil
        stored = Stored()
        try? keychain.deleteTelegramSession()
    }

    // MARK: Chats

    private func requireAccount() throws {
        guard TelegramAPIConfig.bundled != nil, stored.account != nil else { throw SourceError.notConfigured }
    }

    /// The main chat list, without broadcast channels and archived chats.
    public func chatSummaries(limit: Int = 50) async throws -> [ChatSummary] {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getDialogs", [
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
            let latest = top.map { Self.message($0) }
            var preview = latest?.text.replacingOccurrences(of: "\n", with: " ")
            if let latest, let body = preview, !latest.isService {
                if latest.isOutgoing {
                    preview = "You: \(body)"
                } else if peer.kind != .user, let sender = latest.senderId {
                    let name = users[sender].map { $0["first_name"]?.string ?? Self.name(of: $0) } ?? chats[sender]?["title"]?.string
                    preview = name.map { "\($0): \(body)" } ?? body
                }
            }
            return ChatSummary(
                id: "telegram:\(peer.key)",
                network: .telegram,
                title: title,
                avatarURL: nil,
                preview: preview,
                timestamp: latest?.date,
                unreadCount: Int(dialog["unread_count"]?.int ?? 0),
                destination: .telegram(peer: peer),
                namesSenderInPreview: peer.kind != .user,
                titleNamesPeople: peer.kind == .user,
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
        if peer.kind == .user {
            let user = result.objects("users").first { $0["id"]?.long == peer.id }
            title = user?.flag("self") == true ? "Saved Messages" : user.map(Self.name(of:)) ?? "Telegram"
        } else {
            let chat = result.objects("chats").first { $0["id"]?.long == peer.id }
            title = chat?["title"]?.string ?? "Group"
            memberCount = chat?["participants_count"]?.int.map(Int.init)
        }
        return TelegramDialogState(
            title: title,
            isGroup: peer.kind != .user,
            memberCount: memberCount,
            readInboxMaxId: dialog["read_inbox_max_id"]?.int ?? 0,
            readOutboxMaxId: dialog["read_outbox_max_id"]?.int ?? 0,
        )
    }

    /// Messages older than `offsetId` (the newest when 0), newest first as Telegram returns them.
    public func history(peer: TelegramPeer, offsetId: Int32 = 0, limit: Int = 40) async throws -> TelegramHistoryPage {
        try requireAccount()
        guard let result = try await invoke(TLObject("messages.getHistory", [
            "peer": .object(peer.inputPeer), "offset_id": .int(offsetId), "offset_date": .int(0), "add_offset": .int(0),
            "limit": .int(Int32(limit)), "max_id": .int(0), "min_id": .int(0), "hash": .long(0),
        ])).object else { throw TelegramError.protocolViolation("no history") }
        var names: [Int64: String] = [:]
        for user in result.objects("users") {
            if let id = user["id"]?.long {
                names[id] = Self.name(of: user)
            }
        }
        for chat in result.objects("chats") {
            if let id = chat["id"]?.long, let title = chat["title"]?.string {
                names[id] = title
            }
        }
        let messages = result.objects("messages").filter { $0.name != "messageEmpty" }.map { Self.message($0) }
        let hasMore = result.name == "messages.messages" ? false : messages.count >= limit
        return TelegramHistoryPage(messages: messages, names: names, hasMore: hasMore)
    }

    /// Sends text, returning the new message's id.
    public func send(peer: TelegramPeer, text: String, replyTo: Int32?) async throws -> Int32? {
        try requireAccount()
        let randomId = Int64.random(in: 1 ... .max)
        var method = TLObject("messages.sendMessage", ["peer": .object(peer.inputPeer), "message": .string(text), "random_id": .long(randomId)])
        if let replyTo {
            method["reply_to"] = .object(TLObject("inputReplyToMessage", ["reply_to_msg_id": .int(replyTo)]))
        }
        guard let updates = try await invoke(method).object else { return nil }
        if updates.name == "updateShortSentMessage" {
            return updates["id"]?.int
        }
        for update in updates.objects("updates") where update.name == "updateMessageID" && update["random_id"]?.long == randomId {
            return update["id"]?.int
        }
        return nil
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

    static func message(_ message: TLObject) -> TelegramMessage {
        let isService = message.name == "messageService"
        var text = message["message"]?.string ?? ""
        if isService {
            text = message["action"]?.object.map(serviceText) ?? "Service message"
        } else if let media = message["media"]?.object, let label = mediaLabel(media) {
            text = text.isEmpty ? label : "\(label) · \(text)"
        }
        let from = message["from_id"]?.object
        let senderId: Int64? = from.flatMap { $0["user_id"]?.long ?? $0["channel_id"]?.long ?? $0["chat_id"]?.long }
            ?? message["peer_id"]?.object.flatMap { $0.name == "peerUser" ? $0["user_id"]?.long : nil }
        return TelegramMessage(
            id: message["id"]?.int ?? 0,
            date: Date(timeIntervalSince1970: TimeInterval(message["date"]?.int ?? 0)),
            text: text,
            senderId: senderId,
            isOutgoing: message.flag("out"),
            replyToId: message["reply_to"]?.object?["reply_to_msg_id"]?.int,
            isService: isService,
        )
    }

    /// What a message without text shows, such as "Photo" or "Voice message"; nil for link previews.
    static func mediaLabel(_ media: TLObject) -> String? {
        switch media.name {
        case "messageMediaPhoto": return "Photo"
        case "messageMediaGeo", "messageMediaGeoLive", "messageMediaVenue": return "Location"
        case "messageMediaContact": return "Contact"
        case "messageMediaPoll": return "Poll"
        case "messageMediaDice": return media["emoticon"]?.string ?? "Dice"
        case "messageMediaGame": return "Game"
        case "messageMediaInvoice": return "Invoice"
        case "messageMediaStory": return "Story"
        case "messageMediaGiveaway", "messageMediaGiveawayResults": return "Giveaway"
        case "messageMediaWebPage", "messageMediaEmpty": return nil
        case "messageMediaDocument":
            let attributes = media["document"]?.object?.objects("attributes") ?? []
            if let sticker = attributes.first(where: { $0.name == "documentAttributeSticker" }) {
                return [sticker["alt"]?.string, "Sticker"].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
            }
            if let video = attributes.first(where: { $0.name == "documentAttributeVideo" }) {
                return video.flag("round_message") ? "Video message" : attributes.contains { $0.name == "documentAttributeAnimated" } ? "GIF" : "Video"
            }
            if let audio = attributes.first(where: { $0.name == "documentAttributeAudio" }) {
                return audio.flag("voice") ? "Voice message" : audio["title"]?.string ?? "Audio"
            }
            if attributes.contains(where: { $0.name == "documentAttributeAnimated" }) {
                return "GIF"
            }
            return attributes.first { $0.name == "documentAttributeFilename" }?["file_name"]?.string ?? "File"
        default:
            return "Attachment"
        }
    }

    static func serviceText(_ action: TLObject) -> String {
        switch action.name {
        case "messageActionChatCreate": "Group created"
        case "messageActionChatEditTitle": "Group renamed to “\(action["title"]?.string ?? "")”"
        case "messageActionChatEditPhoto": "Group photo changed"
        case "messageActionChatAddUser", "messageActionChatJoinedByLink", "messageActionChatJoinedByRequest": "Someone joined"
        case "messageActionChatDeleteUser": "Someone left"
        case "messageActionPinMessage": "Message pinned"
        case "messageActionPhoneCall": action.flag("video") ? "Video call" : "Call"
        case "messageActionScreenshotTaken": "Screenshot taken"
        case "messageActionContactSignUp": "Joined Telegram"
        case "messageActionChannelMigrateFrom", "messageActionChatMigrateTo": "Group upgraded"
        default: action.name.replacingOccurrences(of: "messageAction", with: "")
        }
    }
}
