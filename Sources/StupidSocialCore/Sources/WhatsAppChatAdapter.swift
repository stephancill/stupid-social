import Foundation

/// One WhatsApp chat. Messages come from the account's WhatsApp store, which history sync and the live connection
/// fill, so the newest page is everything the device has; paging back past it asks the phone for older messages
/// (on-demand history), one request at a time. Photos, videos, voice messages, stickers and files load lazily
/// through `wamedia:` URLs. The chat refreshes when the connection stores something for it. Sends text in
/// one-to-one chats (group sending isn't validated yet, so groups are read-only) and sends read receipts as
/// messages are read.
@MainActor
public final class WhatsAppChatAdapter: ChatAdapter, ChatLiveUpdating, ChatReadOnlyAccess, ChatAudioPreviewing, ChatReactionSending, ChatTyping, ChatMembersListing, ChatVoiceSending {
    public let network = ChatNetwork.whatsapp
    public var canReply: Bool {
        !isReadOnly
    }

    public var acceptsReactions: Bool {
        !isReadOnly
    }

    public private(set) var typingNames: [String] = []
    public var acceptsAttachments: Bool {
        !isReadOnly
    }

    public let pollInterval: Duration? = nil
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onCatchUp: (() -> Void)?
    public private(set) var info: ChatInfo
    public var history: ChatHistory?
    public let isReadOnly: Bool

    private let client: WhatsAppClient
    private let liveFeed: WhatsAppLiveFeed?
    private let accountId: String
    public let chatJID: String
    /// The phone had nothing older than this message: paging back stops here.
    private var historyStart: String?
    /// Messages stored before media was kept (labels only) were asked of the phone again once.
    private var refreshedLegacyMedia = false
    /// The messages last rendered, by id, for the user's reactions.
    private var loaded: [String: WhatsAppMessage] = [:]
    private var ownUser: String?
    /// Who is typing (by JID) and when their indication lapses; WhatsApp sends `paused`, but a lost one shouldn't
    /// leave it showing.
    private var typing: [String: Date] = [:]
    private var typingExpiry: Task<Void, Never>?
    private var lastTypingSent: Date?
    private var pauseTyping: Task<Void, Never>?
    private var names: [String: String] = [:]
    private var avatars: [String: URL] = [:]
    /// Others' messages up to this time are read; locally ahead while a read receipt is pending.
    private var readUpTo: Date?
    /// Others' unread messages last rendered, which a read receipt names.
    private var unread: [WhatsAppMessage] = []
    private var observation: UUID?

    public init(client: WhatsAppClient, liveFeed: WhatsAppLiveFeed?, accountId: String, chatJID: String, title: String) {
        self.client = client
        self.liveFeed = liveFeed
        self.accountId = accountId
        self.chatJID = chatJID
        let isGroup = chatJID.hasSuffix("@\(WhatsAppJID.Server.group)")
        isReadOnly = isGroup
        info = ChatInfo(title: title, subtitle: "", showsSenderNames: isGroup)
        if !isGroup {
            info.avatarUserId = chatJID
        }
    }

    public var key: String {
        "whatsapp:\(chatJID)"
    }

    // MARK: State

    private struct State: Codable {
        let names: [String: String]
        let avatars: [String: URL]
        let readUpTo: Date?
        let title: String
        let avatarURL: URL?
        var historyStart: String?
        var refreshedLegacyMedia: Bool?
    }

    public func state() -> Data? {
        try? JSONEncoder().encode(State(names: names, avatars: avatars, readUpTo: readUpTo, title: info.title, avatarURL: info.avatarURL,
                                        historyStart: historyStart, refreshedLegacyMedia: refreshedLegacyMedia))
    }

    public func restore(state data: Data) {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        names = state.names
        avatars = state.avatars
        readUpTo = state.readUpTo
        info.title = state.title
        info.avatarURL = state.avatarURL
        historyStart = state.historyStart
        refreshedLegacyMedia = state.refreshedLegacyMedia ?? false
    }

    // MARK: Loading

    nonisolated static func record(_ message: WhatsAppMessage) throws -> ChatRecord {
        try ChatRecord(
            id: message.id,
            sortKey: Int64(message.timestamp.timeIntervalSince1970 * 1000),
            version: Int64((message.editedAt ?? message.timestamp).timeIntervalSince1970 * 1000),
            encoding: message,
        )
    }

    public func fetch(_ request: ChatPageRequest) async throws -> ChatPage {
        switch request {
        case .newest:
            let page = try await newestPage()
            refreshLegacyMediaIfNeeded()
            return page
        case let .before(cursor):
            return try await earlierPage(before: cursor.value)
        case .after, .around:
            throw WhatsAppError.unsupported
        }
    }

    /// Everything the device has, oldest first; earlier history continues from the oldest unless the phone said
    /// there is nothing before it.
    private func newestPage() async throws -> ChatPage {
        let page = await client.chatPage(chatJID)
        names = page.names
        avatars = page.avatars
        if !page.isGroup, let avatarURL = page.avatarURL {
            info.avatarURL = avatarURL
        }
        readUpTo = max(readUpTo ?? .distantPast, page.readUpTo ?? .distantPast)
        if let title = page.title {
            info.title = title
        }
        return try ChatPage(records: page.messages.map(Self.record), earlier: earlierCursor(oldest: page.messages.first))
    }

    private func earlierCursor(oldest: WhatsAppMessage?) -> ChatCursor? {
        guard let oldest, oldest.id != historyStart else { return nil }
        return ChatCursor(oldest.id)
    }

    /// Asks the phone for older messages than the one the chat has scrolled back to, then returns everything
    /// stored before it.
    private func earlierPage(before id: String) async throws -> ChatPage {
        guard let anchor = await client.message(id, in: chatJID) else { return ChatPage(records: [], earlier: nil) }
        let received = try await client.requestHistory(chat: chatJID, before: anchor)
        let older = await client.chatPage(chatJID).messages.filter { $0.timestamp < anchor.timestamp || ($0.timestamp == anchor.timestamp && $0.id < anchor.id) }
        if received == 0 || older.isEmpty {
            historyStart = older.first?.id ?? anchor.id
        }
        return try ChatPage(records: older.map(Self.record), earlier: received == 0 ? nil : earlierCursor(oldest: older.first))
    }

    /// Messages stored before the app kept media show only labels. Once per chat, the phone is asked for the
    /// messages before the newest, which come back with their media.
    private func refreshLegacyMediaIfNeeded() {
        guard !refreshedLegacyMedia else { return }
        refreshedLegacyMedia = true
        Task {
            let messages = await client.chatPage(chatJID).messages
            guard let newest = messages.last,
                  let oldestLegacy = messages.firstIndex(where: { $0.media == nil && Self.isMediaLabel($0.label) })
            else { return }
            let count = min(messages.count - oldestLegacy, 100)
            _ = try? await client.requestHistory(chat: chatJID, before: newest, count: count)
            await refreshNewest()
        }
    }

    private static func isMediaLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        return ["Photo", "Video", "Audio", "Voice message", "Sticker"].contains(label) || label.hasPrefix("Document")
    }

    public func startFollowing() async {
        guard observation == nil, let connection = liveFeed?.connection else { return }
        observation = connection.observe { [weak self] update in
            guard let self else { return }
            switch update {
            case let .event(changes):
                if changes.reloadList || changes.chats.contains(chatJID) {
                    Task { await self.refreshNewest() }
                }
                applyTyping(changes.typing.filter { $0.chat == self.chatJID })
            case .catchUp:
                onCatchUp?()
            }
        }
        ownUser = await client.ownUser
        // Online while the chat is open, as WhatsApp Web is while it has focus; typing arrives once subscribed.
        await client.setAvailable(true)
        await client.subscribePresence(chatJID)
    }

    public func stopFollowing() {
        observation.map { liveFeed?.connection.removeObserver($0) }
        observation = nil
        typingExpiry?.cancel()
        typing = [:]
        typingNames = []
        if lastTypingSent != nil {
            lastTypingSent = nil
            Task { [client, chatJID] in await client.sendTyping(false, in: chatJID) }
        }
        pauseTyping?.cancel()
        Task { [client] in await client.setAvailable(false) }
    }

    // MARK: Typing

    private func applyTyping(_ changes: [WhatsAppTyping]) {
        guard !changes.isEmpty else { return }
        for change in changes where change.sender != ownUser {
            typing[change.sender] = change.isTyping ? Date().addingTimeInterval(25) : nil
        }
        publishTyping()
    }

    private func publishTyping() {
        let now = Date()
        typing = typing.filter { $0.value > now }
        typingNames = typing.keys.sorted().map { names[$0] ?? (isReadOnly ? "Someone" : info.title) }
        onChange?()
        typingExpiry?.cancel()
        if let next = typing.values.min() {
            typingExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0.1)))
                guard !Task.isCancelled else { return }
                self?.publishTyping()
            }
        }
    }

    /// `composing` at most every 10 s while the draft changes, and `paused` 5 s after the last change or when the
    /// draft empties, as WhatsApp Web sends them.
    public func draftDidChange(_ draft: String) {
        guard !isReadOnly else { return }
        pauseTyping?.cancel()
        if draft.isEmpty {
            guard lastTypingSent != nil else { return }
            lastTypingSent = nil
            Task { [client, chatJID] in await client.sendTyping(false, in: chatJID) }
            return
        }
        if lastTypingSent.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
            lastTypingSent = Date()
            Task { [client, chatJID] in await client.sendTyping(true, in: chatJID) }
        }
        pauseTyping = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, lastTypingSent != nil else { return }
            lastTypingSent = nil
            await client.sendTyping(false, in: chatJID)
        }
    }

    // MARK: Members

    public func groupDetails() async -> (description: String?, members: [ChatMemberSummary])? {
        guard isReadOnly || chatJID.hasSuffix("@\(WhatsAppJID.Server.group)") else { return nil }
        return await client.groupInfo(chatJID)
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        guard let ownUser, let emoji = loaded[messageId]?.reactions[ownUser] else { return [] }
        return [emoji]
    }

    /// WhatsApp keeps one reaction per person: a new emoji replaces the user's, and the same one takes it back.
    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        let current = yourEmojis(on: messageId).first
        try await client.sendReaction(current == emoji ? "" : emoji, to: messageId, in: chatJID)
        await refreshNewest()
    }

    private func refreshNewest() async {
        do {
            try await history?.apply(newest: fetch(.newest))
        } catch {
            onError?(error)
        }
    }

    // MARK: Sending

    public func send(_ message: ChatOutgoing) async throws -> String? {
        pauseTyping?.cancel()
        lastTypingSent = nil
        if let attachment = message.attachment {
            let media = await WhatsAppOutgoingMedia.make(data: attachment.data, mimeType: attachment.mimeType, filename: attachment.filename, isImage: attachment.isImage)
            let sent = try await client.sendMedia(media, caption: message.text, to: chatJID, replyTo: message.replyToId, accountId: accountId)
            try history?.write([Self.record(sent)])
            return sent.id
        }
        let sent = try await client.sendText(message.text, to: chatJID, replyTo: message.replyToId)
        try history?.write([Self.record(sent)])
        return sent.id
    }

    /// Sent as Ogg Opus, as WhatsApp's apps send voice messages; encoded off the main thread.
    public func send(voice: ChatVoiceNote, replyToId: String?) async throws -> String? {
        pauseTyping?.cancel()
        lastTypingSent = nil
        let fileURL = voice.fileURL
        let data = try await Task.detached { try OggOpusEncoder.encode(fileAt: fileURL) }.value
        let media = WhatsAppOutgoingMedia.voice(oggOpus: data, duration: voice.duration, levels: voice.levels(64))
        let sent = try await client.sendMedia(media, caption: nil, to: chatJID, replyTo: replyToId, accountId: accountId)
        try history?.write([Self.record(sent)])
        return sent.id
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        guard let timestamp = message.timestamp else { return false }
        return timestamp > (readUpTo ?? .distantPast)
    }

    /// WhatsApp takes read receipts per message, so this sends them for others' unread messages up to the one
    /// shown. The read position moves once WhatsApp accepted them.
    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let timestamp = message.timestamp else { return nil }
        let read = unread.filter { $0.timestamp > (readUpTo ?? .distantPast) && $0.timestamp <= timestamp }
        guard !read.isEmpty else { return nil }
        return { [weak self, client, chatJID] in
            try await client.markRead(read, in: chatJID, upTo: timestamp)
            guard let self else { return }
            readUpTo = max(readUpTo ?? .distantPast, timestamp)
        }
    }

    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (loaded[messageId]?.reactions ?? [:]).filter { $0.value == emoji }.map { jid, _ in
            let isYou = jid == ownUser
            return ChatReactor(user: ChatUser(id: isYou ? "me" : jid, name: isYou ? "You" : names[jid], avatarURL: isYou ? nil : avatars[jid]), date: nil, isYou: isYou)
        }
    }

    public func audioPreviewURL(for previewId: String) async -> URL? {
        guard let url = URL(string: previewId), url.scheme == WhatsAppMediaURL.scheme else { return nil }
        return try? await ChatMediaFiles.shared.file(for: url)
    }

    // MARK: Display

    public func render(_ records: [ChatRecord]) -> ChatRendering {
        let messages = records.compactMap { try? $0.decode(WhatsAppMessage.self) }
        unread = messages.filter { !$0.isFromMe && $0.timestamp > (readUpTo ?? .distantPast) }
        for message in messages {
            loaded[message.id] = message
        }
        var reactions: [String: [ChatReaction]] = [:]
        for message in messages where !message.reactions.isEmpty {
            let counts = Dictionary(grouping: message.reactions, by: \.value)
            reactions[message.id] = counts.map { emoji, reactors in
                ChatReaction(emoji: emoji, count: reactors.count, includesYou: reactors.contains { $0.key == ownUser })
            }.sorted { $0.count == $1.count ? $0.emoji < $1.emoji : $0.count > $1.count }
        }
        return ChatRendering(messages: messages.map(chatMessage), reactions: reactions)
    }

    private func chatMessage(_ message: WhatsAppMessage) -> ChatMessage {
        let sender = ChatUser(id: message.isFromMe ? "me" : message.sender, name: message.isFromMe ? "You" : names[message.sender], avatarURL: message.isFromMe ? nil : avatars[message.sender])
        let embeds = message.isDeleted ? [] : message.media.map { embeds(for: $0, message: message) } ?? []
        let text: String? = if message.isDeleted {
            "This message was deleted."
        } else if let text = message.text, !text.isEmpty {
            text
        } else if embeds.isEmpty {
            message.label.map { "[\($0)]" }
        } else {
            nil
        }
        return ChatMessage(id: message.id, sender: sender, timestamp: message.timestamp, text: text, embeds: embeds, replyToId: message.quotedId,
                           isDeleted: message.isDeleted, isOwn: message.isFromMe, isEdited: message.editedAt != nil)
    }

    private func embeds(for media: WhatsAppMedia, message: WhatsAppMessage) -> [ChatEmbed] {
        guard media.isDownloadable, let url = WhatsAppMediaURL.make(accountId: accountId, chat: chatJID, messageId: message.id, fileExtension: media.fileExtension) else {
            return [.card(title: message.label ?? "Media", subtitle: "No longer available", systemImage: "exclamationmark.triangle", imageURL: nil, link: nil)]
        }
        let aspectRatio: Double? = if let width = media.width, let height = media.height, width > 0, height > 0 { Double(width) / Double(height) } else { nil }
        let thumbnailURL = media.thumbnail?.isEmpty == false ? WhatsAppMediaURL.make(accountId: accountId, chat: chatJID, messageId: message.id, fileExtension: "jpg", thumbnail: true) : nil
        switch media.kind {
        case .image:
            return [.image(url: url, aspectRatio: aspectRatio, alt: nil, link: nil, opensViewer: true)]
        case .sticker:
            return [.sticker(ChatSticker(id: message.id, url: url, format: .image, posterURL: nil, aspectRatio: aspectRatio ?? 1, alt: nil))]
        case .video:
            return [.video(url: url, posterURL: thumbnailURL, aspectRatio: aspectRatio, duration: media.seconds.map(Self.duration), isGIF: media.isAnimated)]
        case .audio:
            let waveform = media.waveform.map { $0.map { min(Double($0) / 100, 1) } } ?? []
            return [.voice(previewId: url.absoluteString, duration: media.seconds.map(Double.init), waveform: waveform)]
        case .document:
            let size = media.fileLength.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return [.file(url: url, filename: media.fileName ?? "Document.\(media.fileExtension)", subtitle: size, thumbnailURL: thumbnailURL)]
        }
    }

    private static func duration(_ seconds: UInt32) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
