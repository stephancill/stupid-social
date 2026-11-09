import Foundation

/// Discord message text as the chat shows it. Discord writes mentions, custom emoji and channel links as tokens
/// (`<@id>`, `<:name:id>`, `<#id>`, `<@&id>`, `<t:unix:style>`); the chat writes user mentions as `@<user id>`
/// (matched by `mentionPattern`), custom emoji as `:<emoji id>:` keys, and the rest as the text they read as.
enum DiscordText {
    static let userToken = try! NSRegularExpression(pattern: "<@!?(\\d{15,21})>")
    static let emojiToken = try! NSRegularExpression(pattern: "<(a?):([A-Za-z0-9_~]+):(\\d{15,21})>")
    static let channelToken = try! NSRegularExpression(pattern: "<#(\\d{15,21})>")
    static let roleToken = try! NSRegularExpression(pattern: "<@&(\\d{15,21})>")
    static let timestampToken = try! NSRegularExpression(pattern: "<t:(-?\\d{1,13})(?::([tTdDfFR]))?>")
    /// A mention as the chat writes it.
    static let mention = try! NSRegularExpression(pattern: "@(\\d{15,21})(?!\\d)")

    struct Context {
        var channelNames: [String: String] = [:]
        var roleNames: [String: String] = [:]
        /// For previews, which have no mention rendering: user id → name.
        var userNames: [String: String]?
    }

    /// The text and the custom emoji it uses.
    static func display(_ content: String, context: Context) -> (text: String, emojis: [DiscordEmoji]) {
        var emojis: [DiscordEmoji] = []
        var text = replace(emojiToken, in: content) { groups in
            emojis.append(DiscordEmoji(id: groups[3], name: groups[2], animated: groups[1] == "a"))
            return context.userNames == nil ? ":\(groups[3]):" : ":\(groups[2]):"
        }
        text = replace(userToken, in: text) { groups in
            if let names = context.userNames { return "@\(names[groups[1]] ?? "unknown")" }
            return "@\(groups[1])"
        }
        text = replace(channelToken, in: text) { "#\(context.channelNames[$0[1]] ?? "channel")" }
        text = replace(roleToken, in: text) { "@\(context.roleNames[$0[1]] ?? "role")" }
        text = replace(timestampToken, in: text) { groups in
            guard let seconds = TimeInterval(groups[1]) else { return groups[0] }
            return format(Date(timeIntervalSince1970: seconds), style: groups[2])
        }
        return (text, emojis)
    }

    /// The composer's `@<user id>` mentions as Discord's tokens.
    static func outgoing(_ text: String) -> String {
        replace(mention, in: text) { "<@\($0[1])>" }
    }

    private static func format(_ date: Date, style: String) -> String {
        switch style {
        case "t": date.formatted(date: .omitted, time: .shortened)
        case "T": date.formatted(date: .omitted, time: .standard)
        case "d": date.formatted(date: .numeric, time: .omitted)
        case "D": date.formatted(date: .long, time: .omitted)
        case "F": date.formatted(date: .complete, time: .shortened)
        case "R": date.formatted(.relative(presentation: .named))
        default: date.formatted(date: .long, time: .shortened)
        }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with replacement: ([String]) -> String) -> String {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let groups = (0 ..< match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: result).map { String(result[$0]) } ?? ""
            }
            result.replaceSubrange(range, with: replacement(groups))
        }
        return result
    }

    /// A one-line summary for the Chats list and notifications: the text, else what the message carries.
    static func preview(of message: DiscordMessage, context: Context) -> String {
        var context = context
        var names = context.userNames ?? [:]
        for user in message.mentions {
            names[user.id] = user.name
        }
        context.userNames = names
        let forwarded = message.forwarded
        let attachments = forwarded?.attachments ?? message.attachments
        let text = display(forwarded?.content ?? message.content, context: context).text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        if let attachment = attachments.first {
            let type = attachment.contentType ?? ""
            if type.hasPrefix("image/gif") { return "GIF" }
            if type.hasPrefix("image/") { return attachments.count > 1 ? "\(attachments.count) Photos" : "Photo" }
            if type.hasPrefix("video/") { return "Video" }
            if type.hasPrefix("audio/") { return attachment.waveform != nil || attachment.filename.hasPrefix("voice-message") ? "Voice message" : attachment.filename }
            return attachment.filename
        }
        if let sticker = (forwarded?.stickerItems ?? message.stickerItems)?.first { return "\(sticker.name) Sticker" }
        if let embed = (forwarded?.embeds ?? message.embeds).first { return embed.title ?? embed.description ?? "Link" }
        return systemText(message) ?? "Message"
    }

    /// What a system message reads as, such as a join or a pin; `nil` for a user's message.
    static func systemText(_ message: DiscordMessage) -> String? {
        let name = message.author.name
        return switch message.type {
        case 0, 19: nil
        case 1: "\(name) added someone to the group."
        case 2: "\(name) removed someone from the group."
        case 3: "\(name) started a call."
        case 4: "\(name) changed the group's name."
        case 5: "\(name) changed the group's icon."
        case 6: "\(name) pinned a message."
        case 7: "\(name) joined the server."
        case 8, 9, 10, 11: "\(name) boosted the server."
        case 18: "\(name) started a thread."
        case 20, 23: nil
        default: "\(name) did something Discord shows only in its apps."
        }
    }
}

/// An account's Discord chats for the Chats list: DMs and group DMs, and each guild's text channels the user can see,
/// listed as Apron lists rooms (the guild's name before the channel's). Rows come from the gateway's `READY` and
/// its events; the newest messages of the most recent rows are fetched for their previews and unread counts, and
/// kept until the channel's last message changes. Discord's own unread count is only its mention count, so other
/// unread channels count their unread messages in that page, or show one.
@MainActor
public final class DiscordChatList: ChatListProvider {
    public nonisolated let chatNetwork = ChatNetwork.discord
    /// Rows past this many, newest first, show no preview until a message arrives while the app is open.
    static let previewLimit = 25
    /// Posts listed per forum, newest activity first.
    static let forumPostLimit = 10

    let gateway: DiscordGateway
    private let accountId: String
    private weak var chatList: ChatListViewModel?
    private var observation: UUID?
    /// Channel id → its newest page as of a last message id.
    private var pages: [String: (lastMessageId: String, messages: [DiscordMessage])] = [:]
    /// Forum id → the posts listed for it, as of the forum's last post id.
    private var forumPosts: [String: (lastPostId: String?, postIds: [String])] = [:]

    public init(gateway: DiscordGateway, accountId: String, chatList: ChatListViewModel?) {
        self.gateway = gateway
        self.accountId = accountId
        self.chatList = chatList
        observation = gateway.observe { [weak self] update in
            switch update {
            case let .event(event): self?.handle(event)
            case .catchUp: Task { await chatList?.load() }
            }
        }
    }

    public nonisolated func chatList() async throws -> ChatListPage {
        try await rows()
    }

    private func rows() async throws -> ChatListPage {
        try await gateway.waitUntilReady()
        await loadForumPosts()
        let channels = listedChannels().sorted { DiscordSnowflake.isAfter($0.lastMessageId ?? "0", $1.lastMessageId) }
        let recent = channels.prefix(Self.previewLimit).filter { channel in
            pages[channel.id]?.lastMessageId != channel.lastMessageId
        }
        // A few at a time, as the web client loads channels.
        await withTaskGroup(of: (String, String, [DiscordMessage]?).self) { group in
            var pending = recent.makeIterator()
            func addNext() {
                guard let channel = pending.next(), let last = channel.lastMessageId else { return }
                group.addTask { [client = gateway.client] in
                    await (channel.id, last, try? client.messages(channelId: channel.id, limit: 50))
                }
            }
            for _ in 0 ..< 4 {
                addNext()
            }
            for await (channelId, last, page) in group {
                if let page {
                    pages[channelId] = (last, page)
                }
                addNext()
            }
        }
        return ChatListPage(chats: channels.map(summary), archived: [])
    }

    /// Channels with messages the user can see, without message requests and spam. Threads are listed once the user
    /// has joined them, and forums' newest posts (`loadForumPosts`) whether joined or not.
    func listedChannels() -> [DiscordChannel] {
        let posts = Set(forumPosts.values.flatMap(\.postIds))
        let privates = gateway.privateChannels.values.filter { $0.isListed && $0.isMessageRequest != true && $0.isSpam != true }
        let guildChannels = gateway.guilds.values.flatMap(\.channels).filter { channel in
            channel.isListed && (!channel.isThread || channel.member != nil || posts.contains(channel.id)) && gateway.canView(channel)
        }
        return (privates + guildChannels).filter { $0.lastMessageId != nil }
    }

    /// Each visible forum's newest posts, fetched again only when the forum has a newer post. A forum the user can't
    /// read keeps none.
    private func loadForumPosts() async {
        let forums = gateway.guilds.values.flatMap(\.channels).filter { $0.isForum && gateway.canView($0) }
        for forum in forums where forumPosts[forum.id] == nil || forumPosts[forum.id]?.lastPostId != forum.lastMessageId {
            guard let search = try? await gateway.client.forumThreads(channelId: forum.id, limit: Self.forumPostLimit) else { continue }
            let joined = Set((search.members ?? []).map(\.id))
            for var post in search.threads {
                post.guildId = forum.guildId
                if joined.contains(post.id) { post.member = DiscordChannel.ThreadMember(userId: gateway.me?.id) }
                gateway.remember(post)
            }
            forumPosts[forum.id] = (forum.lastMessageId, search.threads.map(\.id))
        }
    }

    func context(guildId: String?) -> DiscordText.Context {
        var context = DiscordText.Context(userNames: gateway.me.map { [$0.id: $0.name] } ?? [:])
        if let guild = gateway.guild(id: guildId) {
            context.channelNames = Dictionary(guild.channels.compactMap { channel in channel.name.map { (channel.id, $0) } }, uniquingKeysWith: { first, _ in first })
            context.roleNames = Dictionary(guild.roles.compactMap { role in role.name.map { (role.id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        return context
    }

    func summary(_ channel: DiscordChannel) -> ChatSummary {
        let me = gateway.me?.id
        let read = gateway.readStates[channel.id]
        let isUnread = channel.lastMessageId.map { DiscordSnowflake.isAfter($0, read?.lastMessageId) } ?? false
        let page = pages[channel.id]?.messages
        let latest = page?.first
        var unread = 0
        // A thread the user never opened has no read state, and Discord doesn't count it as unread.
        if isUnread, read != nil || !channel.isThread {
            let counted = page.map { $0.count(where: { $0.author.id != me && DiscordSnowflake.isAfter($0.id, read?.lastMessageId) }) } ?? 1
            unread = max(read?.mentionCount ?? 0, counted)
        }
        var preview: String?
        if let latest {
            let body = DiscordText.preview(of: latest, context: context(guildId: channel.guildId))
            preview = latest.author.id == me ? "You: \(body)" : (channel.type == DiscordChannel.dm ? body : "\(latest.author.name): \(body)")
        }
        let guild = gateway.guild(id: channel.guildId)
        let parent = channel.isThread ? gateway.channel(id: channel.parentId ?? "") : nil
        let others = (channel.recipients ?? []).filter { $0.id != me }
        let isDM = channel.type == DiscordChannel.dm
        return ChatSummary(
            id: Self.chatId(channelId: channel.id),
            network: .discord,
            title: channel.title,
            titlePrefix: guild.map { guild in parent?.name.map { "\(guild.name) / \($0)" } ?? guild.name },
            subtitle: channel.topic,
            avatarURL: isDM ? others.first?.avatarURL : (guild?.iconURL ?? channel.icon.flatMap { URL(string: "https://cdn.discordapp.com/channel-icons/\(channel.id)/\($0).png?size=128") }),
            avatarColorKey: isDM ? others.first?.id : channel.guildId ?? channel.id,
            preview: preview,
            timestamp: channel.lastMessageId.flatMap(DiscordSnowflake.date),
            unreadCount: unread,
            destination: .discord(channelId: channel.id),
            namesSenderInPreview: !isDM,
            titleNamesPeople: channel.isPrivate && channel.name?.isEmpty != false,
            isMuted: gateway.isMuted(channel),
        )
    }

    static func chatId(channelId: String) -> String {
        "discord:channel:\(channelId)"
    }
}

extension DiscordChatList: ChatListResolving {
    /// A channel the list leaves out, such as a DM just started from a profile (no messages yet) or a thread the
    /// user hasn't joined, as a row built from the gateway's state.
    public func chat(for destination: ChatDestination, in _: [ChatSummary]) -> ChatSummary? {
        guard case let .discord(channelId) = destination, let channel = gateway.channel(id: channelId) else { return nil }
        return summary(channel)
    }
}

extension DiscordChatList {
    // MARK: Live rows

    private func handle(_ event: DiscordGateway.Event) {
        switch event {
        case let .message(message):
            guard let channel = gateway.channel(id: message.channelId), channel.isListed, gateway.canView(channel) else { return }
            var page = pages[message.channelId]?.messages ?? []
            page.removeAll { $0.id == message.id }
            page.insert(message, at: 0)
            pages[message.channelId] = (message.id, Array(page.prefix(50)))
            publish(channel.id)
        case let .ack(channelId, _):
            publish(channelId)
        default:
            break
        }
    }

    private func publish(_ channelId: String) {
        guard let channel = gateway.channel(id: channelId) else { return }
        chatList?.updateChats([summary(channel)], accountId: accountId)
    }
}
