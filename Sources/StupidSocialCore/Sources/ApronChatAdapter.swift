import Foundation

/// One Apron room: loads recent history, applies live snapshots, posts messages and commands, and keeps the
/// room's members, typing indications and read cursor.
@MainActor
public final class ApronChatAdapter: ChatAdapter, ChatReadOnlyAccess, ChatEditing, ChatDeleting, ChatReactionSending, ChatUnseenReactions, ChatLiveUpdating, ChatReferenceResolving, ChatWindowing, ChatTyping, ChatMentioning, ChatCustomEmojis, ChatCommanding, ChatLinking, ChatReadReceipts {
    public let network = ChatNetwork.apron
    public let canReply = true
    public let pollInterval: Duration? = nil
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onCatchUp: (() -> Void)?
    public var onError: ((Error) -> Void)?
    public private(set) var info: ChatInfo
    public var history: ChatHistory?
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public private(set) var unavailableReferences: Set<String> = []
    /// Names of the other users typing, in the order they started.
    public private(set) var typingNames: [String] = []
    /// User id → name, for showing `@` mentions by name.
    public private(set) var mentionNames: [String: String] = [:]
    public var mentionPattern: NSRegularExpression? {
        ApronMention.pattern
    }

    /// The server's custom emoji (`ext:emoji`), once its catalog loads.
    public private(set) var customEmojis: [String: ChatCustomEmoji] = [:]

    /// The members, profile and notification screens' model, kept current from this room's connection.
    public let room: ApronRoomViewModel
    public let serverURL: URL
    /// Empty in a new direct chat (`directUser`) until its first message starts the room.
    public private(set) var roomId: String

    private let service: ApronService
    private var session: ApronSession?
    private var you: ApronUser?
    /// The server's `ext.media` origins, kept from the last connection so cached image embeds render as images
    /// before the connection is up.
    private var mediaOrigins: [URL] = []
    /// The catalog `customEmojis` came from or is loading from.
    private var emojiCatalogURL: URL?
    /// The messages last rendered: the stretch the chat shows, which actions work on.
    private var snapshots: [String: ApronMessage] = [:]
    /// Reaction totals of the rendered messages.
    private var reactions: [String: [ChatReaction]] = [:]
    /// Kept current user objects (§3.3.1); messages carry recorded `from` objects that often omit avatars.
    /// Mentions show these names; a name another known user shares is left out, so those mentions keep their
    /// `@user_id` (§3.3.1).
    private var users: [String: ApronUser] = [:] {
        didSet { updateMentionNames() }
    }

    /// messageId → userId → that user's newest set; the record with the greatest `log_id` wins (§4.7).
    private var reactionEntries: [String: [String: (logId: Int64, emojis: [String])]] = [:]
    private var reactionAuthors: [String: ApronUser] = [:]
    private var memberIds: Set<String>?
    /// The server's joined rooms, by id, which `#room_id`s and links in messages read by name.
    private var knownRooms: [String: ApronRoom] = [:]
    /// Messages that links in this chat point at, fetched once each: their card, or `nil` when the message can't be
    /// read here (another server without an account, a room you can't see, deleted).
    private var linkedMessages: [ApronLink: ChatEmbed?] = [:]
    private var pendingLinkedMessages: Set<ApronLink> = []
    private var isPrivateRoom = false
    /// This room's record as last listed or updated (§4.2), for its description and whether it can be edited.
    private var roomRecord: ApronRoom?
    private var notices: [ApronMessage] = []
    private var pendingReferences: Set<String> = []
    private let windowSize = 30
    /// Whether the server's cursor is the source of truth here (see `ApronService.serverTracksCursors`).
    private var tracksCursors = false
    /// The furthest anyone else has read here, from their read cursors (§4.6). `nil` until another member's
    /// cursor for this room arrives: servers choose the rooms where members see each other's (the Go server every
    /// room; `ext.settings.read_receipts: "private"` only small private rooms; older servers none), and in the
    /// others one check on every message would read as nobody having read them.
    private var othersRead: Int64?
    /// The cursor last sent to the server, so `activity` goes out only when it moves.
    private var sentReadMessageId: Int64 = 0
    private var ownUserIds: Set<String>
    private var observerToken: UUID?
    private let pageSize = 50
    /// userId → (name, when the typing indication expires), from other users' `activity.typing`.
    private var typingUsers: [(userId: String, name: String, expires: Date)] = []
    private var typingExpiryTask: Task<Void, Never>?
    /// When `typing` was last sent, so it is refreshed before it expires rather than on every keystroke.
    private var typingSentAt: Date?
    /// As in apron-web: announce 15 seconds, refresh every 12 while typing continues, and stop after a 5-second pause.
    private let typingSeconds = 15
    private let typingRefreshInterval: TimeInterval = 12
    private let typingPause: Duration = .seconds(5)
    /// Send times of recent `typing` frames per server, shared by its rooms like the connection. Servers rate-limit
    /// them (the demo allows 10 a minute), so the client keeps under a budget and drops frames beyond it; a
    /// dropped stop just lets the indication lapse.
    private static var typingFrameTimes: [URL: [Date]] = [:]
    private let typingFrameBudget = 7
    private var typingStopTask: Task<Void, Never>?
    /// Recomputes a DM's "last seen …" subtitle, which ages while the chat is open.
    private var subtitleTask: Task<Void, Never>?
    /// Reactions seen on the user's other devices, while the chat is open.
    private var seenReactionsObserver: NSObjectProtocol?
    /// The other person in a new direct chat, whose room is started only when the first message is sent, so
    /// opening a profile's Message and leaving doesn't leave an empty room behind.
    private var directUser: ApronUser?
    private var roomCreation: Task<Void, Error>?
    /// Its snapshots would be keyed by the person, not the room it became, so it keeps none.
    private let isNewDirectChat: Bool

    public convenience init(service: ApronService, serverURL: URL, roomId: String, title: String?) {
        self.init(service: service, serverURL: serverURL, roomId: roomId, directUser: nil, title: title ?? roomId)
    }

    /// A direct chat with the user that has no room yet; the first message starts it.
    public convenience init(service: ApronService, serverURL: URL, directWith user: ApronUser) {
        self.init(service: service, serverURL: serverURL, roomId: "", directUser: user, title: user.displayName)
    }

    private init(service: ApronService, serverURL: URL, roomId: String, directUser: ApronUser?, title: String) {
        ownUserIds = service.readStore.ownUserIds(serverURL: serverURL)
        self.service = service
        self.serverURL = serverURL
        self.roomId = roomId
        self.directUser = directUser
        isNewDirectChat = directUser != nil
        info = ChatInfo(title: title, subtitle: service.server(for: serverURL)?.displayTitle ?? ApronServerInfo.displayTitle(nil, serverURL: serverURL))
        room = ApronRoomViewModel(serverURL: serverURL, roomId: roomId)
        room.adapter = self
    }

    /// The account is the server (`Account.apronId`), so the room names the chat; a new direct chat is named by
    /// the person, so its draft is kept for the next time.
    public var key: String {
        directUser.map { "apron:direct:\($0.userId)" } ?? "apron:\(roomId)"
    }

    /// Before connecting, uploads might be allowed; once connected, the server says (`embed:upload`).
    public var acceptsAttachments: Bool {
        !isReadOnly && session?.server.has("embed:upload") ?? true
    }

    public var acceptsReactions: Bool {
        !isReadOnly && session?.server.has("reactions") ?? false
    }

    /// A guest on a server that lets guests only read, such as the demo (`ext.permissions`).
    public var isReadOnly: Bool {
        you?.canWrite == false
    }

    /// Embed media loads only from the chat server or the origins it lists in `ext.media` (§4.8.1, §5.5).
    private func allowedMediaURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let host = url.host() else { return nil }
        let secure = url.scheme == "https"
        let localPlain = url.scheme == "http" && serverURL.scheme == "ws"
        guard secure || localPlain else { return nil }
        let origins = [serverURL.host()] + mediaOrigins.map { $0.host() }
        return origins.contains(host) ? url : nil
    }

    // MARK: State

    private struct State: Codable {
        /// Authors and reactors of the shown messages, so they show with their avatars before the connection is up.
        let users: [ApronUser]
        /// So image embeds render as images before the connection is up instead of growing from cards.
        let mediaOrigins: [URL]
        /// So custom emoji render before the connection is up; the catalog is cached for as long as its URL stays.
        let emojiCatalogURL: URL?
        /// So read receipts render before the connection is up; only in rooms where another member's cursor arrived.
        let othersRead: Int64?
    }

    public func restore(state data: Data) {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        mediaOrigins = state.mediaOrigins
        othersRead = state.othersRead
        if let url = state.emojiCatalogURL {
            loadEmojiCatalog(url)
        }
        for user in state.users where users[user.userId] == nil {
            users[user.userId] = user
        }
    }

    public func state() -> Data? {
        guard !isNewDirectChat else { return nil }
        let authors = Set(snapshots.values.map(\.from.userId)).union(reactionEntries.values.flatMap(\.keys))
        return try? JSONEncoder().encode(State(
            users: users.values.filter { authors.contains($0.userId) },
            mediaOrigins: mediaOrigins,
            emojiCatalogURL: emojiCatalogURL,
            othersRead: othersRead,
        ))
    }

    // MARK: Records

    /// A message's record is keyed by its `message_id` and replaced only by a snapshot with a greater `log_id`; at an
    /// equal `log_id` the tombstone wins (§2.3).
    nonisolated static func record(_ message: ApronMessage) throws -> ChatRecord? {
        guard let id = message.messageId else { return nil }
        return try ChatRecord(
            id: id, sortKey: Int64(id) ?? message.sortKey, version: message.sortKey * 2 + (message.isDeleted ? 1 : 0), encoding: message,
        )
    }

    /// Each user's reaction set on a message is its own record, related to the message; the newest `log_id` wins
    /// (§4.7).
    nonisolated static func records(_ reactions: ApronReactionRecord, roomId: String) throws -> [ChatRecord] {
        guard reactions.roomId == nil || reactions.roomId == roomId else { return [] }
        let logId = reactions.logId.flatMap(Int64.init) ?? 0
        return try reactions.reactions.map { set in
            try ChatRecord(
                id: "reaction:\(reactions.messageId):\(set.from.userId)", sortKey: logId, relatesTo: reactions.messageId, version: logId,
                encoding: ApronReactionRecord(logId: reactions.logId, messageId: reactions.messageId, roomId: reactions.roomId, reactions: [set]),
            )
        }
    }

    /// A history page as records: the room's messages and reactions. A snapshot in another room means the message
    /// moved out (§4.3.1), so its stored copy goes. Pages run by `log_id`, which a message's id is its creation's, and
    /// can carry older messages edited within them; deletions come as tombstones.
    private func page(_ result: ApronHistoryResult, request: ChatPageRequest) throws -> ChatPage {
        var records: [ChatRecord] = []
        var moved: [String] = []
        for message in result.messages ?? [] {
            if message.roomId == nil || message.roomId == roomId {
                if let record = try Self.record(message) {
                    records.append(record)
                }
            } else if let id = message.messageId {
                moved.append(id)
            }
        }
        for reactions in result.reactions ?? [] {
            records += try Self.records(reactions, roomId: roomId)
        }
        if !moved.isEmpty {
            try history?.delete(ids: moved)
        }
        let first = result.firstLogId.flatMap(Int64.init)
        let last = result.lastLogId.flatMap(Int64.init)
        let more = result.more ?? false
        let covers = first.flatMap { first in last.map { first ... max(first, $0) } }
        switch request {
        case .after:
            return ChatPage(records: records, earlier: first.map { ChatCursor(String($0 - 1)) }, later: more ? last.map { ChatCursor(String($0 + 1)) } : nil, covers: covers, isComplete: false)
        default:
            return ChatPage(records: records, earlier: more ? first.map { ChatCursor(String($0 - 1)) } : nil, covers: covers, isComplete: false)
        }
    }

    // MARK: Connection

    /// Signs in on the shared connection once per visit and starts applying live frames, since replay is
    /// order-independent (§2.3).
    private func ensureSession() async throws -> ApronSession {
        if let session {
            return session
        }
        let session = try await service.session(serverURL: serverURL)
        self.session = session
        do {
            try await setUp(on: session)
        } catch {
            stopObserving()
            throw error
        }
        return session
    }

    private func setUp(on session: ApronSession) async throws {
        you = session.you
        ownUserIds.insert(session.you.userId)
        mediaOrigins = session.server.ext?.mediaOrigins ?? mediaOrigins
        updateEmojiCatalog(session.connection.server ?? session.server)
        tracksCursors = service.serverTracksCursors(session)
        observerToken = session.connection.observe(
            notifications: { [weak self] method, params in self?.handle(method: method, params: params) },
            onClose: { [weak self] error in self?.connectionClosed(error) },
        )
        updateOthersRead(from: session.connection)
        if session.server.has("rooms") {
            let listing = try await session.connection.joinedRooms()
            for user in listing.users {
                users[user.userId] = user
            }
            knownRooms = Dictionary(listing.rooms.map { ($0.roomId, $0) }, uniquingKeysWith: { first, _ in first })
            if let directUser {
                showNewDirectChat(with: directUser, you: session.you)
                return
            }
            if let listed = listing.rooms.first(where: { $0.roomId == roomId }) {
                applyRecord(listed)
                setMembers(of: listed)
            } else {
                // Live deliveries only reach joined rooms (§3.4).
                try? await session.connection.joinRoom(roomId: roomId)
            }
        }
        room.isConnected = true
        updateNotifications()
        onChange?()
    }

    public func fetch(_ request: ChatPageRequest) async throws -> ChatPage {
        let session = try await ensureSession()
        guard directUser == nil else { return ChatPage(records: [], earlier: nil) }
        guard session.server.has("history") else {
            // The room's log is what the connection received before this chat observed it.
            return try page(session.connection.keptPage(roomId: roomId), request: .newest)
        }
        let connection = session.connection
        let result: ChatPage
        switch request {
        case .newest:
            // Any cursor the server keeps arrived after `room_list`, before this result (§1, §4.6).
            let newest = try await connection.history(roomId: roomId, limit: pageSize)
            // Reactions already in the room when it's first shown aren't unseen.
            if let last = newest.lastLogId.flatMap(Int64.init) {
                service.reactionStore.setBaselineIfNeeded(last, serverURL: serverURL, roomId: roomId)
            }
            if let newestMessage = newest.messages?.compactMap({ $0.messageId.flatMap(Int64.init) }).max() {
                service.readStore.setBaselineIfNeeded(newestMessage, serverURL: serverURL, roomId: roomId)
            }
            result = try page(newest, request: request)
        case let .before(cursor):
            result = try await page(connection.history(roomId: roomId, before: cursor.value, limit: pageSize), request: request)
        case let .after(cursor):
            result = try await page(connection.history(roomId: roomId, after: cursor.value, limit: pageSize), request: request)
        case let .around(messageId):
            // A window of history around the message, without loading everything in between (§4.3.2).
            guard let target = Int64(messageId) else { return ChatPage(records: [], earlier: nil) }
            let older = try await connection.history(roomId: roomId, before: messageId, limit: windowSize)
            guard older.messages?.contains(where: { $0.messageId == messageId }) == true else { return ChatPage(records: [], earlier: nil) }
            let newer = try await connection.history(roomId: roomId, after: String(target + 1), limit: windowSize)
            let olderPage = try page(older, request: .before(ChatCursor(messageId)))
            let newerPage = try page(newer, request: .after(ChatCursor(String(target + 1))))
            let low = olderPage.covers?.lowerBound ?? target
            let high = newerPage.covers?.upperBound ?? olderPage.covers?.upperBound ?? target
            result = ChatPage(
                records: olderPage.records + newerPage.records, earlier: olderPage.earlier, later: newerPage.later,
                covers: low ... max(low, high), isComplete: false,
            )
        }
        await loadMissingReferences()
        return result
    }

    /// `before` is inclusive, so the history before a message starts just under its id.
    public func cursor(before record: ChatRecord) -> ChatCursor? {
        ChatCursor(String(record.sortKey - 1))
    }

    /// A new direct chat shows just the two of you, like the room it becomes, with no history to load.
    private func showNewDirectChat(with user: ApronUser, you: ApronUser) {
        users[user.userId] = users[user.userId] ?? user
        users[you.userId] = you
        isPrivateRoom = true
        info.titleIsMemberNames = true
        info.title = currentUser(user).displayName
        memberIds = [you.userId, user.userId]
        room.isConnected = true
        updateNotifications()
        publishMembers()
        onChange?()
    }

    /// Starts the new direct chat's room, once however many sends wait on it, then shows it as that room.
    private func ensureRoom(on session: ApronSession) async throws {
        guard let user = directUser else { return }
        if roomCreation == nil {
            roomCreation = Task { [weak self] in
                let roomId = try await session.connection.directRoom(with: user.userId, you: session.you.userId)
                guard let self else { return }
                self.roomId = roomId
                directUser = nil
                room.roomId = roomId
                // Members joined while the room had no id here, so they come from the listing.
                if let listed = try? await session.connection.joinedRooms().rooms.first(where: { $0.roomId == roomId }) {
                    applyRecord(listed)
                    setMembers(of: listed)
                }
                updateNotifications()
                onChange?()
            }
        }
        do {
            try await roomCreation?.value
        } catch {
            roomCreation = nil
            throw error
        }
    }

    /// Frames arrive once the session is up, which fetching the newest page may already have done; this keeps a
    /// DM's "last seen" current.
    public func startFollowing() async {
        do {
            _ = try await ensureSession()
        } catch {
            onConnectionLost?(error)
            return
        }
        if seenReactionsObserver == nil {
            seenReactionsObserver = NotificationCenter.default.addObserver(forName: ApronReactionStore.remoteDidChangeNotification, object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?["serverURL"] as? URL, room = note.userInfo?["roomId"] as? String
                MainActor.assumeIsolated {
                    guard let self, url == self.serverURL, room == self.roomId else { return }
                    self.onChange?()
                }
            }
        }
        subtitleTask?.cancel()
        subtitleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                updateSubtitle()
                onChange?()
            }
        }
    }

    /// Leaves the room. The connection is shared with the feed, so only this chat's observer goes away.
    public func stopFollowing() {
        if let seenReactionsObserver {
            NotificationCenter.default.removeObserver(seenReactionsObserver)
        }
        seenReactionsObserver = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        stopTyping()
        stopObserving()
    }

    private func stopObserving() {
        if let observerToken {
            session?.connection.removeObserver(observerToken)
        }
        observerToken = nil
        session = nil
        room.isConnected = false
    }

    private func connectionClosed(_ error: Error?) {
        session = nil
        observerToken = nil
        room.isConnected = false
        forgetTyping()
        typingUsers = []
        publishTyping()
        onConnectionLost?(error)
    }

    private func updateNotifications() {
        guard directUser == nil, let session, service.offersPush(session), let push = session.server.push else {
            room.notifications = nil
            return
        }
        room.notifications = ApronRoomNotifications(
            isPrivate: isPrivateRoom,
            isMuted: session.connection.mutedRooms.contains(roomId),
            roomWake: session.connection.roomWakes[roomId],
            serverWake: push.wake ?? [],
            supportsRoomWake: push.roomWake == true,
            supportsMute: session.server.has("status"),
        )
    }

    func setNotificationLevel(_ level: ApronNotificationLevel) async {
        guard let session, let notifications = room.notifications else { return }
        room.notificationError = nil
        do {
            for change in notifications.changes(to: level) {
                switch change {
                case let .mute(muted): try await session.connection.setRoomMuted(roomId: roomId, muted: muted)
                case let .wake(scopes): try await session.connection.setRoomWake(roomId: roomId, scopes: scopes)
                }
            }
        } catch {
            room.notificationError = error.localizedDescription
        }
        updateNotifications()
    }

    // MARK: Display

    /// The stored stretch the chat shows: its messages, with each user's newest reaction set on them.
    public func render(_ records: [ChatRecord]) -> ChatRendering {
        var shown: [String: ApronMessage] = [:]
        var entries: [String: [String: (logId: Int64, emojis: [String])]] = [:]
        for record in records {
            if record.relatesTo == nil {
                if let message = try? record.decode(ApronMessage.self), let id = message.messageId {
                    shown[id] = message
                }
            } else if let reactions = try? record.decode(ApronReactionRecord.self) {
                let logId = reactions.logId.flatMap(Int64.init) ?? 0
                for set in reactions.reactions {
                    // Recorded `from` objects name reactors who aren't listed room members (§3.3.1).
                    reactionAuthors[set.from.userId] = set.from
                    if let existing = entries[reactions.messageId]?[set.from.userId], existing.logId > logId { continue }
                    // Duplicates collapse and order doesn't matter (§4.7).
                    var seen = Set<String>()
                    entries[reactions.messageId, default: [:]][set.from.userId] = (logId, set.emojis.filter { seen.insert($0).inserted })
                }
            }
        }
        snapshots = shown
        reactionEntries = entries
        reactions = [:]
        for messageId in entries.keys {
            updateReactionTotals(for: messageId)
        }
        let own = shown.values.filter(isOwn).compactMap(\.messageId)
        service.reactionStore.addOwnMessageIds(own, serverURL: serverURL, roomId: roomId)
        fetchMissingReferences()
        fetchLinkedMessages()
        return ChatRendering(messages: (sortedSnapshots() + notices).map(chatMessage), reactions: reactions)
    }

    private func sortedSnapshots() -> [ApronMessage] {
        snapshots.values.sorted { lhs, rhs in
            (lhs.messageId.flatMap(Int64.init) ?? lhs.sortKey) < (rhs.messageId.flatMap(Int64.init) ?? rhs.sortKey)
        }
    }

    // MARK: Linked messages

    /// Apron links in either form, as message text writes them; trailing punctuation ends the sentence.
    private static let apronLinkPattern = try! NSRegularExpression(pattern: #"(?:https://link\.apron\.chat/#|apron:\?)[^\s<>"'`]*[^\s<>"'`.,;:!?)\]]"#, options: .caseInsensitive)

    /// The links to messages in a text, read strictly as places, other than to `message` itself; at most three,
    /// as apron-web shows.
    private func messageLinks(in text: String, of message: ApronMessage? = nil) -> [ApronLink] {
        var links: [ApronLink] = []
        for match in Self.apronLinkPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard let url = URL(string: (text as NSString).substring(with: match.range)),
                  let link = ApronLink.place(url, contentServer: serverURL), let messageId = link.message,
                  !(link.serverURL == serverURL && link.room == message?.roomId && messageId == message?.messageId),
                  !links.contains(link)
            else { continue }
            links.append(link)
        }
        return Array(links.prefix(3))
    }

    /// Fetches the messages links point at, each once, on this server or on another the user has an account on;
    /// nothing signs in anywhere new to show one.
    private func fetchLinkedMessages() {
        let links = Set(snapshots.values.flatMap { messageLinks(in: $0.body?.text ?? "", of: $0) })
            .filter { linkedMessages[$0] == nil && !pendingLinkedMessages.contains($0) }
        guard !links.isEmpty else { return }
        pendingLinkedMessages.formUnion(links)
        Task {
            for link in links {
                linkedMessages[link] = await .some(linkedMessageCard(link))
                pendingLinkedMessages.remove(link)
            }
            onChange?()
        }
    }

    /// A card for the linked message, as a reply quote shows it: who sent it where, and its text; `nil` when it
    /// can't be read.
    private func linkedMessageCard(_ link: ApronLink) async -> ChatEmbed? {
        guard let roomId = link.room, let messageId = link.message else { return nil }
        let isHere = link.serverURL == serverURL
        guard isHere || service.servers.contains(where: { $0.serverURL == link.serverURL }),
              let session = isHere ? session : try? await service.session(serverURL: link.serverURL),
              session.server.has("history"),
              let page = try? await session.connection.history(roomId: roomId, after: messageId, before: messageId, limit: 1),
              let message = page.messages?.first(where: { $0.messageId == messageId }), !message.isDeleted
        else { return nil }
        let listing = isHere ? nil : try? await session.connection.joinedRooms()
        let sender = (isHere ? users[message.from.userId] : listing?.users.first { $0.userId == message.from.userId }) ?? message.from
        let room = isHere ? roomName(roomId) : listing?.rooms.first { $0.roomId == roomId }.map { $0.displayTitle(users: [:], you: session.you.userId) } ?? roomId
        let text = (message.body?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .message(title: "\(sender.displayName) in #\(room)", text: text, link: link.webURL)
    }

    /// Fetches reply targets later pages and live messages quote, without holding up the update.
    private func fetchMissingReferences() {
        Task {
            if await loadMissingReferences() {
                onChange?()
            }
        }
    }

    /// Fetches, four at a time, reply targets that aren't loaded, with `after` and `before` both at their id
    /// (§4.3.1). The first load awaits it, so quotes show with the messages instead of loading after them
    /// (the server answers each in about 0.2 s; the wait was the fetches starting only after the chat showed).
    @discardableResult
    private func loadMissingReferences() async -> Bool {
        guard let session, session.server.has("history") else { return false }
        let missing = Set(snapshots.values.compactMap { $0.replyTo?.messageId }).filter {
            snapshots[$0] == nil && referencedMessages[$0] == nil && !unavailableReferences.contains($0) && !pendingReferences.contains($0)
                && (try? history?.record(id: $0)) == nil
        }
        guard !missing.isEmpty else { return false }
        pendingReferences.formUnion(missing)
        let connection = session.connection
        let roomId = roomId
        await withTaskGroup(of: (String, ApronMessage?).self) { group in
            // A few at a time: servers close a connection with more than 8 requests unanswered.
            var queue = Array(missing)
            func fetchNext() {
                guard let messageId = queue.popLast() else { return }
                group.addTask {
                    let page = try? await connection.history(roomId: roomId, after: messageId, before: messageId, limit: 1)
                    return (messageId, page?.messages?.first { $0.messageId == messageId })
                }
            }
            for _ in 0 ..< 4 {
                fetchNext()
            }
            for await (messageId, message) in group {
                fetchNext()
                pendingReferences.remove(messageId)
                if let message {
                    referencedMessages[messageId] = chatMessage(message)
                } else {
                    unavailableReferences.insert(messageId)
                }
            }
        }
        return true
    }

    // MARK: Live frames

    private func handle(method: String, params: Data) {
        if method == "server", let server = session?.connection.server {
            // A new `catalog_url` means the catalog changed (`ext:emoji`).
            updateEmojiCatalog(server)
            return
        }
        if method == "status" {
            // The connection already applied it; this room's level may have changed, also from another device.
            updateNotifications()
            return
        }
        if method == "user" {
            // `you` carries the user's own setting, not what others see, so only `new` applies here (§4.5.2).
            if let new = try? JSONDecoder().decode(ApronUserUpdate.self, from: params).new {
                users[new.userId] = users[new.userId]?.merging(new) ?? new
                if memberIds?.contains(new.userId) == true {
                    publishMembers()
                }
                // Senders show their current avatar.
                onChange?()
            }
            return
        }
        if method == "room_update" {
            if let update = try? JSONDecoder().decode(ApronRoomUpdate.self, from: params) {
                applyRoomUpdate(update)
            }
            return
        }
        if method == "activity" {
            guard let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
                  activity.roomId == nil || activity.roomId == roomId
            else { return }
            if let typing = activity.typing, let from = activity.from, from.userId != you?.userId {
                setTyping(from, seconds: typing)
            }
            if tracksCursors, activity.from?.userId == you?.userId,
               let cursor = activity.readMessageId.flatMap(Int64.init)
            {
                // Read on another device: the server's cursor is the truth.
                service.readStore.setServerCursor(cursor, serverURL: serverURL, roomId: roomId)
                onChange?()
            }
            if let from = activity.from, !isOwnUserId(from.userId), activity.readMessageId != nil, let session {
                updateOthersRead(from: session.connection)
                onChange?()
            }
            return
        }
        if method == "reactions", let record = try? JSONDecoder().decode(ApronReactionRecord.self, from: params) {
            write { try Self.records(record, roomId: roomId) }
            return
        }
        guard method == "message", let message = try? JSONDecoder().decode(ApronMessage.self, from: params) else { return }
        // A new message from a user ends their typing indication (§4.6).
        if message.roomId == roomId, typingUsers.contains(where: { $0.userId == message.from.userId }) {
            typingUsers.removeAll { $0.userId == message.from.userId }
            publishTyping()
        }
        if message.messageId == nil {
            // Transient notices without a room (such as sign-in welcomes) are shown in the open room.
            guard message.roomId == nil || message.roomId == roomId, !notices.contains(where: { $0.id == message.id }) else { return }
            notices.append(message)
            onChange?()
        } else if message.roomId == roomId {
            write { try Self.record(message).map { [$0] } ?? [] }
        } else if let id = message.messageId {
            // Moved to another room (§4.4).
            try? history?.delete(ids: [id])
        }
        // Sending a message means the user has read up to it.
        if let id = message.messageId.flatMap(Int64.init), isOwn(message), let send = markRead(upTo: id) {
            Task { try? await send() }
        }
    }

    private func write(_ records: () throws -> [ChatRecord]) {
        do {
            try history?.write(records())
        } catch {
            onError?(error)
        }
    }

    // MARK: Custom emoji

    /// Follows the latest `server` frame: its catalog while it lists `ext:emoji`, otherwise none.
    private func updateEmojiCatalog(_ server: ApronServerInfo) {
        let url = server.has("ext:emoji") ? server.ext?.emojiCatalogURL : nil
        guard let url else {
            emojiCatalogURL = nil
            if !customEmojis.isEmpty {
                customEmojis = [:]
                onChange?()
            }
            return
        }
        loadEmojiCatalog(url)
    }

    /// Keys keep showing as text until the catalog loads, and the previous catalog stays until a new one has.
    private func loadEmojiCatalog(_ url: URL) {
        guard url != emojiCatalogURL else { return }
        emojiCatalogURL = url
        Task { [weak self, service] in
            let catalog = try? await service.emojiCatalog(url: url)
            guard let self, emojiCatalogURL == url else { return }
            guard let catalog else {
                // Tried again on the next connection or `server` frame.
                emojiCatalogURL = nil
                return
            }
            customEmojis = catalog
            onChange?()
        }
    }

    // MARK: Members

    /// Starts the member list from a listed room (§4.2.2).
    private func setMembers(of listed: ApronRoom) {
        guard let members = listed.members else { return }
        memberIds = Set(members.map(\.userId))
        room.memberCount = listed.memberCount
        publishMembers()
    }

    /// The room's title, privacy and description from its record (§4.2), as listed or edited.
    private func applyRecord(_ record: ApronRoom) {
        roomRecord = record
        isPrivateRoom = record.isPrivate
        info.titleIsMemberNames = record.isNamedForMembers
        info.title = record.displayTitle(users: users, you: you?.userId ?? "")
        updateRoomDetails()
    }

    /// Joining this room delivers it with its members; membership records then add and remove users, and an edit
    /// delivers its record in `updated` (§4.2.3).
    private func applyRoomUpdate(_ update: ApronRoomUpdate) {
        for user in update.users ?? [] {
            users[user.userId] = user
        }
        if let listed = update.joined?.first(where: { $0.roomId == roomId }) {
            applyRecord(listed)
            setMembers(of: listed)
        }
        if let edited = update.updated?.first(where: { $0.roomId == roomId }) {
            applyRecord(edited)
            onChange?()
        }
        let records = (update.memberships ?? []).filter { $0.roomId == roomId }
        guard !records.isEmpty, var ids = memberIds else { return }
        for entry in records.flatMap(\.members) {
            if users[entry.user.userId] == nil {
                users[entry.user.userId] = entry.user
            }
            if entry.joined {
                ids.insert(entry.user.userId)
            } else {
                ids.remove(entry.user.userId)
            }
        }
        memberIds = ids
        publishMembers()
    }

    private func publishMembers() {
        room.members = memberIds.map { ids in
            ids.map { users[$0] ?? ApronUser(userId: $0, name: nil, avatar: nil, roles: nil) }
                .sorted { lhs, rhs in
                    let lhsOwn = isOwnUserId(lhs.userId), rhsOwn = isOwnUserId(rhs.userId)
                    if lhsOwn != rhsOwn { return lhsOwn }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
        }
        updateSubtitle()
        onChange?()
    }

    /// A DM shows the other person's avatar beside the title, and their status in place of the server, when the
    /// server reports it: "last seen …" when it sends `seen` with an offline status (§4.5.2).
    private func updateSubtitle() {
        let others = (room.members ?? []).filter { !isOwnUserId($0.userId) }
        let other = info.titleIsMemberNames && others.count == 1 ? others[0] : nil
        info.avatarUserId = other?.userId
        info.avatarURL = other?.avatarURL
        let status = other.flatMap { user in
            user.lastSeen.map { "last seen \(ChatPresence.lastSeenTime($0))" } ?? presence(of: user)?.text
        }
        info.subtitle = status ?? service.server(for: serverURL)?.displayTitle ?? ApronServerInfo.displayTitle(nil, serverURL: serverURL)
        updateRoomDetails()
    }

    /// What the members screen's header shows. A direct room isn't offered for editing: a title would stop it
    /// being found as the direct room with the other person (`ApronRoom.isDirect`).
    private func updateRoomDetails() {
        room.title = info.title
        room.titleIsMemberNames = info.titleIsMemberNames
        room.avatarURL = info.avatarURL
        room.avatarColorKey = info.avatarUserId ?? roomId
        let description = roomRecord?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        room.roomDescription = description?.isEmpty == false ? description : nil
        room.canEdit = roomRecord.map { !($0.isNamedForMembers && (memberIds?.count ?? 0) <= 2) } ?? false
    }

    /// Replaces the room's title and description; the change shows when the server sends the edited record.
    func editRoom(title: String, description: String) async throws {
        guard let session else { throw ApronError.closed }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        try await session.connection.editRoom(roomId: roomId, title: title.isEmpty ? nil : title, description: description.isEmpty ? nil : description)
    }

    /// Whether the user is reachable now, `nil` when the server doesn't say (§4.5.1). Your own entry follows
    /// your setting, since the server never reports your status as others see it to you.
    func presence(of user: ApronUser) -> ApronPresence? {
        guard isOwnUserId(user.userId) else { return ApronPresence(status: user.status) }
        guard room.isConnected, let you else { return nil }
        switch you.status {
        case "dnd": return .doNotDisturb
        case "invisible", "": return .offline
        default: return .online
        }
    }

    /// Whether a direct room with the user can be opened from here: the server has rooms (§4.2), the user isn't
    /// you, and this room isn't already that one.
    func canOpenDirectRoom(with user: ApronUser) -> Bool {
        guard let session, session.server.has("rooms"), !isOwnUserId(user.userId) else { return false }
        return !(info.titleIsMemberNames && memberIds == [session.you.userId, user.userId])
    }

    /// The room id of the direct room with the user, `nil` when there is none yet.
    func existingDirectRoom(with user: ApronUser) async throws -> String? {
        let session = try await service.session(serverURL: serverURL)
        return try await session.connection.existingDirectRoom(with: user.userId, you: session.you.userId)
    }

    /// The kept current object, falling back to a recorded one such as a message's `from` (§3.3.1).
    func currentUser(_ user: ApronUser) -> ApronUser {
        users[user.userId] ?? reactionAuthors[user.userId] ?? user
    }

    /// The kept or recorded user behind a chat user, such as a tapped avatar.
    func apronUser(for user: ChatUser) -> ApronUser? {
        users[user.id] ?? reactionAuthors[user.id]
    }

    // MARK: Sending

    public func isCommand(_ text: String) -> Bool {
        // `/` sends a command, and `//` escapes a message that starts with `/` (§4.1).
        text.hasPrefix("/") && !text.hasPrefix("//") && session?.server.has("command") == true
    }

    public func sendCommand(_ text: String, replyToId: String?) async throws {
        guard let session else { return }
        stopTyping()
        try await ensureRoom(on: session)
        _ = try await session.connection.post(method: "command", roomId: roomId, body: ApronMessageBody(text: text), replyTo: replyToId)
    }

    /// Posts the message; an attachment is broadcast as a pending upload and then written, and the chat keeps
    /// showing the picked image meanwhile. An upload that fails after its message posted is reported, since the
    /// message itself was sent.
    public func send(_ message: ChatOutgoing) async throws -> String? {
        guard let session else { throw SourceError.serviceError("Not connected to the server.") }
        if let attachment = message.attachment, let limit = session.server.ext?.uploadLimits[attachment.mimeType], attachment.data.count > limit {
            throw SourceError.serviceError("\(attachment.filename) is larger than this server's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit.")
        }
        // Apron messages are Markdown.
        let markdown = message.markdownText()
        let bodyText = markdown.hasPrefix("//") ? String(markdown.dropFirst()) : markdown
        // The server refuses longer text, and three refusals in a minute close the connection.
        if bodyText.utf8.count > ApronConnection.maxTextBytes {
            throw SourceError.serviceError("This message is too long; Apron messages can be at most \(ApronConnection.maxTextBytes) bytes.")
        }
        // A new message ends the indication for others (§4.6).
        forgetTyping()
        try await ensureRoom(on: session)
        let mentions = mentionedUserIds(in: bodyText)
        let result = try await session.connection.post(
            method: "message",
            roomId: roomId,
            body: ApronMessageBody(
                text: bodyText,
                format: "markdown",
                mentions: mentions.isEmpty ? nil : mentions,
                embeds: message.attachment.map { [.upload(title: $0.filename)] },
            ),
            replyTo: message.replyToId,
        )
        if let attachment = message.attachment {
            do {
                guard let writeURL = result.embeds?.first?.writeUrl.flatMap(URL.init(string:)) else {
                    throw SourceError.serviceError("The server did not accept the attachment.")
                }
                try await ApronUploader.put(data: attachment.data, mimeType: attachment.mimeType, to: writeURL)
            } catch {
                onError?(error)
            }
        }
        return result.messageId
    }

    // MARK: Editing

    /// The user's messages, on servers with `edit` (§4.4).
    public func editableText(of message: ChatMessage) -> String? {
        guard session?.server.has("edit") == true, let snapshot = snapshots[message.id], snapshot.messageId != nil, !snapshot.isDeleted,
              isOwn(snapshot)
        else { return nil }
        return snapshot.body?.text ?? ""
    }

    /// A save replaces every client field, so it sends the message as it is with the new text, as apron-web does:
    /// the other body keys, its room and its reply (§4.4, probe `edit`). Mentions follow the new text. The
    /// server broadcasts the new snapshot before it answers.
    public func edit(_ messageId: String, text: String) async throws {
        guard let session else { throw SourceError.serviceError("Not connected to the server.") }
        guard let snapshot = snapshots[messageId] else { return }
        if text.utf8.count > ApronConnection.maxTextBytes {
            throw SourceError.serviceError("This message is too long; Apron messages can be at most \(ApronConnection.maxTextBytes) bytes.")
        }
        let mentions = mentionedUserIds(in: text)
        _ = try await session.connection.post(
            method: "message",
            messageId: messageId,
            roomId: snapshot.roomId ?? roomId,
            body: ApronMessageBody(
                text: text,
                format: snapshot.body?.format,
                mentions: mentions.isEmpty ? nil : mentions,
                embeds: snapshot.body?.embeds,
            ),
            replyTo: snapshot.replyTo?.messageId,
        )
    }

    // MARK: Deleting

    /// The user's messages, on servers with `edit` (§4.4).
    public func canDelete(_ message: ChatMessage) -> Bool {
        guard session?.server.has("edit") == true, let snapshot = snapshots[message.id] else { return false }
        return snapshot.messageId != nil && !snapshot.isDeleted && isOwn(snapshot)
    }

    /// A save with `deleted: true` and no body (§4.4). The server broadcasts the tombstone before it answers, and
    /// the chat shows it as deleted.
    public func delete(_ messageId: String) async throws {
        guard let session else { throw SourceError.serviceError("Not connected to the server.") }
        guard let snapshot = snapshots[messageId] else { return }
        try await session.connection.delete(messageId: messageId, roomId: snapshot.roomId ?? roomId)
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        guard let you else { return [] }
        return reactionEntries[messageId]?[you.userId]?.emojis ?? []
    }

    /// Sends your complete new set: adds the emoji, or removes it when you already reacted with it (§4.7). It
    /// shows once the server broadcasts the record.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        guard let session else { return }
        var emojis = yourEmojis(on: messageId)
        if let index = emojis.firstIndex(of: emoji) {
            emojis.remove(at: index)
        } else {
            emojis.append(emoji)
        }
        try await session.connection.setReactions(messageId: messageId, emojis: emojis)
    }

    /// Who reacted with `emoji` on a message, oldest first. The date is when the user last set their reactions
    /// there: a user's set is logged as one record (§4.7).
    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (reactionEntries[messageId] ?? [:])
            .filter { $0.value.emojis.contains(emoji) }
            .sorted { ($0.value.logId, $0.key) < ($1.value.logId, $1.key) }
            .map { userId, entry in
                let user = users[userId] ?? reactionAuthors[userId] ?? ApronUser(userId: userId, name: nil, avatar: nil, roles: nil)
                return ChatReactor(user: chatUser(user), date: entry.logId > 0 ? ApronLogId.date(String(entry.logId)) : nil, isYou: isOwnUserId(userId))
            }
    }

    // MARK: Unseen reactions

    /// Reactions from others to the user's messages, logged after the user last saw them (`ApronReactionStore`).
    public var unseenReactionMessageIds: [String] {
        let ownMessages = service.reactionStore.ownMessageIds(serverURL: serverURL, roomId: roomId)
        return service.reactionStore.unseenMessageIds(
            in: reactionEntries,
            isOwnMessage: { [snapshots] id in snapshots[id].map { self.isOwn($0) } ?? ownMessages.contains(id) },
            isOwnUser: isOwnUserId,
            serverURL: serverURL,
            roomId: roomId,
        )
    }

    /// Kept on the device, so there is nothing to tell the server.
    public func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)? {
        let newest = Dictionary(uniqueKeysWithValues: messageIds.compactMap { id -> (String, Int64)? in
            let logIds = (reactionEntries[id] ?? [:]).filter { !isOwnUserId($0.key) }.map(\.value.logId)
            return logIds.max().map { (id, $0) }
        })
        service.reactionStore.markSeen(newest, serverURL: serverURL, roomId: roomId)
        return nil
    }

    private func updateReactionTotals(for messageId: String) {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int64] = [:]
        for entry in (reactionEntries[messageId] ?? [:]).values {
            for emoji in entry.emojis {
                counts[emoji, default: 0] += 1
                firstSeen[emoji] = min(firstSeen[emoji] ?? .max, entry.logId)
            }
        }
        // Decided from every identity the user has had here, which is known before sign-in, so cached
        // reactions are highlighted from the first frame instead of once the connection is up.
        let mine = Set((reactionEntries[messageId] ?? [:]).filter { isOwnUserId($0.key) }.flatMap(\.value.emojis))
        let totals = counts
            .map { ChatReaction(emoji: $0.key, count: $0.value, includesYou: mine.contains($0.key)) }
            .sorted { ($0.count, -(firstSeen[$0.emoji] ?? 0)) > ($1.count, -(firstSeen[$1.emoji] ?? 0)) }
        reactions[messageId] = totals.isEmpty ? nil : totals
    }

    // MARK: Typing

    private func setTyping(_ user: ApronUser, seconds: Double) {
        typingUsers.removeAll { $0.userId == user.userId }
        if seconds > 0 {
            let name = users[user.userId]?.displayName ?? user.displayName
            typingUsers.append((user.userId, name, Date().addingTimeInterval(seconds)))
        }
        publishTyping()
    }

    /// Drops expired indications and wakes again at the next expiry.
    private func publishTyping() {
        let now = Date()
        typingUsers.removeAll { $0.expires <= now }
        let names = typingUsers.map(\.name)
        if typingNames != names {
            typingNames = names
            onChange?()
        }
        typingExpiryTask?.cancel()
        guard let next = typingUsers.map(\.expires).min() else { return }
        typingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05))
            guard !Task.isCancelled else { return }
            self?.publishTyping()
        }
    }

    /// Announces typing, refreshed while typing continues, and stops it after a pause.
    public func draftDidChange(_ draft: String) {
        // Others can't see typing in a room that doesn't exist yet.
        guard directUser == nil, let session, session.server.has("activity") else { return }
        restartTypingPause()
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        // Commands aren't messages others wait on.
        guard !draft.hasPrefix("/") || draft.hasPrefix("//") else { return }
        if let typingSentAt, Date().timeIntervalSince(typingSentAt) < typingRefreshInterval { return }
        guard spendTypingFrame() else { return }
        typingSentAt = Date()
        let seconds = typingSeconds
        Task { [roomId] in try? await session.connection.setTyping(roomId: roomId, seconds: seconds) }
    }

    private func restartTypingPause() {
        typingStopTask?.cancel()
        let pause = typingPause
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.stopTyping()
        }
    }

    /// Stops the indication now, unless it is about to lapse anyway or the frame budget is spent.
    private func stopTyping() {
        guard let sentAt = typingSentAt else { return }
        forgetTyping()
        let remaining = Double(typingSeconds) - Date().timeIntervalSince(sentAt)
        guard remaining > 2, let session, session.server.has("activity"), spendTypingFrame() else { return }
        Task { [roomId] in try? await session.connection.setTyping(roomId: roomId, seconds: 0) }
    }

    /// Drops the local typing state without telling the server, for when a sent message ends the indication.
    private func forgetTyping() {
        typingStopTask?.cancel()
        typingStopTask = nil
        typingSentAt = nil
    }

    private func spendTypingFrame() -> Bool {
        let now = Date()
        var times = Self.typingFrameTimes[serverURL, default: []].filter { now.timeIntervalSince($0) < 60 }
        defer { Self.typingFrameTimes[serverURL] = times }
        guard times.count < typingFrameBudget else { return false }
        times.append(now)
        return true
    }

    // MARK: Read state

    private var readCursor: Int64? {
        service.readStore.cursor(serverURL: serverURL, roomId: roomId)
    }

    /// Whether the user sent this message, from any identity they have had on the server. Known before the
    /// connection signs in, so cached messages render on the right side from the first frame.
    private func isOwn(_ message: ApronMessage) -> Bool {
        isOwnUserId(message.from.userId)
    }

    func isOwnUserId(_ userId: String) -> Bool {
        userId == you?.userId || ownUserIds.contains(userId)
    }

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        guard let id = Int64(message.id), let cursor = readCursor else { return false }
        return id > cursor
    }

    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard !message.isNotice, let id = Int64(message.id) else { return nil }
        return markRead(upTo: id)
    }

    /// Advances the read cursor to a message the user has seen, and returns what tells the server (§4.6).
    private func markRead(upTo messageId: Int64) -> (@MainActor () async throws -> Void)? {
        guard (readCursor ?? 0) < messageId else { return nil }
        service.readStore.markRead(messageId, serverURL: serverURL, roomId: roomId, serverTracksCursors: tracksCursors)
        guard let session, session.server.has("activity") else { return nil }
        return { [weak self, roomId] in
            guard let self, messageId > sentReadMessageId else { return }
            sentReadMessageId = messageId
            try await session.connection.markRead(roomId: roomId, messageId: String(messageId))
        }
    }

    // MARK: Read receipts

    /// The connection keeps every cursor it received, including those sent after `room_list` before this chat
    /// observed it.
    private func updateOthersRead(from connection: ApronConnection) {
        let others = (connection.readCursors[roomId] ?? [:]).filter { !isOwnUserId($0.key) }
        if let furthest = others.values.max(), furthest > othersRead ?? 0 {
            othersRead = furthest
        }
    }

    /// None in a room with only you.
    public func receipt(for message: ChatMessage) -> ChatReceipt? {
        guard let othersRead, (memberIds?.count ?? 2) > 1, let id = Int64(message.id) else { return nil }
        return id <= othersRead ? .seen : .sent
    }

    // MARK: Mentions

    private func updateMentionNames() {
        let named = users.values.compactMap { user in user.name.flatMap { $0.isEmpty ? nil : (user.userId, $0) } }
        let counts = Dictionary(named.map { ($0.1, 1) }, uniquingKeysWith: +)
        mentionNames = Dictionary(named.filter { counts[$0.1] == 1 }, uniquingKeysWith: { first, _ in first })
    }

    /// Members to offer while typing `@query`: names or `user_id`s that start with it, then names with a word
    /// that does. Online members come first for an empty query. You aren't offered.
    public func mentionSuggestions(for query: String) -> [ChatUser] {
        let limit = 5
        let candidates = (room.members ?? Array(users.values)).filter { !isOwnUserId($0.userId) && !$0.isSystem }
        let query = query.lowercased()
        func rank(_ user: ApronUser) -> Int? {
            let name = user.displayName.lowercased()
            if query.isEmpty { return presence(of: user)?.isConnected == true ? 0 : 1 }
            if name.hasPrefix(query) || user.userId.lowercased().hasPrefix(query) { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
            return nil
        }
        return candidates
            .compactMap { user in rank(user).map { (user, $0) } }
            .sorted { ($0.1, $0.0.displayName.lowercased()) < ($1.1, $1.0.displayName.lowercased()) }
            .prefix(limit)
            .map { chatUser($0.0) }
    }

    /// Known users written as `@user_id` in outgoing text. Only users in `mentions` count as mentioned (§3.5.5).
    private func mentionedUserIds(in text: String) -> [String] {
        let known = memberIds ?? Set(users.keys)
        var ids: [String] = []
        for match in ApronMention.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let userId = String(text[range].dropFirst())
            if known.contains(userId), !ids.contains(userId) {
                ids.append(userId)
            }
        }
        return ids
    }

    // MARK: Links

    /// A link to share for a message the server has numbered (SPEC.md §1: the web form).
    public func link(toMessage messageId: String) -> URL? {
        guard ApronLink.isMessageId(messageId) else { return nil }
        return ApronLink(serverURL: serverURL, room: roomId, message: messageId).webURL
    }

    /// An Apron link to a message or member of this room, relative ones against its server.
    public func linkTarget(for url: URL) -> ChatLinkTarget? {
        guard ApronLink.isLink(url), let link = try? ApronLink(url: url, contentServer: serverURL),
              link.token == nil, link.serverURL == serverURL, link.room == roomId
        else { return nil }
        if let user = link.user {
            return .user(user)
        }
        return link.message.map(ChatLinkTarget.message) ?? .chat
    }

    public var linkBaseURL: URL? {
        serverURL
    }

    /// A link to a room or member of this server, written as its URL, reads as `#<room name>` or `@name`. Links to
    /// messages stay links with the message as a card under them (`linkedMessageCard`), and links to other servers,
    /// or anything not strictly a place, stay URLs.
    public func placeLabel(forLink url: URL) -> ChatPlaceLabel? {
        // Messages show as cards instead, and other servers' places stay links.
        guard let link = ApronLink.place(url, contentServer: serverURL), let room = link.room,
              link.serverURL == serverURL, link.message == nil
        else { return nil }
        if let user = link.user {
            return ChatPlaceLabel(text: "@\(users[user]?.displayName ?? ApronLink.displayValue(user))", url: link.webURL)
        }
        return ChatPlaceLabel(text: "#\(roomName(room))", url: link.webURL)
    }

    /// `#room_id`, apron-web's ID grammar (Appendix A.3): letters, digits and `_.+@:-`, starting and ending with a
    /// letter, digit or `_`, and not right after a letter or digit.
    public var referencePattern: NSRegularExpression? {
        Self.roomReferencePattern
    }

    private static let roomReferencePattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])#([\p{L}\p{N}_](?:[\p{L}\p{N}_.+@:-]*[\p{L}\p{N}_])?)"#)

    /// A known room's `#room_id` shows its name and opens it; any other stays as written.
    public func placeLabel(forReference reference: String) -> ChatPlaceLabel? {
        guard knownRooms[reference] != nil else { return nil }
        return ChatPlaceLabel(text: "#\(roomName(reference))", url: ApronLink(serverURL: serverURL, room: reference).webURL)
    }

    public var referencePrefix: String? {
        "#"
    }

    /// Joined rooms and threads whose id or title starts with the query, then whose title has a word that does;
    /// a bare `#` lists them all by name. Rooms named for their members (direct and group messages) aren't places
    /// to point others at, so they aren't offered.
    public func referenceSuggestions(for query: String) -> [ChatReferenceSuggestion] {
        let query = query.lowercased()
        func rank(_ room: ApronRoom, title: String) -> Int? {
            if query.isEmpty { return 0 }
            let title = title.lowercased()
            if room.roomId.lowercased().hasPrefix(query) || title.hasPrefix(query) { return 0 }
            if title.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix(query) }) { return 1 }
            return nil
        }
        return knownRooms.values
            .filter { !$0.isNamedForMembers }
            .compactMap { room -> (ChatReferenceSuggestion, Int)? in
                let title = roomName(room.roomId)
                return rank(room, title: title).map {
                    (ChatReferenceSuggestion(reference: room.roomId, title: title, systemImage: room.parentRoomId == nil ? "number" : "bubble.left.and.text.bubble.right"), $0)
                }
            }
            .sorted { ($0.1, $0.0.title.localizedLowercase) < ($1.1, $1.0.title.localizedLowercase) }
            .prefix(8)
            .map(\.0)
    }

    /// A known room's title, a thread's "in #parent"; an unknown one's id, made safe to show.
    private func roomName(_ roomId: String) -> String {
        guard let room = knownRooms[roomId] else { return ApronLink.displayValue(roomId) }
        let title = room.displayTitle(users: users, you: you?.userId ?? "")
        guard let parent = room.parentRoomId else { return title }
        return "\(title) in #\(roomName(parent))"
    }

    // MARK: Display mapping

    private func chatUser(_ user: ApronUser) -> ChatUser {
        ChatUser(id: user.userId, name: user.displayName, avatarURL: user.avatarURL, isSystem: user.isSystem)
    }

    /// Senders show their recorded name and their current avatar, which recorded `from` objects often omit
    /// (§3.3.1).
    private func chatMessage(_ message: ApronMessage) -> ChatMessage {
        let from = message.from
        return ChatMessage(
            id: message.id,
            sender: ChatUser(id: from.userId, name: from.displayName, avatarURL: users[from.userId]?.avatarURL ?? from.avatarURL, isSystem: from.isSystem),
            // When it was sent: the creation's `log_id` (§2.2), which edits and finished uploads don't change.
            timestamp: ApronLogId.date(message.messageId) ?? message.timestamp,
            text: message.body?.text,
            isMarkdown: message.isMarkdown,
            embeds: message.isDeleted ? [] : (message.body?.embeds ?? []).map(chatEmbed)
                + messageLinks(in: message.body?.text ?? "", of: message).compactMap { linkedMessages[$0] ?? nil },
            replyToId: message.replyTo?.messageId,
            isDeleted: message.isDeleted,
            isOwn: !from.isSystem && isOwn(message),
            isNotice: message.messageId == nil,
        )
    }

    /// Image previews come only from allowed media origins; everything else renders as a card (§3.5.2, §4.8).
    private func chatEmbed(_ embed: ApronEmbed) -> ChatEmbed {
        let link = embed.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        if let image = embed.og?.image, let imageURL = allowedMediaURL(image.url) {
            let preview = ChatEmbed.image(url: imageURL, aspectRatio: image.aspectRatio, alt: image.alt ?? embed.title, link: nil, opensViewer: true)
            guard embed.kind != "upload" else { return preview }
            // A link preview shows its title with the image, which opens in the viewer; the title opens the page.
            let title = embed.og?.title ?? embed.title ?? link?.host() ?? "Link"
            return .linkPreview(title: title, subtitle: embed.og?.description ?? embed.text, link: link, media: [preview])
        }
        if embed.isPendingUpload {
            return .pending(title: embed.title ?? "Attachment")
        }
        let title = embed.og?.title ?? embed.title ?? embed.kind
        let subtitle = embed.og?.description ?? embed.text ?? link?.host() ?? (embed.kind == "upload" ? nil : embed.kind)
        return .card(title: title, subtitle: subtitle, systemImage: embed.kind == "upload" ? "doc" : "link", imageURL: nil, link: link)
    }
}

private extension ApronOpenGraphMedia {
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}
