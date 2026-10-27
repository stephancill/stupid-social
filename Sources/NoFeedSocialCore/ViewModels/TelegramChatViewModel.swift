import Foundation

/// One Telegram chat: pages its history, refreshes when Telegram pushes an update on the open session (with a
/// slow poll as a fallback), sends text and replies, and moves the read cursor as messages are read.
@MainActor
public final class TelegramChatViewModel: ChatViewModel {
    private let client: TelegramClient
    private let peer: TelegramPeer
    private var loaded: [Int32: TelegramMessage] = [:]
    private var names: [Int64: String] = [:]
    /// Telegram's read cursor for incoming messages, locally ahead while a mark is pending.
    private var readInboxMaxId: Int32 = 0
    private var readSendTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observer: UUID?
    private let pollInterval: Duration = .seconds(30)
    private let snapshotCache: ChatSnapshotCache
    private var hasLoadedHistory = false

    public init(client: TelegramClient, peer: TelegramPeer, title: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache()) {
        self.client = client
        self.peer = peer
        self.snapshotCache = snapshotCache
        super.init(title: title, subtitle: "Telegram", canReply: true)
        showsSenderNames = peer.kind != .user
        restoreSnapshot()
    }

    private struct Snapshot: Codable {
        let messages: [TelegramMessage]
        let names: [Int64: String]
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
        readInboxMaxId = snapshot.readInboxMaxId
        title = snapshot.title
        subtitle = snapshot.subtitle
        publish()
    }

    private func saveSnapshot() {
        let newest = loaded.values.sorted { $0.id < $1.id }.suffix(ChatSnapshotCache.messageLimit)
        snapshotCache.save(Snapshot(messages: Array(newest), names: names, readInboxMaxId: readInboxMaxId, title: title, subtitle: subtitle), key: snapshotKey)
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
            self.state = .connected
            observer = await client.addUpdateObserver { [weak self] _ in
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
        merge(page)
    }

    override public func loadEarlier() async {
        guard let oldest = loaded.keys.min(), !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await client.history(peer: peer, offsetId: oldest)
            hasEarlierMessages = page.hasMore
            merge(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state == .connected else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let replyTo = replyingTo.flatMap { Int32($0.id) }
            let id = try await client.send(peer: peer, text: text, replyTo: replyTo)
            draft = ""
            replyingTo = nil
            if let id {
                loaded[id] = TelegramMessage(id: id, date: Date(), text: text, senderId: nil, isOutgoing: true, replyToId: replyTo, isService: false)
                publish()
            }
            scrollToLatestRequest += 1
        } catch {
            errorMessage = error.localizedDescription
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

    // MARK: Display

    private func merge(_ page: TelegramHistoryPage) {
        names.merge(page.names) { $1 }
        for message in page.messages {
            loaded[message.id] = message
        }
        publish()
    }

    private func publish() {
        let chatMessages = loaded.values.sorted { $0.id < $1.id }.map(chatMessage)
        if messages != chatMessages {
            messages = chatMessages
        }
        updateUnreadCount()
    }

    private func isUnread(_ message: ChatMessage) -> Bool {
        message.isUserMessage && !message.isOwn && (Int32(message.id) ?? 0) > readInboxMaxId
    }

    private func updateUnreadCount() {
        let count = messages.count(where: isUnread)
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
            ChatUser(id: message.senderId.map(String.init) ?? peer.key, name: message.senderId.flatMap { names[$0] } ?? title, avatarURL: nil)
        }
        return ChatMessage(
            id: id,
            sender: sender,
            timestamp: message.date,
            text: message.text,
            replyToId: message.replyToId.map(String.init),
            isOwn: message.isOutgoing,
        )
    }
}
