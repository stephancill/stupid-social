import Foundation

/// One LinkedIn conversation: pages its history, follows the account's realtime stream (`LinkedInLiveFeed`) for
/// new and changed messages, reactions, typing and read state, sends text and replies, reacts, edits and unsends
/// the user's messages, shows typing both ways, and marks the conversation read. LinkedIn keeps read state per
/// conversation, so it is marked read only once the newest message from someone else has been seen.
@MainActor
public final class LinkedInChatAdapter: ChatAdapter, ChatReactionSending, ChatEditing, ChatDeleting, ChatTyping, ChatReferenceResolving, ChatLiveUpdating {
    public let network = ChatNetwork.linkedin
    public let canReply = true
    public let acceptsAttachments = false
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onCatchUp: (() -> Void)?
    public let acceptsReactions = true
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public let unavailableReferences: Set<String> = []

    private let client: LinkedInClient
    private let conversationUrn: String
    private var loaded: [String: LinkedInMessage] = [:]
    /// Host identity urn → person.
    private var members: [String: ChatUser] = [:]
    private var viewerUrn: String?
    /// Where the viewer has read up to, locally ahead of LinkedIn while a mark is pending.
    private var readAt: Date?
    /// Whether the chat came from LinkedIn this visit; until then the messages are the cached snapshot.
    private var hasLoadedHistory = false
    private var lastTypingSent: Date?
    private let liveFeed: LinkedInLiveFeed?
    private var observation: UUID?
    /// Host identity urn → name and when their typing indication ends.
    private var typing: [String: (name: String, until: Date)] = [:]
    private var typingExpiry: Task<Void, Never>?

    public init(client: LinkedInClient, conversationUrn: String, title: String, liveFeed: LinkedInLiveFeed? = nil) {
        self.client = client
        self.conversationUrn = conversationUrn
        self.liveFeed = liveFeed
        info = ChatInfo(title: title, subtitle: "", showsSenderNames: false, titleIsMemberNames: true)
    }

    /// The stream pushes changes; a slow poll covers anything it misses. Without it, a quicker one.
    public var pollInterval: Duration? {
        liveFeed == nil ? .seconds(10) : .seconds(60)
    }

    public var key: String {
        "linkedin:\(conversationUrn)"
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        let messages: [LinkedInMessage]
        let members: [String: ChatUser]
        let viewerUrn: String?
        let readAt: Date?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
        let titleIsMemberNames: Bool
        let avatarUserId: String?
        let avatarURL: URL?
    }

    public func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for message in snapshot.messages {
            loaded[message.entityUrn] = message
        }
        members = snapshot.members
        viewerUrn = snapshot.viewerUrn
        readAt = snapshot.readAt
        info = ChatInfo(title: snapshot.title, subtitle: snapshot.subtitle, showsSenderNames: snapshot.showsSenderNames, titleIsMemberNames: snapshot.titleIsMemberNames)
        info.avatarUserId = snapshot.avatarUserId
        info.avatarURL = snapshot.avatarURL
        publish()
    }

    public func snapshot() -> Data? {
        let newest = sortedMessages.suffix(ChatSnapshotCache.messageLimit)
        return try? JSONEncoder().encode(Snapshot(
            messages: Array(newest), members: members, viewerUrn: viewerUrn, readAt: readAt,
            title: info.title, subtitle: info.subtitle, showsSenderNames: info.showsSenderNames,
            titleIsMemberNames: info.titleIsMemberNames, avatarUserId: info.avatarUserId, avatarURL: info.avatarURL,
        ))
    }

    // MARK: Loading

    /// The first load also reads the conversation, for its members and read position; polls only fetch messages.
    public func loadNewest() async throws {
        if !hasLoadedHistory {
            let viewerUrn = try await client.me().profileUrn
            async let loadingConversation = client.conversation(urn: conversationUrn)
            let page = try await client.messages(conversationUrn: conversationUrn)
            try await apply(conversation: loadingConversation, viewerUrn: viewerUrn)
            hasEarlierMessages = !page.isEmpty
            hasLoadedHistory = true
            merge(page)
            return
        }
        try await merge(client.messages(conversationUrn: conversationUrn))
    }

    private func apply(conversation: LinkedInConversation, viewerUrn: String) {
        self.viewerUrn = viewerUrn
        for participant in conversation.conversationParticipants {
            remember(participant)
        }
        let others = conversation.others(viewerUrn: viewerUrn)
        let isGroup = conversation.isGroup(viewerUrn: viewerUrn)
        info.title = conversation.displayTitle(viewerUrn: viewerUrn)
        info.titleIsMemberNames = conversation.title?.isEmpty != false
        info.showsSenderNames = isGroup
        info.subtitle = isGroup ? "\(conversation.conversationParticipants.count) members" : ""
        info.avatarUserId = isGroup ? nil : others.first?.hostIdentityUrn
        info.avatarURL = isGroup ? nil : others.first?.avatarURL
        // `lastReadAt` can trail the newest message by a moment even when the chat reads as read.
        let position = conversation.unreadCount == 0 ? max(conversation.lastReadDate ?? .distantPast, conversation.lastActivityDate ?? .distantPast) : conversation.lastReadDate
        if let position, position > (readAt ?? .distantPast) {
            readAt = position
        }
    }

    public func loadEarlier() async throws {
        guard let oldest = sortedMessages.first else { return }
        let page = try await client.messages(conversationUrn: conversationUrn, before: oldest.deliveredAt)
        hasEarlierMessages = page.hasMore
        merge(page.messages)
    }

    public func send(_ message: ChatOutgoing) async throws -> String? {
        let replyTo = message.replyToId.flatMap { loaded[$0] }
        let sent = try await client.send(conversationUrn: conversationUrn, text: message.text, replyTo: replyTo)
        try await merge(client.messages(conversationUrn: conversationUrn))
        return sent.entityUrn
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (message.timestamp ?? .distantPast) > (readAt ?? .distantPast)
    }

    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let shown = message.timestamp, shown > (readAt ?? .distantPast) else { return nil }
        let fromOthers = loaded.values.filter { $0.sender.hostIdentityUrn != viewerUrn && !$0.isRecalled }
        guard fromOthers.contains(where: { $0.deliveredAt > (readAt ?? .distantPast) && $0.deliveredAt <= shown }) else { return nil }
        readAt = shown
        // Read state is the whole conversation's: only mark it once nothing newer from the others is left.
        guard !fromOthers.contains(where: { $0.deliveredAt > shown }) else { return nil }
        return { [client, conversationUrn] in
            try await client.setRead(conversationUrn: conversationUrn)
        }
    }

    // MARK: Editing and unsending

    public func editableText(of message: ChatMessage) -> String? {
        guard let original = loaded[message.id], original.sender.hostIdentityUrn == viewerUrn, !original.isRecalled else { return nil }
        return original.body?.text
    }

    public func edit(_ messageId: String, text: String) async throws {
        try await client.edit(messageUrn: messageId, text: text)
        try await merge(client.messages(conversationUrn: conversationUrn))
    }

    public func canDelete(_ message: ChatMessage) -> Bool {
        guard let original = loaded[message.id] else { return false }
        return original.sender.hostIdentityUrn == viewerUrn && !original.isRecalled
    }

    /// Unsends: LinkedIn keeps the message in the history, shown as deleted.
    public func delete(_ messageId: String) async throws {
        try await client.recall(messageUrn: messageId)
        try await merge(client.messages(conversationUrn: conversationUrn))
    }

    // MARK: Live

    public func startFollowing() async {
        guard observation == nil, let connection = liveFeed?.connection else { return }
        observation = connection.observe { [weak self] update in
            guard let self else { return }
            switch update {
            case let .event(event): handle(event)
            case .catchUp: onCatchUp?()
            }
        }
    }

    public func stopFollowing() {
        observation.map { liveFeed?.connection.removeObserver($0) }
        observation = nil
        typingExpiry?.cancel()
        typing = [:]
    }

    func handle(_ event: LinkedInLiveEvent) {
        switch event {
        case let .message(conversation, message) where conversation == conversationUrn:
            typing[message.sender.hostIdentityUrn] = nil
            merge([message])
        case let .reaction(messageUrn, summary) where loaded[messageUrn] != nil:
            var summaries = loaded[messageUrn]?.reactionSummaries ?? []
            summaries.removeAll { $0.emoji == summary.emoji }
            if summary.count > 0 {
                summaries.append(summary)
            }
            setReactions(summaries, on: messageUrn)
        case let .conversation(conversation) where conversation.entityUrn == conversationUrn:
            // Read elsewhere, renamed, or members changed.
            if let viewerUrn {
                apply(conversation: conversation, viewerUrn: viewerUrn)
                onChange?()
            }
        case let .typing(conversation, participant) where conversation == conversationUrn && participant.hostIdentityUrn != viewerUrn:
            typing[participant.hostIdentityUrn] = (participant.name, Date().addingTimeInterval(5))
            scheduleTypingExpiry()
            onChange?()
        default:
            break
        }
    }

    // MARK: Typing

    public var typingNames: [String] {
        typing.values.filter { $0.until > Date() }.sorted { $0.until < $1.until }.map(\.name)
    }

    private func scheduleTypingExpiry() {
        typingExpiry?.cancel()
        guard let next = typing.values.map(\.until).min() else { return }
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            guard let self, !Task.isCancelled else { return }
            typing = typing.filter { $0.value.until > Date() }
            scheduleTypingExpiry()
            onChange?()
        }
    }

    /// The web client sends `typing` at most every few seconds while the draft changes.
    public func draftDidChange(_ draft: String) {
        guard !draft.isEmpty, Date().timeIntervalSince(lastTypingSent ?? .distantPast) > 5 else { return }
        lastTypingSent = Date()
        Task { [client, conversationUrn] in try? await client.sendTyping(conversationUrn: conversationUrn) }
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        (loaded[messageId]?.reactionSummaries ?? []).filter(\.viewerReacted).map(\.emoji)
    }

    /// Adds or removes one emoji. Shown right away and put back if LinkedIn refuses it.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        guard let message = loaded[messageId] else { return }
        let previous = message.reactionSummaries
        let remove = yourEmojis(on: messageId).contains(emoji)
        var updated = previous
        if let index = updated.firstIndex(where: { $0.emoji == emoji }) {
            let summary = updated[index]
            let count = summary.count + (remove ? -1 : 1)
            if count > 0 {
                updated[index] = LinkedInMessage.ReactionSummary(emoji: emoji, count: count, viewerReacted: !remove)
            } else {
                updated.remove(at: index)
            }
        } else if !remove {
            updated.append(LinkedInMessage.ReactionSummary(emoji: emoji, count: 1, viewerReacted: true))
        }
        setReactions(updated, on: messageId)
        do {
            try await client.setReaction(messageUrn: messageId, emoji: emoji, remove: remove)
        } catch {
            setReactions(previous, on: messageId)
            throw error
        }
    }

    private func setReactions(_ summaries: [LinkedInMessage.ReactionSummary], on messageId: String) {
        loaded[messageId]?.reactionSummaries = summaries
        publish()
    }

    /// LinkedIn's counts don't say who reacted, apart from the viewer.
    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        guard let viewerUrn, yourEmojis(on: messageId).contains(emoji) else { return [] }
        return [ChatReactor(user: person(viewerUrn), date: nil, isYou: true)]
    }

    // MARK: Display

    private var sortedMessages: [LinkedInMessage] {
        loaded.values.sorted { ($0.deliveredAtMs, $0.entityUrn) < ($1.deliveredAtMs, $1.entityUrn) }
    }

    private func merge(_ page: [LinkedInMessage]) {
        for message in page {
            loaded[message.entityUrn] = message
            if let actor = message.actor {
                remember(actor)
            }
        }
        publish()
    }

    private func remember(_ participant: LinkedInParticipant) {
        let isViewer = participant.hostIdentityUrn == viewerUrn
        members[participant.hostIdentityUrn] = ChatUser(id: participant.hostIdentityUrn, name: isViewer ? "You" : participant.name, avatarURL: participant.avatarURL)
    }

    private func person(_ urn: String) -> ChatUser {
        members[urn] ?? ChatUser(id: urn, name: "LinkedIn Member", avatarURL: nil)
    }

    private func publish() {
        let sorted = sortedMessages
        var totals: [String: [ChatReaction]] = [:]
        var referenced: [String: ChatMessage] = [:]
        for message in sorted {
            if !message.reactionSummaries.isEmpty {
                totals[message.entityUrn] = message.reactionSummaries
                    .map { ChatReaction(emoji: $0.emoji, count: $0.count, includesYou: $0.viewerReacted) }
                    .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
            }
            // A reply carries its quoted message, which may be older than what's loaded.
            for content in message.renderContent {
                guard let replied = content.repliedMessageContent, let id = replied.originalMessage?.entityUrn, loaded[id] == nil else { continue }
                let sender = replied.originalSender
                referenced[id] = ChatMessage(
                    id: id,
                    sender: sender.map { ChatUser(id: $0.hostIdentityUrn, name: $0.hostIdentityUrn == viewerUrn ? "You" : $0.name, avatarURL: $0.avatarURL) } ?? person(""),
                    timestamp: replied.originalSendAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    text: replied.messageBody?.text,
                    isOwn: sender?.hostIdentityUrn == viewerUrn,
                )
            }
        }
        reactions = totals
        referencedMessages = referenced
        messages = sorted.map(chatMessage)
        onChange?()
    }

    func chatMessage(_ message: LinkedInMessage) -> ChatMessage {
        let isOwn = message.sender.hostIdentityUrn == viewerUrn
        let sender = person(message.sender.hostIdentityUrn)
        if message.isRecalled {
            return ChatMessage(id: message.entityUrn, sender: sender, timestamp: message.deliveredAt, text: nil, isDeleted: true, isOwn: isOwn)
        }
        var embeds: [ChatEmbed] = []
        var replyToId: String?
        var forwardedFrom: ChatForwardOrigin?
        var forwardedText: String?
        for content in message.renderContent {
            if let replied = content.repliedMessageContent {
                replyToId = replied.originalMessage?.entityUrn
            } else if let embed = Self.embed(content) {
                embeds.append(embed)
            }
            if let forwarded = content.forwardedMessageContent {
                forwardedFrom = ChatForwardOrigin(name: forwarded.originalSender?.name)
                forwardedText = forwarded.forwardedBody?.text
            }
        }
        var text = message.text ?? forwardedText
        if let subject = message.subject, !subject.isEmpty {
            text = [subject, text].compactMap(\.self).joined(separator: "\n\n")
        }
        if text == nil, embeds.isEmpty {
            text = message.renderContentFallbackText
        }
        return ChatMessage(
            id: message.entityUrn,
            sender: sender,
            timestamp: message.deliveredAt,
            text: text,
            embeds: embeds,
            replyToId: replyToId,
            isOwn: isOwn,
            isEdited: message.isEdited,
            forwardedFrom: forwardedFrom,
        )
    }

    static func embed(_ content: LinkedInRenderContent) -> ChatEmbed? {
        if let image = content.vectorImage, let url = image.url(width: 1280) {
            return .image(url: url, aspectRatio: image.aspectRatio, alt: nil, link: nil, opensViewer: true)
        }
        if let gif = content.externalMedia, let url = gif.media?.url {
            let size = aspectRatio(width: gif.media?.originalWidth, height: gif.media?.originalHeight)
            if url.pathExtension.lowercased() == "mp4" {
                return .video(url: url, posterURL: gif.previewMedia?.url, aspectRatio: size, duration: nil, isGIF: true)
            }
            return .image(url: url, aspectRatio: size, alt: gif.title, link: nil, opensViewer: true)
        }
        if let video = content.video {
            let stream = video.progressiveStreams?.max { ($0.width ?? 0) < ($1.width ?? 0) }
            guard let url = stream?.streamingLocations?.first?.url else { return nil }
            let ratio = aspectRatio(width: stream?.width, height: stream?.height)
            return .video(url: url, posterURL: video.thumbnail?.url(width: 640), aspectRatio: ratio, duration: video.duration.map { duration(milliseconds: $0) }, isGIF: false)
        }
        if let file = content.file, let url = file.url {
            let size = file.byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return .file(url: url, filename: file.name ?? "File", subtitle: size, thumbnailURL: nil)
        }
        if let audio = content.audio {
            return .card(title: "Voice message", subtitle: audio.duration.map { duration(milliseconds: $0) }, systemImage: "waveform", imageURL: nil, link: nil)
        }
        if let host = content.hostUrnData, let urn = host.hostUrn {
            return .card(title: "Shared a post", subtitle: "LinkedIn", systemImage: "text.bubble", imageURL: nil, link: postURL(urn: urn))
        }
        return nil
    }

    /// `urn:li:activity:…` and similar update urns open as `/feed/update/<urn>/`.
    static func postURL(urn: String) -> URL? {
        URL(string: "https://www.linkedin.com/feed/update/\(urn)/")
    }

    static func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    static func duration(milliseconds: Int64) -> String {
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
