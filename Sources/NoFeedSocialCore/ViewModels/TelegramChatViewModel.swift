import Foundation

/// One Telegram chat: pages its history, refreshes when Telegram pushes an update on the open session (with a
/// slow poll as a fallback), sends text, replies, photos and files, reacts, and moves the read cursor as
/// messages are read. Media, avatars and link previews load lazily through `tgfile:` URLs.
@MainActor
public final class TelegramChatViewModel: ChatViewModel {
    private let client: TelegramClient
    private let peer: TelegramPeer
    private var loaded: [Int32: TelegramMessage] = [:]
    private var names: [Int64: String] = [:]
    private var avatars: [Int64: URL] = [:]
    /// Telegram's read cursor for incoming messages, locally ahead while a mark is pending.
    private var readInboxMaxId: Int32 = 0
    private var readSendTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observer: UUID?
    private let pollInterval: Duration = .seconds(30)
    private let snapshotCache: ChatSnapshotCache
    private var hasLoadedHistory = false
    /// Reply targets being fetched, so a refresh doesn't ask for them again.
    private var pendingReferences: Set<Int32> = []

    /// The group's members once `loadMembers()` has run; `nil` while loading or for a private chat.
    @Published public private(set) var members: TelegramMemberList?
    @Published public private(set) var membersError: String?

    /// Groups list their members from the title; private chats have none to list.
    public var isGroup: Bool {
        peer.kind != .user
    }

    public init(client: TelegramClient, peer: TelegramPeer, title: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache()) {
        self.client = client
        self.peer = peer
        self.snapshotCache = snapshotCache
        super.init(network: .telegram, title: title, subtitle: "Telegram", canReply: true, offersAttachments: true)
        showsSenderNames = peer.kind != .user
        restoreSnapshot()
    }

    /// Fetches the member list each time it opens, so statuses are current.
    public func loadMembers() async {
        guard isGroup else { return }
        membersError = nil
        do {
            members = try await client.members(peer: peer)
        } catch {
            membersError = Self.membersErrorText(error)
        }
    }

    private static func membersErrorText(_ error: Error) -> String {
        if case let TelegramError.rpc(_, message) = error, message == "CHAT_ADMIN_REQUIRED" {
            return "This group's admins have hidden its member list."
        }
        return error.localizedDescription
    }

    private struct Snapshot: Codable {
        let messages: [TelegramMessage]
        let names: [Int64: String]
        let avatars: [Int64: URL]
        let readInboxMaxId: Int32
        let title: String
        let subtitle: String
    }

    private var snapshotKey: String {
        "telegram:\(peer.key)"
    }

    private func restoreSnapshot() {
        guard let snapshot = snapshotCache.load(Snapshot.self, key: snapshotKey) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        names = snapshot.names
        avatars = snapshot.avatars
        readInboxMaxId = snapshot.readInboxMaxId
        title = snapshot.title
        subtitle = snapshot.subtitle
        // The divider is in the first render, rather than appearing once history arrives.
        firstUnreadMessageId = loaded.values.sorted { $0.id < $1.id }.map(chatMessage).first(where: isUnread)?.id
        publish()
    }

    private func saveSnapshot() {
        let newest = loaded.values.sorted { $0.id < $1.id }.suffix(ChatSnapshotCache.messageLimit)
        snapshotCache.save(
            Snapshot(messages: Array(newest), names: names, avatars: avatars, readInboxMaxId: readInboxMaxId, title: title, subtitle: subtitle),
            key: snapshotKey,
        )
    }

    override public func connect() async {
        guard pollTask == nil else { return }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        do {
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
            if firstUnreadMessageId == nil {
                firstUnreadMessageId = messages.first { isUnread($0) }?.id
            }
            saveSnapshot()
            canAttach = true
            canReact = true
            self.state = .connected
            observer = await client.addUpdateObserver(peer: peer) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            startPolling()
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        if let observer {
            self.observer = nil
            Task { [client] in await client.removeUpdateObserver(observer) }
        }
        saveSnapshot()
    }

    private func apply(_ dialog: TelegramDialogState) {
        title = dialog.title
        if dialog.readInboxMaxId > readInboxMaxId {
            readInboxMaxId = dialog.readInboxMaxId
        }
        subtitle = dialog.memberCount.map { "\($0) members" } ?? "Telegram"
    }

    private func startPolling() {
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                await refreshNewest()
            }
        }
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

    override public func loadEarlier() async {
        guard let oldest = loaded.keys.min(), !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await client.history(peer: peer, offsetId: oldest)
            hasEarlierMessages = page.hasMore
            await resolveReferences(in: page)
            merge(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends optimistically (see `sendOptimistically`): text is added as sent, and media waits for Telegram's
    /// copy (its photo sizes and file reference), which the refresh after sending loads.
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachment
        guard !text.isEmpty || attachment != nil, state == .connected else { return }
        let replyTo = replyingTo.flatMap { Int32($0.id) }
        await sendOptimistically(text: text, attachment: attachment, replyToId: replyTo.map(String.init)) {
            let id = if let attachment {
                try await client.sendMedia(
                    peer: peer,
                    data: attachment.data,
                    mimeType: attachment.mimeType,
                    filename: attachment.filename,
                    isImage: attachment.isImage,
                    caption: text,
                    replyTo: replyTo,
                )
            } else {
                try await client.send(peer: peer, text: text, replyTo: replyTo)
            }
            if attachment == nil, let id {
                loaded[id] = TelegramMessage(id: id, date: Date(), text: text, caption: text, senderId: nil, isOutgoing: true, replyToId: replyTo, isService: false)
                publish()
            } else {
                scheduleRefresh()
            }
            return id.map(String.init)
        }
    }

    /// Moves Telegram's read cursor to the newest message shown, shortly after, when that passes an unread one.
    override public func markRead(upTo message: ChatMessage) {
        guard let id = Int32(message.id), id > readInboxMaxId,
              loaded.values.contains(where: { !$0.isOutgoing && $0.id > readInboxMaxId && $0.id <= id })
        else { return }
        readInboxMaxId = id
        updateUnreadCount()
        readSendTask?.cancel()
        readSendTask = Task { [weak self, client, peer] in
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil, !Task.isCancelled else { return }
            try? await client.markRead(peer: peer, maxId: id)
        }
    }

    // MARK: Reactions

    override public func yourEmojis(on messageId: String) -> [String] {
        guard let id = Int32(messageId) else { return [] }
        return (loaded[id]?.reactions ?? []).filter(\.isMine).map(\.emoji)
    }

    /// Telegram keeps one reaction per person without Premium, so a new emoji replaces yours and your current
    /// one removes it. Shown right away, then replaced by Telegram's totals, or put back if it fails.
    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard canReact, let id = Int32(messageId), let message = loaded[id] else { return }
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
            errorMessage = error.localizedDescription
        }
    }

    private func setReactions(_ totals: [TelegramReaction], reactors: [TelegramReactor], on id: Int32) {
        loaded[id]?.reactions = totals
        loaded[id]?.reactors = reactors
        publish()
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
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
        publish(history: sorted.map(chatMessage), reactions: totals)
        updateUnreadCount()
    }

    private func isUnread(_ message: ChatMessage) -> Bool {
        message.isUserMessage && !message.isOwn && (Int32(message.id) ?? 0) > readInboxMaxId
    }

    private func updateUnreadCount() {
        // `history`, since `messages` may be held back while the chat opens.
        let count = history.count(where: isUnread)
        if unreadCount != count {
            unreadCount = count
        }
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
                name: message.senderId.flatMap { names[$0] } ?? title,
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
        )
    }
}
