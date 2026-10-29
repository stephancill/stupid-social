import Foundation
import ImageIO
import NoFeedSocialPush

/// Someone shown in a chat: a message sender, reactor, or mention suggestion.
public struct ChatUser: Hashable, Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: URL?
    /// System senders, such as server notices, render as centered captions instead of bubbles.
    public let isSystem: Bool

    public init(id: String, name: String?, avatarURL: URL?, isSystem: Bool = false) {
        self.id = id
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.avatarURL = avatarURL
        self.isSystem = isSystem
    }
}

/// When someone was last online: exact for people who share it, otherwise only roughly (as Telegram reports it).
public enum ChatPresence: Codable, Hashable, Sendable {
    case online
    case lastSeen(Date)
    case recently
    case lastWeek
    case lastMonth
    case unknown

    /// "online", "last seen 5 minutes ago", or roughly when the exact time is private.
    public var text: String {
        switch self {
        case .online: "online"
        case let .lastSeen(date): "last seen \(date.formatted(.relative(presentation: .named)))"
        case .recently: "last seen recently"
        case .lastWeek: "last seen within a week"
        case .lastMonth: "last seen within a month"
        case .unknown: "last seen a long time ago"
        }
    }
}

/// Rich content shown in a message bubble.
public enum ChatEmbed: Hashable, Sendable {
    /// An image sized from `aspectRatio` (width / height). Media that `opensViewer` fills the bubble and opens
    /// full screen; a preview image sits inside the padding and opens `link`.
    case image(url: URL, aspectRatio: Double?, alt: String?, link: URL?, opensViewer: Bool)
    /// An attachment that is still uploading.
    case pending(title: String)
    /// A tappable card. `imageURL` shows a thumbnail, such as album artwork, in place of the symbol.
    case card(title: String, subtitle: String?, systemImage: String, imageURL: URL?, link: URL?)
    /// A song or other audio with artwork and an inline preview, which plays from `audioPreviewURL(for:)`;
    /// tapping elsewhere on the card opens `link`.
    case audio(previewId: String, title: String, subtitle: String?, detail: String?, imageURL: URL?, link: URL?)
}

/// One message as the chat shows it. Each network maps its own messages to this.
public struct ChatMessage: Hashable, Identifiable, Sendable {
    /// Stable across edits; replies and reactions refer to it.
    public let id: String
    public let sender: ChatUser
    public let timestamp: Date?
    public let text: String?
    /// Inline Markdown, rendered without raw HTML.
    public let isMarkdown: Bool
    public let embeds: [ChatEmbed]
    public let replyToId: String?
    public let isDeleted: Bool
    public let isOwn: Bool
    /// A transient notice outside the history: it can't be replied to, reacted to, or marked read.
    public let isNotice: Bool
    /// Sent by the user and not yet confirmed by the network: shown at once, with a sending indicator.
    public let isSending: Bool
    /// Parts of `text` hidden until tapped (UTF-16 ranges); plain text only.
    public let spoilers: [NSRange]

    public init(
        id: String,
        sender: ChatUser,
        timestamp: Date?,
        text: String?,
        isMarkdown: Bool = false,
        embeds: [ChatEmbed] = [],
        replyToId: String? = nil,
        isDeleted: Bool = false,
        isOwn: Bool,
        isNotice: Bool = false,
        isSending: Bool = false,
        spoilers: [NSRange] = [],
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.text = text
        self.isMarkdown = isMarkdown
        self.embeds = embeds
        self.replyToId = replyToId
        self.isDeleted = isDeleted
        self.isOwn = isOwn
        self.isNotice = isNotice
        self.isSending = isSending
        self.spoilers = spoilers
    }

    /// The message with `image` in place of its first image or pending upload, such as the picked file for a
    /// message the user just sent.
    func showing(_ image: ChatEmbed) -> ChatMessage {
        var embeds = embeds
        if let index = embeds.firstIndex(where: {
            switch $0 {
            case .image, .pending: true
            default: false
            }
        }) {
            embeds[index] = image
        } else {
            return self
        }
        return ChatMessage(
            id: id, sender: sender, timestamp: timestamp, text: text, isMarkdown: isMarkdown, embeds: embeds,
            replyToId: replyToId, isDeleted: isDeleted, isOwn: isOwn, isNotice: isNotice, isSending: isSending,
            spoilers: spoilers,
        )
    }

    /// Whether it is a real message someone sent, rather than a notice or system caption.
    public var isUserMessage: Bool {
        !isNotice && !sender.isSystem
    }

    /// One line describing the message, for reply quotes and the composer's reply preview.
    public var previewText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return SpoilerText.mask(text, ranges: spoilers) }
        for embed in embeds {
            switch embed {
            case .image: return "Photo"
            case let .card(title, _, _, _, _): return title
            case let .audio(_, title, _, _, _, _): return title
            case let .pending(title): return title
            }
        }
        return "Attachment"
    }
}

/// A display total for one emoji on one message.
public struct ChatReaction: Hashable, Sendable {
    public let emoji: String
    public let count: Int
    public let includesYou: Bool

    public init(emoji: String, count: Int, includesYou: Bool) {
        self.emoji = emoji
        self.count = count
        self.includesYou = includesYou
    }
}

/// Who reacted with an emoji, for a reaction chip's long-press list.
public struct ChatReactor: Hashable, Sendable {
    public let user: ChatUser
    public let date: Date?
    public let isYou: Bool

    public init(user: ChatUser, date: Date?, isYou: Bool) {
        self.user = user
        self.date = date
        self.isYou = isYou
    }
}

/// A file staged in the composer.
public struct ChatAttachment: Equatable {
    public let data: Data
    public let mimeType: String
    public let filename: String
    public let isImage: Bool

    public init(data: Data, mimeType: String, filename: String, isImage: Bool) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        self.isImage = isImage
    }
}

public enum ChatConnectionState: Equatable {
    case connecting
    case connected
    case disconnected(String?)
}

/// Where a link in a chat's messages points within that same chat.
public enum ChatLinkTarget: Equatable {
    /// The chat itself, which is already showing.
    case chat
    case message(String)
    case user(String)
}

/// What the shared chat screen shows and does: the screen's state and the behavior every chat shares (drafts,
/// polling, unread counting, the divider, read-marker debouncing, optimistic sending). `AdapterChatViewModel`,
/// its one subclass, drives it from a network's `ChatAdapter`; an action the adapter doesn't offer keeps the
/// no-op here, and the capability flags hide it from the UI.
@MainActor
public class ChatViewModel: ObservableObject {
    /// What the chat shows: the network's `history`, then the user's messages still sending.
    @Published public private(set) var messages: [ChatMessage] = [] {
        didSet {
            messagesById = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            reportSummary()
        }
    }

    /// The network's messages, oldest first; each network sets this and `messages` follows.
    var history: [ChatMessage] = [] {
        didSet { composeMessages() }
    }

    @Published public internal(set) var state: ChatConnectionState = .connecting {
        didSet {
            // History has arrived, or won't.
            if state != .connecting {
                releaseRestoredMessages()
            }
        }
    }

    /// While set, `messages` stays empty; see `expectUnread()`.
    private var holdsRestoredMessages = false
    @Published public internal(set) var title: String
    @Published public internal(set) var subtitle: String
    /// The other person in a one-to-one chat, beside the title (`ChatInfo.avatarUserId`).
    @Published public internal(set) var avatarUserId: String?
    @Published public internal(set) var avatarURL: URL?
    /// The chat's picture from its Chats row, beside the title when no one person is named (`avatarUserId`),
    /// such as in groups and rooms.
    @Published public private(set) var rowAvatar: ChatTitleAvatar?
    @Published public internal(set) var hasEarlierMessages = false
    @Published public internal(set) var isLoadingEarlier = false
    /// True while showing a window of older history that doesn't reach the newest message.
    @Published public internal(set) var hasLaterMessages = false
    @Published public internal(set) var isLoadingLater = false
    @Published public internal(set) var isSending = false
    @Published public internal(set) var canAttach = false
    @Published public internal(set) var canReact = false
    /// Per-message reaction totals, keyed by message id.
    @Published public internal(set) var reactions: [String: [ChatReaction]] = [:]
    /// Kept per chat across visits.
    @Published public var draft = "" {
        didSet { draftStore.setDraft(draft, key: chatKey) }
    }

    @Published public var attachment: ChatAttachment?
    @Published public internal(set) var replyingTo: ChatMessage?
    /// A message the view should scroll to and highlight, set by `jump(to:)`.
    @Published public internal(set) var jumpTarget: String?
    /// Incremented when the view should scroll to the newest message.
    @Published public internal(set) var scrollToLatestRequest = 0
    /// Reply targets outside the loaded messages.
    @Published public internal(set) var referencedMessages: [String: ChatMessage] = [:]
    @Published public internal(set) var unavailableReferences: Set<String> = []
    /// The "New Messages" divider sits above this message for the whole visit.
    @Published public internal(set) var firstUnreadMessageId: String?
    /// Unread messages among those loaded, for the jump-to-latest badge.
    @Published public internal(set) var unreadCount = 0 {
        didSet { reportSummary() }
    }

    /// The user's messages with reactions from others the user hasn't seen, oldest first; they may include
    /// messages that aren't loaded. Empty for chats that don't track them (`tracksUnseenReactions`).
    @Published public internal(set) var unseenReactionMessageIds: [String] = [] {
        didSet { reportSummary() }
    }

    /// Names of the other users typing, in the order they started.
    @Published public internal(set) var typingNames: [String] = []
    /// User id → name, for showing `@` mentions by name.
    @Published public internal(set) var mentionNames: [String: String] = [:]
    @Published public var errorMessage: String?

    /// Names head each sender's group of bubbles; one-to-one chats turn them off.
    public internal(set) var showsSenderNames = true
    /// Set when the title is made of member names, such as an untitled Apron private room.
    var titleIsMemberNames = false
    /// Whether the title names people (a one-to-one chat, or a room named for its members), so name
    /// redaction applies to it.
    public var titleNamesPeople: Bool {
        !showsSenderNames || titleIsMemberNames
    }

    /// The chat's network, whose icon leads the subtitle.
    public let network: SocialNetwork
    /// Identifies the chat across visits, such as for its draft: the network, a colon, and the network's id for it.
    public let chatKey: String
    /// Whether swipe-to-reply and the Reply action are offered.
    public let canReply: Bool
    /// Whether the composer has an attachments button; `canAttach` enables it once the network allows uploads.
    public let offersAttachments: Bool
    /// `@user_id` mentions in message text, highlighted and tappable; `nil` when the network has none.
    public let mentionPattern: NSRegularExpression?

    public static let quickReactions = ["👍", "❤️", "😂", "🔥", "😮", "🙏"]
    public static let unreadBadgeCap = 50

    /// Messages the user sent that aren't in `history` yet, shown after it with a sending indicator.
    private var outgoing: [ChatMessage] = []
    /// Confirmed message id → its sending copy, which stays until the message is in `history`.
    private var awaitingHistory: [String: String] = [:]
    /// "Sending" ids → the history ids when they were sent, so the sent message is recognized if history brings it
    /// before the send returns its id.
    private var historyAtSend: [String: Set<String>] = [:]
    /// Sent messages' ids → the "sending" id they were shown under, so the chat keeps their cell once confirmed.
    public private(set) var sentLocalIds: [String: String] = [:]
    /// Confirmed message id → the image the user picked. The message keeps showing it, so the swap from the
    /// sending copy doesn't reload the image or change its size.
    private var pickedImages: [String: ChatEmbed] = [:]

    /// Whether the network reports which reactions the user hasn't seen.
    var tracksUnseenReactions = false
    /// The newest message with its one-line preview, the unread count, and the unseen reactions count (`nil`
    /// without `tracksUnseenReactions`), for the chat's row in the Chats list.
    var summaryDidChange: ((_ latest: ChatMessage?, _ body: String?, _ unreadCount: Int, _ unseenReactionCount: Int?) -> Void)?
    private var messagesById: [String: ChatMessage] = [:]
    private var renderedTextCache: [String: AttributedString] = [:]
    private let draftStore: ChatDraftStore
    private var pollTask: Task<Void, Never>?
    private var readSendTask: Task<Void, Never>?
    private var reactionsSeenSendTask: Task<Void, Never>?

    init(
        network: SocialNetwork,
        chatKey: String,
        title: String,
        subtitle: String,
        canReply: Bool,
        offersAttachments: Bool = false,
        mentionPattern: NSRegularExpression? = nil,
        draftStore: ChatDraftStore = ChatDraftStore(),
    ) {
        self.network = network
        self.chatKey = chatKey
        self.title = title
        self.subtitle = subtitle
        self.canReply = canReply
        self.offersAttachments = offersAttachments
        self.mentionPattern = mentionPattern
        self.draftStore = draftStore
        draft = draftStore.draft(key: chatKey)
    }

    // MARK: Lifecycle and history

    /// Loads the conversation and starts following it; called again when the app becomes active.
    public func connect() async {
        preconditionFailure("\(type(of: self)) must override connect()")
    }

    /// Stops following the conversation when the chat closes.
    public func disconnect() {}

    public func loadEarlier() async {}

    public func loadLater() async {}

    /// Leaves an older window, if any, and scrolls to the newest message.
    public func jumpToLatest() async {
        scrollToLatestRequest += 1
    }

    /// Scrolls to a loaded message; networks that can load a window around older ones override this.
    public func jump(to messageId: String) async {
        if messagesById[messageId] != nil {
            jumpTarget = messageId
        }
    }

    public func clearJumpTarget() {
        jumpTarget = nil
    }

    /// The user has seen everything up to and including this message.
    public func markRead(upTo _: ChatMessage) {}

    /// The user saw these messages, and with them their reactions.
    public func reactionsSeen(on _: Set<String>) {}

    /// Scrolls to the oldest message with reactions the user hasn't seen.
    public func jumpToNextUnseenReaction() async {
        guard let messageId = unseenReactionMessageIds.first else { return }
        await jump(to: messageId)
    }

    // MARK: Polling

    /// Whether the chat is polling, which networks also read as "already connected".
    var isPolling: Bool {
        pollTask != nil
    }

    /// Calls `poll()` every `interval` until `stopPolling()`, for networks without pushed updates or as a
    /// fallback to them.
    func startPolling(every interval: Duration) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll, such as fetching the newest page; networks that call `startPolling(every:)` override it.
    func poll() async {}

    // MARK: Unread

    /// Whether the message is past the user's read position; networks that track one override this, and
    /// `isUnread`, `updateUnreadCount()` and `placeUnreadDivider()` build on it.
    func isAfterReadPosition(_: ChatMessage) -> Bool {
        false
    }

    func isUnread(_ message: ChatMessage) -> Bool {
        message.isUserMessage && !message.isOwn && !message.isDeleted && isAfterReadPosition(message)
    }

    /// Counts `history`, since `messages` may be held back while the chat opens.
    func updateUnreadCount() {
        let count = history.count(where: isUnread)
        if unreadCount != count {
            unreadCount = count
        }
    }

    /// Puts the "New Messages" divider above the first unread message, unless this visit already placed it. It
    /// reads `history`, since `messages` stays empty while restored messages are held (see `expectUnread()`).
    func placeUnreadDivider() {
        if firstUnreadMessageId == nil {
            firstUnreadMessageId = history.first(where: isUnread)?.id
        }
    }

    /// Tells the network the new read position shortly after it moves, so reading a burst of messages sends one
    /// mark: each call replaces the one still waiting. Failures are ignored, since the next read sends it again.
    func scheduleReadMarker(_ send: @escaping @MainActor () async throws -> Void) {
        readSendTask?.cancel()
        readSendTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil, !Task.isCancelled else { return }
            try? await send()
        }
    }

    /// Tells the network which reactions the user saw, shortly after, like `scheduleReadMarker`. Each send
    /// covers every message seen since the last one that went through, so replacing a waiting one loses nothing.
    func scheduleReactionsSeen(_ send: @escaping @MainActor () async throws -> Void) {
        reactionsSeenSendTask?.cancel()
        reactionsSeenSendTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil, !Task.isCancelled else { return }
            try? await send()
        }
    }

    // MARK: Composing

    public func send() async {
        preconditionFailure("\(type(of: self)) must override send()")
    }

    /// Call as the user edits the draft, for typing indications.
    public func draftDidChange() {}

    /// The optimistic send every network shares: the message shows at once as sending and the composer clears;
    /// `deliver` sends it and returns the network's id for it (nil when unknown). The sending copy stays until a
    /// message with that id is in `history`, so it never blinks out; without an id it goes when `deliver`
    /// returns, which should first load the sent message. A failure takes it away and puts the text and
    /// attachment back in the composer, if the user hasn't started another message.
    func sendOptimistically(text: String, attachment: ChatAttachment?, replyToId: String?, deliver: () async throws -> String?) async {
        errorMessage = nil
        let localId = "sending-\(UUID().uuidString)"
        historyAtSend[localId] = Set(history.map(\.id))
        let image = attachment.flatMap { Self.localImage(attachment: $0, id: localId) }
        outgoing.append(ChatMessage(
            id: localId,
            sender: ChatUser(id: "you", name: "You", avatarURL: nil),
            timestamp: Date(),
            text: text.isEmpty ? nil : text,
            embeds: image.map { [$0] } ?? attachment.map { [.pending(title: $0.filename)] } ?? [],
            replyToId: replyToId,
            isOwn: true,
            isSending: true,
        ))
        draft = ""
        self.attachment = nil
        replyingTo = nil
        composeMessages()
        scrollToLatestRequest += 1
        do {
            if let id = try await deliver() {
                pickedImages[id] = image
                awaitingHistory[id] = localId
            } else {
                historyAtSend[localId] = nil
                outgoing.removeAll { $0.id == localId }
            }
            AppMetrics.messageSent(network: network, hasAttachment: attachment != nil, isReply: replyToId != nil, error: nil)
        } catch {
            AppMetrics.messageSent(network: network, hasAttachment: attachment != nil, isReply: replyToId != nil, error: error)
            historyAtSend[localId] = nil
            outgoing.removeAll { $0.id == localId }
            if draft.isEmpty, self.attachment == nil {
                draft = text
                self.attachment = attachment
            }
            errorMessage = error.localizedDescription
        }
        composeMessages()
    }

    /// Sets reactions before the messages they belong to, so new bubbles render with their reactions instead of
    /// growing a moment later.
    func publish(history newHistory: [ChatMessage], reactions newReactions: [String: [ChatReaction]]) {
        if reactions != newReactions {
            reactions = newReactions
        }
        if history != newHistory {
            history = newHistory
        }
    }

    /// Called as a chat opens from a Chats row with unread messages. When the messages restored from the last visit
    /// hold none of them, showing those would open at their bottom and then jump once history adds the new
    /// messages and the "New Messages" divider. So the chat shows nothing until history arrives, for at most 1.5
    /// seconds, and then opens at the divider.
    /// The picture beside the title: the other person in a one-to-one chat, else the chat's own from its row.
    public var titleAvatar: ChatTitleAvatar? {
        avatarUserId.map { ChatTitleAvatar(url: avatarURL, colorKey: $0) } ?? rowAvatar
    }

    /// Shows the chat's Chats row picture beside the title, as the row does.
    public func showRowAvatar(url: URL?, colorKey: String?) {
        rowAvatar = ChatTitleAvatar(url: url, colorKey: colorKey)
    }

    public func expectUnread() {
        guard unreadCount == 0, state == .connecting else { return }
        holdsRestoredMessages = true
        composeMessages()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.releaseRestoredMessages()
        }
    }

    private func releaseRestoredMessages() {
        guard holdsRestoredMessages else { return }
        holdsRestoredMessages = false
        composeMessages()
    }

    private func composeMessages() {
        // A pushed update can bring the sent message before the send returns its id; showing both copies until then
        // would add a row and take it away again.
        for local in outgoing {
            guard let before = historyAtSend[local.id], !awaitingHistory.values.contains(local.id) else { continue }
            let claimed = Set(awaitingHistory.keys).union(sentLocalIds.keys)
            if let sent = history.last(where: { $0.isOwn && !before.contains($0.id) && !claimed.contains($0.id) && $0.text == local.text }) {
                awaitingHistory[sent.id] = local.id
            }
        }
        let ids = Set(history.map(\.id))
        for (id, localId) in awaitingHistory where ids.contains(id) {
            awaitingHistory[id] = nil
            sentLocalIds[id] = localId
            historyAtSend[localId] = nil
            outgoing.removeAll { $0.id == localId }
        }
        let shown = holdsRestoredMessages ? [] : history.map { message in pickedImages[message.id].map(message.showing) ?? message } + outgoing
        if messages != shown {
            messages = shown
        }
    }

    /// The picked image, written to a local file the chat's image views load like any URL.
    private static func localImage(attachment: ChatAttachment, id: String) -> ChatEmbed? {
        guard attachment.isImage else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(id)-\(attachment.filename)")
        guard (try? attachment.data.write(to: file)) != nil else { return nil }
        return .image(url: file, aspectRatio: aspectRatio(of: attachment.data), alt: nil, link: nil, opensViewer: true)
    }

    private static func aspectRatio(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double, height > 0
        else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? height / width : width / height
    }

    public func startReply(to message: ChatMessage) {
        guard canReply, message.isUserMessage, !message.isDeleted, !message.isSending else { return }
        replyingTo = message
    }

    public func cancelReply() {
        replyingTo = nil
    }

    public func mentionSuggestions(for _: String) -> [ChatUser] {
        []
    }

    // MARK: Reactions

    public func yourEmojis(on _: String) -> [String] {
        []
    }

    /// Adds the emoji, or removes it when you already reacted with it.
    public func toggleReaction(_: String, on _: String) async {}

    public func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    // MARK: Display

    /// An older window doesn't reach the newest message, so it has nothing to report about the latest one.
    private func reportSummary() {
        guard let summaryDidChange else { return }
        let latest = hasLaterMessages ? nil : messages.last { $0.isUserMessage && !$0.isDeleted }
        summaryDidChange(latest, latest.map(summaryBody), unreadCount, tracksUnseenReactions ? unseenReactionMessageIds.count : nil)
    }

    /// One line for the Chats list: the text with mentions by name, or what was shared.
    private func summaryBody(for message: ChatMessage) -> String {
        if let text = message.text, !text.isEmpty {
            return showingMentionNames(SpoilerText.mask(text, ranges: message.spoilers)).replacingOccurrences(of: "\n", with: " ")
        }
        switch message.embeds.first {
        case let .audio(_, title, _, _, _, _), let .card(title, _, _, _, _):
            return "Shared “\(title)”"
        case .image:
            return "Photo"
        case let .pending(title):
            return title
        case nil:
            return "Message"
        }
    }

    /// The clip an `.audio` embed plays, resolved when the user first presses play.
    public func audioPreviewURL(for _: String) async -> URL? {
        nil
    }

    public func avatarURL(for user: ChatUser) -> URL? {
        user.avatarURL
    }

    // MARK: Links

    /// A link to the message to share, offered as Copy Link; `nil` when the network has none.
    public func link(toMessage _: String) -> URL? {
        nil
    }

    /// What a link in this chat's messages points at in this same chat, which the chat then shows; `nil` opens
    /// it as usual.
    public func linkTarget(for _: URL) -> ChatLinkTarget? {
        nil
    }

    /// The base for relative links in this chat's messages, such as an Apron room's server.
    public var linkBaseURL: URL? {
        nil
    }

    public func message(withId id: String) -> ChatMessage? {
        messagesById[id] ?? referencedMessages[id]
    }

    public func isUnavailableReference(_ messageId: String) -> Bool {
        unavailableReferences.contains(messageId)
    }

    /// Plain text with mentions shown by name, for previews such as reply quotes.
    public func showingMentionNames(_ text: String) -> String {
        guard let mentionPattern else { return text }
        var result = text
        for match in mentionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let name = mentionNames[String(text[range].dropFirst())] else { continue }
            result.replaceSubrange(range, with: "@\(name)")
        }
        return result
    }

    /// Markdown messages render as inline CommonMark, cached per text; raw HTML is never rendered.
    public func renderedText(for message: ChatMessage) -> AttributedString {
        let text = message.text ?? ""
        guard message.isMarkdown else { return AttributedString(text) }
        if let cached = renderedTextCache[text] {
            return cached
        }
        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        renderedTextCache[text] = rendered
        return rendered
    }
}

/// A picture beside a chat's title; without a URL, initials on the color of `colorKey`, or a gray initial.
public struct ChatTitleAvatar: Equatable, Sendable {
    public let url: URL?
    public let colorKey: String?
}
