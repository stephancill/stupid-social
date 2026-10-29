import Foundation

/// Preview chats across networks for demo mode, so the Chats list and chat screen can be browsed without
/// credentials. Nothing is sent: messages and reactions change only in memory.
public struct DemoChatListProvider: ChatListProvider {
    public let network = SocialNetwork.debug

    public init() {}

    public func chatList() async throws -> ChatListPage {
        guard DemoData.isDemoMode else { throw SourceError.notConfigured }
        return ChatListPage(chats: DemoChats.summaries(), archived: [])
    }
}

enum DemoChats {
    struct Chat: Sendable {
        let id: String
        let network: SocialNetwork
        let title: String
        var titlePrefix: String?
        var avatarURL: URL?
        var unreadCount = 0
        var isGroup = false
        var isMuted = false
        var presence: ChatPresence?
        let messages: @Sendable (Date) -> [ChatMessage]
        var reactions: [String: [ChatReaction]] = [:]
    }

    static let you = ChatUser(id: "demo-you", name: "You", avatarURL: nil)
    static let maya = person("maya", "Maya Chen", women: 44)
    static let jules = person("jules", "Jules", women: 65)
    static let amy = person("amy", "Amy", women: 21)
    static let riley = person("riley", "Riley", men: 32)
    static let kade = person("kade", "Kade", men: 75)
    static let nova = person("nova", "Nova", women: 8)
    static let theo = person("theo", "Theo", men: 12)

    static let customEmojis: [String: ChatCustomEmoji] = [
        ":apron:": ChatCustomEmoji(key: ":apron:", url: URL(string: "https://media.apron.chat/e/nrIp9696F6rvBbltXXvS6A")!, category: "Apron"),
        ":stupid-social:": ChatCustomEmoji(key: ":stupid-social:", url: URL(string: "https://media.apron.chat/e/Z8cTDyVmJWip_2338U2POA")!, category: "Apron"),
    ]

    static let chats: [Chat] = [
        Chat(
            id: "apron-general", network: .apron, title: "general", titlePrefix: "apron.chat",
            avatarURL: URL(string: "https://web.apron.chat/icon-512.png"), unreadCount: 3, isGroup: true,
            messages: { now in
                [
                    message("a1", nova, now, minutes: 42, "Anyone tried the new custom emoji yet? :apron:"),
                    message("a2", theo, now, minutes: 40, "Yes! :stupid-social: works in reactions too"),
                    message("a3", you, now, minutes: 31, "Shipped # autocomplete for rooms today, try it in the composer"),
                    message("a4", nova, now, minutes: 12, "Linking the thread from #design so we don't lose it", embeds: [
                        .message(title: "Theo in #design", text: "What if every chat looked the same no matter which network it came from?", link: nil),
                    ]),
                    message("a5", theo, now, minutes: 9, "One inbox for everything. No feed. That's the dream", replyTo: "a4"),
                    message("a6", maya, now, minutes: 2, "Telegram, X and Bluesky DMs all in one list now 🤯"),
                ]
            },
            reactions: [
                "a1": [ChatReaction(emoji: ":apron:", count: 4, includesYou: true), ChatReaction(emoji: "🔥", count: 2, includesYou: false)],
                "a3": [ChatReaction(emoji: "🎉", count: 5, includesYou: false), ChatReaction(emoji: ":stupid-social:", count: 3, includesYou: false)],
                "a5": [ChatReaction(emoji: "💯", count: 2, includesYou: true)],
            ],
        ),
        Chat(
            id: "telegram-maya", network: .telegram, title: "Maya Chen", avatarURL: maya.avatarURL, unreadCount: 2, presence: .online,
            messages: { now in
                [
                    message("t1", maya, now, minutes: 64, "are you coming to the climbing gym saturday?"),
                    message("t2", you, now, minutes: 60, "yes! 10am?"),
                    message("t3", maya, now, minutes: 5, "perfect, I'll bring the spare shoes"),
                    message("t4", maya, now, minutes: 4, "", embeds: [.image(url: URL(string: "https://picsum.photos/seed/climbwall/1200/900")!, aspectRatio: 4 / 3, alt: nil, link: nil, opensViewer: true)]),
                ]
            },
            reactions: ["t2": [ChatReaction(emoji: "👍", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "x-jules", network: .x, title: "Jules", avatarURL: jules.avatarURL, unreadCount: 1,
            messages: { now in
                [
                    message("x1", you, now, minutes: 30, "did you see X Chat is encrypted end to end now?"),
                    message("x2", jules, now, minutes: 18, "and it works outside the X app 👀"),
                ]
            },
        ),
        Chat(
            id: "instagram-amy", network: .instagram, title: "Amy", avatarURL: amy.avatarURL,
            messages: { now in
                [
                    message("i1", amy, now, minutes: 95, "", embeds: [.image(url: URL(string: "https://picsum.photos/seed/sunset-coast/1000/1250")!, aspectRatio: 0.8, alt: nil, link: nil, opensViewer: true)]),
                    message("i2", amy, now, minutes: 94, "sunset from last night"),
                    message("i3", you, now, minutes: 41, "wow, where is this?"),
                ]
            },
            reactions: ["i1": [ChatReaction(emoji: "😍", count: 1, includesYou: true)]],
        ),
        Chat(
            id: "spotify-riley", network: .spotify, title: "Riley", avatarURL: riley.avatarURL,
            messages: { now in
                [
                    message("s1", riley, now, minutes: 180, "", embeds: [
                        .audio(previewId: "demo", title: "Midnight Drive", subtitle: "The Night Owls", detail: "3:42", imageURL: URL(string: "https://picsum.photos/seed/album-night/400/400"), link: nil),
                    ]),
                    message("s2", you, now, minutes: 150, "on repeat all morning"),
                ]
            },
        ),
        Chat(
            id: "bluesky-kade", network: .bluesky, title: "Kade", avatarURL: kade.avatarURL,
            messages: { now in
                [
                    message("b1", kade, now, minutes: 300, "your app finally got me to delete the feed apps"),
                    message("b2", you, now, minutes: 290, "that's the whole idea 😄"),
                ]
            },
            reactions: ["b2": [ChatReaction(emoji: "❤️", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "telegram-climbing", network: .telegram, title: "Weekend Climbing 🧗", unreadCount: 14, isGroup: true, isMuted: true,
            messages: { now in
                [
                    message("g1", theo, now, minutes: 420, "Who's in for the crag on Sunday?"),
                    message("g2", maya, now, minutes: 400, "me + 2 friends"),
                ]
            },
        ),
    ]

    static func summaries(now: Date = Date()) -> [ChatSummary] {
        chats.map { chat in
            let latest = chat.messages(now).last
            let body = latest?.previewText ?? ""
            let preview = if latest?.isOwn == true {
                "You: \(body)"
            } else if chat.isGroup, let latest {
                "\(latest.sender.name): \(body)"
            } else {
                body
            }
            return ChatSummary(
                id: "demo:\(chat.id)",
                network: chat.network,
                title: chat.title,
                titlePrefix: chat.titlePrefix,
                avatarURL: chat.avatarURL,
                avatarColorKey: chat.id,
                preview: preview,
                timestamp: latest?.timestamp,
                unreadCount: chat.unreadCount,
                destination: .demo(chatId: chat.id),
                namesSenderInPreview: chat.isGroup,
                isMuted: chat.isMuted,
                presence: chat.presence,
            )
        }
    }

    private static func person(_ id: String, _ name: String, women: Int? = nil, men: Int? = nil) -> ChatUser {
        let url = if let women {
            URL(string: "https://randomuser.me/api/portraits/women/\(women).jpg")
        } else {
            URL(string: "https://randomuser.me/api/portraits/men/\(men ?? 1).jpg")
        }
        return ChatUser(id: "demo-\(id)", name: name, avatarURL: url)
    }

    private static func message(_ id: String, _ sender: ChatUser, _ now: Date, minutes: Double, _ text: String, embeds: [ChatEmbed] = [], replyTo: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id,
            sender: sender,
            timestamp: now.addingTimeInterval(-60 * minutes),
            text: text.isEmpty ? nil : text,
            embeds: embeds,
            replyToId: replyTo,
            isOwn: sender.id == you.id,
        )
    }
}

/// One preview chat. Sending and reacting only change what it shows.
@MainActor
public final class DemoChatAdapter: ChatReactionSending, ChatCustomEmojis {
    public let network: SocialNetwork
    public let key: String
    public let canReply = true
    public let acceptsAttachments = false
    public let pollInterval: Duration? = nil
    public var onChange: (() -> Void)?
    public let info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]]
    public let hasEarlierMessages = false
    public let acceptsReactions = true
    public let customEmojis: [String: ChatCustomEmoji]
    private let chat: DemoChats.Chat
    private let readCount: Int

    public init(chatId: String) {
        let chat = DemoChats.chats.first { $0.id == chatId } ?? DemoChats.chats[0]
        self.chat = chat
        network = chat.network
        key = "demo:\(chat.id)"
        reactions = chat.reactions
        customEmojis = chat.network == .apron ? DemoChats.customEmojis : [:]
        readCount = chat.messages(Date()).count - chat.unreadCount
        var info = ChatInfo(title: chat.title, subtitle: chat.isGroup ? "5 members" : (chat.presence?.text ?? ""), showsSenderNames: chat.isGroup)
        if !chat.isGroup {
            info.avatarUserId = chat.id
            info.avatarURL = chat.avatarURL
        }
        self.info = info
    }

    public func loadNewest() async throws {
        if messages.isEmpty {
            messages = chat.messages(Date())
        }
    }

    public func loadEarlier() async throws {}

    public func send(_ message: ChatOutgoing) async throws -> String? {
        let id = UUID().uuidString
        messages.append(ChatMessage(id: id, sender: DemoChats.you, timestamp: Date(), text: message.text, replyToId: message.replyToId, isOwn: true))
        return id
    }

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return false }
        return index >= readCount
    }

    public func markRead(upTo _: ChatMessage) -> (@MainActor () async throws -> Void)? {
        nil
    }

    public func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    public func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId, default: []].filter(\.includesYou).map(\.emoji)
    }

    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        var list = reactions[messageId, default: []]
        if let index = list.firstIndex(where: { $0.emoji == emoji }) {
            let reaction = list[index]
            let count = reaction.count + (reaction.includesYou ? -1 : 1)
            if count == 0 {
                list.remove(at: index)
            } else {
                list[index] = ChatReaction(emoji: emoji, count: count, includesYou: !reaction.includesYou)
            }
        } else {
            list.append(ChatReaction(emoji: emoji, count: 1, includesYou: true))
        }
        reactions[messageId] = list
        onChange?()
    }

    public func snapshot() -> Data? {
        nil
    }

    public func restore(snapshot _: Data) {}
}
