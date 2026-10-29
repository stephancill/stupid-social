import Foundation

/// What a chat shows about itself, above its messages.
public struct ChatInfo: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// Names head each sender's group of bubbles; one-to-one chats turn them off.
    public var showsSenderNames: Bool
    /// The title is made of member names, such as an untitled group, so name redaction applies to it.
    public var titleIsMemberNames: Bool
    /// A one-to-one chat shows the other person beside its title: their picture, else their initials on their
    /// chat color, as their Chats row does.
    public var avatarUserId: String?
    public var avatarURL: URL?

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
/// Optional abilities are separate protocols (reactions, unseen reactions, audio previews, live updates, quoted
/// messages, windows of older history, typing, mentions, custom emoji, commands, links), so a chat offers an action exactly when its adapter
/// implements it.
@MainActor
public protocol ChatAdapter: AnyObject {
    var network: SocialNetwork { get }
    /// The network and its id for the conversation, such as `spotify:<chat id>`; the account id is added to it.
    var key: String { get }
    /// Whether messages can be sent as replies.
    var canReply: Bool { get }
    /// Whether messages can carry a photo or file. Read again once connected, since a server may not allow
    /// uploads; before that, whether it might.
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
    /// network, which the framework sends shortly after; `nil` when there is nothing to send.
    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)?
    func reactors(of emoji: String, on messageId: String) -> [ChatReactor]

    /// What the chat showed, for opening with it next time; `nil` when there is nothing to keep.
    func snapshot() -> Data?
    func restore(snapshot: Data)
}

/// Reacting to messages.
@MainActor
public protocol ChatReactionSending: ChatAdapter {
    /// Read once connected, since a server may not allow reactions.
    var acceptsReactions: Bool { get }
    func yourEmojis(on messageId: String) -> [String]
    /// Adds the emoji, or removes it when you already reacted with it. The adapter shows the change at once
    /// and puts it back if the network refuses it.
    func toggleReaction(_ emoji: String, on messageId: String) async throws
}

/// Reactions others put on the user's messages since the user last saw them, which the chat badges and jumps
/// between.
@MainActor
public protocol ChatUnseenReactions: ChatAdapter {
    /// Ids of the user's messages with unseen reactions, oldest first; they may include messages that aren't
    /// loaded.
    var unseenReactionMessageIds: [String] { get }
    /// The user saw these messages on screen. Drops their reactions from the unseen ones at once and returns what
    /// tells the network, which the framework sends shortly after; `nil` when there is nothing to send. The send
    /// covers every message seen since the last send that went through.
    func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)?
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
    /// Set by the framework: the connection closed, with an error unless the app closed it itself.
    var onConnectionLost: ((Error?) -> Void)? { get set }
    /// Set by the framework: something failed outside a call it made, such as an upload after its message posted.
    var onError: ((Error) -> Void)? { get set }
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

/// Showing a window of older history around a message, without loading everything in between.
@MainActor
public protocol ChatWindowing: ChatAdapter {
    /// True while the messages are an older window that doesn't reach the newest message.
    var hasLaterMessages: Bool { get }
    func loadLater() async throws
    /// Shows a window around the message; `false` when the network no longer has it.
    func showWindow(around messageId: String) async throws -> Bool
    /// Leaves an older window for the newest messages.
    func showLatest() async throws
}

/// Typing indications, both ways.
@MainActor
public protocol ChatTyping: ChatAdapter {
    /// Names of the other users typing, in the order they started.
    var typingNames: [String] { get }
    /// Called as the user edits the draft.
    func draftDidChange(_ draft: String)
}

/// `@` mentions in message text.
@MainActor
public protocol ChatMentioning: ChatAdapter {
    /// Matches a mention written in the text, such as `@user_id`, which shows by name and is tappable; `nil`
    /// for a network that marks mentions by position (`ChatMessage.mentions`).
    var mentionPattern: NSRegularExpression? { get }
    /// User id → name.
    var mentionNames: [String: String] { get }
    func mentionSuggestions(for query: String) -> [ChatUser]
}

/// Custom emoji the network defines, written as `:name:` keys in reactions and text.
@MainActor
public protocol ChatCustomEmojis: ChatAdapter {
    /// Key → emoji; empty until the network's catalog loads, then the adapter calls `onChange`.
    var customEmojis: [String: ChatCustomEmoji] { get }
}

/// Text that runs a command rather than posting a message, which may post nothing.
@MainActor
public protocol ChatCommanding: ChatAdapter {
    func isCommand(_ text: String) -> Bool
    func sendCommand(_ text: String, replyToId: String?) async throws
}

/// Links to messages, and links in messages that point into the chat itself.
@MainActor
public protocol ChatLinking: ChatAdapter {
    func link(toMessage messageId: String) -> URL?
    func linkTarget(for url: URL) -> ChatLinkTarget?
    var linkBaseURL: URL? { get }
    /// How a link written as its URL reads, such as "Message in #general"; `nil` keeps the URL.
    func placeLabel(forLink url: URL) -> ChatPlaceLabel?
    /// Finds references to places written in text, such as `#room_id`; the first capture group is the reference.
    var referencePattern: NSRegularExpression? { get }
    /// How a reference reads; `nil` keeps it as written.
    func placeLabel(forReference reference: String) -> ChatPlaceLabel?
    /// What starts a reference the composer completes, such as `#`.
    var referencePrefix: String? { get }
    /// Places to offer for a typed reference; an empty query lists them to browse.
    func referenceSuggestions(for query: String) -> [ChatReferenceSuggestion]
}

/// The shared chat screen's model for a network that has a `ChatAdapter`.
@MainActor
public final class AdapterChatViewModel<Adapter: ChatAdapter>: ChatViewModel {
    public let adapter: Adapter
    /// A message to show once the chat loads, such as from a link.
    public var focusMessageId: String?
    private let snapshotCache: ChatSnapshotCache
    /// From a successful `connect()` until `disconnect()` or a lost connection; `connect()` runs again when the
    /// app becomes active.
    private var isOpen = false
    private var isConnecting = false
    private var snapshotSaveTask: Task<Void, Never>?
    /// A computed property, since generic classes can't have static stored ones.
    private static var jumpPageLimit: Int {
        20
    }

    public init(adapter: Adapter, accountId: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache(), draftStore: ChatDraftStore = ChatDraftStore()) {
        self.adapter = adapter
        self.snapshotCache = snapshotCache
        super.init(
            network: adapter.network,
            chatKey: "\(accountId)|\(adapter.key)",
            title: adapter.info.title,
            subtitle: adapter.info.subtitle,
            canReply: adapter.canReply,
            offersAttachments: adapter.acceptsAttachments,
            mentionPattern: (adapter as? any ChatMentioning)?.mentionPattern ?? nil,
            draftStore: draftStore,
        )
        tracksUnseenReactions = adapter is any ChatUnseenReactions
        adapter.onChange = { [weak self] in self?.adapterDidChange() }
        if let live = adapter as? any ChatLiveUpdating {
            live.onConnectionLost = { [weak self] error in self?.connectionLost(error) }
            live.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
        }
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
            // A divider placed from the snapshot goes when history replaced the messages it sat on.
            if let divider = firstUnreadMessageId, message(withId: divider) == nil {
                firstUnreadMessageId = nil
            }
            placeUnreadDivider()
            saveSnapshot()
            canReact = (adapter as? any ChatReactionSending)?.acceptsReactions ?? false
            canAttach = adapter.acceptsAttachments
            isOpen = true
            state = .connected
            if let live = adapter as? any ChatLiveUpdating {
                await live.startFollowing()
            }
            if let interval = adapter.pollInterval {
                startPolling(every: interval)
            }
            if let focusMessageId {
                self.focusMessageId = nil
                await jump(to: focusMessageId)
            }
        } catch {
            (adapter as? any ChatLiveUpdating)?.stopFollowing()
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        isOpen = false
        stopPolling()
        (adapter as? any ChatLiveUpdating)?.stopFollowing()
        snapshotSaveTask?.cancel()
        saveSnapshot()
    }

    /// Without an error the app closed the connection itself (it went to the background) and reconnects when
    /// active again, so there is nothing to report.
    private func connectionLost(_ error: Error?) {
        isOpen = false
        stopPolling()
        state = error.map { .disconnected($0.localizedDescription) } ?? .connecting
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

    // MARK: Windows

    override public func loadLater() async {
        guard let windowing = adapter as? any ChatWindowing, hasLaterMessages, !isLoadingLater else { return }
        isLoadingLater = true
        defer { isLoadingLater = false }
        do {
            try await windowing.loadLater()
        } catch {
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    /// Scrolls to a loaded message, or shows a window around one that isn't. Networks without windows load
    /// earlier pages until it's there, up to `jumpPageLimit` of them.
    override public func jump(to messageId: String) async {
        if message(withId: messageId) != nil, referencedMessages[messageId] == nil {
            jumpTarget = messageId
            return
        }
        guard let windowing = adapter as? any ChatWindowing else {
            for _ in 0 ..< Self.jumpPageLimit where adapter.hasEarlierMessages && message(withId: messageId) == nil {
                await loadEarlier()
            }
            if message(withId: messageId) != nil {
                jumpTarget = messageId
            } else {
                errorMessage = "That message is too far back to show."
            }
            return
        }
        do {
            guard try await windowing.showWindow(around: messageId) else {
                errorMessage = "That message is no longer available."
                return
            }
            adapterDidChange()
            jumpTarget = messageId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    override public func jumpToLatest() async {
        if let windowing = adapter as? any ChatWindowing, hasLaterMessages {
            do {
                try await windowing.showLatest()
                adapterDidChange()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        scrollToLatestRequest += 1
    }

    // MARK: Composing

    /// Sends optimistically (see `sendOptimistically`); a command waits for the network instead, since it may
    /// post nothing.
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = adapter.acceptsAttachments ? attachment : nil
        guard !text.isEmpty || attachment != nil, state == .connected else { return }
        let replyToId = canReply ? replyingTo?.id : nil
        if let commanding = adapter as? any ChatCommanding, commanding.isCommand(text) {
            isSending = true
            errorMessage = nil
            defer { isSending = false }
            do {
                try await commanding.sendCommand(text, replyToId: replyToId)
                draft = ""
                self.attachment = nil
                replyingTo = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        await sendOptimistically(text: text, attachment: attachment, replyToId: replyToId) { [adapter] in
            let id = try await adapter.send(ChatOutgoing(text: text, attachment: attachment, replyToId: replyToId))
            adapterDidChange()
            return id
        }
    }

    override public func draftDidChange() {
        (adapter as? any ChatTyping)?.draftDidChange(draft)
    }

    override public func mentionSuggestions(for query: String) -> [ChatUser] {
        (adapter as? any ChatMentioning)?.mentionSuggestions(for: query) ?? []
    }

    // MARK: Read position

    /// The read position moves at once (the count follows it); the network hears shortly after.
    override public func markRead(upTo message: ChatMessage) {
        let send = adapter.markRead(upTo: message)
        updateUnreadCount()
        if let send {
            scheduleReadMarker(send)
        }
    }

    override func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        adapter.isAfterReadPosition(message)
    }

    // MARK: Reactions

    override public func yourEmojis(on messageId: String) -> [String] {
        (adapter as? any ChatReactionSending)?.yourEmojis(on: messageId) ?? []
    }

    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard canReact, let reacting = adapter as? any ChatReactionSending else { return }
        do {
            try await reacting.toggleReaction(emoji, on: messageId)
        } catch {
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    /// Only once connected, like the read position: cached messages shown before then may be out of date.
    override public func reactionsSeen(on messageIds: Set<String>) {
        guard isOpen, let unseen = adapter as? any ChatUnseenReactions else { return }
        let ids = messageIds.intersection(unseenReactionMessageIds)
        guard !ids.isEmpty else { return }
        let send = unseen.markReactionsSeen(on: ids)
        adapterDidChange()
        if let send {
            scheduleReactionsSeen(send)
        }
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        adapter.reactors(of: emoji, on: messageId)
    }

    override public func audioPreviewURL(for previewId: String) async -> URL? {
        await (adapter as? any ChatAudioPreviewing)?.audioPreviewURL(for: previewId)
    }

    // MARK: Links

    override public func link(toMessage messageId: String) -> URL? {
        (adapter as? any ChatLinking)?.link(toMessage: messageId)
    }

    override public func linkTarget(for url: URL) -> ChatLinkTarget? {
        (adapter as? any ChatLinking)?.linkTarget(for: url)
    }

    override public var linkBaseURL: URL? {
        (adapter as? any ChatLinking)?.linkBaseURL
    }

    override public func placeLabel(forLink url: URL) -> ChatPlaceLabel? {
        (adapter as? any ChatLinking)?.placeLabel(forLink: url)
    }

    override public var referencePattern: NSRegularExpression? {
        (adapter as? any ChatLinking)?.referencePattern ?? nil
    }

    override public func placeLabel(forReference reference: String) -> ChatPlaceLabel? {
        (adapter as? any ChatLinking)?.placeLabel(forReference: reference)
    }

    override public var referencePrefix: String? {
        (adapter as? any ChatLinking)?.referencePrefix ?? nil
    }

    override public func referenceSuggestions(for query: String) -> [ChatReferenceSuggestion] {
        (adapter as? any ChatLinking)?.referenceSuggestions(for: query) ?? []
    }

    // MARK: Publishing

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
        if avatarUserId != info.avatarUserId {
            avatarUserId = info.avatarUserId
        }
        if avatarURL != info.avatarURL {
            avatarURL = info.avatarURL
        }
        if hasEarlierMessages != adapter.hasEarlierMessages {
            hasEarlierMessages = adapter.hasEarlierMessages
        }
        if let windowing = adapter as? any ChatWindowing, hasLaterMessages != windowing.hasLaterMessages {
            hasLaterMessages = windowing.hasLaterMessages
        }
        if let typing = adapter as? any ChatTyping, typingNames != typing.typingNames {
            typingNames = typing.typingNames
        }
        if let unseen = adapter as? any ChatUnseenReactions, unseenReactionMessageIds != unseen.unseenReactionMessageIds {
            unseenReactionMessageIds = unseen.unseenReactionMessageIds
        }
        if let mentioning = adapter as? any ChatMentioning, mentionNames != mentioning.mentionNames {
            mentionNames = mentioning.mentionNames
        }
        if let emojis = adapter as? any ChatCustomEmojis, customEmojis != emojis.customEmojis {
            customEmojis = emojis.customEmojis
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
        scheduleSnapshotSave()
    }

    /// Saves shortly after changes while open, so the snapshot survives the app being killed in a chat.
    private func scheduleSnapshotSave() {
        guard isOpen else { return }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSnapshot()
        }
    }

    private func saveSnapshot() {
        guard let snapshot = adapter.snapshot() else { return }
        snapshotCache.save(data: snapshot, key: chatKey)
    }
}
