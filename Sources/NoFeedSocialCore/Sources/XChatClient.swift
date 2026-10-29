import Foundation
import JuiceboxSdk

/// The account's XChat private keys: P-256 identity (ECDH) and signing (ECDSA) keys, recovered from X's
/// Juicebox realms with the user's XChat PIN.
public struct XChatKeys: Codable, Sendable {
    let userId: String
    /// The public key version X registered these under, which signatures name.
    let version: String
    let identityPrivateKey: Data
    let signingPrivateKey: Data
    /// As X registered it: base64 SubjectPublicKeyInfo DER, carried in every signature.
    let signingPublicKey: String
}

/// One XChat `MessageEvent`: a message, reaction, read marker, key change and so on, in `detail`'s union.
public struct XChatEvent: Sendable {
    let sequenceId: String
    let messageId: String?
    let senderId: String
    let conversationId: String
    let conversationToken: String?
    let createdAt: Date?
    let detail: ThriftStruct

    init(_ event: ThriftStruct) throws {
        guard let sequenceId = event.string(1), let senderId = event.string(3), let conversationId = event.string(4) else {
            throw SourceError.invalidResponse
        }
        self.sequenceId = sequenceId
        messageId = event.string(2)
        self.senderId = senderId
        self.conversationId = conversationId
        conversationToken = event.string(5)
        createdAt = event.string(6).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        detail = event.structure(7) ?? ThriftStruct()
    }

    init(base64: String) throws {
        guard let data = Data(base64Encoded: base64) else { throw SourceError.invalidResponse }
        try self.init(ThriftCoder.decode(data))
    }

    /// Sequence ids are 64-bit and increase through a conversation.
    var sequence: Int64 {
        Int64(sequenceId) ?? 0
    }

    var messageCreate: ThriftStruct? {
        detail.structure(1)
    }

    var keyChange: ThriftStruct? {
        detail.structure(3)
    }

    var deletedSequenceIds: [String] {
        detail.structure(7)?.list(1).compactMap { if case let .binary(data) = $0 { String(data: data, encoding: .utf8) } else { nil } } ?? []
    }

    var readUntil: Int64? {
        detail.structure(12)?.string(1).flatMap { Int64($0) }
    }
}

/// What a message event decrypts to (`MessageEntryContents`).
public enum XChatEntry: Equatable, Sendable {
    case message(XChatMessageContents)
    case reaction(targetSequenceId: String, emoji: String, added: Bool)
    case edit(targetSequenceId: String, text: String)
    /// Other entries, such as accepting a message request, which the chat doesn't show.
    case other

    init(plaintext: Data) throws {
        let contents = try ThriftCoder.decode(plaintext).structure(1) ?? ThriftStruct()
        if let message = contents.structure(1) {
            self = .message(XChatMessageContents(message))
        } else if let reaction = contents.structure(2) ?? contents.structure(3), let target = reaction.string(1), let emoji = reaction.string(2) {
            self = .reaction(targetSequenceId: target, emoji: emoji, added: contents.structure(2) != nil)
        } else if let edit = contents.structure(4), let target = edit.string(1), let text = edit.string(2) {
            self = .edit(targetSequenceId: target, text: text)
        } else {
            self = .other
        }
    }
}

public struct XChatMessageContents: Equatable, Sendable {
    public struct Reply: Equatable, Sendable {
        let sequenceId: String?
        let senderName: String?
        let text: String?
    }

    public enum Attachment: Equatable, Sendable {
        /// Migrated legacy DM media still has an X CDN URL; new media is encrypted.
        case media(filename: String?, legacyURL: URL?, aspectRatio: Double?)
        case post(url: URL?)
        case link(url: URL?, title: String?)
    }

    let text: String?
    let reply: Reply?
    let attachments: [Attachment]

    init(text: String?, reply: Reply? = nil, attachments: [Attachment] = []) {
        self.text = text
        self.reply = reply
        self.attachments = attachments
    }

    init(_ message: ThriftStruct) {
        text = message.string(1)
        reply = message.structure(4).map { Reply(sequenceId: $0.string(6), senderName: $0.string(5), text: $0.string(2)) }
        attachments = message.structures(3).compactMap { attachment in
            if let media = attachment.structure(1) {
                let size = media.structure(2)
                let aspectRatio = size.flatMap { size in size.int(1).flatMap { width in size.int(2).map { Double(width) / Double(max($0, 1)) } } }
                return .media(filename: media.string(6), legacyURL: media.string(8).flatMap(URL.init), aspectRatio: aspectRatio)
            }
            if let post = attachment.structure(2) {
                return .post(url: post.string(2).flatMap(URL.init))
            }
            if let link = attachment.structure(3) ?? attachment.structure(4) {
                return .link(url: link.string(1).flatMap(URL.init), title: link.string(4))
            }
            return nil
        }
    }

    /// One line for previews.
    var preview: String {
        if let text, !text.isEmpty { return text }
        switch attachments.first {
        case .media: return "Photo"
        case .post: return "Shared a post"
        case let .link(url, title): return title ?? url?.absoluteString ?? "Link"
        case nil: return "Message"
        }
    }
}

public struct XChatPerson: Hashable, Codable, Sendable {
    let id: String
    let name: String
    let screenName: String?
    let avatarURL: URL?
}

/// A conversation as the inbox lists it, kept by the client so a chat opens with its people and keys.
public struct XChatConversationInfo: Sendable {
    let id: String
    let isGroup: Bool
    let isMuted: Bool
    let isArchived: Bool
    /// Everyone but the viewer.
    let others: [XChatPerson]
    /// A group's name, sealed under one of its conversation keys; `name` once decrypted.
    let sealedName: Data?
    var name: String?
    /// Grown by events the socket delivers, so the Chats row stays current between inbox loads.
    var latestEvents: [XChatEvent]
    var keyChanges: [XChatEvent]
    var readEvents: [XChatEvent]
}

/// One page of a conversation's events, newest last.
public struct XChatEventPage: Sendable {
    let events: [XChatEvent]
    let hasMore: Bool
}

/// XChat, X's end-to-end encrypted chat, which replaced DMs. Everything goes through X's persisted GraphQL
/// operations with the same cookies as the X client; event payloads are Thrift, and message contents are
/// encrypted with per-conversation keys that only the account's private keys open. See
/// `scripts/xchat-client.py`, which validated each request live, and `docs/IMPLEMENTATION.md`.
public actor XChatClient: ChatListProvider {
    public nonisolated let network: SocialNetwork = .x

    private enum Operation: String {
        case initialPage = "GetInitialXChatPageQuery"
        case inboxPage = "GetInboxPageRequestQuery"
        case conversationPage = "GetConversationPageQuery"
        case publicKeys = "GetPublicKeysQuery"
        case sendCreate = "SendMessageCreateMutation"
        case sendEvent = "SendMessageEventMutation"
        case socketToken = "GenerateXChatTokenMutation"

        var queryId: String {
            switch self {
            case .initialPage: "Q4Mw0C6YcnjJac21wq-5NA"
            case .inboxPage: "txrXftx8RcSvw9jCjwRZWA"
            case .conversationPage: "GX9ZijkxG8AqRMQVD7hMnQ"
            case .publicKeys: "C-YphxeIcPLOGtFNGhkuOw"
            case .sendCreate: "TWRPP7gnKwV_R8-tE-Dd3Q"
            case .sendEvent: "G7WwJGKvTBVb-BXhZNSVMw"
            case .socketToken: "Qh3fZRjPPtPoHYR_2sCZsA"
            }
        }
    }

    /// Every received event is signed with version 7; versions from 9 add a "signature_version=" suffix.
    private static let signatureVersion = "7"
    /// `MessageSentFrom.ConversationScreenComposer`, as X's own composer sends.
    private static let sentFromComposer: Int32 = 1
    /// GetConversationPageQuery returns events older than `min_local_sequence_id`.
    private static let newestSequenceId = String(Int64.max)

    /// Scoped to the X account, for its cookies and X Chat keys.
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    private var conversations: [String: XChatConversationInfo] = [:]
    /// Conversation id → key version → 32-byte conversation key.
    private var conversationKeys: [String: [String: Data]] = [:]

    public init(credentialStore: KeychainCredentialStore, session: URLSession = XClient.defaultSession) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public func forgetKeys() throws {
        try credentialStore.deleteXChatKeys()
        conversations = [:]
        conversationKeys = [:]
    }

    // MARK: Keys

    public enum RecoveryError: LocalizedError {
        case noXChatKeys
        case wrongPIN(guessesRemaining: Int)
        case keysDoNotMatch
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noXChatKeys:
                "This X account hasn't set up encrypted chat. Set it up in X first."
            case let .wrongPIN(remaining):
                "Wrong PIN. \(remaining) \(remaining == 1 ? "guess" : "guesses") left before your encrypted chats are locked."
            case .keysDoNotMatch:
                "The recovered keys don't match this account's encrypted chat keys."
            case let .failed(reason):
                "Couldn't recover your encrypted chat keys: \(reason)"
            }
        }
    }

    /// Recovers the private keys from Juicebox with the XChat PIN and keeps them in the Keychain. A wrong PIN
    /// uses up one of the account's guesses.
    public func recoverKeys(pin: String) async throws {
        let credentials = try xCredentials()
        let userId = try await viewerId(credentials: credentials)
        let response = try await query(.publicKeys, variables: ["ids": [userId], "include_juicebox_tokens": true], credentials: credentials)
        let versions = (((response["user_results_by_rest_ids"] as? [[String: Any]])?.first?["result"] as? [String: Any])?["get_public_keys"] as? [String: Any])?["public_keys_with_token_map"] as? [[String: Any]] ?? []
        guard let newest = versions.max(by: { Self.version(of: $0) < Self.version(of: $1) }),
              let metadata = newest["public_key_with_metadata"] as? [String: Any],
              let version = metadata["version"] as? String,
              let publicKey = metadata["public_key"] as? [String: Any],
              let identityPublicKey = (publicKey["public_key"] as? String).flatMap({ Data(lenientBase64: $0) }),
              let signingPublicKey = publicKey["signing_public_key"] as? String,
              let tokenMap = newest["token_map"] as? [String: Any],
              let configuration = tokenMap["key_store_token_map_json"] as? String,
              let tokens = tokenMap["token_map"] as? [[String: Any]]
        else { throw RecoveryError.noXChatKeys }

        var authTokens: [RealmId: AuthToken] = [:]
        for entry in tokens {
            guard let realm = (entry["key"] as? String).flatMap({ RealmId(string: $0) }),
                  let token = (entry["value"] as? [String: Any])?["token"] as? String
            else { throw RecoveryError.noXChatKeys }
            authTokens[realm] = AuthToken(jwt: token)
        }
        let client = Client(configuration: Configuration(json: configuration), authTokens: authTokens)
        let secret: Data
        do {
            secret = try await client.recover(pin: Data(pin.utf8), info: Data())
        } catch let RecoverError.invalidPin(guessesRemaining) {
            throw RecoveryError.wrongPIN(guessesRemaining: Int(guessesRemaining))
        } catch let error as RecoverError {
            throw RecoveryError.failed(String(describing: error))
        }
        // The secret is the identity key then the signing key; both must match what X registered.
        guard secret.count == 64 else { throw RecoveryError.keysDoNotMatch }
        let identity = secret.prefix(32), signing = secret.suffix(32)
        guard try XChatCrypto.identityPublicKeyDER(identityPrivateKey: identity) == identityPublicKey,
              try XChatCrypto.signingPublicKeyDER(signingPrivateKey: signing) == Data(lenientBase64: signingPublicKey)
        else { throw RecoveryError.keysDoNotMatch }
        try credentialStore.saveXChatKeys(XChatKeys(
            userId: userId,
            version: version,
            identityPrivateKey: Data(identity),
            signingPrivateKey: Data(signing),
            signingPublicKey: signingPublicKey,
        ))
    }

    private static func version(of entry: [String: Any]) -> Int64 {
        ((entry["public_key_with_metadata"] as? [String: Any])?["version"] as? String).flatMap(Int64.init) ?? 0
    }

    private func viewerId(credentials: XCredentials) async throws -> String {
        var request = URLRequest(url: URL(string: "https://x.com/i/api/1.1/account/multi/list.json")!)
        request.allHTTPHeaderFields = XClient.apiHeaders(credentials: credentials)
        let users = try await json(for: request)["users"] as? [[String: Any]]
        guard let id = users?.first.flatMap({ $0["user_id"] as? String ?? $0["id_str"] as? String }) else { throw SourceError.invalidResponse }
        return id
    }

    // MARK: Inbox

    /// The archived rows come from the inbox the main rows just loaded.
    public func chatList() async throws -> ChatListPage {
        let chats = try await chatSummaries(archived: false)
        let archived = try? await chatSummaries(archived: true)
        return ChatListPage(chats: chats, archived: archived)
    }

    /// Every conversation in the inbox (not message requests), newest first, as Chats rows.
    func chatSummaries(archived: Bool) async throws -> [ChatSummary] {
        let keys = try xChatKeys()
        if !archived {
            try await loadInbox(keys: keys)
        }
        return conversations.values.filter { $0.isArchived == archived }.map { chatSummary($0, keys: keys) }
    }

    private func loadInbox(keys: XChatKeys) async throws {
        let credentials = try xCredentials()
        var page = try await query(.initialPage, variables: ["message_pull_version": 1], credentials: credentials)["get_initial_chat_page"] as? [String: Any]
        var items: [[String: Any]] = []
        while let current = page {
            items += current["items"] as? [[String: Any]] ?? []
            guard let cursor = current["inboxCursor"] as? [String: Any], cursor["__typename"] as? String == "XChatGetInboxPageContinueCursor",
                  let cursorId = cursor["cursor_id"] as? String, let snapshot = cursor["graph_snapshot_id"] as? String
            else { break }
            page = try await query(.inboxPage, variables: ["continue_cursor": ["cursor_id": cursorId, "graph_snapshot_id": snapshot]], credentials: credentials)["get_inbox_page"] as? [String: Any]
        }
        var loaded: [String: XChatConversationInfo] = [:]
        for item in items {
            guard var info = Self.conversationInfo(item, viewerId: keys.userId) else { continue }
            addKeys(from: info.keyChanges, keys: keys)
            info.name = info.sealedName.flatMap { openName($0, conversationId: info.id) }
            loaded[info.id] = info
        }
        conversations = loaded
    }

    private static func conversationInfo(_ item: [String: Any], viewerId: String) -> XChatConversationInfo? {
        guard let detail = item["conversation_detail"] as? [String: Any], let id = detail["conversation_id"] as? String else { return nil }
        let isGroup = detail["__typename"] as? String == "XChatGroupConversationDetail"
        // Groups' `group_members_results` are ids only; `participants_results` has every other member's profile.
        let members = (detail["participants_results"] as? [[String: Any]] ?? [])
            .compactMap { person($0["result"] as? [String: Any]) }
            .filter { $0.id != viewerId }
        func events(_ key: String) -> [XChatEvent] {
            (item[key] as? [String] ?? []).compactMap { try? XChatEvent(base64: $0) }
        }
        let readEvents = (item["latest_read_events_per_participant"] as? [[String: Any]] ?? [])
            .compactMap { ($0["latest_mark_conversation_read_event"] as? String).flatMap { try? XChatEvent(base64: $0) } }
        return XChatConversationInfo(
            id: id,
            isGroup: isGroup,
            isMuted: detail["is_muted"] as? Bool ?? false,
            isArchived: detail["is_archived"] as? Bool ?? false,
            others: members,
            sealedName: ((detail["group_metadata"] as? [String: Any])?["group_name"] as? String).flatMap { Data(base64Encoded: $0) },
            latestEvents: events("latest_message_events"),
            keyChanges: events("latest_conversation_key_change_events"),
            readEvents: readEvents,
        )
    }

    private static func person(_ user: [String: Any]?) -> XChatPerson? {
        guard let user, let id = user["rest_id"] as? String else { return nil }
        let core = user["core"] as? [String: Any]
        let screenName = core?["screen_name"] as? String
        return XChatPerson(
            id: id,
            name: (core?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? screenName ?? "X user",
            screenName: screenName,
            avatarURL: ((user["avatar"] as? [String: Any])?["image_url"] as? String).flatMap(URL.init),
        )
    }

    private func chatSummary(_ conversation: XChatConversationInfo, keys: XChatKeys) -> ChatSummary {
        let readUntil = Self.readUntil(conversation.readEvents, userId: keys.userId)
        var latest: (event: XChatEvent, contents: XChatMessageContents)?
        var unread = 0
        for event in conversation.latestEvents.sorted(by: { $0.sequence > $1.sequence }) {
            guard event.messageCreate != nil else { continue }
            // An event that doesn't decrypt is counted and shown, so missing keys don't hide messages.
            let entry = try? decrypt(event)
            let contents: XChatMessageContents? = if case let .message(contents) = entry { contents } else if entry == nil { XChatMessageContents(text: "Encrypted message") } else { nil }
            guard let contents else { continue }
            if latest == nil {
                latest = (event, contents)
            }
            if event.senderId != keys.userId, event.sequence > readUntil {
                unread += 1
            }
        }
        var preview: String?
        if let latest {
            let body = latest.contents.preview.replacingOccurrences(of: "\n", with: " ")
            if latest.event.senderId == keys.userId {
                preview = "You: \(body)"
            } else if conversation.isGroup, let sender = conversation.others.first(where: { $0.id == latest.event.senderId }) {
                preview = "\(sender.name): \(body)"
            } else {
                preview = body
            }
        }
        let partner = conversation.isGroup ? nil : conversation.others.first
        return ChatSummary(
            id: "x:chat:\(conversation.id)",
            network: .x,
            title: partner?.name ?? conversation.name ?? Self.groupTitle(conversation.others),
            avatarURL: partner?.avatarURL ?? conversation.others.first?.avatarURL,
            preview: preview,
            timestamp: latest?.event.createdAt ?? conversation.latestEvents.compactMap(\.createdAt).max(),
            unreadCount: unread,
            destination: .x(conversationId: conversation.id),
            namesSenderInPreview: conversation.isGroup,
            titleNamesPeople: conversation.name == nil,
            isMuted: conversation.isMuted,
        )
    }

    static func groupTitle(_ members: [XChatPerson]) -> String {
        let names = members.prefix(3).map(\.name)
        let rest = members.count - names.count
        return names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    static func readUntil(_ readEvents: [XChatEvent], userId: String) -> Int64 {
        readEvents.filter { $0.senderId == userId }.compactMap(\.readUntil).max() ?? 0
    }

    // MARK: Conversations

    func conversation(_ conversationId: String) async throws -> XChatConversationInfo {
        if let info = conversations[conversationId] {
            return info
        }
        try await loadInbox(keys: xChatKeys())
        guard let info = conversations[conversationId] else { throw SourceError.serviceError("This X chat is no longer in your inbox.") }
        return info
    }

    /// Events older than `beforeSequenceId`, or the newest page; its key changes are kept for decrypting.
    func eventPage(conversationId: String, beforeSequenceId: String? = nil) async throws -> XChatEventPage {
        let keys = try xChatKeys()
        let page = try await query(
            .conversationPage,
            variables: [
                "conversation_id": conversationId,
                "min_local_sequence_id": beforeSequenceId ?? Self.newestSequenceId,
                "min_conversation_key_version": "0",
            ],
            credentials: xCredentials(),
        )["get_conversation_page"] as? [String: Any]
        guard let page else { throw SourceError.invalidResponse }
        let events = (page["encoded_message_events"] as? [String] ?? []).compactMap { try? XChatEvent(base64: $0) }
        let missingKeys = (page["missing_conversation_key_change_events"] as? [String] ?? []).compactMap { try? XChatEvent(base64: $0) }
        addKeys(from: missingKeys + events.filter { $0.keyChange != nil }, keys: keys)
        return XChatEventPage(events: events.sorted { $0.sequence < $1.sequence }, hasMore: page["has_more"] as? Bool ?? false)
    }

    func decrypt(_ event: XChatEvent) throws -> XChatEntry? {
        guard let create = event.messageCreate else { return nil }
        guard let contents = create.data(100) else { throw SourceError.invalidResponse }
        // Without a key version (101) the message was sent unencrypted (109 is then true), such as to someone
        // without X Chat keys: the contents are the plain `MessageEntryHolder`.
        guard let version = create.string(101) else {
            return try XChatEntry(plaintext: contents)
        }
        guard let key = conversationKeys[event.conversationId]?[version] else {
            throw SourceError.serviceError("Missing the key for an encrypted X message.")
        }
        // Version 1 derives a key per message; no account seen so far sends it, so it fails loudly instead.
        guard (create.int(112) ?? 0) == 0 else { throw SourceError.unsupported }
        return try XChatEntry(plaintext: XChatCrypto.open(contents, key: key))
    }

    /// The name doesn't say which key sealed it, so each of the conversation's keys is tried, newest first.
    private func openName(_ sealed: Data, conversationId: String) -> String? {
        let keys = (conversationKeys[conversationId] ?? [:]).sorted { (Int64($0.key) ?? 0) > (Int64($1.key) ?? 0) }
        for (_, key) in keys {
            if let plaintext = try? XChatCrypto.open(sealed, key: key) {
                return String(data: plaintext, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return nil
    }

    private func addKeys(from keyChanges: [XChatEvent], keys: XChatKeys) {
        for event in keyChanges {
            guard let change = event.keyChange, let version = change.string(1) else { continue }
            for participant in change.structures(2) where participant.string(1) == keys.userId {
                guard let wrapped = participant.data(2).flatMap({ Data(base64Encoded: $0) }),
                      let key = try? XChatCrypto.unwrapConversationKey(wrapped, identityPrivateKey: keys.identityPrivateKey)
                else { continue }
                conversationKeys[event.conversationId, default: [:]][version] = key
            }
        }
    }

    /// Applies events the socket delivered to the cached conversations, and returns the Chats rows they
    /// changed. `nil` when an event is for a conversation the inbox hasn't loaded, such as a new chat.
    func ingest(_ events: [XChatEvent]) -> [ChatSummary]? {
        guard let keys = try? xChatKeys() else { return [] }
        var changed: Set<String> = []
        for event in events {
            guard var conversation = conversations[event.conversationId] else { return nil }
            if event.keyChange != nil {
                conversation.keyChanges.append(event)
                addKeys(from: [event], keys: keys)
            } else if event.readUntil != nil {
                conversation.readEvents.append(event)
            } else if event.messageCreate != nil, !conversation.latestEvents.contains(where: { $0.sequenceId == event.sequenceId }) {
                conversation.latestEvents.append(event)
            }
            conversations[event.conversationId] = conversation
            changed.insert(event.conversationId)
        }
        return changed.compactMap { conversations[$0] }.filter { !$0.isArchived }.map { chatSummary($0, keys: keys) }
    }

    /// A short-lived token for X's chat WebSocket.
    func socketToken() async throws -> String {
        let result = try await mutation(.socketToken, variables: [:])["user_get_x_chat_auth_token"] as? [String: Any]
        guard let token = result?["token"] as? String else {
            throw SourceError.serviceError("X didn't issue a chat connection token (\(result?["error_code"] as? String ?? "no error code")).")
        }
        return token
    }

    var viewerId: String? {
        try? credentialStore.loadXChatKeys()?.userId
    }

    // MARK: Sending

    /// Sends a text message and returns its sequence id.
    func sendText(_ text: String, conversationId: String, token: String?) async throws -> XChatEvent {
        var message = ThriftStruct()
        message[1] = .string(text)
        message[2] = .structs([])
        message[3] = .structs([])
        message[7] = .i32(Self.sentFromComposer)
        return try await send(entry: [1: .structure(message)], conversationId: conversationId, token: token)
    }

    func sendReaction(_ emoji: String, on sequenceId: String, remove: Bool, conversationId: String, token: String?) async throws -> XChatEvent {
        var reaction = ThriftStruct()
        reaction[1] = .string(sequenceId)
        reaction[2] = .string(emoji)
        return try await send(entry: [remove ? 3 : 2: .structure(reaction)], conversationId: conversationId, token: token)
    }

    /// Encrypts, franks, signs and sends one `MessageEntryContents`, returning the event X stored.
    private func send(entry: [Int16: ThriftValue], conversationId: String, token: String?) async throws -> XChatEvent {
        let keys = try xChatKeys()
        guard let (version, key) = conversationKeys[conversationId]?.max(by: { (Int64($0.key) ?? 0) < (Int64($1.key) ?? 0) }) else {
            throw SourceError.serviceError("Missing the key for this X chat.")
        }
        let messageId = UUID().uuidString.lowercased()
        var holder = ThriftStruct()
        holder[1] = .structure(ThriftStruct(entry))
        let plaintext = ThriftCoder.encode(holder)
        let contents = try XChatCrypto.seal(plaintext, key: key)
        let frankingNonce = try XChatCrypto.randomBytes(32)
        var franking = ThriftStruct()
        franking[1] = .binary(XChatCrypto.frankingTag(plaintext: plaintext, nonce: frankingNonce, messageId: messageId, conversationId: conversationId))
        franking[2] = try .binary(XChatCrypto.seal(frankingNonce, key: key))
        var create = ThriftStruct()
        create[100] = .binary(contents)
        create[101] = .string(version)
        create[102] = .bool(true)
        create[105] = .bool(false)
        create[106] = .i32(1)
        create[108] = .structure(franking)
        create[109] = .bool(false)
        let payload = ["MessageCreateEvent", messageId, keys.userId, conversationId, version, contents.unpaddedBase64].joined(separator: ",")
        var variables: [String: Any] = try [
            "conversation_id": conversationId,
            "message_id": messageId,
            "encoded_message_create_event": ThriftCoder.encode(create).base64EncodedString(),
            "encoded_message_event_signature": ThriftCoder.encode(signature(payload, keys: keys)).base64EncodedString(),
        ]
        variables["conversation_token"] = token
        let result = try await mutation(.sendCreate, variables: variables)["xchat_send_create_message_event"] as? [String: Any]
        guard let encoded = result?["encoded_message_event"] as? String else { throw SourceError.invalidResponse }
        return try XChatEvent(base64: encoded)
    }

    /// Moves the viewer's read marker, which X keeps per person, to `sequenceId`.
    func markRead(upTo sequenceId: String, conversationId: String) async throws {
        let keys = try xChatKeys()
        let messageId = UUID().uuidString.lowercased()
        let seenAt = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = ["MarkConversationReadEvent", messageId, keys.userId, conversationId, sequenceId, String(seenAt)].joined(separator: ",")
        var marker = ThriftStruct()
        marker[1] = .string(sequenceId)
        marker[2] = .i64(seenAt)
        var detail = ThriftStruct()
        detail[12] = .structure(marker)
        var event = ThriftStruct()
        event[2] = .string(messageId)
        event[3] = .string(keys.userId)
        event[4] = .string(conversationId)
        event[6] = .string(String(seenAt))
        event[7] = .structure(detail)
        event[9] = try .structure(signature(payload, keys: keys))
        let result = try await mutation(.sendEvent, variables: ["encoded_message_event": ThriftCoder.encode(event).base64EncodedString()])["xchat_send_message_event"] as? [String: Any]
        if let code = result?["error_code"] as? String {
            throw SourceError.serviceError("X didn't mark the chat read (\(code)).")
        }
    }

    private func signature(_ payload: String, keys: XChatKeys) throws -> ThriftStruct {
        var info = ThriftStruct()
        info[1] = .string(keys.userId)
        info[2] = .string(keys.version)
        info[3] = .string(keys.signingPublicKey)
        var signature = ThriftStruct()
        signature[1] = try .string(XChatCrypto.sign(payload, signingPrivateKey: keys.signingPrivateKey).unpaddedBase64)
        signature[2] = .string(keys.version)
        signature[3] = .string(Self.signatureVersion)
        signature[4] = .string(keys.signingPublicKey)
        signature[5] = .structs([info])
        return signature
    }

    // MARK: Transport

    private func xCredentials() throws -> XCredentials {
        guard let credentials = try credentialStore.loadXCredentials() else { throw SourceError.notConfigured }
        return credentials
    }

    private func xChatKeys() throws -> XChatKeys {
        guard let keys = try credentialStore.loadXChatKeys() else { throw SourceError.notConfigured }
        return keys
    }

    private func query(_ operation: Operation, variables: [String: Any], credentials: XCredentials) async throws -> [String: Any] {
        let variablesJSON = try String(decoding: JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
        var components = URLComponents(string: "https://x.com/i/api/graphql/\(operation.queryId)/\(operation.rawValue)")!
        components.queryItems = [URLQueryItem(name: "variables", value: variablesJSON)]
        // `+` in a query string reads as a space; base64 cursors and keys need it escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.allHTTPHeaderFields = XClient.apiHeaders(credentials: credentials)
        return try await graphQLData(for: request)
    }

    private func mutation(_ operation: Operation, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://x.com/i/api/graphql/\(operation.queryId)/\(operation.rawValue)")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try XClient.apiHeaders(credentials: xCredentials())
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["queryId": operation.queryId, "variables": variables])
        return try await graphQLData(for: request)
    }

    private func graphQLData(for request: URLRequest) async throws -> [String: Any] {
        let body = try await json(for: request)
        if let message = (body["errors"] as? [[String: Any]])?.first?["message"] as? String {
            throw SourceError.serviceError("X: \(message)")
        }
        guard let data = body["data"] as? [String: Any] else { throw SourceError.invalidResponse }
        return data
    }

    private func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }
        guard (200 ..< 300).contains(http.statusCode), let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.serviceError("X returned HTTP \(http.statusCode).")
        }
        return body
    }
}
