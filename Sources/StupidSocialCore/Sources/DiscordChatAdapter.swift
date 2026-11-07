import Foundation

/// One Discord channel (a DM, group DM or guild text channel): pages its history over REST, follows the gateway's
/// events for it, and sends, replies, edits, deletes, reacts, types and moves the read position as the web client
/// does. A guild channel subscribes to its guild's events when it opens; a poll catches what a large guild
/// doesn't send. Files go through Discord's upload slots; stickers are the standard packs and the guild's own (any
/// guild's with Nitro).
@MainActor
public final class DiscordChatAdapter: ChatAdapter, ChatReadOnlyAccess, ChatEditing, ChatDeleting, ChatReactionSending, ChatLiveUpdating, ChatReferenceResolving, ChatTyping, ChatMentioning, ChatCustomEmojis, ChatStickerSending {
    public let network = SocialNetwork.discord
    public let canReply = true
    /// Read again once connected: a guild channel may not allow files.
    public private(set) var acceptsAttachments = true
    /// Events arrive on the gateway; the poll covers guilds that send them only to some sessions.
    public let pollInterval: Duration? = .seconds(30)
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onError: ((Error) -> Void)?
    public private(set) var info: ChatInfo
    public private(set) var messages: [ChatMessage] = []
    public private(set) var reactions: [String: [ChatReaction]] = [:]
    public private(set) var hasEarlierMessages = false
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public private(set) var unavailableReferences: Set<String> = []
    public private(set) var customEmojis: [String: ChatCustomEmoji] = [:]
    public private(set) var mentionNames: [String: String] = [:]
    public private(set) var isReadOnly = false
    public private(set) var acceptsReactions = true

    private let gateway: DiscordGateway
    private let client: DiscordClient
    private let channelId: String
    private var loaded: [String: DiscordMessage] = [:]
    private var users: [String: DiscordUser] = [:]
    /// Guild nicknames by user id.
    private var nicknames: [String: String] = [:]
    private var meId: String?
    private var readId: String?
    private var observation: UUID?
    private var typing: [String: (name: String, until: Date)] = [:]
    private var typingExpiry: Task<Void, Never>?
    private var lastTypingSent: Date?
    /// Reactors fetched per "<message id>|<emoji key>".
    private var reactorCache: [String: [DiscordUser]] = [:]
    private var reactorRequests: Set<String> = []
    private var hasLoadedHistory = false

    public init(gateway: DiscordGateway, channelId: String, title: String) {
        self.gateway = gateway
        client = gateway.client
        self.channelId = channelId
        info = ChatInfo(title: title, subtitle: "Discord")
        applyChannel()
    }

    public var key: String {
        "discord:\(channelId)"
    }

    private var channel: DiscordChannel? {
        gateway.channel(id: channelId)
    }

    private func applyChannel() {
        meId = gateway.me?.id ?? meId
        if let read = gateway.readStates[channelId]?.lastMessageId, DiscordSnowflake.isAfter(read, readId) {
            readId = read
        }
        guard let channel else { return }
        let guild = gateway.guild(id: channel.guildId)
        let others = (channel.recipients ?? []).filter { $0.id != meId }
        for user in others {
            users[user.id] = user
        }
        info.title = channel.title
        info.titleIsMemberNames = channel.isPrivate && channel.name?.isEmpty != false
        if channel.type == DiscordChannel.dm {
            info.showsSenderNames = false
            info.subtitle = others.first?.username.map { "@\($0)" } ?? "Discord"
            info.avatarUserId = others.first?.id
            info.avatarURL = others.first?.avatarURL
        } else if channel.type == DiscordChannel.groupDM {
            info.subtitle = "\((channel.recipients ?? []).count + 1) members"
        } else if channel.isThread, let parent = gateway.channel(id: channel.parentId ?? "") {
            info.subtitle = [guild?.name, parent.name.map { "#\($0)" }].compactMap(\.self).joined(separator: " / ")
        } else {
            info.subtitle = guild?.name ?? "Discord"
        }
        if let guild {
            for member in guild.members ?? [] {
                guard let user = member.user else { continue }
                users[user.id] = user
                if let nick = member.nick { nicknames[user.id] = nick }
            }
            for emoji in guild.emojis ?? [] {
                register(emoji)
            }
            let permissions = gateway.permissions(in: channel)
            let send = channel.isThread ? DiscordPermissions.sendMessagesInThreads : DiscordPermissions.sendMessages
            isReadOnly = permissions & send == 0 || channel.threadMetadata?.locked == true
            acceptsReactions = permissions & DiscordPermissions.addReactions != 0
            acceptsAttachments = permissions & DiscordPermissions.attachFiles != 0
        }
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        let messages: [DiscordMessage]
        let users: [String: DiscordUser]
        let nicknames: [String: String]
        let meId: String?
        let readId: String?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
    }

    public func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder.discord.decode(Snapshot.self, from: data) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        users.merge(snapshot.users) { current, _ in current }
        nicknames.merge(snapshot.nicknames) { current, _ in current }
        meId = meId ?? snapshot.meId
        if let read = snapshot.readId, DiscordSnowflake.isAfter(read, readId) {
            readId = read
        }
        if channel == nil {
            info.title = snapshot.title
            info.subtitle = snapshot.subtitle
            info.showsSenderNames = snapshot.showsSenderNames
        }
        publish()
    }

    public func snapshot() -> Data? {
        let newest = sortedMessages.suffix(ChatSnapshotCache.messageLimit)
        return try? JSONEncoder.discord.encode(Snapshot(
            messages: Array(newest), users: users, nicknames: nicknames, meId: meId, readId: readId,
            title: info.title, subtitle: info.subtitle, showsSenderNames: info.showsSenderNames,
        ))
    }

    // MARK: Loading

    public func loadNewest() async throws {
        try await gateway.waitUntilReady()
        applyChannel()
        let page = try await client.messages(channelId: channelId, limit: 50)
        if !hasLoadedHistory {
            hasLoadedHistory = true
            hasEarlierMessages = page.count == 50
            // The snapshot's messages may have been deleted or edited since; the page replaces those it covers.
            if let oldest = page.last {
                loaded = loaded.filter { !DiscordSnowflake.isAfter($0.key, oldest.id) && $0.key != oldest.id }
            }
        }
        merge(page)
    }

    public func loadEarlier() async throws {
        guard let oldest = sortedMessages.first else { return }
        let page = try await client.messages(channelId: channelId, before: oldest.id, limit: 50)
        hasEarlierMessages = page.count == 50
        merge(page)
    }

    public func send(_ message: ChatOutgoing) async throws -> String? {
        let upload = if let attachment = message.attachment { try await client.upload(channelId: channelId, data: attachment.data, mimeType: attachment.mimeType, filename: attachment.filename) } else { DiscordUploaded?.none }
        let sent = try await client.send(channelId: channelId, content: DiscordText.outgoing(message.text), replyTo: message.replyToId, nonce: DiscordSnowflake.now(), upload: upload)
        accept(sent)
        return sent.id
    }

    /// The network's copy of a message the user sent, which also reads the channel up to it.
    private func accept(_ sent: DiscordMessage) {
        loaded[sent.id] = sent
        gateway.setRead(channelId: channelId, messageId: sent.id)
        readId = sent.id
        publish()
    }

    // MARK: Stickers

    /// The guild's own stickers first (without Nitro only this guild's can be sent here, and none in DMs), then
    /// Discord's standard packs.
    public func stickerSets() async throws -> [ChatStickerSet] {
        var sets: [ChatStickerSet] = []
        for guild in sendableGuildStickers() {
            let stickers = (guild.stickers ?? []).filter { $0.available != false }.compactMap(Self.sticker)
            guard !stickers.isEmpty else { continue }
            sets.append(ChatStickerSet(id: "guild:\(guild.id)", title: guild.name, cover: stickers.first, count: stickers.count, stickers: stickers))
        }
        for pack in try await gateway.standardStickerPacks() {
            let stickers = pack.stickers.compactMap(Self.sticker)
            let cover = pack.coverStickerId.flatMap { id in stickers.first { $0.id == id } } ?? stickers.first
            sets.append(ChatStickerSet(id: "pack:\(pack.id)", title: pack.name, cover: cover, count: stickers.count, stickers: stickers))
        }
        return sets
    }

    public func stickers(inSet id: String) async throws -> [ChatSticker] {
        try await stickerSets().first { $0.id == id }?.stickers ?? []
    }

    /// Stickers tagged with the emoji: a guild sticker's tag is the emoji it stands for.
    public func stickers(forEmoji emoji: String) async throws -> [ChatSticker] {
        let guildStickers = sendableGuildStickers().flatMap { $0.stickers ?? [] }
        let standard = try await gateway.standardStickerPacks().flatMap(\.stickers)
        return (guildStickers + standard)
            .filter { ($0.tags ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == emoji } }
            .compactMap(Self.sticker)
    }

    public func send(sticker: ChatSticker, replyToId: String?) async throws -> String? {
        let sent = try await client.send(channelId: channelId, content: "", replyTo: replyToId, nonce: DiscordSnowflake.now(), stickerIds: [sticker.id])
        accept(sent)
        return sent.id
    }

    private func sendableGuildStickers() -> [DiscordGuild] {
        if gateway.me?.premiumType ?? 0 > 0 {
            return gateway.guilds.values.sorted { $0.id == channel?.guildId && $1.id != channel?.guildId }
        }
        return gateway.guild(id: channel?.guildId).map { [$0] } ?? []
    }

    /// PNG, APNG and GIF stickers as images, Lottie ones as plain Lottie JSON.
    static func sticker(_ sticker: DiscordSticker) -> ChatSticker? {
        Self.sticker(id: sticker.id, formatType: sticker.formatType, alt: sticker.name)
    }

    static func sticker(id: String, formatType: Int, alt: String?) -> ChatSticker? {
        let poster = URL(string: "https://media.discordapp.net/stickers/\(id).png?size=160&passthrough=false")
        switch formatType {
        case 1, 2:
            guard let url = URL(string: "https://media.discordapp.net/stickers/\(id).png?size=320") else { return nil }
            return ChatSticker(id: id, url: url, format: .image, posterURL: nil, aspectRatio: 1, alt: alt)
        case 4:
            guard let url = URL(string: "https://media.discordapp.net/stickers/\(id).gif?size=320") else { return nil }
            return ChatSticker(id: id, url: url, format: .image, posterURL: nil, aspectRatio: 1, alt: alt)
        case 3:
            guard let url = URL(string: "https://discord.com/stickers/\(id).json") else { return nil }
            return ChatSticker(id: id, url: url, format: .lottie, posterURL: poster, aspectRatio: 1, alt: alt)
        default:
            return nil
        }
    }

    // MARK: Live

    public func startFollowing() async {
        guard observation == nil else { return }
        observation = gateway.observe { [weak self] event in self?.handle(event) }
        if let guildId = channel?.guildId {
            gateway.subscribe(guildId: guildId)
        }
    }

    public func stopFollowing() {
        observation.map(gateway.removeObserver)
        observation = nil
        typingExpiry?.cancel()
    }

    private func handle(_ event: DiscordGateway.Event) {
        switch event {
        case let .message(message) where message.channelId == channelId:
            typing[message.author.id] = nil
            loaded[message.id] = message
            publish()
        case let .messageUpdate(update) where update.channelId == channelId:
            guard var message = loaded[update.id] else { return }
            if let content = update.content { message.content = content }
            if let edited = update.editedTimestamp { message.editedTimestamp = edited }
            if let attachments = update.attachments { message.attachments = attachments }
            if let embeds = update.embeds { message.embeds = embeds }
            if let mentions = update.mentions { message.mentions = mentions }
            loaded[update.id] = message
            publish()
        case let .messageDelete(channelId, messageId) where channelId == self.channelId:
            guard loaded.removeValue(forKey: messageId) != nil else { return }
            publish()
        case let .reaction(channelId, messageId, userId, emoji, added) where channelId == self.channelId:
            guard userId != meId else { return }
            reactorCache[reactorKey(messageId, emoji.key ?? "")] = nil
            adjustReaction(emoji, on: messageId, by: added ? 1 : -1, mine: false)
        case let .typing(channelId, userId, name) where channelId == self.channelId:
            typing[userId] = (name ?? nicknames[userId] ?? users[userId]?.name ?? "Someone", Date().addingTimeInterval(10))
            scheduleTypingExpiry()
            onChange?()
        case let .ack(channelId, messageId) where channelId == self.channelId:
            if DiscordSnowflake.isAfter(messageId, readId) {
                readId = messageId
                onChange?()
            }
        case .reconnected:
            Task { try? await self.loadNewest() }
        default:
            break
        }
    }

    // MARK: Read position

    public func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        DiscordSnowflake.isAfter(message.id, readId)
    }

    public func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard DiscordSnowflake.isAfter(message.id, readId),
              loaded.values.contains(where: { $0.author.id != meId && DiscordSnowflake.isAfter($0.id, readId) && !DiscordSnowflake.isAfter($0.id, message.id) })
        else { return nil }
        readId = message.id
        gateway.setRead(channelId: channelId, messageId: message.id)
        return { [client, channelId, messageId = message.id] in
            try await client.ack(channelId: channelId, messageId: messageId)
        }
    }

    // MARK: Editing and deleting

    public func editableText(of message: ChatMessage) -> String? {
        guard let original = loaded[message.id], original.author.id == meId, original.isUserMessage else { return nil }
        return DiscordText.display(original.content, context: textContext).text
    }

    public func edit(_ messageId: String, text: String) async throws {
        let edited = try await client.edit(channelId: channelId, messageId: messageId, content: DiscordText.outgoing(text))
        loaded[messageId] = edited
        publish()
    }

    public func canDelete(_ message: ChatMessage) -> Bool {
        loaded[message.id]?.author.id == meId
    }

    public func delete(_ messageId: String) async throws {
        try await client.delete(channelId: channelId, messageId: messageId)
        loaded[messageId] = nil
        publish()
    }

    // MARK: Reactions

    public func yourEmojis(on messageId: String) -> [String] {
        (loaded[messageId]?.reactions ?? []).filter(\.me).compactMap(\.emoji.key)
    }

    public func toggleReaction(_ emoji: String, on messageId: String) async throws {
        let discordEmoji = discordEmoji(forKey: emoji)
        let remove = yourEmojis(on: messageId).contains(emoji)
        adjustReaction(discordEmoji, on: messageId, by: remove ? -1 : 1, mine: true)
        do {
            try await client.setReaction(channelId: channelId, messageId: messageId, emoji: discordEmoji, remove: remove)
        } catch {
            adjustReaction(discordEmoji, on: messageId, by: remove ? 1 : -1, mine: true)
            throw error
        }
    }

    private func discordEmoji(forKey key: String) -> DiscordEmoji {
        if key.hasPrefix(":"), key.hasSuffix(":"), key.count > 2 {
            let id = String(key.dropFirst().dropLast())
            return DiscordEmoji(id: id, name: customEmojis[key]?.alt?.trimmingCharacters(in: CharacterSet(charactersIn: ":")), animated: nil)
        }
        return DiscordEmoji(id: nil, name: key, animated: nil)
    }

    private func adjustReaction(_ emoji: DiscordEmoji, on messageId: String, by delta: Int, mine: Bool) {
        guard var message = loaded[messageId], let key = emoji.key else { return }
        var reactions = message.reactions ?? []
        if let index = reactions.firstIndex(where: { $0.emoji.key == key }) {
            reactions[index].count += delta
            if mine { reactions[index].me = delta > 0 }
            if reactions[index].count <= 0 { reactions.remove(at: index) }
        } else if delta > 0 {
            reactions.append(DiscordReaction(emoji: emoji, count: delta, me: mine))
        }
        message.reactions = reactions
        loaded[messageId] = message
        register(emoji)
        publish()
    }

    public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        let key = reactorKey(messageId, emoji)
        guard let users = reactorCache[key] else {
            loadReactors(emoji, on: messageId)
            return []
        }
        return users.map { ChatReactor(user: person($0.id, fallback: $0), date: nil, isYou: $0.id == meId) }
    }

    private func reactorKey(_ messageId: String, _ emoji: String) -> String {
        "\(messageId)|\(emoji)"
    }

    private func loadReactors(_ emoji: String, on messageId: String) {
        let key = reactorKey(messageId, emoji)
        guard !reactorRequests.contains(key) else { return }
        reactorRequests.insert(key)
        Task { [weak self, client, channelId] in
            guard let self else { return }
            let users = try? await client.reactors(channelId: channelId, messageId: messageId, emoji: discordEmoji(forKey: emoji))
            reactorRequests.remove(key)
            guard let users else { return }
            reactorCache[key] = users
            for user in users where self.users[user.id] == nil {
                self.users[user.id] = user
            }
            onChange?()
        }
    }

    // MARK: Typing

    public var typingNames: [String] {
        typing.values.filter { $0.until > Date() }.sorted { $0.until < $1.until }.map(\.name)
    }

    /// Discord shows typing for 10 s after each `typing` call; the web client calls again every 8 s or so while
    /// the draft changes.
    public func draftDidChange(_ draft: String) {
        guard !draft.isEmpty, Date().timeIntervalSince(lastTypingSent ?? .distantPast) > 8 else { return }
        lastTypingSent = Date()
        Task { [client, channelId] in try? await client.typing(channelId: channelId) }
    }

    private func scheduleTypingExpiry() {
        typingExpiry?.cancel()
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10.5))
            guard let self, !Task.isCancelled else { return }
            typing = typing.filter { $0.value.until > Date() }
            onChange?()
        }
    }

    // MARK: Mentions

    public var mentionPattern: NSRegularExpression? {
        DiscordText.mention
    }

    public func mentionSuggestions(for query: String) -> [ChatUser] {
        let query = query.lowercased()
        let candidates = users.values.filter { $0.id != meId && $0.bot != true }
        let matching = candidates.filter { user in
            query.isEmpty || displayName(user).lowercased().hasPrefix(query) || user.username?.lowercased().hasPrefix(query) == true
                || displayName(user).lowercased().split(separator: " ").contains { $0.hasPrefix(query) }
        }
        return matching.sorted { displayName($0) < displayName($1) }.prefix(20).map { person($0.id, fallback: $0) }
    }

    // MARK: Display

    private var textContext: DiscordText.Context {
        var context = DiscordText.Context()
        if let guild = gateway.guild(id: channel?.guildId) {
            context.channelNames = Dictionary(guild.channels.compactMap { channel in channel.name.map { (channel.id, $0) } }, uniquingKeysWith: { first, _ in first })
            context.roleNames = Dictionary(guild.roles.compactMap { role in role.name.map { (role.id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        return context
    }

    private var sortedMessages: [DiscordMessage] {
        loaded.values.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
    }

    private func merge(_ page: [DiscordMessage]) {
        for message in page {
            loaded[message.id] = message
        }
        publish()
    }

    private func register(_ emoji: DiscordEmoji) {
        guard let key = emoji.key, emoji.id != nil, customEmojis[key] == nil, let url = emoji.imageURL else { return }
        customEmojis[key] = ChatCustomEmoji(key: key, url: url, alt: ":\(emoji.name ?? "emoji"):", isHidden: true)
    }

    private func displayName(_ user: DiscordUser) -> String {
        nicknames[user.id] ?? user.name
    }

    private func person(_ id: String, fallback: DiscordUser? = nil) -> ChatUser {
        let user = users[id] ?? fallback
        return ChatUser(id: id, name: user.map(displayName) ?? nicknames[id], avatarURL: user?.avatarURL)
    }

    private func publish() {
        let context = textContext
        var referenced: [String: ChatMessage] = [:]
        var unavailable: Set<String> = []
        let sorted = sortedMessages
        for message in sorted {
            users[message.author.id] = message.author
            if let nick = message.member?.nick { nicknames[message.author.id] = nick }
            for user in message.mentions where users[user.id] == nil {
                users[user.id] = user
            }
            if message.type == 19, let referenceId = message.messageReference?.messageId, loaded[referenceId] == nil {
                if let quoted = message.referencedMessage?.message {
                    users[quoted.author.id] = users[quoted.author.id] ?? quoted.author
                    referenced[referenceId] = chatMessage(quoted, context: context)
                } else {
                    unavailable.insert(referenceId)
                }
            }
        }
        mentionNames = Dictionary(users.keys.map { ($0, displayName(users[$0]!)) }, uniquingKeysWith: { first, _ in first })
        var totals: [String: [ChatReaction]] = [:]
        for message in sorted {
            guard let list = message.reactions, !list.isEmpty else { continue }
            for reaction in list {
                register(reaction.emoji)
            }
            totals[message.id] = list.compactMap { reaction in
                reaction.emoji.key.map { ChatReaction(emoji: $0, count: reaction.count, includesYou: reaction.me) }
            }
        }
        reactions = totals
        referencedMessages = referenced
        unavailableReferences = unavailable
        messages = sorted.map { chatMessage($0, context: context) }
        onChange?()
    }

    private func chatMessage(_ message: DiscordMessage, context: DiscordText.Context) -> ChatMessage {
        let isOwn = message.author.id == meId
        if let system = DiscordText.systemText(message) {
            return ChatMessage(id: message.id, sender: ChatUser(id: "discord", name: "Discord", avatarURL: nil, isSystem: true), timestamp: message.date, text: system, isOwn: false)
        }
        let (text, emojis) = DiscordText.display(message.content, context: context)
        for emoji in emojis {
            register(emoji)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatMessage(
            id: message.id,
            sender: person(message.author.id, fallback: message.author),
            timestamp: message.date,
            text: trimmed.isEmpty ? nil : text,
            isMarkdown: true,
            embeds: Self.embeds(of: message, hasText: !trimmed.isEmpty),
            replyToId: message.type == 19 ? message.messageReference?.messageId : nil,
            isOwn: isOwn,
            isEdited: message.editedTimestamp != nil,
        )
    }

    static func embeds(of message: DiscordMessage, hasText: Bool) -> [ChatEmbed] {
        var embeds: [ChatEmbed] = []
        for attachment in message.attachments {
            guard let url = URL(string: attachment.url) else { continue }
            let aspect = attachment.width.flatMap { width in attachment.height.map { Double(width) / Double(max($0, 1)) } }
            let type = attachment.contentType ?? ""
            if type.hasPrefix("image/") {
                embeds.append(.image(url: url, aspectRatio: aspect, alt: attachment.filename, link: nil, opensViewer: true))
            } else if type.hasPrefix("video/") {
                embeds.append(.video(url: url, posterURL: attachment.proxyUrl.flatMap { URL(string: "\($0)\($0.contains("?") ? "&" : "?")format=jpeg") }, aspectRatio: aspect, duration: nil, isGIF: false))
            } else {
                let size = attachment.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                embeds.append(.file(url: url, filename: attachment.filename, subtitle: size, thumbnailURL: nil))
            }
        }
        for item in message.stickerItems ?? [] {
            if let sticker = sticker(id: item.id, formatType: item.formatType, alt: item.name) {
                embeds.append(.sticker(sticker))
            } else {
                embeds.append(.card(title: item.name, subtitle: "Sticker", systemImage: "face.smiling", imageURL: nil, link: nil))
            }
        }
        for embed in message.embeds {
            let thumbnail = (embed.thumbnail?.proxyUrl ?? embed.thumbnail?.url ?? embed.image?.proxyUrl ?? embed.image?.url).flatMap(URL.init(string:))
            let link = embed.url.flatMap(URL.init(string:))
            switch embed.type {
            case "gifv":
                if let video = (embed.video?.proxyUrl ?? embed.video?.url).flatMap(URL.init(string:)) {
                    let aspect = embed.video?.width.flatMap { width in embed.video?.height.map { Double(width) / Double(max($0, 1)) } }
                    embeds.append(.video(url: video, posterURL: thumbnail, aspectRatio: aspect, duration: nil, isGIF: true))
                }
            case "image":
                if let thumbnail {
                    let media = embed.thumbnail ?? embed.image
                    let aspect = media?.width.flatMap { width in media?.height.map { Double(width) / Double(max($0, 1)) } }
                    embeds.append(.image(url: thumbnail, aspectRatio: aspect, alt: nil, link: link, opensViewer: true))
                }
            default:
                guard embed.title != nil || embed.description != nil || (!hasText && link != nil) else { continue }
                embeds.append(.card(
                    title: embed.title ?? embed.author?.name ?? embed.provider?.name ?? link?.host() ?? "Link",
                    subtitle: embed.description.map { String($0.prefix(200)) } ?? embed.provider?.name,
                    systemImage: "link",
                    imageURL: thumbnail,
                    link: link,
                ))
            }
        }
        return embeds
    }
}
