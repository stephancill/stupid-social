import Foundation

/// One X Chat conversation: decrypts its events, pages its history, follows new events from X's chat WebSocket
/// (`XChatLiveFeed`), sends text and reactions, and moves the viewer's read marker as messages are read. Reactions, edits and deletes are events of their own, applied to the messages
/// they name by sequence id.
@MainActor
public final class XChatViewModel: ChatViewModel {
    private let client: XChatClient
    private let conversationId: String
    /// Every loaded event by sequence id, with what its message decrypted to (nil when it didn't).
    private var events: [String: XChatEvent] = [:]
    private var entries: [String: XChatEntry?] = [:]
    private var people: [String: ChatUser] = [:]
    private var viewerId: String?
    private var conversationToken: String?
    /// The viewer's read marker, locally ahead of X while a mark is pending.
    private var readUntil: Int64 = 0
    private var hasMoreEarlier = false
    private var hasLoadedHistory = false
    private var readSendTask: Task<Void, Never>?
    private let liveFeed: XChatLiveFeed
    private var observation: UUID?

    public init(client: XChatClient, liveFeed: XChatLiveFeed, conversationId: String, title: String) {
        self.client = client
        self.liveFeed = liveFeed
        self.conversationId = conversationId
        super.init(title: title, subtitle: "X", canReply: false)
    }

    override public func connect() async {
        guard observation == nil else { return }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        do {
            let conversation = try await client.conversation(conversationId)
            viewerId = await client.viewerId
            apply(conversation)
            let page = try await client.eventPage(conversationId: conversationId)
            if !hasLoadedHistory {
                hasLoadedHistory = true
                hasMoreEarlier = page.hasMore
                hasEarlierMessages = page.hasMore
            }
            await merge(page.events)
            if firstUnreadMessageId == nil {
                firstUnreadMessageId = messages.first { isUnread($0) }?.id
            }
            canReact = true
            state = .connected
            follow()
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        observation.map(liveFeed.removeObserver)
        observation = nil
    }

    private func apply(_ conversation: XChatConversationInfo) {
        for person in conversation.others {
            people[person.id] = ChatUser(id: person.id, name: person.name, avatarURL: person.avatarURL)
        }
        if let viewerId {
            people[viewerId] = ChatUser(id: viewerId, name: "You", avatarURL: nil)
            readUntil = max(readUntil, XChatClient.readUntil(conversation.readEvents, userId: viewerId))
        }
        showsSenderNames = conversation.isGroup
        if conversation.isGroup {
            titleIsMemberNames = true
            subtitle = "\(conversation.others.count + 1) members"
        }
    }

    /// Pushed events merge as they arrive; after a reconnect the newest page fills in what the socket missed.
    private func follow() {
        observation = liveFeed.observe(
            conversationId: conversationId,
            onEvents: { [weak self] events in Task { await self?.merge(events) } },
            onCatchUp: { [weak self] in Task { await self?.refreshNewest() } },
        )
    }

    private func refreshNewest() async {
        guard let page = try? await client.eventPage(conversationId: conversationId) else { return }
        await merge(page.events)
    }

    override public func loadEarlier() async {
        guard hasMoreEarlier, !isLoadingEarlier, let oldest = events.values.min(by: { $0.sequence < $1.sequence }) else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await client.eventPage(conversationId: conversationId, beforeSequenceId: oldest.sequenceId)
            hasMoreEarlier = page.hasMore && !page.events.isEmpty
            hasEarlierMessages = hasMoreEarlier
            await merge(page.events)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends optimistically (see `sendOptimistically`); X answers with the stored event, which takes its place.
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state == .connected else { return }
        await sendOptimistically(text: text, attachment: nil, replyToId: nil) {
            let event = try await client.sendText(text, conversationId: conversationId, token: conversationToken)
            await merge([event])
            return event.sequenceId
        }
    }

    /// X keeps one read marker per person, so this moves it to the newest message shown, shortly after, whenever
    /// that passes an unread message from someone else.
    override public func markRead(upTo message: ChatMessage) {
        guard let sequence = Int64(message.id), sequence > readUntil,
              events.values.contains(where: { $0.senderId != viewerId && $0.sequence > readUntil && $0.sequence <= sequence && $0.messageCreate != nil })
        else { return }
        readUntil = sequence
        updateUnreadCount()
        readSendTask?.cancel()
        readSendTask = Task { [weak self, client, conversationId, sequenceId = message.id] in
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil, !Task.isCancelled else { return }
            try? await client.markRead(upTo: sequenceId, conversationId: conversationId)
        }
    }

    // MARK: Display

    private func merge(_ page: [XChatEvent]) async {
        for event in page where events[event.sequenceId] == nil {
            events[event.sequenceId] = event
            if event.messageCreate != nil {
                let entry = try? await client.decrypt(event)
                // `.some(nil)` keeps a message that didn't decrypt, where assigning nil would drop it.
                entries[event.sequenceId] = .some(entry)
            }
            if let token = event.conversationToken {
                conversationToken = token
            }
            if event.senderId == viewerId, let read = event.readUntil {
                readUntil = max(readUntil, read)
            }
        }
        publish()
    }

    private func publish() {
        let sorted = events.values.sorted { $0.sequence < $1.sequence }
        var edits: [String: String] = [:]
        var deleted: Set<String> = []
        // Target sequence id → (sender, emoji) pairs, applied in order so a removal undoes an earlier add.
        var reactionsByTarget: [String: [(sender: String, emoji: String)]] = [:]
        for event in sorted {
            deleted.formUnion(event.deletedSequenceIds)
            guard event.messageCreate != nil, case let .some(.some(entry)) = entries[event.sequenceId] else { continue }
            switch entry {
            case let .edit(target, text):
                edits[target] = text
            case let .reaction(target, emoji, added):
                var reactions = reactionsByTarget[target] ?? []
                reactions.removeAll { $0.sender == event.senderId && $0.emoji == emoji }
                if added {
                    reactions.append((event.senderId, emoji))
                }
                reactionsByTarget[target] = reactions
            case .message, .other:
                break
            }
        }

        var chatMessages: [ChatMessage] = []
        var references: [String: ChatMessage] = [:]
        for event in sorted where event.messageCreate != nil {
            let isOwn = event.senderId == viewerId
            switch entries[event.sequenceId] {
            case let .some(.some(.message(contents))):
                if let reply = contents.reply, let id = reply.sequenceId, events[id] == nil {
                    references[id] = ChatMessage(
                        id: id,
                        sender: ChatUser(id: "", name: reply.senderName ?? "Someone", avatarURL: nil),
                        timestamp: nil,
                        text: reply.text,
                        isOwn: false,
                    )
                }
                chatMessages.append(ChatMessage(
                    id: event.sequenceId,
                    sender: person(event.senderId),
                    timestamp: event.createdAt,
                    text: deleted.contains(event.sequenceId) ? nil : edits[event.sequenceId] ?? contents.text,
                    embeds: deleted.contains(event.sequenceId) ? [] : contents.attachments.map(embed),
                    replyToId: contents.reply?.sequenceId,
                    isDeleted: deleted.contains(event.sequenceId),
                    isOwn: isOwn,
                ))
            case .some(.none):
                // Shown rather than hidden, so a message is never silently missing.
                chatMessages.append(ChatMessage(
                    id: event.sequenceId,
                    sender: person(event.senderId),
                    timestamp: event.createdAt,
                    text: "Couldn't decrypt this message.",
                    isOwn: isOwn,
                ))
            default:
                continue
            }
        }
        if history != chatMessages {
            history = chatMessages
        }
        if referencedMessages != references {
            referencedMessages = references
        }

        var totals: [String: [ChatReaction]] = [:]
        for (target, reactions) in reactionsByTarget where !reactions.isEmpty {
            totals[target] = Dictionary(grouping: reactions, by: \.emoji)
                .map { emoji, reactions in ChatReaction(emoji: emoji, count: reactions.count, includesYou: reactions.contains { $0.sender == viewerId }) }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        if reactions != totals {
            reactions = totals
        }
        updateUnreadCount()
    }

    private func isUnread(_ message: ChatMessage) -> Bool {
        message.isUserMessage && !message.isOwn && (Int64(message.id) ?? 0) > readUntil
    }

    private func updateUnreadCount() {
        let count = messages.count(where: isUnread)
        if unreadCount != count {
            unreadCount = count
        }
    }

    private func person(_ id: String) -> ChatUser {
        people[id] ?? ChatUser(id: id, name: nil, avatarURL: nil)
    }

    private func embed(_ attachment: XChatMessageContents.Attachment) -> ChatEmbed {
        switch attachment {
        case let .media(filename, legacyURL, aspectRatio):
            if let legacyURL {
                return .image(url: legacyURL, aspectRatio: aspectRatio, alt: nil, link: nil, opensViewer: true)
            }
            // New media is encrypted with its own stream key, which the app doesn't decrypt yet.
            return .card(title: filename ?? "Photo", subtitle: "Open in X", systemImage: "photo", imageURL: nil, link: chatURL)
        case let .post(url):
            return .card(title: "Post", subtitle: url?.host(), systemImage: "text.bubble", imageURL: nil, link: url)
        case let .link(url, title):
            return .card(title: title ?? url?.absoluteString ?? "Link", subtitle: title == nil ? nil : url?.host(), systemImage: "link", imageURL: nil, link: url)
        }
    }

    private var chatURL: URL? {
        URL(string: "https://x.com/i/chat/\(conversationId)")
    }

    // MARK: Reactions

    override public func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId]?.filter(\.includesYou).map(\.emoji) ?? []
    }

    /// Adds the emoji, or removes it when it's already yours. Shown once X stores the reaction event.
    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard canReact else { return }
        let remove = yourEmojis(on: messageId).contains(emoji)
        do {
            let event = try await client.sendReaction(emoji, on: messageId, remove: remove, conversationId: conversationId, token: conversationToken)
            await merge([event])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        var current: [String: XChatEvent] = [:]
        for event in events.values.sorted(by: { $0.sequence < $1.sequence }) {
            guard case let .some(.some(.reaction(target, reactionEmoji, added))) = entries[event.sequenceId], target == messageId, reactionEmoji == emoji else { continue }
            if added {
                current[event.senderId] = event
            } else {
                current.removeValue(forKey: event.senderId)
            }
        }
        return current.map { sender, event in ChatReactor(user: person(sender), date: event.createdAt, isYou: sender == viewerId) }
    }
}
