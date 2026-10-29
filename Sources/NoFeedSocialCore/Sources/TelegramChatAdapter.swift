import Foundation

/// One Telegram chat: pages its history, refreshes when Telegram pushes an update on the open session (with a
/// slow poll as a fallback), sends text, replies, photos and files, reacts, and moves the read cursor as
/// messages are read. Media, avatars and link previews load lazily through `tgfile:` URLs.
@MainActor
public final class TelegramChatAdapter: ChatAdapter, ChatReactionSending, ChatLiveUpdating, ChatReferenceResolving {
    public let network = SocialNetwork.telegram
    public let canReply = true
    public let acceptsAttachments = true
    /// A fallback to pushed updates; it also re-reads a private chat's "last seen", which ages.
    public let pollInterval: Duration? = .seconds(30)
    public var onChange: (() -> Void)?
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public private(set) var unavailableReferences: Set<String> = []

    private let client: TelegramClient
    public let peer: TelegramPeer
    private var loaded: [Int32: TelegramMessage] = [:]
    private var names: [Int64: String] = [:]
    private var avatars: [Int64: URL] = [:]
    /// Telegram's read cursor for incoming messages, locally ahead while a mark is pending.
    private var readInboxMaxId: Int32 = 0
    private var refreshTask: Task<Void, Never>?
    private var observer: UUID?
    private var statusObserver: UUID?
    /// The other person's last-seen status in a private chat, which the subtitle shows.
    private var userStatus: ChatPresence?
    /// The Chats list's status, which is newer than a snapshot's.
    private let listedStatus: ChatPresence?
    private var hasLoadedHistory = false
    /// Reply targets being fetched, so a refresh doesn't ask for them again.
    private var pendingReferences: Set<Int32> = []

    public init(client: TelegramClient, peer: TelegramPeer, title: String, userStatus: ChatPresence? = nil) {
        self.client = client
        self.peer = peer
        listedStatus = userStatus
        self.userStatus = userStatus
        info = ChatInfo(title: title, subtitle: userStatus?.text ?? "Telegram", showsSenderNames: peer.kind != .user)
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
    }

    public func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        names = snapshot.names
        avatars = snapshot.avatars
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
            title: info.title, subtitle: info.subtitle, userStatus: userStatus,
        ))
    }

    // MARK: Loading

    /// The dialog (title, member count, read cursor, status) and the newest page together.
    public func loadNewest() async throws {
        async let dialog = client.dialogState(peer: peer)
        async let page = client.history(peer: peer)
        let (state, history) = try await (dialog, page)
        // Quoted messages outside the page load before the chat shows, so replies don't wait on them.
        await resolveReferences(in: history)
        apply(state)
        if !hasLoadedHistory {
            hasLoadedHistory = true
            hasEarlierMessages = history.hasMore
        }
        merge(history)
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
        if peer.kind == .user {
            statusObserver = await client.addStatusObserver(userId: peer.id) { [weak self] status in
                Task { @MainActor in self?.apply(status: status) }
            }
        }
    }

    public func stopFollowing() {
        refreshTask?.cancel()
        for id in [observer, statusObserver].compactMap(\.self) {
            Task { [client] in await client.removeUpdateObserver(id) }
        }
        observer = nil
        statusObserver = nil
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
        let replyTo = message.replyToId.flatMap { Int32($0) }
        let id = if let attachment = message.attachment {
            try await client.sendMedia(
                peer: peer,
                data: attachment.data,
                mimeType: attachment.mimeType,
                filename: attachment.filename,
                isImage: attachment.isImage,
                caption: message.text,
                replyTo: replyTo,
            )
        } else {
            try await client.send(peer: peer, text: message.text, replyTo: replyTo)
        }
        if message.attachment == nil, let id {
            loaded[id] = TelegramMessage(id: id, date: Date(), text: message.text, caption: message.text, senderId: nil, isOutgoing: true, replyToId: replyTo, isService: false)
            publish()
        } else {
            scheduleRefresh()
        }
        return id.map(String.init)
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
        for message in found.messages {
            referencedMessages[String(message.id)] = chatMessage(message)
        }
        for id in missing where !found.messages.contains(where: { $0.id == id }) {
            unavailableReferences.insert(String(id))
        }
    }

    // MARK: Display

    private func merge(_ page: TelegramHistoryPage) {
        names.merge(page.names) { $1 }
        avatars.merge(page.avatars) { $1 }
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
        )
    }
}
