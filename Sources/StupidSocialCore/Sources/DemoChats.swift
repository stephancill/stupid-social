import Foundation

/// Preview chats across networks for demo mode, so the Chats list and chat screen can be browsed without
/// credentials. Nothing is sent: messages and reactions change only in memory.
public struct DemoChatListProvider: ChatListProvider {
    public let chatNetwork = ChatNetwork.debug

    public init() {}

    public func chatList() async throws -> ChatListPage {
        guard DemoData.isDemoMode else { throw SourceError.notConfigured }
        return ChatListPage(chats: DemoChats.summaries(), archived: [])
    }
}

enum DemoChats {
    struct Chat {
        let id: String
        let network: ChatNetwork
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

    /// Plays for the demo's voice messages and audio file; each adds a fragment, since the player follows clips by id.
    static let voiceSample = "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"

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

    /// A voice message's levels: a few phrases with pauses between them, the same every time.
    static func waveform(seed: Int) -> [Double] {
        (0 ..< 100).map { index in
            let phrase = sin(Double(index + seed) / 6.5)
            let syllable = abs(sin(Double(index * (seed + 3)) / 2.3))
            return phrase > -0.3 ? 0.25 + 0.75 * syllable * (phrase + 0.3) / 1.3 : 0.05
        }
    }

    static func picture(_ id: Int, _ width: Int, _ height: Int) -> ChatEmbed {
        .image(url: DemoData.photo(id, width, height), aspectRatio: Double(width) / Double(height), alt: nil, link: nil, opensViewer: true)
    }

    static let chats: [Chat] = [
        Chat(
            id: "telegram-trip", network: .telegram, title: "Trip Photos 📸", isGroup: true,
            messages: { now in
                [
                    message("m1", maya, now, minutes: 240, "made it!! first batch from the coast", embeds: [
                        picture(1050, 1200, 900), picture(1052, 900, 900), picture(211, 900, 900),
                    ]),
                    message("m2", theo, now, minutes: 230, "the cliff path is covered in these", embeds: [
                        .video(url: URL(string: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4")!, posterURL: DemoData.photo(152, 1280, 720), aspectRatio: 16 / 9, duration: "0:05", isGIF: false),
                    ]),
                    message("m3", nova, now, minutes: 200, "", embeds: [
                        .video(url: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4")!, posterURL: nil, aspectRatio: 16 / 9, duration: nil, isGIF: true),
                    ]),
                    message("m4", maya, now, minutes: 120, "", embeds: [.voice(previewId: Self.voiceSample + "#maya", duration: 14, waveform: waveform(seed: 1))]),
                    message("m5", you, now, minutes: 110, "", embeds: [.voice(previewId: Self.voiceSample + "#you", duration: 6, waveform: waveform(seed: 4))]),
                    message("m5b", theo, now, minutes: 90, "booked the cabin for saturday night https://seacliffcabins.com/the-loft", embeds: [
                        .card(title: "The Loft · Seacliff Cabins", subtitle: "Sleeps 4 · wood stove · deck over the water", systemImage: "link", imageURL: DemoData.photo(424, 400, 400), link: URL(string: "https://seacliffcabins.com/the-loft")),
                    ]),
                    message("m5c", you, now, minutes: 80, "and the route for sunday https://trailguide.io/cliff-path-loop", embeds: [
                        .card(title: "Cliff path loop", subtitle: "11.4 km · 3h 40m · moderate, with a swim stop halfway", systemImage: "link", imageURL: nil, link: URL(string: "https://trailguide.io/cliff-path-loop")),
                    ]),
                    message("m5d", maya, now, minutes: 72, "the tide pools from last year https://pinboard.social/maya/posts/1182", embeds: [
                        .linkPreview(title: "Maya Chen (@maya)", subtitle: "low tide at the point, every pool full of anemones", link: URL(string: "https://pinboard.social/maya/posts/1182"), media: [
                            picture(1011, 960, 1280), picture(1043, 960, 1280), picture(1036, 960, 1280), picture(1039, 960, 1280),
                        ]),
                    ]),
                    message("m5e", nova, now, minutes: 66, "https://pinboard.social/nova/posts/77", embeds: [
                        .linkPreview(title: "Nova (@nova)", subtitle: "how the cliff path looked in spring", link: URL(string: "https://pinboard.social/nova/posts/77"), media: [
                            .video(url: URL(string: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4")!, posterURL: DemoData.photo(152, 1280, 720), aspectRatio: 16 / 9, duration: "0:05", isGIF: false),
                        ]),
                    ]),
                    message("m6", theo, now, minutes: 60, "", embeds: [
                        .file(url: URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf")!, filename: "packing list.pdf", subtitle: "13 KB", thumbnailURL: nil),
                    ]),
                    message("m7", nova, now, minutes: 45, "", embeds: [
                        .audio(previewId: Self.voiceSample + "#mix", title: "roadtrip mix v2", subtitle: "MP3 · 6:12", detail: nil, imageURL: nil, link: nil),
                    ]),
                    message("m8", maya, now, minutes: 20, "same time next year? 🧗"),
                ]
            },
            reactions: [
                "m1": [ChatReaction(emoji: "😍", count: 3, includesYou: true)],
                "m7": [ChatReaction(emoji: "🔥", count: 2, includesYou: false)],
                "m8": [ChatReaction(emoji: "🙋", count: 4, includesYou: true)],
            ],
        ),
        Chat(
            id: "apron-general", network: .apron, title: "general", titlePrefix: "apron.chat",
            avatarURL: URL(string: "https://web.apron.chat/icon-512.png"), unreadCount: 3, isGroup: true,
            messages: { now in
                [
                    message("a1", nova, now, minutes: 42, "ok the new overhang wall at the gym is SO good"),
                    message("a2", theo, now, minutes: 40, "I fell off the purple one 11 times 😭"),
                    message("a3", you, now, minutes: 31, "going tomorrow after work if anyone wants to join"),
                    message("a4", nova, now, minutes: 12, "linking this from #routes so it doesn't get buried", embeds: [
                        .message(title: "Theo in #routes", text: "purple problem: start low, left heel hook, then just trust the sloper", link: nil),
                    ]),
                    message("a5", theo, now, minutes: 9, "\"just trust the sloper\" is my new life motto", replyTo: "a4"),
                    message("a6", maya, now, minutes: 2, "save me a spot, I'll bring snacks 🍪"),
                ]
            },
            reactions: [
                "a1": [ChatReaction(emoji: ":apron:", count: 4, includesYou: true), ChatReaction(emoji: "🔥", count: 2, includesYou: false)],
                "a3": [ChatReaction(emoji: "🙋", count: 3, includesYou: false), ChatReaction(emoji: ":stupid-social:", count: 2, includesYou: false)],
                "a5": [ChatReaction(emoji: "💯", count: 2, includesYou: true)],
            ],
        ),
        Chat(
            id: "telegram-maya", network: .telegram, title: "Maya Chen", avatarURL: maya.avatarURL, unreadCount: 2, presence: .online,
            messages: { now in
                [
                    message("t1", maya, now, minutes: 64, "are you still coming saturday?"),
                    message("t2", you, now, minutes: 60, "yes!! what time"),
                    message("t3", maya, now, minutes: 5, "10ish. this is where we're going 😍"),
                    message("t4", maya, now, minutes: 4, "", embeds: [picture(1015, 1200, 900)]),
                ]
            },
            reactions: ["t2": [ChatReaction(emoji: "👍", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "x-jules", network: .x, title: "Jules", avatarURL: jules.avatarURL, unreadCount: 1,
            messages: { now in
                [
                    message("x1", you, now, minutes: 30, "did you end up getting the film camera?"),
                    message("x2", jules, now, minutes: 18, "I did 👀 first roll gets developed this week"),
                ]
            },
        ),
        Chat(
            id: "instagram-amy", network: .instagram, title: "Amy", avatarURL: amy.avatarURL,
            messages: { now in
                [
                    message("i1", amy, now, minutes: 95, "", embeds: [picture(900, 1000, 1250)]),
                    message("i2", amy, now, minutes: 94, "sunset from the pier last night"),
                    message("i3", you, now, minutes: 41, "ok I need to go there. where is this??"),
                ]
            },
            reactions: ["i1": [ChatReaction(emoji: "😍", count: 1, includesYou: true)]],
        ),
        Chat(
            id: "spotify-riley", network: .spotify, title: "Riley", avatarURL: riley.avatarURL,
            messages: { now in
                [
                    message("s1", riley, now, minutes: 180, "", embeds: [
                        .audio(previewId: "demo", title: "Midnight Drive", subtitle: "The Night Owls", detail: "3:42", imageURL: DemoData.photo(1082, 400, 400), link: nil),
                    ]),
                    message("s2", you, now, minutes: 150, "on repeat all morning"),
                ]
            },
        ),
        Chat(
            id: "bluesky-kade", network: .bluesky, title: "Kade", avatarURL: kade.avatarURL,
            messages: { now in
                [
                    message("b1", kade, now, minutes: 300, "pushed the fix for the map tiles, can you try it on your phone?"),
                    message("b2", you, now, minutes: 290, "works now, and so fast 😄"),
                ]
            },
            reactions: ["b2": [ChatReaction(emoji: "❤️", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "telegram-climbing", network: .telegram, title: "Weekend Climbing 🧗", unreadCount: 14, isGroup: true, isMuted: true,
            messages: { now in
                [
                    message("g1", theo, now, minutes: 420, "who's in for the crag on sunday?"),
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
public final class DemoChatAdapter: ChatReactionSending, ChatCustomEmojis, ChatAudioPreviewing, ChatReadReceipts {
    public let network: ChatNetwork
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
    /// Sent this visit; no one reads them.
    private var sentIds: Set<String> = []

    public init(chatId: String) {
        let chat = DemoChats.chats.first { $0.id == chatId } ?? DemoChats.chats[0]
        self.chat = chat
        network = chat.network
        key = "demo:\(chat.id)"
        reactions = chat.reactions
        customEmojis = [.apron, .telegram].contains(chat.network) ? DemoChats.customEmojis : [:]
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
        sentIds.insert(id)
        return id
    }

    /// As the networks that report receipts show them: earlier messages seen, new ones sent.
    public func receipt(for message: ChatMessage) -> ChatReceipt? {
        guard [.telegram, .instagram, .x].contains(network) else { return nil }
        return sentIds.contains(message.id) ? .sent : .seen
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

    /// The demo's voice messages and audio file play a sample from the web; Spotify's preview has none.
    public func audioPreviewURL(for previewId: String) async -> URL? {
        URL(string: previewId).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    public func restore(snapshot _: Data) {}
}
