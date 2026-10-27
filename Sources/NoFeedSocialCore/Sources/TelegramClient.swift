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
    public var embeds: [TelegramEmbed] = []
    public var reactions: [TelegramReaction] = []
    public var reactors: [TelegramReactor] = []
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
    /// User and chat id → profile photo (a `tgfile:` URL).
    public let avatars: [Int64: URL]
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
public actor TelegramClient {
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

    private let keychain = KeychainCredentialStore()
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
    private let mediaDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "telegram-media", directoryHint: .isDirectory)

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
        let task = Task { try await download(location: file.location, dc: file.dc) }
        downloads[file.key] = task
        defer { downloads[file.key] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// `upload.getFile` in 512 KB parts until a short one, following `FILE_MIGRATE_X`.
    private func download(location: TLObject, dc initialDC: Int) async throws -> Data {
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
            if bytes.count < limit || data.count >= TelegramMediaURL.maxDownloadSize {
                return data
            }
        }
    }

    // MARK: Updates

    /// Calls `observer` when Telegram pushes an update to `peer`'s messages (new, edited, deleted, read by
    /// the other side) while the session is open. Status and typing updates, which arrive constantly, don't count.
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
    public func registerPush(deviceToken: String, sandbox: Bool) async throws {
        try requireAccount()
        _ = try await invoke(TLObject("account.registerDevice", [
            "no_muted": .bool(true),
            "token_type": .int(1),
            "token": .string(deviceToken),
            "app_sandbox": .bool(sandbox),
            "secret": .bytes(Data()),
            "other_uids": .vector([]),
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
    public func chatSummaries(archived: Bool = false, limit: Int = 50) async throws -> [ChatSummary] {
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
            var preview = latest?.text.replacingOccurrences(of: "\n", with: " ")
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
        let page = page(from: result, peer: peer)
        let hasMore = result.name == "messages.messages" ? false : page.messages.count >= limit
        return TelegramHistoryPage(messages: page.messages, names: page.names, avatars: page.avatars, hasMore: hasMore)
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
        for user in result.objects("users") {
            guard let id = user["id"]?.long else { continue }
            names[id] = Self.name(of: user)
            // A "min" user's access hash can't be used; its photo is reached through a message it sent.
            let inputPeer: TLObject? = if !user.flag("min"), let hash = user["access_hash"]?.long {
                TLObject("inputPeerUser", ["user_id": .long(id), "access_hash": .long(hash)])
            } else if let sent = rawMessages.first(where: { $0["from_id"]?.object?["user_id"]?.long == id })?["id"]?.int {
                TLObject("inputPeerUserFromMessage", ["peer": .object(peer.inputPeer), "msg_id": .int(sent), "user_id": .long(id)])
            } else {
                nil
            }
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
        let messages = rawMessages.map { Self.message($0, selfId: stored.account?.userId) }
        return TelegramHistoryPage(messages: messages, names: names, avatars: avatars, hasMore: false)
    }

    /// Sends text, returning the new message's id.
    public func send(peer: TelegramPeer, text: String, replyTo: Int32?) async throws -> Int32? {
        try requireAccount()
        let randomId = Int64.random(in: 1 ... .max)
        var method = TLObject("messages.sendMessage", ["peer": .object(peer.inputPeer), "message": .string(text), "random_id": .long(randomId)])
        if let replyTo {
            method["reply_to"] = .object(TLObject("inputReplyToMessage", ["reply_to_msg_id": .int(replyTo)]))
        }
        return try await Self.sentMessageId(invoke(method).object, randomId: randomId)
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
    public func sendMedia(peer: TelegramPeer, data: Data, mimeType: String, filename: String, isImage: Bool, caption: String, replyTo: Int32?) async throws -> Int32? {
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
        return try await Self.sentMessageId(invoke(method).object, randomId: randomId)
    }

    /// Sets the user's reaction (nil removes it), returning the message's new totals when Telegram sends them.
    public func setReaction(peer: TelegramPeer, messageId: Int32, emoji: String?) async throws -> (totals: [TelegramReaction], reactors: [TelegramReactor])? {
        try requireAccount()
        let reaction: [TLValue] = emoji.map { [.object(TLObject("reactionEmoji", ["emoticon": .string($0)]))] } ?? []
        let updates = try await invoke(TLObject("messages.sendReaction", ["peer": .object(peer.inputPeer), "msg_id": .int(messageId), "reaction": .vector(reaction)])).object
        guard let update = updates?.objects("updates").first(where: { $0.name == "updateMessageReactions" }), let reactions = update["reactions"] else { return nil }
        return TelegramMediaParser.reactions(of: TLObject("message", ["reactions": reactions]))
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
    static func message(_ message: TLObject, selfId: Int64? = nil) -> TelegramMessage {
        let isService = message.name == "messageService"
        let caption = message["message"]?.string ?? ""
        var text = caption
        var embeds: [TelegramEmbed] = []
        if isService {
            text = message["action"]?.object.map(serviceText) ?? "Service message"
        } else if let media = message["media"]?.object {
            let content = TelegramMediaParser.content(of: media)
            embeds = content.embeds
            if let label = content.label {
                text = caption.isEmpty ? label : "\(label) · \(caption)"
            }
        }
        let from = message["from_id"]?.object
        let senderId: Int64? = from.flatMap { $0["user_id"]?.long ?? $0["channel_id"]?.long ?? $0["chat_id"]?.long }
            ?? message["peer_id"]?.object.flatMap { $0.name == "peerUser" ? $0["user_id"]?.long : nil }
        let reactions = TelegramMediaParser.reactions(of: message)
        return TelegramMessage(
            id: message["id"]?.int ?? 0,
            date: Date(timeIntervalSince1970: TimeInterval(message["date"]?.int ?? 0)),
            text: text,
            caption: isService ? "" : caption,
            embeds: embeds,
            reactions: reactions.totals,
            reactors: reactions.reactors,
            senderId: senderId,
            isOutgoing: message.flag("out") || (selfId != nil && senderId == selfId),
            replyToId: message["reply_to"]?.object?["reply_to_msg_id"]?.int,
            isService: isService,
        )
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
