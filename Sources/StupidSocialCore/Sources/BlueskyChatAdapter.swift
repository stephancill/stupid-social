import Foundation

/// One Bluesky chat: pages its history, is polled for new messages (the chat service's event log isn't used),
/// sends text, reacts, and moves the read position as messages are read. Bluesky chats have no replies or
/// attachments.
@MainActor
public final class BlueskyChatAdapter: ChatAdapter, ChatReactionSending {
    public let network = SocialNetwork.bluesky
    public let canReply = false
    public let acceptsAttachments = false
    public let pollInterval: Duration? = .seconds(10)
    public var onChange: (() -> Void)?
    public let acceptsReactions = true
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false

    private let client: BlueskyClient
    private let convoId: String
    private var loaded: [String: BlueskyChatMessage] = [:]
    private var cursor: String?
    /// DID → member.
    private var members: [String: ChatUser] = [:]
    private var viewerDid: String?
    /// Where the viewer has read up to, locally ahead of Bluesky while a mark is pending.
    private var readAt: Date?
    /// Whether the chat came from Bluesky this visit; until then the messages are the cached snapshot.
    private var hasLoadedHistory = false

    public init(client: BlueskyClient, convoId: String, title: String) {
        self.client = client
        self.convoId = convoId
        info = ChatInfo(title: title, subtitle: "Bluesky", showsSenderNames: false, titleIsMemberNames: true)
    }

    public var key: String {
        "bluesky:\(convoId)"
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        let messages: [BlueskyChatMessage]
        let members: [String: ChatUser]
        let viewerDid: String?
        let readAt: Date?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
    }

    public func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        members = snapshot.members
        viewerDid = snapshot.viewerDid
        readAt = snapshot.readAt
        info = ChatInfo(title: snapshot.title, subtitle: snapshot.subtitle, showsSenderNames: snapshot.showsSenderNames, titleIsMemberNames: true)
        publish()
    }

    public func snapshot() -> Data? {
        let newest = sortedMessages.suffix(ChatSnapshotCache.messageLimit)
        return try? JSONEncoder().encode(Snapshot(
            messages: Array(newest), members: members, viewerDid: viewerDid, readAt: readAt,
            title: info.title, subtitle: info.subtitle, showsSenderNames: info.showsSenderNames,
        ))
    }

    // MARK: Loading

    /// The first load also reads the chat itself, for its members and unread count; polls only fetch messages.
    public func loadNewest() async throws {
        if !hasLoadedHistory {
            let viewerDid = try await client.viewerDid()
            async let loadingConvo = client.convo(id: convoId)
            let page = try await client.messages(convoId: convoId)
            let convo = try await loadingConvo
            apply(convo: convo, viewerDid: viewerDid)
            if let position = convo.readPosition(messages: page.messages.elements, viewerDid: viewerDid), position > (readAt ?? .distantPast) {
                readAt = position
            }
            cursor = page.cursor
            hasEarlierMessages = cursor != nil
            hasLoadedHistory = true
            merge(page.messages.elements)
            return
        }
        try await merge(client.messages(convoId: convoId).messages.elements)
    }

    private func apply(convo: BlueskyConvo, viewerDid: String) {
        self.viewerDid = viewerDid
        for member in convo.members {
            members[member.did] = ChatUser(id: member.did, name: member.did == viewerDid ? "You" : member.name, avatarURL: member.avatar)
        }
        let others = convo.others(viewerDid: viewerDid)
        info.title = convo.title(viewerDid: viewerDid)
        info.showsSenderNames = convo.isGroup(viewerDid: viewerDid)
        info.subtitle = info.showsSenderNames ? "\(convo.members.count) members" : others.first?.handle.map { "@\($0)" } ?? "Bluesky"
    }

    public func loadEarlier() async throws {
        guard let cursor else { return }
        let page = try await client.messages(convoId: convoId, cursor: cursor)
        self.cursor = page.cursor
        hasEarlierMessages = page.cursor != nil
        merge(page.messages.elements)
    }

    public func send(_ message: ChatOutgoing) async throws -> String? {
        let sent = try await client.sendMessage(convoId: convoId, text: message.text)
        loaded[sent.id] = sent
        publish()
        return sent.id
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (message.timestamp ?? .distantPast) > (readAt ?? .distantPast)
    }

    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let shown = message.timestamp, shown > (readAt ?? .distantPast),
              loaded.values.contains(where: { $0.sender.did != viewerDid && !$0.isDeleted && $0.sentAt > (readAt ?? .distantPast) && $0.sentAt <= shown })
        else { return nil }
        readAt = shown
        return { [client, convoId, messageId = message.id] in
            try await client.markConvoRead(convoId: convoId, messageId: messageId)
        }
    }

    // MARK: Display

    private var sortedMessages: [BlueskyChatMessage] {
        loaded.values.sorted { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }
    }

    private func merge(_ page: [BlueskyChatMessage]) {
        for message in page {
            loaded[message.id] = message
        }
        publish()
    }

    private func publish() {
        let sorted = sortedMessages
        var totals: [String: [ChatReaction]] = [:]
        for message in sorted {
            guard let reactions = message.reactions, !reactions.isEmpty else { continue }
            totals[message.id] = Dictionary(grouping: reactions, by: \.value)
                .map { emoji, reactions in
                    ChatReaction(emoji: emoji, count: reactions.count, includesYou: reactions.contains { $0.sender.did == viewerDid })
                }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        reactions = totals
        messages = sorted.map(chatMessage)
        onChange?()
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        (loaded[messageId]?.reactions ?? []).filter { $0.sender.did == viewerDid }.map(\.value)
    }

    /// Bluesky allows several reactions per person, so this adds or removes just the one emoji. Shown right away,
    /// then replaced by Bluesky's answer, or put back if it fails.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        guard let viewerDid, let message = loaded[messageId] else { return }
        let previous = message.reactions
        let remove = yourEmojis(on: messageId).contains(emoji)
        let mine = BlueskyChatMessage.Reaction(value: emoji, sender: .init(did: viewerDid), createdAt: Date())
        setReactions(remove ? (previous ?? []).filter { !($0.sender.did == viewerDid && $0.value == emoji) } : (previous ?? []) + [mine], on: messageId)
        do {
            let updated = try await client.setReaction(convoId: convoId, messageId: messageId, emoji: emoji, remove: remove)
            setReactions(updated.reactions, on: messageId)
        } catch {
            setReactions(previous, on: messageId)
            throw error
        }
    }

    private func setReactions(_ reactions: [BlueskyChatMessage.Reaction]?, on messageId: String) {
        loaded[messageId]?.reactions = reactions
        publish()
    }

    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (loaded[messageId]?.reactions ?? [])
            .filter { $0.value == emoji }
            .map { ChatReactor(user: person(did: $0.sender.did), date: $0.createdAt, isYou: $0.sender.did == viewerDid) }
    }

    private func person(did: String) -> ChatUser {
        members[did] ?? ChatUser(id: did, name: nil, avatarURL: nil)
    }

    private func chatMessage(_ message: BlueskyChatMessage) -> ChatMessage {
        let isOwn = message.sender.did == viewerDid
        if message.isDeleted {
            return ChatMessage(id: message.id, sender: person(did: message.sender.did), timestamp: message.sentAt, text: nil, isDeleted: true, isOwn: isOwn)
        }
        var embeds: [ChatEmbed] = []
        if let record = message.embed?.record {
            embeds.append(postEmbed(record))
        }
        return ChatMessage(
            id: message.id,
            sender: person(did: message.sender.did),
            timestamp: message.sentAt,
            text: message.text.flatMap { $0.isEmpty ? nil : $0 },
            embeds: embeds,
            isOwn: isOwn,
        )
    }

    /// A shared post as a card that opens it on bsky.app; one that's gone or blocked as a plain card.
    private func postEmbed(_ record: BlueskyChatMessage.Embed.Record) -> ChatEmbed {
        guard record.type == "app.bsky.embed.record#viewRecord" else {
            return .card(title: "Post unavailable", subtitle: nil, systemImage: "text.bubble", imageURL: nil, link: nil)
        }
        let text = record.value?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = record.author.flatMap { $0.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? $0.handle }
        return .card(
            title: text.flatMap { $0.isEmpty ? nil : $0 } ?? author.map { "Post by \($0)" } ?? "Post",
            subtitle: text?.isEmpty == false ? author : nil,
            systemImage: "text.bubble",
            imageURL: record.author?.avatar,
            link: record.postURL,
        )
    }
}
