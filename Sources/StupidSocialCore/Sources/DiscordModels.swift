import Foundation

// Discord's REST v9 and gateway payloads, as the web client receives them (scripts/discord-web-client.py). Keys are
// snake case, decoded with `.convertFromSnakeCase`. Ids are snowflakes: strings holding a 64-bit number whose top
// 42 bits are milliseconds since the Discord epoch, so they sort by time and carry it.

public enum DiscordSnowflake {
    /// 2015-01-01T00:00:00Z in milliseconds.
    static let epoch: UInt64 = 1_420_070_400_000

    public static func date(_ id: String) -> Date? {
        guard let value = UInt64(id) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval((value >> 22) + epoch) / 1000)
    }

    /// Whether `id` is later than `other`; a missing `other` is earlier than everything.
    public static func isAfter(_ id: String, _ other: String?) -> Bool {
        guard let other, let otherValue = UInt64(other) else { return true }
        return (UInt64(id) ?? 0) > otherValue
    }

    /// A snowflake for now, which the web client sends as a message's nonce.
    static func now() -> String {
        String((UInt64(Date().timeIntervalSince1970 * 1000) - epoch) << 22)
    }

    static func newest(_ ids: [String?]) -> String? {
        ids.compactMap(\.self).max { (UInt64($0) ?? 0) < (UInt64($1) ?? 0) }
    }
}

public struct DiscordUser: Codable, Hashable, Sendable {
    public let id: String
    public let username: String?
    public let globalName: String?
    public let avatar: String?
    public let bot: Bool?
    /// Set on the signed-in user (`READY`, `/users/@me`): 0 none, else a Nitro tier, which may send any guild's stickers.
    public let premiumType: Int?

    public init(id: String, username: String?, globalName: String? = nil, avatar: String? = nil, bot: Bool? = nil, premiumType: Int? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.avatar = avatar
        self.bot = bot
        self.premiumType = premiumType
    }

    public var name: String {
        globalName.flatMap { $0.isEmpty ? nil : $0 } ?? username ?? id
    }

    public var avatarURL: URL? {
        avatar.flatMap { URL(string: "https://cdn.discordapp.com/avatars/\(id)/\($0).png?size=128") }
    }
}

struct DiscordPermissionOverwrite: Codable, Hashable {
    let id: String
    /// 0 for a role, 1 for a member.
    let type: Int
    let allow: String
    let deny: String
}

struct DiscordChannel: Codable, Hashable {
    let id: String
    let type: Int
    let name: String?
    /// Missing on the channels a guild lists in `READY` and `GUILD_CREATE`; `DiscordGuild.withGuildIds` sets it.
    var guildId: String?
    let parentId: String?
    let position: Int?
    var lastMessageId: String?
    let recipients: [DiscordUser]?
    let permissionOverwrites: [DiscordPermissionOverwrite]?
    let icon: String?
    let topic: String?
    let isMessageRequest: Bool?
    let isSpam: Bool?
    /// A thread's state, such as whether it is archived.
    let threadMetadata: ThreadMetadata?
    /// Set on a thread the user has joined (`READY`, `THREAD_CREATE`, the forum search's own `members`).
    var member: ThreadMember?

    struct ThreadMetadata: Codable, Hashable {
        let archived: Bool?
        let locked: Bool?
    }

    struct ThreadMember: Codable, Hashable {
        let userId: String?
    }

    static let text = 0
    static let dm = 1
    static let groupDM = 3
    static let announcement = 5
    static let announcementThread = 10
    static let publicThread = 11
    static let privateThread = 12
    static let forum = 15
    static let media = 16

    var isPrivate: Bool {
        type == Self.dm || type == Self.groupDM
    }

    var isThread: Bool {
        [Self.announcementThread, Self.publicThread, Self.privateThread].contains(type)
    }

    /// Forum and media channels: their posts are threads, and they hold no messages of their own.
    var isForum: Bool {
        type == Self.forum || type == Self.media
    }

    /// Channels with messages the Chats list shows: text and announcement channels, DMs and group DMs, and threads
    /// (including forum posts). Voice channels' text chat isn't listed.
    var isListed: Bool {
        [Self.text, Self.announcement, Self.dm, Self.groupDM].contains(type) || isThread
    }

    /// A DM's recipient's name, a group DM's name or its members' names, or a guild channel's name.
    var title: String {
        if let name, !name.isEmpty { return name }
        let names = (recipients ?? []).map(\.name)
        return names.isEmpty ? "Discord" : names.joined(separator: ", ")
    }
}

struct DiscordRole: Codable, Hashable {
    let id: String
    let name: String?
    let permissions: String
}

struct DiscordMember: Codable, Hashable {
    let user: DiscordUser?
    let roles: [String]
    let nick: String?
}

struct DiscordEmoji: Codable, Hashable {
    let id: String?
    let name: String?
    let animated: Bool?

    /// A custom emoji's key in text and reactions (`:<id>:`), as Telegram's are, since names repeat across guilds;
    /// a Unicode emoji is itself.
    var key: String? {
        if let id { return ":\(id):" }
        return name
    }

    var imageURL: URL? {
        id.flatMap { URL(string: "https://cdn.discordapp.com/emojis/\($0).\(animated == true ? "gif" : "png")?size=96") }
    }

    /// How the reaction routes name it: the emoji itself, or `name:id` for a custom one.
    var routeName: String? {
        if let id { return "\(name ?? "_"):\(id)" }
        return name
    }
}

struct DiscordGuild: Codable, Hashable {
    let id: String
    let name: String
    let icon: String?
    let ownerId: String?
    let roles: [DiscordRole]
    var channels: [DiscordChannel]
    let members: [DiscordMember]?
    let emojis: [DiscordEmoji]?
    let stickers: [DiscordSticker]?
    /// Active threads the user can see, in `READY` and `GUILD_CREATE`; `withGuildIds` moves them into `channels`.
    let threads: [DiscordChannel]?

    /// The guild with its id on each channel, and its threads among its channels.
    var withGuildIds: DiscordGuild {
        var guild = self
        let known = Set(guild.channels.map(\.id))
        guild.channels += (threads ?? []).filter { !known.contains($0.id) }
        for index in guild.channels.indices {
            guild.channels[index].guildId = id
        }
        return guild
    }

    var iconURL: URL? {
        icon.flatMap { URL(string: "https://cdn.discordapp.com/icons/\(id)/\($0).png?size=128") }
    }
}

struct DiscordReadState: Codable, Hashable {
    /// The channel's id.
    let id: String
    var lastMessageId: String?
    var mentionCount: Int?
}

struct DiscordGuildSettings: Codable, Hashable {
    struct ChannelOverride: Codable, Hashable {
        let channelId: String
        let muted: Bool?
    }

    /// `nil` for the settings of DMs.
    let guildId: String?
    let muted: Bool?
    let channelOverrides: [ChannelOverride]?
}

/// The gateway's `READY` for an identify with no capabilities: guilds with their channels, roles and the user's
/// own member, DMs, read states and notification settings as plain arrays (observed 2026-11-07).
struct DiscordReady: Decodable {
    let user: DiscordUser
    let sessionId: String
    let resumeGatewayUrl: String?
    let guilds: [DiscordGuild]
    let privateChannels: [DiscordChannel]
    let readState: [DiscordReadState]
    let userGuildSettings: [DiscordGuildSettings]

    private enum CodingKeys: String, CodingKey {
        case user, sessionId, resumeGatewayUrl, guilds, privateChannels, readState, userGuildSettings
    }

    /// Capabilities wrap read states and settings in `{entries: […]}`; either shape decodes.
    private struct Entries<T: Decodable>: Decodable {
        let entries: [T]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(DiscordUser.self, forKey: .user)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        resumeGatewayUrl = try container.decodeIfPresent(String.self, forKey: .resumeGatewayUrl)
        guilds = (try? container.decode([DiscordGuild].self, forKey: .guilds)) ?? []
        privateChannels = try container.decodeIfPresent([DiscordChannel].self, forKey: .privateChannels) ?? []
        func entries<T: Decodable>(_ key: CodingKeys) -> [T] {
            (try? container.decode([T].self, forKey: key)) ?? (try? container.decode(Entries<T>.self, forKey: key).entries) ?? []
        }
        readState = entries(.readState)
        userGuildSettings = entries(.userGuildSettings)
    }
}

public struct DiscordAttachment: Codable, Hashable, Sendable {
    let id: String
    let filename: String
    let url: String
    let proxyUrl: String?
    let width: Int?
    let height: Int?
    let contentType: String?
    let size: Int?
    /// On a voice message's audio.
    var durationSecs: Double? = nil
    /// A voice message's levels: base64 of up to 256 bytes, each 0–255.
    var waveform: String? = nil

    var waveformLevels: [Double]? {
        waveform.flatMap { Data(base64Encoded: $0) }.map { $0.map { Double($0) / 255 } }
    }
}

public struct DiscordEmbed: Codable, Hashable, Sendable {
    struct Media: Codable, Hashable {
        let url: String?
        let proxyUrl: String?
        let width: Int?
        let height: Int?
    }

    struct Named: Codable, Hashable {
        let name: String?
    }

    /// `rich`, `image`, `video`, `gifv`, `article`, `link`…
    let type: String?
    let title: String?
    let description: String?
    let url: String?
    let thumbnail: Media?
    let image: Media?
    let video: Media?
    let provider: Named?
    let author: Named?
}

public struct DiscordReaction: Codable, Hashable, Sendable {
    let emoji: DiscordEmoji
    var count: Int
    var me: Bool
}

/// A sticker from `/sticker-packs` or a guild's `stickers`.
struct DiscordSticker: Codable, Hashable {
    let id: String
    let name: String
    /// Words to find it by; for a guild sticker, the Unicode emoji it stands for.
    let tags: String?
    /// 1 PNG, 2 APNG, 3 Lottie, 4 GIF.
    let formatType: Int
    let packId: String?
    let guildId: String?
    let available: Bool?
}

struct DiscordStickerPack: Codable, Hashable {
    let id: String
    let name: String
    let stickers: [DiscordSticker]
    let coverStickerId: String?
}

/// `/users/{id}/profile`, as the web client's profile popout loads it.
public struct DiscordProfile: Decodable, Sendable {
    struct UserProfile: Decodable {
        let bio: String?
        let pronouns: String?
    }

    struct MutualGuild: Decodable {
        let id: String
        let nick: String?
    }

    let user: DiscordUser
    let userProfile: UserProfile?
    let mutualGuilds: [MutualGuild]?
    let mutualFriendsCount: Int?
}

/// `/channels/{forum}/threads/search`: a forum's posts.
struct DiscordThreadSearch: Decodable {
    let threads: [DiscordChannel]
    let members: [DiscordThreadMemberEntry]?
    let hasMore: Bool?
}

struct DiscordThreadMemberEntry: Decodable {
    /// The thread's id.
    let id: String
    let userId: String?
}

/// `POST /channels/{id}/attachments`: where to upload each file.
struct DiscordUploadSlots: Decodable {
    struct Slot: Decodable {
        let id: Int?
        let uploadUrl: String
        let uploadFilename: String
    }

    let attachments: [Slot]
}

public struct DiscordStickerItem: Codable, Hashable, Sendable {
    let id: String
    let name: String
    /// 1 PNG, 2 APNG, 3 Lottie, 4 GIF.
    let formatType: Int
}

/// A message's `nonce`, which Discord echoes as sent: a string, or a number for some clients.
struct DiscordNonce: Codable, Hashable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = try String(container.decode(Int64.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The message a forward names: its channel, and the channel's guild for a server channel.
struct DiscordForwardReference: Codable, Hashable {
    let channelId: String
    let messageId: String
    let guildId: String?
}

/// A message's `referenced_message`, boxed since a message can't hold itself.
public final class DiscordReferencedMessage: Codable, Hashable, @unchecked Sendable {
    let message: DiscordMessage

    init(_ message: DiscordMessage) {
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        message = try DiscordMessage(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try message.encode(to: encoder)
    }

    public static func == (lhs: DiscordReferencedMessage, rhs: DiscordReferencedMessage) -> Bool {
        lhs.message == rhs.message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(message)
    }
}

public struct DiscordMessage: Codable, Hashable, Sendable {
    struct Reference: Codable, Hashable {
        let messageId: String?
        let channelId: String?
        /// 0 a reply, 1 a forward (`message_snapshots` then has the content).
        var type: Int? = nil
    }

    /// What a forward copied of the original (observed 2026-11-07): no author or id of its own.
    struct Snapshot: Codable, Hashable {
        struct Message: Codable, Hashable {
            var content: String
            var attachments: [DiscordAttachment]
            var embeds: [DiscordEmbed]
            var stickerItems: [DiscordStickerItem]? = nil
            var flags: Int? = nil
        }

        let message: Message
    }

    /// `IS_VOICE_MESSAGE`.
    static let voiceMessageFlag = 1 << 13
    /// `HAS_SNAPSHOT`: a forward.
    static let snapshotFlag = 1 << 14

    struct Member: Codable, Hashable {
        let nick: String?
    }

    let id: String
    let channelId: String
    /// 0 a message, 19 a reply; others are system messages such as joins and pins.
    let type: Int
    var content: String
    let author: DiscordUser
    var editedTimestamp: String?
    var attachments: [DiscordAttachment]
    var embeds: [DiscordEmbed]
    var reactions: [DiscordReaction]?
    let messageReference: Reference?
    let referencedMessage: DiscordReferencedMessage?
    var mentions: [DiscordUser]
    let stickerItems: [DiscordStickerItem]?
    let nonce: DiscordNonce?
    let guildId: String?
    let member: Member?
    var flags: Int? = nil
    var messageSnapshots: [Snapshot]? = nil

    /// The forwarded message, on a forward.
    var forwarded: Snapshot.Message? {
        messageReference?.type == 1 || (flags ?? 0) & Self.snapshotFlag != 0 ? messageSnapshots?.first?.message : nil
    }

    var date: Date? {
        DiscordSnowflake.date(id)
    }

    /// Messages and replies; everything else is a system message.
    var isUserMessage: Bool {
        type == 0 || type == 19
    }
}

/// `MESSAGE_UPDATE` carries only what changed (and, for embeds unfurling, may lack the content).
struct DiscordMessageUpdate: Decodable {
    let id: String
    let channelId: String
    let content: String?
    let editedTimestamp: String?
    let attachments: [DiscordAttachment]?
    let embeds: [DiscordEmbed]?
    let mentions: [DiscordUser]?
}

/// Discord's permission bits (https://discord.com/developers/docs/topics/permissions) and how a member's are
/// worked out for a channel: the guild's `@everyone` role and the member's roles, then the channel's overwrites
/// for `@everyone`, the member's roles and the member.
enum DiscordPermissions {
    static let administrator: UInt64 = 1 << 3
    static let viewChannel: UInt64 = 1 << 10
    static let sendMessages: UInt64 = 1 << 11
    static let readMessageHistory: UInt64 = 1 << 16
    static let addReactions: UInt64 = 1 << 6
    static let attachFiles: UInt64 = 1 << 15
    static let sendMessagesInThreads: UInt64 = 1 << 38

    /// A thread has its parent channel's permissions; a private one also needs the user to have joined it.
    static func of(userId: String, in guild: DiscordGuild, channel: DiscordChannel) -> UInt64 {
        if channel.isThread {
            guard let parent = guild.channels.first(where: { $0.id == channel.parentId }) else { return 0 }
            if channel.type == DiscordChannel.privateThread, channel.member == nil, guild.ownerId != userId { return 0 }
            return of(userId: userId, in: guild, channel: parent)
        }
        if guild.ownerId == userId { return .max }
        let roles = Dictionary(guild.roles.map { ($0.id, UInt64($0.permissions) ?? 0) }, uniquingKeysWith: { first, _ in first })
        let memberRoles = guild.members?.first { $0.user?.id == userId }?.roles ?? []
        var permissions = roles[guild.id] ?? 0
        for role in memberRoles {
            permissions |= roles[role] ?? 0
        }
        if permissions & administrator != 0 { return .max }
        let overwrites = channel.permissionOverwrites ?? []
        func apply(_ overwrite: DiscordPermissionOverwrite?) {
            guard let overwrite else { return }
            permissions &= ~(UInt64(overwrite.deny) ?? 0)
            permissions |= UInt64(overwrite.allow) ?? 0
        }
        apply(overwrites.first { $0.id == guild.id })
        var roleAllow: UInt64 = 0
        var roleDeny: UInt64 = 0
        for overwrite in overwrites where overwrite.type == 0 && memberRoles.contains(overwrite.id) {
            roleAllow |= UInt64(overwrite.allow) ?? 0
            roleDeny |= UInt64(overwrite.deny) ?? 0
        }
        permissions &= ~roleDeny
        permissions |= roleAllow
        apply(overwrites.first { $0.type == 1 && $0.id == userId })
        return permissions
    }
}

enum DiscordError: LocalizedError {
    case http(status: Int, message: String?)
    case rateLimited(retryAfter: Double)
    case notConnected

    var errorDescription: String? {
        switch self {
        case let .http(status, message): message.map { "Discord: \($0)" } ?? "Discord answered \(status)."
        case let .rateLimited(retryAfter): "Discord is rate limiting requests; try again in \(Int(retryAfter.rounded(.up))) s."
        case .notConnected: "Discord isn't connected."
        }
    }
}

extension JSONDecoder {
    static var discord: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    static var discord: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

/// A file uploaded for a message that names it.
struct DiscordUploaded {
    let filename: String
    let uploadedFilename: String
}
