import Foundation

/// Live chat for one Apron room: loads recent history, applies live snapshots, and posts messages.
@MainActor
public final class ApronChatViewModel: ObservableObject {
    /// A file staged in the composer, sent as an `upload` embed (§4.8.4).
    public struct Attachment: Equatable {
        public let data: Data
        public let mimeType: String
        public let filename: String
        public let isImage: Bool

        public init(data: Data, mimeType: String, filename: String, isImage: Bool) {
            self.data = data
            self.mimeType = mimeType
            self.filename = filename
            self.isImage = isImage
        }
    }

    public enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected(String?)
    }

    @Published public private(set) var messages: [ApronMessage] = []
    @Published public private(set) var state: ConnectionState = .connecting
    @Published public private(set) var title: String
    @Published public private(set) var you: ApronUser?
    @Published public private(set) var hasEarlierMessages = false
    @Published public private(set) var isLoadingEarlier = false
    @Published public private(set) var isSending = false
    @Published public private(set) var canAttach = false
    @Published public private(set) var canReact = false
    /// Per-message totals; tombstones show none (§4.4).
    @Published public private(set) var reactions: [String: [ApronReactionCount]] = [:]
    @Published public var draft = ""
    @Published public var attachment: Attachment?
    @Published public private(set) var replyingTo: ApronMessage?
    /// True while showing a window of older history that doesn't reach the newest message.
    @Published public private(set) var hasLaterMessages = false
    @Published public private(set) var isLoadingLater = false
    /// A message the view should scroll to and highlight, set by `jump(to:)`.
    @Published public private(set) var jumpTarget: String?
    /// Incremented when the view should scroll to the newest message.
    @Published public private(set) var scrollToLatestRequest = 0
    /// Reply targets outside the loaded window, fetched one by one (§4.3.1).
    @Published public private(set) var referencedMessages: [String: ApronMessage] = [:]
    @Published public private(set) var unavailableReferences: Set<String> = []
    /// The first message from someone else after the read cursor at the time the room opened; the
    /// "New Messages" divider sits above it for the whole visit.
    @Published public private(set) var firstUnreadMessageId: String?
    /// Messages from others after the current cursor among those loaded, for the jump-to-latest badge.
    @Published public private(set) var unreadCount = 0

    public static let quickReactions = ["👍", "❤️", "😂", "🔥", "😮", "🙏"]
    @Published public var errorMessage: String?

    public let serverURL: URL
    public let roomId: String

    private let service: ApronService
    private var session: ApronSession?
    private var snapshots: [String: ApronMessage] = [:]
    /// Kept current user objects (§3.3.1); messages carry recorded `from` objects that often omit avatars.
    private var users: [String: ApronUser] = [:]
    /// messageId → userId → that user's newest set; the record with the greatest `log_id` wins (§4.7).
    private var reactionEntries: [String: [String: (logId: Int64, emojis: [String])]] = [:]
    private var notices: [ApronMessage] = []
    private var firstLogId: String?
    private var lastLogId: String?
    private var pendingReferences: Set<String> = []
    private let windowSize = 30
    /// Whether the server's cursor is the source of truth here (see `ApronService.serverTracksCursors`).
    private var tracksCursors = false
    /// The cursor last sent to the server, so `activity` goes out only when it moves.
    private var sentReadMessageId: Int64 = 0
    private var readSendTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?
    private var ownUserIds: Set<String>
    private var observerToken: UUID?
    private var hasLoadedHistory = false
    private var renderedTextCache: [String: AttributedString] = [:]
    private let pageSize = 50

    public init(service: ApronService, serverURL: URL, roomId: String, title: String?) {
        ownUserIds = service.readStore.ownUserIds(serverURL: serverURL)
        self.service = service
        self.serverURL = serverURL
        self.roomId = roomId
        self.title = title ?? roomId
    }

    public var serverHost: String {
        serverURL.host() ?? serverURL.absoluteString
    }

    public var canSend: Bool {
        state == .connected && !isSending && (attachment != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Embed media loads only from the chat server or the origins it lists in `ext.media` (§4.8.1, §5.5).
    public func allowedMediaURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let host = url.host() else { return nil }
        let secure = url.scheme == "https"
        let localPlain = url.scheme == "http" && serverURL.scheme == "ws"
        guard secure || localPlain else { return nil }
        let origins = [serverURL.host()] + (session?.server.ext?.mediaOrigins ?? []).map { $0.host() }
        return origins.contains(host) ? url : nil
    }

    public func connect() async {
        guard session == nil else { return }
        state = .connecting
        errorMessage = nil
        showCachedMessages()
        do {
            let session = try await service.session(serverURL: serverURL)
            self.session = session
            you = session.you
            ownUserIds.insert(session.you.userId)
            canAttach = session.server.has("embed:upload")
            canReact = session.server.has("reactions")
            tracksCursors = service.serverTracksCursors(session)
            // Replay is order-independent (§2.3), so live frames can be applied while history loads.
            observerToken = session.connection.observe(
                notifications: { [weak self] method, params in self?.handle(method: method, params: params) },
                onClose: { [weak self] error in
                    guard let self else { return }
                    self.session = nil
                    observerToken = nil
                    state = .disconnected(error?.localizedDescription)
                },
            )

            if session.server.has("rooms") {
                let listing = try await session.connection.joinedRooms(members: true)
                for user in listing.users {
                    users[user.userId] = user
                }
                if let room = listing.rooms.first(where: { $0.roomId == roomId }) {
                    title = room.displayTitle
                } else {
                    // Live deliveries only reach joined rooms (§3.4).
                    try? await session.connection.joinRoom(roomId: roomId)
                }
            }
            if session.server.has("history") {
                // Any cursor the server keeps arrived after `room_list`, before this result (§1, §4.6).
                let page = try await session.connection.history(roomId: roomId, limit: pageSize)
                dropCacheBehindGap(newestPage: page)
                apply(page, publishing: false)
                // The divider and opening window belong to the first load of a visit; a reconnect (such as
                // after the app was in the background) only merges what arrived meanwhile.
                if !hasLoadedHistory {
                    try await openAtFirstUnread()
                }
                hasLoadedHistory = true
                publish()
            }
            state = .connected
        } catch {
            stopObserving()
            state = .disconnected(error.localizedDescription)
        }
    }

    /// Leaves the room. The connection is shared with the feed, so only this chat's observer goes away.
    public func disconnect() {
        saveCache()
        stopObserving()
    }

    private func stopObserving() {
        if let observerToken {
            session?.connection.removeObserver(observerToken)
        }
        observerToken = nil
        session = nil
    }

    /// Shows the room's cached recent messages before the connection is up, with the divider placed from
    /// the locally known cursor. History then merges in by `log_id` (§2.3).
    private func showCachedMessages() {
        guard snapshots.isEmpty, let entry = service.messageCache.load(serverURL: serverURL, roomId: roomId) else { return }
        for user in entry.users where users[user.userId] == nil {
            users[user.userId] = user
        }
        for message in entry.messages {
            install(message)
        }
        if let cursor = readCursor {
            firstUnreadMessageId = sortedSnapshots().first { countsAsUnread($0, after: cursor) }?.id
        }
        publish()
    }

    /// Cached messages older than a full newest page would sit next to it with a hole between; drop them.
    private func dropCacheBehindGap(newestPage page: ApronHistoryResult) {
        guard page.more == true, let pageFirst = page.firstLogId.flatMap(Int64.init) else { return }
        snapshots = snapshots.filter { (Int64($0.key) ?? 0) >= pageFirst }
        if let divider = firstUnreadMessageId, snapshots[divider] == nil {
            firstUnreadMessageId = nil
        }
    }

    /// Saves the newest messages, unless an older window is showing.
    private func saveCache() {
        guard !hasLaterMessages, !snapshots.isEmpty else { return }
        let recent = sortedSnapshots().suffix(ApronMessageCache.messageLimit)
        let authors = Set(recent.map(\.from.userId))
        service.messageCache.save(
            messages: Array(recent),
            users: users.values.filter { authors.contains($0.userId) },
            serverURL: serverURL,
            roomId: roomId,
        )
    }

    public func loadEarlier() async {
        guard let session, let firstLogId, let first = Int64(firstLogId), !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await session.connection.history(roomId: roomId, before: String(first - 1), limit: pageSize)
            apply(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachment
        guard let session, !text.isEmpty || attachment != nil else { return }
        if let attachment, let limit = session.server.ext?.uploadLimits[attachment.mimeType], attachment.data.count > limit {
            errorMessage = "\(attachment.filename) is larger than this server's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            // `/` sends a command, and `//` escapes a message that starts with `/` (§4.1).
            let isCommand = text.hasPrefix("/") && !text.hasPrefix("//") && session.server.has("command")
            let bodyText = !isCommand && text.hasPrefix("//") ? String(text.dropFirst()) : text
            let body = ApronMessageBody(
                text: bodyText,
                format: isCommand ? nil : "markdown",
                embeds: attachment.map { [.upload(title: $0.filename)] },
            )
            let result = try await session.connection.post(
                method: isCommand ? "command" : "message",
                roomId: roomId,
                body: body,
                replyTo: replyingTo?.messageId,
            )
            // The message is broadcast with a pending upload; clear the composer before writing the file.
            draft = ""
            self.attachment = nil
            replyingTo = nil
            if let attachment {
                guard let write = result.embeds?.first?.writeUrl, let writeURL = URL(string: write) else {
                    throw SourceError.serviceError("The server did not accept the attachment.")
                }
                try await ApronUploader.put(data: attachment.data, mimeType: attachment.mimeType, to: writeURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startReply(to message: ApronMessage) {
        guard message.messageId != nil, !message.isDeleted, !message.from.isSystem else { return }
        replyingTo = message
    }

    public func cancelReply() {
        replyingTo = nil
    }

    public func yourEmojis(on messageId: String) -> [String] {
        guard let you else { return [] }
        return reactionEntries[messageId]?[you.userId]?.emojis ?? []
    }

    /// Sends your complete new set: adds the emoji, or removes it when you already reacted with it (§4.7).
    public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard let session, canReact else { return }
        var emojis = yourEmojis(on: messageId)
        if let index = emojis.firstIndex(of: emoji) {
            emojis.remove(at: index)
        } else {
            emojis.append(emoji)
        }
        do {
            try await session.connection.setReactions(messageId: messageId, emojis: emojis)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyReactions(_ record: ApronReactionRecord) {
        guard record.roomId == nil || record.roomId == roomId else { return }
        let logId = record.logId.flatMap(Int64.init) ?? 0
        var entries = reactionEntries[record.messageId] ?? [:]
        for set in record.reactions {
            if let existing = entries[set.from.userId], existing.logId > logId { continue }
            // Duplicates collapse and order doesn't matter (§4.7).
            var seen = Set<String>()
            entries[set.from.userId] = (logId, set.emojis.filter { seen.insert($0).inserted })
        }
        reactionEntries[record.messageId] = entries
        updateReactionTotals(for: record.messageId)
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
        let mine = Set(yourEmojis(on: messageId))
        let totals = counts
            .map { ApronReactionCount(emoji: $0.key, count: $0.value, includesYou: mine.contains($0.key)) }
            .sorted { ($0.count, -(firstSeen[$0.emoji] ?? 0)) > ($1.count, -(firstSeen[$1.emoji] ?? 0)) }
        if reactions[messageId] != totals {
            reactions[messageId] = totals.isEmpty ? nil : totals
        }
    }

    private func handle(method: String, params: Data) {
        if method == "activity" {
            if tracksCursors, let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
               activity.from?.userId == you?.userId, activity.roomId == nil || activity.roomId == roomId,
               let cursor = activity.readMessageId.flatMap(Int64.init)
            {
                // Read on another device: the server's cursor is the truth.
                service.readStore.setServerCursor(cursor, serverURL: serverURL, roomId: roomId)
                updateUnreadCount()
            }
            return
        }
        if method == "reactions", let record = try? JSONDecoder().decode(ApronReactionRecord.self, from: params) {
            applyReactions(record)
            return
        }
        guard method == "message", let message = try? JSONDecoder().decode(ApronMessage.self, from: params) else { return }
        if message.messageId == nil {
            // Transient notices without a room (such as sign-in welcomes) are shown in the open room.
            guard message.roomId == nil || message.roomId == roomId, !notices.contains(where: { $0.id == message.id }) else { return }
            notices.append(message)
        } else if message.roomId == roomId {
            // While showing an older window, new messages arrive later by paging forward; edits to loaded ones apply now.
            if !hasLaterMessages || message.messageId.map({ snapshots[$0] != nil }) == true {
                install(message)
            }
        } else if let id = message.messageId, snapshots[id] != nil {
            // Moved out of this room (§4.4).
            snapshots[id] = nil
        }
        publish()
        // Sending a message means the user has read up to it.
        if let id = message.messageId.flatMap(Int64.init), isOwn(message) {
            markRead(upTo: id)
        }
    }

    private enum PageDirection {
        case backward
        case forward
    }

    /// `more` describes the selected direction: older pages for `before`, newer ones for `after` (§4.3.2).
    private func apply(_ page: ApronHistoryResult, direction: PageDirection = .backward, publishing: Bool = true) {
        for message in page.messages ?? [] where message.roomId == nil || message.roomId == roomId {
            install(message)
        }
        for record in page.reactions ?? [] {
            applyReactions(record)
        }
        if let pageFirst = page.firstLogId.flatMap(Int64.init),
           firstLogId.flatMap(Int64.init).map({ pageFirst < $0 }) ?? true
        {
            firstLogId = String(pageFirst)
        }
        if let pageLast = page.lastLogId.flatMap(Int64.init),
           lastLogId.flatMap(Int64.init).map({ pageLast > $0 }) ?? true
        {
            lastLogId = String(pageLast)
        }
        switch direction {
        case .backward: hasEarlierMessages = page.more ?? false
        case .forward: hasLaterMessages = page.more ?? false
        }
        if publishing {
            publish()
        }
    }

    /// Scrolls to a message. One outside the loaded history is shown in a window around it,
    /// without loading everything in between (§4.3.2).
    public func jump(to messageId: String) async {
        if snapshots[messageId] != nil {
            jumpTarget = messageId
            return
        }
        guard let session, session.server.has("history"), let target = Int64(messageId) else { return }
        do {
            let older = try await session.connection.history(roomId: roomId, before: messageId, limit: windowSize)
            guard older.messages?.contains(where: { $0.messageId == messageId }) == true else {
                errorMessage = "That message is no longer available."
                return
            }
            let newer = try await session.connection.history(roomId: roomId, after: String(target + 1), limit: windowSize)
            snapshots = [:]
            notices = []
            firstLogId = nil
            lastLogId = nil
            apply(older, direction: .backward, publishing: false)
            apply(newer, direction: .forward, publishing: false)
            jumpTarget = messageId
            publish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearJumpTarget() {
        jumpTarget = nil
    }

    public func loadLater() async {
        guard let session, hasLaterMessages, !isLoadingLater, let last = lastLogId.flatMap(Int64.init) else { return }
        isLoadingLater = true
        defer { isLoadingLater = false }
        do {
            let page = try await session.connection.history(roomId: roomId, after: String(last + 1), limit: pageSize)
            apply(page, direction: .forward)
            if !hasLaterMessages {
                // Caught up: live delivery resumes; read once more for anything that arrived during this page.
                if let last = lastLogId.flatMap(Int64.init) {
                    let tail = try await session.connection.history(roomId: roomId, after: String(last + 1), limit: pageSize)
                    apply(tail, direction: .forward)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves an older window and shows the newest messages again.
    public func jumpToLatest() async {
        guard hasLaterMessages else {
            scrollToLatestRequest += 1
            return
        }
        guard let session else { return }
        do {
            let page = try await session.connection.history(roomId: roomId, limit: pageSize)
            snapshots = [:]
            firstLogId = nil
            lastLogId = nil
            hasLaterMessages = false
            apply(page, publishing: false)
            scrollToLatestRequest += 1
            publish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func isUnavailableReference(_ messageId: String) -> Bool {
        unavailableReferences.contains(messageId)
    }

    /// Fetches reply targets that aren't loaded with `after` and `before` both at their id (§4.3.1).
    private func fetchMissingReferences() {
        guard let session, session.server.has("history") else { return }
        let missing = Set(snapshots.values.compactMap { $0.replyTo?.messageId }).filter {
            snapshots[$0] == nil && referencedMessages[$0] == nil && !unavailableReferences.contains($0) && !pendingReferences.contains($0)
        }
        for messageId in missing {
            pendingReferences.insert(messageId)
            Task {
                defer { pendingReferences.remove(messageId) }
                let page = try? await session.connection.history(roomId: roomId, after: messageId, before: messageId, limit: 1)
                if let message = page?.messages?.first(where: { $0.messageId == messageId }) {
                    referencedMessages[messageId] = message
                } else {
                    unavailableReferences.insert(messageId)
                }
            }
        }
    }

    /// Keeps the snapshot with the greatest `log_id`; at an equal `log_id` the tombstone wins (§2.3).
    private func install(_ message: ApronMessage) {
        guard let id = message.messageId else { return }
        if let existing = snapshots[id] {
            if existing.sortKey > message.sortKey { return }
            if existing.sortKey == message.sortKey, existing.isDeleted { return }
        }
        snapshots[id] = message
    }

    private func sortedSnapshots() -> [ApronMessage] {
        snapshots.values.sorted { lhs, rhs in
            (lhs.messageId.flatMap(Int64.init) ?? lhs.sortKey) < (rhs.messageId.flatMap(Int64.init) ?? rhs.sortKey)
        }
    }

    private func publish() {
        updateUnreadCount()
        messages = sortedSnapshots() + notices
        fetchMissingReferences()
        scheduleCacheSave()
    }

    /// Saves shortly after changes while connected, so the cache survives the app being killed in a chat.
    private func scheduleCacheSave() {
        guard session != nil else { return }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveCache()
        }
    }

    // MARK: Read state

    private var readCursor: Int64? {
        service.readStore.cursor(serverURL: serverURL, roomId: roomId)
    }

    /// Whether the user sent this message, from any identity they have had on the server. Known before the
    /// connection signs in, so cached messages render on the right side from the first frame.
    public func isOwn(_ message: ApronMessage) -> Bool {
        message.from.userId == you?.userId || ownUserIds.contains(message.from.userId)
    }

    private func countsAsUnread(_ message: ApronMessage, after cursor: Int64) -> Bool {
        guard let id = message.messageId.flatMap(Int64.init), id > cursor else { return false }
        return !message.isDeleted && !message.from.isSystem && !isOwn(message)
    }

    /// Places the divider at the first unread message. When it lies before the loaded page, loads a window
    /// starting just before it rather than every page in between (§4.3.2).
    private func openAtFirstUnread() async throws {
        let newest = snapshots.keys.compactMap(Int64.init).max()
        if let newest {
            service.readStore.setBaselineIfNeeded(newest, serverURL: serverURL, roomId: roomId)
        }
        guard let cursor = readCursor, let session else { return }
        let loadedFrom = firstLogId.flatMap(Int64.init) ?? 0
        if hasEarlierMessages, cursor + 1 < loadedFrom {
            let older = try await session.connection.history(roomId: roomId, before: String(cursor), limit: 10)
            let newer = try await session.connection.history(roomId: roomId, after: String(cursor + 1), limit: pageSize)
            snapshots = [:]
            firstLogId = nil
            lastLogId = nil
            apply(older, direction: .backward, publishing: false)
            apply(newer, direction: .forward, publishing: false)
        }
        // Keep a divider already placed from the cache; otherwise place it now that history is in.
        if firstUnreadMessageId == nil {
            firstUnreadMessageId = sortedSnapshots().first { countsAsUnread($0, after: cursor) }?.id
        }
    }

    /// Advances the read cursor to a message the user has seen, and tells the server shortly after (§4.6).
    public func markRead(upTo messageId: Int64) {
        guard (readCursor ?? 0) < messageId else { return }
        service.readStore.markRead(messageId, serverURL: serverURL, roomId: roomId, serverTracksCursors: tracksCursors)
        updateUnreadCount()
        guard let session, session.server.has("activity") else { return }
        readSendTask?.cancel()
        readSendTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, messageId > sentReadMessageId else { return }
            sentReadMessageId = messageId
            try? await session.connection.markRead(roomId: roomId, messageId: String(messageId))
        }
    }

    private func updateUnreadCount() {
        let cursor = readCursor ?? .max
        let count = snapshots.values.count(where: { countsAsUnread($0, after: cursor) })
        if unreadCount != count {
            unreadCount = count
        }
    }

    /// The kept user object's avatar, falling back to the recorded `from` (§3.3.1).
    public func avatarURL(for user: ApronUser) -> URL? {
        users[user.userId]?.avatarURL ?? user.avatarURL
    }

    public func message(withId id: String) -> ApronMessage? {
        snapshots[id] ?? referencedMessages[id]
    }

    /// Markdown messages render as inline CommonMark; parsing is cached per snapshot. Raw HTML is never rendered (§3.5.2).
    public func renderedText(for message: ApronMessage) -> AttributedString {
        let text = message.body?.text ?? ""
        guard message.isMarkdown else { return AttributedString(text) }
        let key = "\(message.id)|\(message.logId ?? "")"
        if let cached = renderedTextCache[key] {
            return cached
        }
        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        renderedTextCache[key] = rendered
        return rendered
    }
}
