import Foundation

/// One WhatsApp chat. Messages come from the account's WhatsApp store, which history sync and the live connection
/// fill (WhatsApp keeps no history for linked devices to page through), so the newest page is everything the
/// device has and there is nothing earlier to fetch. The chat refreshes when the connection stores something for
/// it. Sends text in one-to-one chats (group sending isn't validated yet, so groups are read-only) and sends read
/// receipts as messages are read.
@MainActor
public final class WhatsAppChatAdapter: ChatAdapter, ChatLiveUpdating, ChatReadOnlyAccess {
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
    public let chatJID: String
    private var names: [String: String] = [:]
    private var avatars: [String: URL] = [:]
    /// Others' messages up to this time are read; locally ahead while a read receipt is pending.
    private var readUpTo: Date?
    /// Others' unread messages last rendered, which a read receipt names.
    private var unread: [WhatsAppMessage] = []
    private var observation: UUID?

    public init(client: WhatsAppClient, liveFeed: WhatsAppLiveFeed?, chatJID: String, title: String) {
        self.client = client
        self.liveFeed = liveFeed
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
    }

    public func state() -> Data? {
        try? JSONEncoder().encode(State(names: names, avatars: avatars, readUpTo: readUpTo, title: info.title, avatarURL: info.avatarURL))
    }

    public func restore(state data: Data) {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        names = state.names
        avatars = state.avatars
        readUpTo = state.readUpTo
        info.title = state.title
        info.avatarURL = state.avatarURL
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
        guard case .newest = request else { throw WhatsAppError.unsupported }
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
        return try ChatPage(records: page.messages.map(Self.record), earlier: nil)
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

    // MARK: Display

    public func render(_ records: [ChatRecord]) -> ChatRendering {
        let messages = records.compactMap { try? $0.decode(WhatsAppMessage.self) }
        unread = messages.filter { !$0.isFromMe && $0.timestamp > (readUpTo ?? .distantPast) }
        return ChatRendering(messages: messages.map(chatMessage))
    }

    private func chatMessage(_ message: WhatsAppMessage) -> ChatMessage {
        let sender = ChatUser(id: message.isFromMe ? "me" : message.sender, name: message.isFromMe ? "You" : names[message.sender], avatarURL: message.isFromMe ? nil : avatars[message.sender])
        let text: String? = if message.isDeleted {
            "This message was deleted."
        } else if let text = message.text, !text.isEmpty {
            text
        } else {
            message.label.map { "[\($0)]" }
        }
        return ChatMessage(id: message.id, sender: sender, timestamp: message.timestamp, text: text, isDeleted: message.isDeleted, isOwn: message.isFromMe)
    }
}
