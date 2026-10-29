import Foundation

/// Live chat for one Apron room: loads recent history, applies live snapshots, and posts messages.
@MainActor
public final class ApronChatViewModel: ChatViewModel {
    @Published public private(set) var you: ApronUser?
    /// The room's members, you first, then by name; `nil` until the server has listed them (§4.2.1).
    @Published public private(set) var members: [ApronUser]?
    /// The total when the server listed only some members.
    @Published public private(set) var memberCount: Int?
    /// This room's notification level and the levels it offers; `nil` where the server doesn't push to this account.
    @Published public private(set) var notifications: ApronRoomNotifications?
    @Published public private(set) var notificationError: String?

    public let serverURL: URL
    public let roomId: String

    private let service: ApronService
    private var session: ApronSession?
    private var cachedMediaOrigins: [URL] = []
    private var snapshots: [String: ApronMessage] = [:]
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
    private var isPrivateRoom = false
    private var notices: [ApronMessage] = []
    private var firstLogId: String?
    private var lastLogId: String?
    private var pendingReferences: Set<String> = []
    private let windowSize = 30
    /// Whether the server's cursor is the source of truth here (see `ApronService.serverTracksCursors`).
    private var tracksCursors = false
    /// The cursor last sent to the server, so `activity` goes out only when it moves.
    private var sentReadMessageId: Int64 = 0
    private var cacheSaveTask: Task<Void, Never>?
    private var ownUserIds: Set<String>
    private var observerToken: UUID?
    private var hasLoadedHistory = false
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

    /// Set when the Chats list knows of unread messages, which may all be newer than the cache.
    private let expectsUnread: Bool
    /// A message to show once the room loads, such as from a link.
    public var focusMessageId: String?

    public init(service: ApronService, serverURL: URL, roomId: String, title: String?, expectsUnread: Bool = false) {
        ownUserIds = service.readStore.ownUserIds(serverURL: serverURL)
        self.expectsUnread = expectsUnread
        self.service = service
        self.serverURL = serverURL
        self.roomId = roomId
        super.init(
            network: .apron,
            chatKey: Self.chatKey(serverURL: serverURL, roomId: roomId),
            title: title ?? roomId,
            subtitle: serverURL.host() ?? serverURL.absoluteString,
            canReply: true,
            offersAttachments: true,
            mentionPattern: ApronMention.pattern,
            draftStore: service.draftStore,
        )
    }

    /// Each server is its own account, so the server and room name the chat without an account id.
    static func chatKey(serverURL: URL, roomId: String) -> String {
        "apron:\(serverURL.absoluteString)|\(roomId)"
    }

    /// The live session's media origins, or the cached ones until it is up.
    private var mediaOrigins: [URL] {
        session?.server.ext?.mediaOrigins ?? cachedMediaOrigins
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

    override public func connect() async {
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
                    forgetTyping()
                    typingUsers = []
                    publishTyping()
                    // Without an error the app closed the connection itself (it went to the background) and
                    // rejoins when active again, so there is nothing to report; a notice would resize the composer.
                    state = error == nil ? .connecting : .disconnected(error?.localizedDescription)
                },
            )

            if session.server.has("rooms") {
                let listing = try await session.connection.joinedRooms()
                for user in listing.users {
                    users[user.userId] = user
                }
                if let room = listing.rooms.first(where: { $0.roomId == roomId }) {
                    isPrivateRoom = room.isPrivate
                    titleIsMemberNames = room.isNamedForMembers
                    title = room.displayTitle(users: users, you: session.you.userId)
                    setMembers(of: room)
                } else {
                    // Live deliveries only reach joined rooms (§3.4).
                    try? await session.connection.joinRoom(roomId: roomId)
                }
            }
            if session.server.has("history") {
                if hasLoadedHistory, let last = lastLogId.flatMap(Int64.init) {
                    // A reconnect (such as after the app was in the background) keeps what the user is reading,
                    // including the divider, and catches up from the last loaded message so nothing between is
                    // skipped. With `more`, the rest loads by paging forward, like an older window.
                    let page = try await session.connection.history(roomId: roomId, after: String(last + 1), limit: pageSize)
                    apply(page, direction: .forward, publishing: false)
                } else {
                    // Any cursor the server keeps arrived after `room_list`, before this result (§1, §4.6).
                    let page = try await session.connection.history(roomId: roomId, limit: pageSize)
                    dropCacheBehindGap(newestPage: page)
                    apply(page, publishing: false)
                    // The divider and opening window belong to the first load of a visit.
                    try await openAtFirstUnread()
                }
                hasLoadedHistory = true
                await loadMissingReferences()
                publish()
            }
            updateNotifications()
            state = .connected
            subtitleTask?.cancel()
            subtitleTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self else { return }
                    updateSubtitle()
                }
            }
            if let message = focusMessageId {
                focusMessageId = nil
                await jump(to: message)
            }
        } catch {
            stopObserving()
            state = .disconnected(error.localizedDescription)
        }
    }

    private func updateNotifications() {
        guard let session, service.offersPush(session), let push = session.server.push else {
            notifications = nil
            return
        }
        notifications = ApronRoomNotifications(
            isPrivate: isPrivateRoom,
            isMuted: session.connection.mutedRooms.contains(roomId),
            roomWake: session.connection.roomWakes[roomId],
            serverWake: push.wake ?? [],
            supportsRoomWake: push.roomWake == true,
            supportsMute: session.server.has("status"),
        )
    }

    /// Applies a notification level with `status` (`ApronRoomNotifications`); the server keeps it for every device.
    public func setNotificationLevel(_ level: ApronNotificationLevel) async {
        guard let session, let notifications else { return }
        notificationError = nil
        do {
            for change in notifications.changes(to: level) {
                switch change {
                case let .mute(muted): try await session.connection.setRoomMuted(roomId: roomId, muted: muted)
                case let .wake(scopes): try await session.connection.setRoomWake(roomId: roomId, scopes: scopes)
                }
            }
        } catch {
            notificationError = error.localizedDescription
        }
        updateNotifications()
    }

    /// Leaves the room. The connection is shared with the feed, so only this chat's observer goes away.
    override public func disconnect() {
        subtitleTask?.cancel()
        subtitleTask = nil
        saveCache()
        stopTyping()
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
        cachedMediaOrigins = entry.mediaOrigins ?? []
        for user in entry.users where users[user.userId] == nil {
            users[user.userId] = user
        }
        for message in entry.messages {
            install(message)
        }
        // Reactions come with the cache so bubbles don't grow once history arrives.
        for record in entry.reactions ?? [] {
            applyReactions(record)
        }
        if let cursor = readCursor {
            firstUnreadMessageId = sortedSnapshots().first { countsAsUnread($0, after: cursor) }?.id
        }
        if expectsUnread, firstUnreadMessageId == nil {
            // The unread messages are newer than the cache. Showing it would open at its bottom and then jump to
            // the divider once history arrives, so wait briefly for history, which publishes the cache with it.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !hasLoadedHistory else { return }
                publish()
            }
            return
        }
        publish()
    }

    /// Cached messages older than a full newest page would sit next to it with a hole between; drop them. A cache
    /// that reaches the page has no hole, so it stays, with the divider it may already show.
    private func dropCacheBehindGap(newestPage page: ApronHistoryResult) {
        guard page.more == true, let pageFirst = page.firstLogId.flatMap(Int64.init),
              let cachedNewest = snapshots.keys.compactMap(Int64.init).max(), cachedNewest < pageFirst
        else { return }
        snapshots = snapshots.filter { (Int64($0.key) ?? 0) >= pageFirst }
        if let divider = firstUnreadMessageId, snapshots[divider] == nil {
            firstUnreadMessageId = nil
        }
    }

    /// Saves the newest messages, unless an older window is showing.
    private func saveCache() {
        guard !hasLaterMessages, !snapshots.isEmpty else { return }
        let recent = sortedSnapshots().suffix(ApronMessageCache.messageLimit)
        // Reactors too, so the reaction list has their avatars before the connection is up.
        let authors = Set(recent.map(\.from.userId)).union(recent.compactMap(\.messageId).flatMap { (reactionEntries[$0] ?? [:]).keys })
        // One record per user and message, keeping each set's own `log_id` so merging stays correct (§4.7).
        let reactions = recent.compactMap(\.messageId).flatMap { messageId in
            (reactionEntries[messageId] ?? [:]).map { userId, entry in
                ApronReactionRecord(
                    logId: String(entry.logId),
                    messageId: messageId,
                    roomId: roomId,
                    reactions: [ApronReactionSet(from: users[userId] ?? reactionAuthors[userId] ?? ApronUser(userId: userId, name: nil, avatar: nil, roles: nil), emojis: entry.emojis)],
                )
            }
        }
        service.messageCache.save(
            messages: Array(recent),
            users: users.values.filter { authors.contains($0.userId) },
            reactions: reactions,
            mediaOrigins: mediaOrigins,
            serverURL: serverURL,
            roomId: roomId,
        )
    }

    override public func loadEarlier() async {
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

    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachment
        guard let session, !text.isEmpty || attachment != nil else { return }
        if let attachment, let limit = session.server.ext?.uploadLimits[attachment.mimeType], attachment.data.count > limit {
            errorMessage = "\(attachment.filename) is larger than this server's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
            return
        }
        // `/` sends a command, and `//` escapes a message that starts with `/` (§4.1).
        if text.hasPrefix("/"), !text.hasPrefix("//"), session.server.has("command") {
            await sendCommand(text, session: session)
            return
        }
        // A new message ends the indication for others (§4.6).
        forgetTyping()
        let bodyText = text.hasPrefix("//") ? String(text.dropFirst()) : text
        let mentions = mentionedUserIds(in: bodyText)
        var writeURL: URL?
        let replyTo = replyingTo?.id
        // Shown at once as sending until the server's broadcast of it arrives (see `sendOptimistically`).
        await sendOptimistically(text: text, attachment: attachment, replyToId: replyTo) {
            let result = try await session.connection.post(
                method: "message",
                roomId: roomId,
                body: ApronMessageBody(
                    text: bodyText,
                    format: "markdown",
                    mentions: mentions.isEmpty ? nil : mentions,
                    embeds: attachment.map { [.upload(title: $0.filename)] },
                ),
                replyTo: replyTo,
            )
            writeURL = result.embeds?.first?.writeUrl.flatMap(URL.init(string:))
            return result.messageId
        }
        // The message is broadcast with a pending upload, then the file is written; the chat keeps showing the
        // picked image meanwhile.
        guard let attachment, errorMessage == nil else { return }
        do {
            guard let writeURL else { throw SourceError.serviceError("The server did not accept the attachment.") }
            try await ApronUploader.put(data: attachment.data, mimeType: attachment.mimeType, to: writeURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A command may not post a message, so it keeps the composer busy rather than showing one.
    private func sendCommand(_ text: String, session: ApronSession) async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        stopTyping()
        do {
            _ = try await session.connection.post(method: "command", roomId: roomId, body: ApronMessageBody(text: text), replyTo: replyingTo?.id)
            draft = ""
            attachment = nil
            replyingTo = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    override public func yourEmojis(on messageId: String) -> [String] {
        guard let you else { return [] }
        return reactionEntries[messageId]?[you.userId]?.emojis ?? []
    }

    /// Sends your complete new set: adds the emoji, or removes it when you already reacted with it (§4.7).
    override public func toggleReaction(_ emoji: String, on messageId: String) async {
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

    /// Who reacted with `emoji` on a message, oldest first, for the reaction chip's long-press list. The date is
    /// when the user last set their reactions there: a user's set is logged as one record (§4.7).
    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (reactionEntries[messageId] ?? [:])
            .filter { $0.value.emojis.contains(emoji) }
            .sorted { ($0.value.logId, $0.key) < ($1.value.logId, $1.key) }
            .map { userId, entry in
                let user = users[userId] ?? reactionAuthors[userId] ?? ApronUser(userId: userId, name: nil, avatar: nil, roles: nil)
                return ChatReactor(user: chatUser(user), date: entry.logId > 0 ? ApronLogId.date(String(entry.logId)) : nil, isYou: isOwnUserId(userId))
            }
    }

    /// Starts the member list from a listed room (§4.2.2).
    private func setMembers(of room: ApronRoom) {
        guard let listed = room.members else { return }
        memberIds = Set(listed.map(\.userId))
        memberCount = room.memberCount
        publishMembers()
    }

    /// Joining this room delivers it with its members; membership records then add and remove users.
    private func applyRoomUpdate(_ update: ApronRoomUpdate) {
        for user in update.users ?? [] {
            users[user.userId] = user
        }
        if let room = update.joined?.first(where: { $0.roomId == roomId }) {
            setMembers(of: room)
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
        members = memberIds.map { ids in
            ids.map { users[$0] ?? ApronUser(userId: $0, name: nil, avatar: nil, roles: nil) }
                .sorted { lhs, rhs in
                    let lhsOwn = isOwnUser(lhs), rhsOwn = isOwnUser(rhs)
                    if lhsOwn != rhsOwn { return lhsOwn }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
        }
        updateSubtitle()
    }

    /// A DM shows the other person's status in place of the server, when the server reports it: "last seen …"
    /// when it sends `seen` with an offline status (§4.5.2).
    private func updateSubtitle() {
        let others = (members ?? []).filter { !isOwnUser($0) }
        let other = titleIsMemberNames && others.count == 1 ? others[0] : nil
        let status = other.flatMap { user in
            user.lastSeen.map { "last seen \($0.formatted(.relative(presentation: .named)))" } ?? presence(of: user)?.text
        }
        subtitle = status ?? serverURL.host() ?? serverURL.absoluteString
    }

    /// Whether the user is reachable now, `nil` when the server doesn't say (§4.5.1). Your own entry follows
    /// your setting, since the server never reports your status as others see it to you.
    public func presence(of user: ApronUser) -> ApronPresence? {
        guard isOwnUser(user) else { return ApronPresence(status: user.status) }
        guard state == .connected, let you else { return nil }
        switch you.status {
        case "dnd": return .doNotDisturb
        case "invisible", "": return .offline
        default: return .online
        }
    }

    public func isOwnUser(_ user: ApronUser) -> Bool {
        isOwnUserId(user.userId)
    }

    private func applyReactions(_ record: ApronReactionRecord) {
        guard record.roomId == nil || record.roomId == roomId else { return }
        let logId = record.logId.flatMap(Int64.init) ?? 0
        var entries = reactionEntries[record.messageId] ?? [:]
        for set in record.reactions {
            // Recorded `from` objects name reactors who aren't listed room members (§3.3.1).
            reactionAuthors[set.from.userId] = set.from
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
        // Decided from every identity the user has had here, which is known before sign-in, so cached
        // reactions are highlighted from the first frame instead of once the connection is up.
        let mine = Set((reactionEntries[messageId] ?? [:]).filter { isOwnUserId($0.key) }.flatMap(\.value.emojis))
        let totals = counts
            .map { ChatReaction(emoji: $0.key, count: $0.value, includesYou: mine.contains($0.key)) }
            .sorted { ($0.count, -(firstSeen[$0.emoji] ?? 0)) > ($1.count, -(firstSeen[$1.emoji] ?? 0)) }
        if reactions[messageId] != totals {
            reactions[messageId] = totals.isEmpty ? nil : totals
        }
    }

    private func handle(method: String, params: Data) {
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
                updateUnreadCount()
            }
            return
        }
        if method == "reactions", let record = try? JSONDecoder().decode(ApronReactionRecord.self, from: params) {
            applyReactions(record)
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
    override public func jump(to messageId: String) async {
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

    override public func loadLater() async {
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
    override public func jumpToLatest() async {
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

    /// Fetches reply targets later pages and live messages quote, without holding up the update.
    private func fetchMissingReferences() {
        Task { await loadMissingReferences() }
    }

    /// Fetches, all at once, reply targets that aren't loaded, with `after` and `before` both at their id
    /// (§4.3.1). The first load awaits it, so quotes show with the messages instead of loading after them
    /// (the server answers each in about 0.2 s; the wait was the fetches starting only after the chat showed).
    private func loadMissingReferences() async {
        guard let session, session.server.has("history") else { return }
        let missing = Set(snapshots.values.compactMap { $0.replyTo?.messageId }).filter {
            snapshots[$0] == nil && referencedMessages[$0] == nil && !unavailableReferences.contains($0) && !pendingReferences.contains($0)
        }
        guard !missing.isEmpty else { return }
        pendingReferences.formUnion(missing)
        let connection = session.connection
        let roomId = roomId
        await withTaskGroup(of: (String, ApronMessage?).self) { group in
            for messageId in missing {
                group.addTask {
                    let page = try? await connection.history(roomId: roomId, after: messageId, before: messageId, limit: 1)
                    return (messageId, page?.messages?.first { $0.messageId == messageId })
                }
            }
            for await (messageId, message) in group {
                pendingReferences.remove(messageId)
                if let message {
                    referencedMessages[messageId] = chatMessage(message)
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
        history = (sortedSnapshots() + notices).map(chatMessage)
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
        }
        typingExpiryTask?.cancel()
        guard let next = typingUsers.map(\.expires).min() else { return }
        typingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05))
            guard !Task.isCancelled else { return }
            self?.publishTyping()
        }
    }

    /// Call as the draft changes: announces typing, refreshed while typing continues, and stops it after a pause.
    override public func draftDidChange() {
        guard let session, session.server.has("activity") else { return }
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
        Task { try? await session.connection.setTyping(roomId: roomId, seconds: seconds) }
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
        Task { try? await session.connection.setTyping(roomId: roomId, seconds: 0) }
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
    public func isOwn(_ message: ApronMessage) -> Bool {
        isOwnUserId(message.from.userId)
    }

    private func isOwnUserId(_ userId: String) -> Bool {
        userId == you?.userId || ownUserIds.contains(userId)
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

    override public func markRead(upTo message: ChatMessage) {
        guard !message.isNotice, let id = Int64(message.id) else { return }
        markRead(upTo: id)
    }

    /// Advances the read cursor to a message the user has seen, and tells the server shortly after (§4.6).
    private func markRead(upTo messageId: Int64) {
        guard (readCursor ?? 0) < messageId else { return }
        service.readStore.markRead(messageId, serverURL: serverURL, roomId: roomId, serverTracksCursors: tracksCursors)
        updateUnreadCount()
        guard let session, session.server.has("activity") else { return }
        scheduleReadMarker { [weak self, roomId] in
            guard let self, messageId > sentReadMessageId else { return }
            sentReadMessageId = messageId
            try await session.connection.markRead(roomId: roomId, messageId: String(messageId))
        }
    }

    /// Counts the room's kept messages rather than `history`, which may be an older window.
    override func updateUnreadCount() {
        let cursor = readCursor ?? .max
        let count = snapshots.values.count(where: { countsAsUnread($0, after: cursor) })
        if unreadCount != count {
            unreadCount = count
        }
    }

    private func updateMentionNames() {
        let named = users.values.compactMap { user in user.name.flatMap { $0.isEmpty ? nil : (user.userId, $0) } }
        let counts = Dictionary(named.map { ($0.1, 1) }, uniquingKeysWith: +)
        let names = Dictionary(named.filter { counts[$0.1] == 1 }, uniquingKeysWith: { first, _ in first })
        if mentionNames != names {
            mentionNames = names
        }
    }

    /// Members to offer while typing `@query`: names or `user_id`s that start with it, then names with a word
    /// that does. Online members come first for an empty query. You aren't offered.
    override public func mentionSuggestions(for query: String) -> [ChatUser] {
        let limit = 5
        let candidates = (members ?? Array(users.values)).filter { !isOwnUser($0) && !$0.isSystem }
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

    /// The kept current object, falling back to a recorded one such as a message's `from` (§3.3.1).
    public func currentUser(_ user: ApronUser) -> ApronUser {
        users[user.userId] ?? reactionAuthors[user.userId] ?? user
    }

    /// A link to share for a message the server has numbered (SPEC.md §1: the web form).
    override public func link(toMessage messageId: String) -> URL? {
        guard ApronLink.isMessageId(messageId) else { return nil }
        return ApronLink(serverURL: serverURL, room: roomId, message: messageId).webURL
    }

    /// An Apron link to a message or member of this room, relative ones against its server.
    override public func linkTarget(for url: URL) -> ChatLinkTarget? {
        guard ApronLink.isLink(url), let link = try? ApronLink(url: url, contentServer: serverURL),
              link.token == nil, link.serverURL == serverURL, link.room == roomId
        else { return nil }
        if let user = link.user {
            return .user(user)
        }
        return link.message.map(ChatLinkTarget.message) ?? .chat
    }

    override public var linkBaseURL: URL? {
        serverURL
    }

    /// The kept or recorded user behind a chat user, such as a tapped avatar, for the profile screen.
    public func apronUser(for user: ChatUser) -> ApronUser {
        users[user.id] ?? reactionAuthors[user.id]
            ?? ApronUser(userId: user.id, name: user.name == user.id ? nil : user.name, avatar: user.avatarURL?.absoluteString, roles: nil)
    }

    /// The kept user object's avatar, falling back to the recorded `from` (§3.3.1).
    public func avatarURL(for user: ApronUser) -> URL? {
        users[user.userId]?.avatarURL ?? user.avatarURL
    }

    override public func avatarURL(for user: ChatUser) -> URL? {
        users[user.id]?.avatarURL ?? user.avatarURL
    }

    // MARK: Display mapping

    private func chatUser(_ user: ApronUser) -> ChatUser {
        ChatUser(id: user.userId, name: user.displayName, avatarURL: user.avatarURL, isSystem: user.isSystem)
    }

    private func chatMessage(_ message: ApronMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            sender: chatUser(message.from),
            timestamp: message.timestamp,
            text: message.body?.text,
            isMarkdown: message.isMarkdown,
            embeds: message.isDeleted ? [] : (message.body?.embeds ?? []).map(chatEmbed),
            replyToId: message.replyTo?.messageId,
            isDeleted: message.isDeleted,
            isOwn: !message.from.isSystem && isOwn(message),
            isNotice: message.messageId == nil,
        )
    }

    /// Image previews come only from allowed media origins; everything else renders as a card (§3.5.2, §4.8).
    private func chatEmbed(_ embed: ApronEmbed) -> ChatEmbed {
        let link = embed.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        if let image = embed.og?.image, let imageURL = allowedMediaURL(image.url) {
            // Uploaded images open in the viewer; a link preview's image opens its page.
            let isUpload = embed.kind == "upload"
            return .image(url: imageURL, aspectRatio: image.aspectRatio, alt: image.alt ?? embed.title, link: isUpload ? nil : link, opensViewer: isUpload)
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
