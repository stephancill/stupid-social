import Foundation

/// One Discord channel (a DM, group DM or guild text channel): pages its history over REST, follows the gateway's
/// events for it, and sends, replies, edits, deletes, reacts, types and moves the read position as the web client
/// does. A guild channel subscribes to its guild's events when it opens; a poll catches what a large guild
/// doesn't send. Files go through Discord's upload slots; stickers are the standard packs and the guild's own (any
/// guild's with Nitro).
@MainActor
public final class DiscordChatAdapter: ChatAdapter, ChatWindowing, ChatReadOnlyAccess, ChatEditing, ChatDeleting, ChatReactionSending, ChatLiveUpdating, ChatReferenceResolving, ChatTyping, ChatMentioning, ChatCustomEmojis, ChatStickerSending, ChatForwarding, ChatVoiceSending, ChatAudioPreviewing, ChatMessageLinking {
    public let network = ChatNetwork.discord
    public let canReply = true
    /// Read again once connected: a guild channel may not allow files.
    public private(set) var acceptsAttachments = true
    /// Events arrive on the gateway; the poll covers guilds that send them only to some sessions.
    public let pollInterval: Duration? = .seconds(30)
    public var onChange: (() -> Void)?
    public var onConnectionLost: ((Error?) -> Void)?
    public var onCatchUp: (() -> Void)?
    public var onError: ((Error) -> Void)?
    public private(set) var info: ChatInfo
    public var history: ChatHistory?
    public private(set) var referencedMessages: [String: ChatMessage] = [:]
    public private(set) var unavailableReferences: Set<String> = []
    public private(set) var customEmojis: [String: ChatCustomEmoji] = [:]
    public private(set) var mentionNames: [String: String] = [:]
    public private(set) var isReadOnly = false
    public private(set) var acceptsReactions = true

    private let gateway: DiscordGateway
    private let client: DiscordClient
    private let channelId: String
    /// The messages last rendered: the stretch the chat shows.
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
    private let pageSize = 50

    public init(gateway: DiscordGateway, channelId: String, title: String) {
        self.gateway = gateway
        client = gateway.client
        self.channelId = channelId
        info = ChatInfo(title: title, subtitle: "")
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
            info.subtitle = others.first?.username.map { "@\($0)" } ?? ""
            info.avatarUserId = others.first?.id
            info.avatarURL = others.first?.avatarURL
        } else if channel.type == DiscordChannel.groupDM {
            info.subtitle = "\((channel.recipients ?? []).count + 1) members"
        } else if channel.isThread, let parent = gateway.channel(id: channel.parentId ?? "") {
            info.subtitle = [guild?.name, parent.name.map { "#\($0)" }].compactMap(\.self).joined(separator: " / ")
        } else {
            info.subtitle = guild?.name ?? ""
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

    // MARK: State

    private struct State: Codable {
        let users: [String: DiscordUser]
        let nicknames: [String: String]
        let meId: String?
        let readId: String?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
    }

    public func restore(state data: Data) {
        guard let state = try? JSONDecoder.discord.decode(State.self, from: data) else { return }
        users.merge(state.users) { current, _ in current }
        nicknames.merge(state.nicknames) { current, _ in current }
        meId = meId ?? state.meId
        if let read = state.readId, DiscordSnowflake.isAfter(read, readId) {
            readId = read
        }
        if channel == nil {
            info.title = state.title
            info.subtitle = state.subtitle
            info.showsSenderNames = state.showsSenderNames
        }
    }

    /// The people the shown messages name, so they show by name and picture before the gateway is ready.
    public func state() -> Data? {
        let shown = Set(loaded.values.flatMap { [$0.author.id] + $0.mentions.map(\.id) })
        return try? JSONEncoder.discord.encode(State(
            users: users.filter { shown.contains($0.key) }, nicknames: nicknames.filter { shown.contains($0.key) }, meId: meId, readId: readId,
            title: info.title, subtitle: info.subtitle, showsSenderNames: info.showsSenderNames,
        ))
    }

    // MARK: Loading

    /// Snowflakes order messages and fit in 63 bits.
    nonisolated static func record(_ message: DiscordMessage) throws -> ChatRecord {
        try ChatRecord(id: message.id, sortKey: Int64(message.id) ?? 0, data: JSONEncoder.discord.encode(message))
    }

    /// Discord returns pages newest first; a short page reached the end of history in its direction.
    public func fetch(_ request: ChatPageRequest) async throws -> ChatPage {
        try await gateway.waitUntilReady()
        applyChannel()
        switch request {
        case .newest:
            let page = try await client.messages(channelId: channelId, limit: pageSize)
            return try ChatPage(records: page.map(Self.record), earlier: page.count == pageSize ? page.last.map { ChatCursor($0.id) } : nil)
        case let .before(cursor):
            let page = try await client.messages(channelId: channelId, before: cursor.value, limit: pageSize)
            return try ChatPage(records: page.map(Self.record), earlier: page.count == pageSize ? page.last.map { ChatCursor($0.id) } : nil)
        case let .after(cursor):
            let page = try await client.messages(channelId: channelId, after: cursor.value, limit: pageSize)
            return try ChatPage(
                records: page.map(Self.record), earlier: ChatCursor(cursor.value),
                later: page.count == pageSize ? page.first.map { ChatCursor($0.id) } : nil,
            )
        case let .around(messageId):
            let page = try await client.messages(channelId: channelId, around: messageId, limit: pageSize)
            guard page.contains(where: { $0.id == messageId }) else { return ChatPage(records: [], earlier: nil) }
            let newest = page.first?.id
            let reachesNewest = newest != nil && newest == channel?.lastMessageId
            return try ChatPage(
                records: page.map(Self.record), earlier: page.last.map { ChatCursor($0.id) },
                later: reachesNewest ? nil : newest.map(ChatCursor.init),
            )
        }
    }

    public func cursor(before record: ChatRecord) -> ChatCursor? {
        ChatCursor(record.id)
    }

    public func send(_ message: ChatOutgoing) async throws -> String? {
        let upload = if let attachment = message.attachment { try await client.upload(channelId: channelId, data: attachment.data, mimeType: attachment.mimeType, filename: attachment.filename) } else { DiscordUploaded?.none }
        let sent = try await client.send(channelId: channelId, content: DiscordText.outgoing(message.markdownText()), replyTo: message.replyToId, nonce: DiscordSnowflake.now(), upload: upload)
        accept(sent)
        return sent.id
    }

    // MARK: Links

    /// The link Discord's Copy Message Link gives: the guild (`@me` for DMs), the channel or thread, the message.
    public func link(toMessage messageId: String) -> URL? {
        guard loaded[messageId] != nil else { return nil }
        return URL(string: "https://discord.com/channels/\(channel?.guildId ?? "@me")/\(channelId)/\(messageId)")
    }

    // MARK: Forwarding

    public func forwardReference(for message: ChatMessage) -> String? {
        guard loaded[message.id] != nil,
              let data = try? JSONEncoder().encode(DiscordForwardReference(channelId: channelId, messageId: message.id, guildId: channel?.guildId))
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func forward(reference: String) async throws -> String? {
        let source = try JSONDecoder().decode(DiscordForwardReference.self, from: Data(reference.utf8))
        let sent = try await client.forward(channelId: channelId, from: source, nonce: DiscordSnowflake.now())
        accept(sent)
        return sent.id
    }

    // MARK: Voice messages

    /// Ogg Opus, as Discord's apps send them, with 64 levels (as the probe's `send-voice` sent, observed 2026-11-07).
    public func send(voice: ChatVoiceNote, replyToId: String?) async throws -> String? {
        let fileURL = voice.fileURL
        let data = try await Task.detached { try OggOpusEncoder.encode(fileAt: fileURL) }.value
        let upload = try await client.upload(channelId: channelId, data: data, mimeType: "audio/ogg", filename: "voice-message.ogg")
        let waveform = Data(voice.levels(64).map { UInt8(($0 * 255).rounded()) })
        let sent = try await client.sendVoice(channelId: channelId, upload: upload, duration: voice.duration, waveform: waveform, replyTo: replyToId, nonce: DiscordSnowflake.now())
        accept(sent)
        return sent.id
    }

    public func audioPreviewURL(for previewId: String) async -> URL? {
        guard let url = URL(string: previewId), url.scheme == "https" else { return nil }
        return try? await ChatMediaFiles.shared.file(for: url, filename: "voice-message.ogg")
    }

    /// The network's copy of a message the user sent, which also reads the channel up to it.
    private func accept(_ sent: DiscordMessage) {
        gateway.setRead(channelId: channelId, messageId: sent.id)
        readId = sent.id
        write(sent)
    }

    private func write(_ message: DiscordMessage) {
        do {
            try history?.write([Self.record(message)])
        } catch {
            onError?(error)
        }
    }

    private func stored(_ id: String) -> DiscordMessage? {
        loaded[id] ?? (try? history?.record(id: id)).flatMap(\.self).flatMap { try? JSONDecoder.discord.decode(DiscordMessage.self, from: $0.data) }
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
        observation = gateway.observe { [weak self] update in
            switch update {
            case let .event(event): self?.handle(event)
            case .catchUp: self?.onCatchUp?()
            }
        }
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
            write(message)
        case let .messageUpdate(update) where update.channelId == channelId:
            // Partial: applied to the stored copy.
            guard var message = stored(update.id) else { return }
            if let content = update.content { message.content = content }
            if let edited = update.editedTimestamp { message.editedTimestamp = edited }
            if let attachments = update.attachments { message.attachments = attachments }
            if let embeds = update.embeds { message.embeds = embeds }
            if let mentions = update.mentions { message.mentions = mentions }
            write(message)
        case let .messageDelete(channelId, messageId) where channelId == self.channelId:
            try? history?.delete(ids: [messageId])
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
        return { [weak self, client, channelId, messageId = message.id] in
            try await client.ack(channelId: channelId, messageId: messageId)
            guard let self else { return }
            if DiscordSnowflake.isAfter(messageId, readId) {
                readId = messageId
            }
            gateway.setRead(channelId: channelId, messageId: messageId)
        }
    }

    // MARK: Editing and deleting

    public func editableText(of message: ChatMessage) -> String? {
        guard let original = loaded[message.id], original.author.id == meId, original.isUserMessage else { return nil }
        return DiscordText.display(original.content, context: textContext).text
    }

    public func edit(_ messageId: String, text: String) async throws {
        let edited = try await client.edit(channelId: channelId, messageId: messageId, content: DiscordText.outgoing(text))
        try history?.write([Self.record(edited)])
    }

    public func canDelete(_ message: ChatMessage) -> Bool {
        loaded[message.id]?.author.id == meId
    }

    public func delete(_ messageId: String) async throws {
        try await client.delete(channelId: channelId, messageId: messageId)
        try history?.delete(ids: [messageId])
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
        guard var message = stored(messageId), let key = emoji.key else { return }
        var reactions = message.reactions ?? []
        if let index = reactions.firstIndex(where: { $0.emoji.key == key }) {
            reactions[index].count += delta
            if mine { reactions[index].me = delta > 0 }
            if reactions[index].count <= 0 { reactions.remove(at: index) }
        } else if delta > 0 {
            reactions.append(DiscordReaction(emoji: emoji, count: delta, me: mine))
        }
        message.reactions = reactions
        register(emoji)
        write(message)
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

    public func render(_ records: [ChatRecord]) -> ChatRendering {
        loaded = Dictionary(
            records.compactMap { try? JSONDecoder.discord.decode(DiscordMessage.self, from: $0.data) }.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest },
        )
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
        referencedMessages = referenced
        unavailableReferences = unavailable
        return ChatRendering(messages: sorted.map { chatMessage($0, context: context) }, reactions: totals)
    }

    private func chatMessage(_ message: DiscordMessage, context: DiscordText.Context) -> ChatMessage {
        let isOwn = message.author.id == meId
        if let system = DiscordText.systemText(message) {
            return ChatMessage(id: message.id, sender: ChatUser(id: "discord", name: "Discord", avatarURL: nil, isSystem: true), timestamp: message.date, text: system, isOwn: false)
        }
        // A forward's content is in its snapshot; its own is empty.
        let forwarded = message.forwarded
        let (text, emojis) = DiscordText.display(forwarded?.content ?? message.content, context: context)
        for emoji in emojis {
            register(emoji)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let embeds = if let forwarded {
            Self.embeds(attachments: forwarded.attachments, stickers: forwarded.stickerItems, embeds: forwarded.embeds, flags: forwarded.flags, hasText: !trimmed.isEmpty)
        } else {
            Self.embeds(attachments: message.attachments, stickers: message.stickerItems, embeds: message.embeds, flags: message.flags, hasText: !trimmed.isEmpty)
        }
        return ChatMessage(
            id: message.id,
            sender: person(message.author.id, fallback: message.author),
            timestamp: message.date,
            text: trimmed.isEmpty ? nil : text,
            isMarkdown: true,
            embeds: embeds,
            replyToId: message.type == 19 ? message.messageReference?.messageId : nil,
            isOwn: isOwn,
            isEdited: message.editedTimestamp != nil,
            // The snapshot doesn't say who wrote the original.
            forwardedFrom: forwarded == nil ? nil : ChatForwardOrigin(name: nil),
        )
    }

    static func embeds(attachments: [DiscordAttachment], stickers: [DiscordStickerItem]?, embeds messageEmbeds: [DiscordEmbed], flags: Int?, hasText: Bool) -> [ChatEmbed] {
        var embeds: [ChatEmbed] = []
        let isVoice = (flags ?? 0) & DiscordMessage.voiceMessageFlag != 0
        for attachment in attachments {
            guard let url = URL(string: attachment.url) else { continue }
            let aspect = attachment.width.flatMap { width in attachment.height.map { Double(width) / Double(max($0, 1)) } }
            let type = attachment.contentType ?? ""
            if isVoice || attachment.waveform != nil {
                embeds.append(.voice(previewId: url.absoluteString, duration: attachment.durationSecs, waveform: attachment.waveformLevels ?? []))
            } else if type.hasPrefix("image/") {
                embeds.append(.image(url: url, aspectRatio: aspect, alt: attachment.filename, link: nil, opensViewer: true))
            } else if type.hasPrefix("video/") {
                embeds.append(.video(url: url, posterURL: attachment.proxyUrl.flatMap { URL(string: "\($0)\($0.contains("?") ? "&" : "?")format=jpeg") }, aspectRatio: aspect, duration: nil, isGIF: false))
            } else {
                let size = attachment.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                embeds.append(.file(url: url, filename: attachment.filename, subtitle: size, thumbnailURL: nil))
            }
        }
        for item in stickers ?? [] {
            if let sticker = sticker(id: item.id, formatType: item.formatType, alt: item.name) {
                embeds.append(.sticker(sticker))
            } else {
                embeds.append(.card(title: item.name, subtitle: "Sticker", systemImage: "face.smiling", imageURL: nil, link: nil))
            }
        }
        for group in groupedByURL(messageEmbeds) {
            let embed = group[0]
            let thumbnail = (embed.thumbnail?.proxyUrl ?? embed.thumbnail?.url ?? embed.image?.proxyUrl ?? embed.image?.url).flatMap(URL.init(string:))
            let link = embed.url.flatMap(URL.init(string:))
            let media = group.flatMap { linkMedia($0, link: link) }
            if !media.isEmpty, embed.type != "gifv", embed.type != "image" {
                embeds.append(.linkPreview(
                    title: embed.title ?? embed.author?.name ?? embed.provider?.name ?? link?.host() ?? "Link",
                    subtitle: embed.description.map { String($0.prefix(300)) } ?? (embed.title == nil ? nil : embed.author?.name ?? embed.provider?.name),
                    link: link,
                    media: media,
                ))
                continue
            }
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

    /// Discord shows a link's several images, such as a post's photos, as one embed: embeds after the first that
    /// share its `url` carry only an `image`. Embeds without a URL stand alone.
    static func groupedByURL(_ embeds: [DiscordEmbed]) -> [[DiscordEmbed]] {
        var groups: [[DiscordEmbed]] = []
        for embed in embeds {
            if let url = embed.url, let last = groups.last, last[0].url == url {
                groups[groups.count - 1].append(embed)
            } else {
                groups.append([embed])
            }
        }
        return groups
    }

    /// A link embed's large media: a video file Discord proxies (with its image or thumbnail as the poster), else
    /// its `image`. A video without a proxied file, such as YouTube's player, shows its thumbnail, which opens the
    /// link. A `thumbnail` beside the text stays a card's thumbnail.
    private static func linkMedia(_ embed: DiscordEmbed, link: URL?) -> [ChatEmbed] {
        func aspect(_ media: DiscordEmbed.Media?) -> Double? {
            media?.width.flatMap { width in media?.height.map { Double(width) / Double(max($0, 1)) } }
        }
        let image = embed.image.flatMap { media in (media.proxyUrl ?? media.url).flatMap(URL.init(string:)).map { ($0, aspect(media)) } }
        let thumbnail = embed.thumbnail.flatMap { media in (media.proxyUrl ?? media.url).flatMap(URL.init(string:)).map { ($0, aspect(media)) } }
        if let video = embed.video, let url = video.proxyUrl.flatMap(URL.init(string:)) {
            return [.video(url: url, posterURL: (image ?? thumbnail)?.0, aspectRatio: aspect(video) ?? (image ?? thumbnail)?.1, duration: nil, isGIF: false)]
        }
        if embed.video != nil, embed.type == "video", let poster = image ?? thumbnail {
            return [.image(url: poster.0, aspectRatio: aspect(embed.video) ?? poster.1, alt: nil, link: link, opensViewer: false)]
        }
        if let image {
            return [.image(url: image.0, aspectRatio: image.1, alt: nil, link: nil, opensViewer: true)]
        }
        return []
    }
}
