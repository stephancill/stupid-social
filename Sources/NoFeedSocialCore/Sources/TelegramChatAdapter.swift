import Foundation

/// One Telegram chat: pages its history, refreshes when Telegram pushes an update on the open session (with a
/// slow poll as a fallback), sends text, replies, photos and files, reacts, and moves the read cursor as
/// messages are read. Media, avatars and link previews load lazily through `tgfile:` URLs. In groups it offers
/// members to mention: `@username`, or for someone without one a name mention. Shows who is typing and shares
/// the user's own typing.
@MainActor
public final class TelegramChatAdapter: ChatAdapter, ChatReactionSending, ChatUnseenReactions, ChatLiveUpdating, ChatReferenceResolving, ChatMentioning, ChatTyping {
    public let network = SocialNetwork.telegram
    public let canReply = true
    public let acceptsAttachments = true
    /// A fallback to pushed updates; it also re-reads a private chat's "last seen", which ages.
    public let pollInterval: Duration? = .seconds(30)
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    public let acceptsReactions = true
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public private(set) var unavailableReferences: Set<String> = []
    public private(set) var unseenReactionMessageIds: [String] = []
    public private(set) var typingNames: [String] = []

    private let client: TelegramClient
    public let peer: TelegramPeer
    private var loaded: [Int32: TelegramMessage] = [:]
    private var names: [Int64: String] = [:]
    private var avatars: [Int64: URL] = [:]
    /// Lowercased username → user id, so `@username` mentions open the user's profile without looking them up.
    private var usernames: [String: Int64] = [:]
    /// A group's members, offered while typing `@`; loaded once with the chat.
    private var members: [TelegramMember] = []
    private var hasLoadedMembers = false
    /// Telegram's read cursor for incoming messages, locally ahead while a mark is pending.
    private var readInboxMaxId: Int32 = 0
    private var refreshTask: Task<Void, Never>?
    private var observer: UUID?
    private var statusObserver: UUID?
    private var reactionObserver: UUID?
    private var typingObserver: UUID?
    /// Who is typing, in the order they started, and when each indication lapses.
    private var typingUsers: [(userId: Int64, expires: Date)] = []
    private var typingExpiryTask: Task<Void, Never>?
    /// When the user's own typing was last sent; Telegram's apps repeat it every 5 seconds while typing goes on.
    private var typingSentAt: Date?
    /// The user's messages Telegram says have unseen reactions, including ones that aren't loaded.
    private var unreadReactionIds: Set<Int32> = []
    /// Seen here this visit, so they stay seen while Telegram catches up; `pendingSeen` hasn't been sent yet.
    private var seenReactionIds: Set<Int32> = []
    private var pendingSeen: Set<Int32> = []
    /// The other person's last-seen status in a private chat, which the subtitle shows.
    private var userStatus: ChatPresence?
    /// The Chats list's status, which is newer than a snapshot's.
    private let listedStatus: ChatPresence?
    private var hasLoadedHistory = false
    /// Reply targets being fetched, so a refresh doesn't ask for them again.
    private var pendingReferences: Set<Int32> = []

    /// `avatarURL` is the chat's picture from its Chats row, shown beside a private chat's title.
    public init(client: TelegramClient, peer: TelegramPeer, title: String, userStatus: ChatPresence? = nil, avatarURL: URL? = nil) {
        self.client = client
        self.peer = peer
        listedStatus = userStatus
        self.userStatus = userStatus
        info = ChatInfo(title: title, subtitle: userStatus?.text ?? "Telegram", showsSenderNames: peer.kind != .user)
        if peer.kind == .user {
            // The id the person's messages carry, so the initials match their bubbles' color.
            info.avatarUserId = String(peer.id)
            info.avatarURL = avatarURL
        }
    }

    public var key: String {
        "telegram:\(peer.key)"
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        let messages: [TelegramMessage]
        let names: [Int64: String]
        let avatars: [Int64: URL]
        let readInboxMaxId: Int32
        let title: String
        let subtitle: String
        /// Saved so a private chat's "last seen" shows, freshly worded, as it opens.
        var userStatus: ChatPresence?
        var usernames: [String: Int64]?
    }

    public func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        names = snapshot.names
        avatars = snapshot.avatars
        usernames = snapshot.usernames ?? [:]
        readInboxMaxId = snapshot.readInboxMaxId
        userStatus = listedStatus ?? snapshot.userStatus
        info.title = snapshot.title
        info.subtitle = userStatus?.text ?? snapshot.subtitle
        publish()
    }

    public func snapshot() -> Data? {
        let newest = loaded.values.sorted { $0.id < $1.id }.suffix(ChatSnapshotCache.messageLimit)
        return try? JSONEncoder().encode(Snapshot(
            messages: Array(newest), names: names, avatars: avatars, readInboxMaxId: readInboxMaxId,
            title: info.title, subtitle: info.subtitle, userStatus: userStatus, usernames: usernames,
        ))
    }

    // MARK: Loading

    /// The dialog (title, member count, read cursor, status) and the newest page together.
    public func loadNewest() async throws {
        async let dialog = client.dialogState(peer: peer)
        async let page = client.history(peer: peer)
        let (state, history) = try await (dialog, page)
        // Telegram counts them with the dialog, so they're listed only when there are some.
        unreadReactionIds = await state.unreadReactionsCount > 0 ? Set((try? client.unreadReactionMessageIds(peer: peer)) ?? []) : []
        // Quoted messages outside the page load before the chat shows, so replies don't wait on them.
        await resolveReferences(in: history)
        apply(state)
        if !hasLoadedHistory {
            hasLoadedHistory = true
            hasEarlierMessages = history.hasMore
        }
        merge(history)
        await loadMembersIfNeeded()
    }

    /// Who can be mentioned; a group that hides its members just offers none.
    private func loadMembersIfNeeded() async {
        guard peer.kind != .user, !hasLoadedMembers else { return }
        hasLoadedMembers = true
        guard let list = try? await client.members(peer: peer) else { return }
        members = list.members
        for member in list.members {
            if let username = member.username {
                usernames[username.lowercased()] = member.id
            }
            avatars[member.id] = avatars[member.id] ?? member.avatarURL
        }
        publish()
    }

    private func apply(_ dialog: TelegramDialogState) {
        info.title = dialog.title
        if dialog.readInboxMaxId > readInboxMaxId {
            readInboxMaxId = dialog.readInboxMaxId
        }
        userStatus = dialog.userStatus
        info.subtitle = dialog.memberCount.map { "\($0) members" } ?? userStatus?.text ?? "Telegram"
    }

    public func startFollowing() async {
        guard observer == nil else { return }
        observer = await client.addUpdateObserver(peer: peer) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        reactionObserver = await client.addReactionObserver(peer: peer) { [weak self] in
            Task { @MainActor in await self?.refreshUnseenReactions() }
        }
        typingObserver = await client.addTypingObserver(peer: peer) { [weak self] userId, isTyping in
            Task { @MainActor in self?.setTyping(userId: userId, isTyping: isTyping) }
        }
        if peer.kind == .user {
            statusObserver = await client.addStatusObserver(userId: peer.id) { [weak self] status in
                Task { @MainActor in self?.apply(status: status) }
            }
        }
    }

    public func stopFollowing() {
        refreshTask?.cancel()
        for id in [observer, statusObserver, reactionObserver, typingObserver].compactMap(\.self) {
            Task { [client] in await client.removeUpdateObserver(id) }
        }
        observer = nil
        statusObserver = nil
        reactionObserver = nil
        typingObserver = nil
        typingUsers = []
        if updateTypingNames() {
            onChange?()
        }
    }

    private func apply(status: ChatPresence) {
        userStatus = status
        info.subtitle = status.text
        onChange?()
    }

    /// Updates arrive in bursts (the message, then read and typing updates), so one refresh follows each burst.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await refreshNewest()
        }
    }

    private func refreshNewest() async {
        guard let page = try? await client.history(peer: peer, limit: 30) else { return }
        await resolveReferences(in: page)
        merge(page)
    }

    public func loadEarlier() async throws {
        guard let oldest = loaded.keys.min() else { return }
        let page = try await client.history(peer: peer, offsetId: oldest)
        hasEarlierMessages = page.hasMore
        await resolveReferences(in: page)
        merge(page)
    }

    /// Text is added as sent; media waits for Telegram's copy (its photo sizes and file reference), which the
    /// refresh after sending loads.
    public func send(_ message: ChatOutgoing) async throws -> String? {
        // Telegram's apps end the sender's typing when the message arrives.
        typingSentAt = nil
        let replyTo = message.replyToId.flatMap { Int32($0) }
        let (text, mentions) = Self.resolvingMentions(in: message.text, names: Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        let id = if let attachment = message.attachment {
            try await client.sendMedia(
                peer: peer,
                data: attachment.data,
                mimeType: attachment.mimeType,
                filename: attachment.filename,
                isImage: attachment.isImage,
                caption: text,
                mentions: mentions,
                replyTo: replyTo,
            )
        } else {
            try await client.send(peer: peer, text: text, mentions: mentions, replyTo: replyTo)
        }
        if message.attachment == nil, let id {
            loaded[id] = TelegramMessage(id: id, date: Date(), text: text, caption: text, mentions: mentions.isEmpty ? nil : mentions, senderId: nil, isOutgoing: true, replyToId: replyTo, isService: false)
            publish()
        } else {
            scheduleRefresh()
        }
        return id.map(String.init)
    }

    /// The draft with each `@<user id>` the composer put in for someone without a username replaced by their
    /// name, and the name mentions that go with it. Usernames can't start with a digit, so these can't be one;
    /// ids of people not in `names` stay as typed.
    nonisolated static func resolvingMentions(in text: String, names: [Int64: String]) -> (text: String, mentions: [TelegramMention]) {
        let source = text as NSString
        let output = NSMutableString()
        var mentions: [TelegramMention] = []
        var cursor = 0
        for match in idMentionPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let id = Int64(source.substring(with: match.range(at: 1))), let name = names[id] else { continue }
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            mentions.append(TelegramMention(offset: output.length, length: (name as NSString).length, userId: id, username: nil))
            output.append(name)
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        return (output as String, mentions)
    }

    private nonisolated static let idMentionPattern = try! NSRegularExpression(pattern: #"(?<![\w@])@([0-9]+)(?!\w)"#)

    // MARK: Mentions

    /// Mentions are marked by position (`ChatMessage.mentions`), not written as `@user_id`.
    public var mentionPattern: NSRegularExpression? {
        nil
    }

    public var mentionNames: [String: String] {
        [:]
    }

    /// Members whose name or username starts with the query, then whose name has a word that does; online ones
    /// first for a bare `@`. Each is inserted as `@username`, or `@<user id>` for someone without one, which
    /// sending turns into their name.
    public func mentionSuggestions(for query: String) -> [ChatUser] {
        let query = query.lowercased()
        func rank(_ member: TelegramMember) -> Int? {
            if query.isEmpty { return member.status == .online ? 0 : 1 }
            let name = member.name.lowercased()
            if name.hasPrefix(query) || member.username?.lowercased().hasPrefix(query) == true { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
            return nil
        }
        return members
            .filter { !$0.isYou }
            .compactMap { member in rank(member).map { (member, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { member, _ in ChatUser(id: member.username ?? String(member.id), name: member.name, avatarURL: member.avatarURL) }
    }

    // MARK: Typing

    private func setTyping(userId: Int64, isTyping: Bool) {
        if !isTyping {
            typingUsers.removeAll { $0.userId == userId }
        } else if let index = typingUsers.firstIndex(where: { $0.userId == userId }) {
            typingUsers[index].expires = Date().addingTimeInterval(6)
        } else {
            typingUsers.append((userId, Date().addingTimeInterval(6)))
        }
        if updateTypingNames() {
            onChange?()
        }
    }

    /// Drops lapsed indications, wakes again at the next one, and says whether the names changed.
    private func updateTypingNames() -> Bool {
        let now = Date()
        typingUsers.removeAll { $0.expires <= now }
        typingExpiryTask?.cancel()
        if let next = typingUsers.map(\.expires).min() {
            typingExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05))
                guard !Task.isCancelled, let self else { return }
                if updateTypingNames() {
                    onChange?()
                }
            }
        }
        let names = typingUsers.map { typingName(of: $0.userId) }
        guard names != typingNames else { return false }
        typingNames = names
        return true
    }

    private func typingName(of userId: Int64) -> String {
        if peer.kind == .user {
            return info.title
        }
        return names[userId] ?? members.first { $0.id == userId }?.name ?? "Someone"
    }

    /// Repeats the indication every 5 seconds while the draft changes, so it lapses 6 seconds after the last
    /// edit; clearing the draft ends it now.
    public func draftDidChange(_ draft: String) {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            guard let sentAt = typingSentAt, Date().timeIntervalSince(sentAt) < 6 else { return }
            typingSentAt = nil
            Task { [client, peer] in try? await client.setTyping(peer: peer, isTyping: false) }
            return
        }
        if let typingSentAt, Date().timeIntervalSince(typingSentAt) < 5 { return }
        typingSentAt = Date()
        Task { [client, peer] in try? await client.setTyping(peer: peer, isTyping: true) }
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int32(message.id) ?? 0) > readInboxMaxId
    }

    /// Moves Telegram's read cursor to the newest message shown when that passes an unread one.
    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let id = Int32(message.id), id > readInboxMaxId,
              loaded.values.contains(where: { !$0.isOutgoing && $0.id > readInboxMaxId && $0.id <= id })
        else { return nil }
        readInboxMaxId = id
        return { [client, peer] in try await client.markRead(peer: peer, maxId: id) }
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        guard let id = Int32(messageId) else { return [] }
        return (loaded[id]?.reactions ?? []).filter(\.isMine).map(\.emoji)
    }

    /// Telegram keeps one reaction per person without Premium, so a new emoji replaces yours and your current
    /// one removes it. Shown right away, then replaced by Telegram's totals, or put back if it fails.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        guard let id = Int32(messageId), let message = loaded[id] else { return }
        let previous = (message.reactions, message.reactors)
        let removing = message.reactions.contains { $0.isMine && $0.emoji == emoji }
        var totals = message.reactions.compactMap { reaction -> TelegramReaction? in
            guard reaction.isMine else { return reaction }
            return reaction.count > 1 ? TelegramReaction(emoji: reaction.emoji, count: reaction.count - 1, isMine: false) : nil
        }
        if !removing {
            if let index = totals.firstIndex(where: { $0.emoji == emoji }) {
                totals[index] = TelegramReaction(emoji: emoji, count: totals[index].count + 1, isMine: true)
            } else {
                totals.append(TelegramReaction(emoji: emoji, count: 1, isMine: true))
            }
        }
        setReactions(totals, reactors: message.reactors.filter { !$0.isMine }, on: id)
        do {
            if let updated = try await client.setReaction(peer: peer, messageId: id, emoji: removing ? nil : emoji) {
                setReactions(updated.totals, reactors: updated.reactors, on: id)
            }
        } catch {
            setReactions(previous.0, reactors: previous.1, on: id)
            throw error
        }
    }

    /// A reaction changed on one of the chat's messages, which may be an older one than the refresh loads.
    private func refreshUnseenReactions() async {
        guard let ids = try? await client.unreadReactionMessageIds(peer: peer) else { return }
        unreadReactionIds = Set(ids)
        scheduleRefresh()
    }

    /// Telegram marks reactions seen per message, as its apps do when the messages show.
    public func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)? {
        let ids = Set(messageIds.compactMap { Int32($0) })
        seenReactionIds.formUnion(ids)
        pendingSeen.formUnion(ids)
        publish()
        return { [weak self] in
            guard let self, !pendingSeen.isEmpty else { return }
            let sending = pendingSeen
            try await client.markReactionsSeen(peer: peer, messageIds: sending.sorted())
            pendingSeen.subtract(sending)
        }
    }

    private func setReactions(_ totals: [TelegramReaction], reactors: [TelegramReactor], on id: Int32) {
        loaded[id]?.reactions = totals
        loaded[id]?.reactors = reactors
        publish()
    }

    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        guard let id = Int32(messageId) else { return [] }
        return (loaded[id]?.reactors ?? []).filter { $0.emoji == emoji }.map { reactor in
            ChatReactor(
                user: reactor.isMine ? ChatUser(id: "you", name: "You", avatarURL: nil) : ChatUser(id: String(reactor.peerId), name: names[reactor.peerId], avatarURL: avatars[reactor.peerId]),
                date: nil,
                isYou: reactor.isMine,
            )
        }
    }

    /// Fetches, in one call, the messages replies in `page` quote that are neither in it nor loaded; ones
    /// Telegram doesn't return (deleted, or in another chat) show as unavailable.
    private func resolveReferences(in page: TelegramHistoryPage) async {
        let inPage = Set(page.messages.map(\.id))
        let missing = Set(page.messages.compactMap(\.replyToId)).filter { id in
            !inPage.contains(id) && loaded[id] == nil && !pendingReferences.contains(id)
                && referencedMessages[String(id)] == nil && !unavailableReferences.contains(String(id))
        }
        guard !missing.isEmpty else { return }
        pendingReferences.formUnion(missing)
        defer { pendingReferences.subtract(missing) }
        guard let found = try? await client.messages(peer: peer, ids: Array(missing)) else { return }
        names.merge(found.names) { $1 }
        avatars.merge(found.avatars) { $1 }
        usernames.merge(found.usernames) { $1 }
        for message in found.messages {
            referencedMessages[String(message.id)] = chatMessage(message)
        }
        for id in missing where !found.messages.contains(where: { $0.id == id }) {
            unavailableReferences.insert(String(id))
        }
    }

    // MARK: Display

    private func merge(_ page: TelegramHistoryPage) {
        // A new message from someone typing ends their indication.
        let senders = Set(page.messages.filter { loaded[$0.id] == nil && !$0.isOutgoing }.compactMap { $0.senderId ?? (peer.kind == .user ? peer.id : nil) })
        if typingUsers.contains(where: { senders.contains($0.userId) }) {
            typingUsers.removeAll { senders.contains($0.userId) }
            _ = updateTypingNames()
        }
        names.merge(page.names) { $1 }
        avatars.merge(page.avatars) { $1 }
        usernames.merge(page.usernames) { $1 }
        for message in page.messages {
            loaded[message.id] = message
        }
        publish()
    }

    private func publish() {
        let sorted = loaded.values.sorted { $0.id < $1.id }
        var totals: [String: [ChatReaction]] = [:]
        for message in sorted where !message.reactions.isEmpty {
            totals[String(message.id)] = message.reactions
                .map { ChatReaction(emoji: $0.emoji, count: $0.count, includesYou: $0.isMine) }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        reactions = totals
        // Telegram's list, and loaded messages whose recent reactions say so, which arrive with a refresh.
        let flagged = sorted.filter { $0.isOutgoing && $0.reactors.contains(where: \.isUnread) }.map(\.id)
        unseenReactionMessageIds = unreadReactionIds.union(flagged).subtracting(seenReactionIds).sorted().map(String.init)
        messages = sorted.map(chatMessage)
        onChange?()
    }

    private func chatMessage(_ message: TelegramMessage) -> ChatMessage {
        let id = String(message.id)
        if message.isService {
            return ChatMessage(
                id: id,
                sender: ChatUser(id: "telegram", name: "Telegram", avatarURL: nil, isSystem: true),
                timestamp: message.date,
                text: message.text,
                isOwn: false,
            )
        }
        let sender = if message.isOutgoing {
            ChatUser(id: "you", name: "You", avatarURL: nil)
        } else {
            ChatUser(
                id: message.senderId.map(String.init) ?? peer.key,
                name: message.senderId.flatMap { names[$0] } ?? info.title,
                avatarURL: (message.senderId ?? (peer.kind == .user ? peer.id : nil)).flatMap { avatars[$0] },
            )
        }
        let embeds: [ChatEmbed] = message.embeds.map { embed in
            switch embed {
            case let .image(url, aspectRatio):
                .image(url: url, aspectRatio: aspectRatio, alt: nil, link: nil, opensViewer: true)
            case let .card(title, subtitle, systemImage, imageURL, link):
                .card(title: title, subtitle: subtitle, systemImage: systemImage, imageURL: imageURL, link: link)
            }
        }
        // Media without a caption shows only the media; media the app can't draw shows its label.
        let text: String? = if !message.caption.isEmpty {
            message.caption
        } else if embeds.isEmpty {
            message.text
        } else {
            nil
        }
        return ChatMessage(
            id: id,
            sender: sender,
            timestamp: message.date,
            text: text,
            embeds: embeds,
            replyToId: message.replyToId.map(String.init),
            isOwn: message.isOutgoing,
            spoilers: text == message.caption ? message.spoilers ?? [] : [],
            mentions: text == message.caption ? (message.mentions ?? []).map(chatMention) : [],
        )
    }

    /// A mention opens its user's profile: by id, or by `@username` when that user isn't loaded.
    private func chatMention(_ mention: TelegramMention) -> ChatMessageMention {
        let userId = mention.userId ?? mention.username.flatMap { usernames[$0.lowercased()] }
        return ChatMessageMention(range: mention.range, userId: userId.map(String.init) ?? "@\(mention.username ?? "")")
    }
}
