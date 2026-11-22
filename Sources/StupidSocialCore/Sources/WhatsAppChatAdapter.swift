import Foundation

/// One WhatsApp chat. Messages come from the account's WhatsApp store, which history sync and the live connection
/// fill, so the newest page is everything the device has; paging back past it asks the phone for older messages
/// (on-demand history), one request at a time. Photos, videos, voice messages, stickers and files load lazily
/// through `wamedia:` URLs. The chat refreshes when the connection stores something for it. Sends text in
/// one-to-one chats (group sending isn't validated yet, so groups are read-only) and sends read receipts as
/// messages are read.
@MainActor
public final class WhatsAppChatAdapter: ChatAdapter, ChatLiveUpdating, ChatReadOnlyAccess, ChatAudioPreviewing {
    public let network = ChatNetwork.whatsapp
    public let canReply = false
    public let acceptsAttachments = false
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
            case let .event(changes) where changes.reloadList || changes.chats.contains(chatJID):
                Task { await self.refreshNewest() }
            case .event:
                break
            case .catchUp:
                onCatchUp?()
            }
        }
    }

    public func stopFollowing() {
        observation.map { liveFeed?.connection.removeObserver($0) }
        observation = nil
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
        let sent = try await client.sendText(message.text, to: chatJID)
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

    public func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    public func audioPreviewURL(for previewId: String) async -> URL? {
        guard let url = URL(string: previewId), url.scheme == WhatsAppMediaURL.scheme else { return nil }
        return try? await ChatMediaFiles.shared.file(for: url)
    }

    // MARK: Display

    public func render(_ records: [ChatRecord]) -> ChatRendering {
        let messages = records.compactMap { try? $0.decode(WhatsAppMessage.self) }
        unread = messages.filter { !$0.isFromMe && $0.timestamp > (readUpTo ?? .distantPast) }
        return ChatRendering(messages: messages.map(chatMessage))
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
        return ChatMessage(id: message.id, sender: sender, timestamp: message.timestamp, text: text, embeds: embeds, isDeleted: message.isDeleted,
                           isOwn: message.isFromMe, isEdited: message.editedAt != nil)
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
