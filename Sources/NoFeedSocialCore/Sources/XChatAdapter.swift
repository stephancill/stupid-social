import Foundation

/// One X Chat conversation: decrypts its events, pages its history, follows new events from X's chat WebSocket
/// (`XChatLiveFeed`), sends text and reactions, and moves the viewer's read marker as messages are read.
/// Reactions, edits and deletes are events of their own, applied to the messages they name by sequence id.
@MainActor
public final class XChatAdapter: ChatAdapter, ChatReactionSending, ChatLiveUpdating, ChatReferenceResolving {
    public let network = SocialNetwork.x
    public let canReply = false
    public let acceptsAttachments = false
    public let pollInterval: Duration? = nil
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    public let acceptsReactions = true
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false
    /// Replies render from the decrypted reply preview when the original isn't loaded.
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public let unavailableReferences: Set<String> = []

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
    private var hasLoadedHistory = false
    private let liveFeed: XChatLiveFeed
    private var observation: UUID?

    public init(client: XChatClient, liveFeed: XChatLiveFeed, conversationId: String, title: String) {
        self.client = client
        self.liveFeed = liveFeed
        self.conversationId = conversationId
        info = ChatInfo(title: title, subtitle: "X")
    }

    public var key: String {
        "x:\(conversationId)"
    }

    /// Decrypting needs the account's keys, so nothing is cached between visits.
    public func snapshot() -> Data? {
        nil
    }

    public func restore(snapshot _: Data) {}

    // MARK: Loading

    public func loadNewest() async throws {
        let conversation = try await client.conversation(conversationId)
        viewerId = await client.viewerId
        apply(conversation)
        let page = try await client.eventPage(conversationId: conversationId)
        if !hasLoadedHistory {
            hasLoadedHistory = true
            hasEarlierMessages = page.hasMore
        }
        await merge(page.events)
    }

    private func apply(_ conversation: XChatConversationInfo) {
        for person in conversation.others {
            people[person.id] = ChatUser(id: person.id, name: person.name, avatarURL: person.avatarURL)
        }
        if let viewerId {
            people[viewerId] = ChatUser(id: viewerId, name: "You", avatarURL: nil)
            readUntil = max(readUntil, XChatClient.readUntil(conversation.readEvents, userId: viewerId))
        }
        info.showsSenderNames = conversation.isGroup
        if conversation.isGroup {
            info.titleIsMemberNames = true
            info.subtitle = "\(conversation.others.count + 1) members"
        }
    }

    /// Pushed events merge as they arrive; after a reconnect the newest page fills in what the socket missed.
    public func startFollowing() async {
        guard observation == nil else { return }
        observation = liveFeed.observe(
            conversationId: conversationId,
            onEvents: { [weak self] events in Task { await self?.merge(events) } },
            onCatchUp: { [weak self] in Task { await self?.refreshNewest() } },
        )
    }

    public func stopFollowing() {
        observation.map(liveFeed.removeObserver)
        observation = nil
    }

    private func refreshNewest() async {
        guard let page = try? await client.eventPage(conversationId: conversationId) else { return }
        await merge(page.events)
    }

    public func loadEarlier() async throws {
        guard hasEarlierMessages, let oldest = events.values.min(by: { $0.sequence < $1.sequence }) else { return }
        let page = try await client.eventPage(conversationId: conversationId, beforeSequenceId: oldest.sequenceId)
        hasEarlierMessages = page.hasMore && !page.events.isEmpty
        await merge(page.events)
    }

    /// X answers with the stored event, which takes the sending copy's place.
    public func send(_ message: ChatOutgoing) async throws -> String? {
        let event = try await client.sendText(message.text, conversationId: conversationId, token: conversationToken)
        await merge([event])
        return event.sequenceId
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int64(message.id) ?? 0) > readUntil
    }

    /// X keeps one read marker per person, so this moves it to the newest message shown whenever that passes an
    /// unread message from someone else.
    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let sequence = Int64(message.id), sequence > readUntil,
              events.values.contains(where: { $0.senderId != viewerId && $0.sequence > readUntil && $0.sequence <= sequence && $0.messageCreate != nil })
        else { return nil }
        readUntil = sequence
        return { [client, conversationId, sequenceId = message.id] in
            try await client.markRead(upTo: sequenceId, conversationId: conversationId)
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
        referencedMessages = references

        var totals: [String: [ChatReaction]] = [:]
        for (target, reactions) in reactionsByTarget where !reactions.isEmpty {
            totals[target] = Dictionary(grouping: reactions, by: \.emoji)
                .map { emoji, reactions in ChatReaction(emoji: emoji, count: reactions.count, includesYou: reactions.contains { $0.sender == viewerId }) }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        reactions = totals
        messages = chatMessages
        onChange?()
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

    public func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId]?.filter(\.includesYou).map(\.emoji) ?? []
    }

    /// Adds the emoji, or removes it when it's already yours. Shown once X stores the reaction event.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        let remove = yourEmojis(on: messageId).contains(emoji)
        let event = try await client.sendReaction(emoji, on: messageId, remove: remove, conversationId: conversationId, token: conversationToken)
        await merge([event])
    }

    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
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
