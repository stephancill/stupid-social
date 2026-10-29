import Foundation

/// What a chat shows about itself, above its messages.
public struct ChatInfo: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// Names head each sender's group of bubbles; one-to-one chats turn them off.
    public var showsSenderNames: Bool
    /// The title is made of member names, such as an untitled group, so name redaction applies to it.
    public var titleIsMemberNames: Bool

    public init(title: String, subtitle: String, showsSenderNames: Bool = true, titleIsMemberNames: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.showsSenderNames = showsSenderNames
        self.titleIsMemberNames = titleIsMemberNames
    }
}

/// A message the user is sending.
public struct ChatOutgoing {
    public let text: String
    public let attachment: ChatAttachment?
    public let replyToId: String?
}

/// One conversation on one network, as the chat framework drives it. An adapter only translates: it loads and
/// sends through its network and maps what comes back to `ChatMessage`s. The framework (`AdapterChatViewModel`)
/// owns the screen's state and the behavior every chat shares: connecting, polling, paging, unread counting and
/// the divider, read-marker debouncing, snapshots, drafts and optimistic sending.
///
/// Optional abilities are separate protocols (`ChatReactionSending`, `ChatAudioPreviewing`), so a chat offers
/// an action exactly when its adapter implements it.
@MainActor
public protocol ChatAdapter: AnyObject {
    var network: SocialNetwork { get }
    /// The network and its id for the conversation, such as `spotify:<chat id>`; the account id is added to it.
    var key: String { get }
    /// Whether messages can be sent as replies.
    var canReply: Bool { get }
    /// Whether messages can carry a photo or file.
    var acceptsAttachments: Bool { get }
    /// How often to fetch the newest messages while the chat is open; `nil` when the network pushes them and the
    /// adapter calls `onChange`.
    var pollInterval: Duration? { get }
    /// Set by the framework; the adapter calls it when what it shows changes on its own, such as a profile name or
    /// track details loading after the messages did.
    var onChange: (() -> Void)? { get set }

    var info: ChatInfo { get }
    /// Oldest first.
    var messages: [ChatMessage] { get }
    /// Per-message reaction totals, keyed by message id.
    var reactions: [String: [ChatReaction]] { get }
    var hasEarlierMessages: Bool { get }

    /// Loads the newest messages, both when the chat opens and on each poll.
    func loadNewest() async throws
    func loadEarlier() async throws
    /// Sends and returns the network's id for the message, or `nil` when the network doesn't say (then the
    /// adapter loads the sent message before returning).
    func send(_ message: ChatOutgoing) async throws -> String?
    /// Whether the message is past the user's read position on the network.
    func isAfterReadPosition(_ message: ChatMessage) -> Bool
    /// Moves the read position up to the message, if that passes unread messages, and returns what tells the
    /// network, which the framework sends shortly after; `nil` when nothing moved.
    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)?
    func reactors(of emoji: String, on messageId: String) -> [ChatReactor]

    /// What the chat showed, for opening with it next time; `nil` before anything loaded.
    func snapshot() -> Data?
    func restore(snapshot: Data)
}

/// Reacting to messages.
@MainActor
public protocol ChatReactionSending: ChatAdapter {
    func yourEmojis(on messageId: String) -> [String]
    /// Adds the emoji, or removes it when you already reacted with it. The adapter shows the change at once
    /// and puts it back if the network refuses it.
    func toggleReaction(_ emoji: String, on messageId: String) async throws
}

/// Inline previews for `.audio` embeds.
@MainActor
public protocol ChatAudioPreviewing: ChatAdapter {
    func audioPreviewURL(for previewId: String) async -> URL?
}

/// Updates the network pushes while the chat is open. The adapter applies them and calls `onChange`; a network
/// can also name a `pollInterval` as a fallback.
@MainActor
public protocol ChatLiveUpdating: ChatAdapter {
    /// Called once the newest messages have loaded.
    func startFollowing() async
    func stopFollowing()
}

/// Messages that replies quote but that aren't among the loaded ones.
@MainActor
public protocol ChatReferenceResolving: ChatAdapter {
    var referencedMessages: [String: ChatMessage] { get }
    /// Quoted messages the network couldn't return, such as deleted ones.
    var unavailableReferences: Set<String> { get }
}

/// The shared chat screen's model for a network that has a `ChatAdapter`.
@MainActor
public final class AdapterChatViewModel: ChatViewModel {
    public let adapter: any ChatAdapter
    private let snapshotCache: ChatSnapshotCache
    /// From a successful `connect()` until `disconnect()`; `connect()` runs again when the app becomes active.
    private var isOpen = false
    private var isConnecting = false

    public init(adapter: any ChatAdapter, accountId: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache(), draftStore: ChatDraftStore = ChatDraftStore()) {
        self.adapter = adapter
        self.snapshotCache = snapshotCache
        super.init(
            network: adapter.network,
            chatKey: "\(accountId)|\(adapter.key)",
            title: adapter.info.title,
            subtitle: adapter.info.subtitle,
            canReply: adapter.canReply,
            offersAttachments: adapter.acceptsAttachments,
            draftStore: draftStore,
        )
        adapter.onChange = { [weak self] in self?.adapterDidChange() }
        if let snapshot = snapshotCache.data(key: chatKey) {
            adapter.restore(snapshot: snapshot)
        }
        adapterDidChange()
        // In the first render, rather than appearing once history arrives.
        placeUnreadDivider()
    }

    override public func connect() async {
        guard !isOpen, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        do {
            try await adapter.loadNewest()
            adapterDidChange()
            placeUnreadDivider()
            saveSnapshot()
            canReact = adapter is any ChatReactionSending
            canAttach = adapter.acceptsAttachments
            isOpen = true
            state = .connected
            if let live = adapter as? any ChatLiveUpdating {
                await live.startFollowing()
            }
            if let interval = adapter.pollInterval {
                startPolling(every: interval)
            }
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        isOpen = false
        stopPolling()
        (adapter as? any ChatLiveUpdating)?.stopFollowing()
        saveSnapshot()
    }

    override func poll() async {
        try? await adapter.loadNewest()
        adapterDidChange()
    }

    override public func loadEarlier() async {
        guard hasEarlierMessages, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            try await adapter.loadEarlier()
        } catch {
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    /// Sends optimistically (see `sendOptimistically`).
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = adapter.acceptsAttachments ? attachment : nil
        guard !text.isEmpty || attachment != nil, state == .connected else { return }
        let replyToId = canReply ? replyingTo?.id : nil
        await sendOptimistically(text: text, attachment: attachment, replyToId: replyToId) { [adapter] in
            let id = try await adapter.send(ChatOutgoing(text: text, attachment: attachment, replyToId: replyToId))
            adapterDidChange()
            return id
        }
    }

    override public func markRead(upTo message: ChatMessage) {
        guard let send = adapter.markRead(upTo: message) else { return }
        updateUnreadCount()
        scheduleReadMarker(send)
    }

    override func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        adapter.isAfterReadPosition(message)
    }

    override public func yourEmojis(on messageId: String) -> [String] {
        (adapter as? any ChatReactionSending)?.yourEmojis(on: messageId) ?? []
    }

    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard let reacting = adapter as? any ChatReactionSending else { return }
        do {
            try await reacting.toggleReaction(emoji, on: messageId)
        } catch {
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        adapter.reactors(of: emoji, on: messageId)
    }

    override public func audioPreviewURL(for previewId: String) async -> URL? {
        await (adapter as? any ChatAudioPreviewing)?.audioPreviewURL(for: previewId)
    }

    private func adapterDidChange() {
        let info = adapter.info
        if title != info.title {
            title = info.title
        }
        if subtitle != info.subtitle {
            subtitle = info.subtitle
        }
        showsSenderNames = info.showsSenderNames
        titleIsMemberNames = info.titleIsMemberNames
        if hasEarlierMessages != adapter.hasEarlierMessages {
            hasEarlierMessages = adapter.hasEarlierMessages
        }
        if let resolving = adapter as? any ChatReferenceResolving {
            if referencedMessages != resolving.referencedMessages {
                referencedMessages = resolving.referencedMessages
            }
            if unavailableReferences != resolving.unavailableReferences {
                unavailableReferences = resolving.unavailableReferences
            }
        }
        publish(history: adapter.messages, reactions: adapter.reactions)
        updateUnreadCount()
    }

    private func saveSnapshot() {
        guard let snapshot = adapter.snapshot() else { return }
        snapshotCache.save(data: snapshot, key: chatKey)
    }
}
