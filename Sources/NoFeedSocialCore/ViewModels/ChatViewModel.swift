import Foundation

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
    }

    /// Whether it is a real message someone sent, rather than a notice or system caption.
    public var isUserMessage: Bool {
        !isNotice && !sender.isSystem
    }

    /// One line describing the message, for reply quotes and the composer's reply preview.
    public var previewText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
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

/// What the shared chat screen shows and does. Each network subclasses it, publishes its messages as
/// `ChatMessage`s, and overrides the actions it supports; the capability flags hide the rest of the UI.
@MainActor
public class ChatViewModel: ObservableObject {
    @Published public internal(set) var messages: [ChatMessage] = [] {
        didSet {
            messagesById = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            reportSummary()
        }
    }

    @Published public internal(set) var state: ChatConnectionState = .connecting
    @Published public internal(set) var title: String
    @Published public internal(set) var subtitle: String
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
    @Published public var draft = "" {
        didSet { draftWasSet() }
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

    /// Whether swipe-to-reply and the Reply action are offered.
    public let canReply: Bool
    /// Whether the composer has an attachments button; `canAttach` enables it once the network allows uploads.
    public let offersAttachments: Bool
    /// `@user_id` mentions in message text, highlighted and tappable; `nil` when the network has none.
    public let mentionPattern: NSRegularExpression?

    public static let quickReactions = ["👍", "❤️", "😂", "🔥", "😮", "🙏"]
    public static let unreadBadgeCap = 50

    /// The newest message with its one-line preview, and the unread count, for the chat's row in the Chats list.
    var summaryDidChange: ((_ latest: ChatMessage?, _ body: String?, _ unreadCount: Int) -> Void)?
    private var messagesById: [String: ChatMessage] = [:]
    private var renderedTextCache: [String: AttributedString] = [:]

    init(title: String, subtitle: String, canReply: Bool, offersAttachments: Bool = false, mentionPattern: NSRegularExpression? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.canReply = canReply
        self.offersAttachments = offersAttachments
        self.mentionPattern = mentionPattern
    }

    public var canSend: Bool {
        state == .connected && !isSending && (attachment != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: Composing

    public func send() async {
        preconditionFailure("\(type(of: self)) must override send()")
    }

    /// Call as the user edits the draft, for typing indications.
    public func draftDidChange() {}

    /// Runs whenever `draft` is assigned, such as to keep it across visits.
    func draftWasSet() {}

    public func startReply(to message: ChatMessage) {
        guard canReply, message.isUserMessage, !message.isDeleted else { return }
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
        summaryDidChange(latest, latest.map(summaryBody), unreadCount)
    }

    /// One line for the Chats list: the text with mentions by name, or what was shared.
    private func summaryBody(for message: ChatMessage) -> String {
        if let text = message.text, !text.isEmpty {
            return showingMentionNames(text).replacingOccurrences(of: "\n", with: " ")
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
