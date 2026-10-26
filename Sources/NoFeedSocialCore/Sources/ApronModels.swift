import Foundation

/// Wire types for the Apron Chat Protocol (https://github.com/shazow/apron, PROTOCOL.md v9).
public struct ApronServerInfo: Decodable, Equatable, Sendable {
    public let apron: Int
    public let auth: [String]
    public let agent: String?
    public let capabilities: [String]?
    public let welcome: String?
    public let signup: [String]?
    public let ping: Double?
    public let ext: ApronServerExt?

    public func has(_ capability: String) -> Bool {
        capabilities?.contains(capability) ?? false
    }

    public var acceptedSchemes: Set<String> {
        Set(auth).union(signup ?? [])
    }
}

public struct ApronUser: Codable, Hashable, Sendable {
    public let userId: String
    public let name: String?
    public let avatar: String?
    public let roles: [String]?
    /// What others see, in current objects only; `nil` when unknown (§4.5).
    public let status: String?
    /// `ext.bio`, the profile text apron-web shows; `""` clears it (§4.12).
    public let bio: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case avatar
        case roles
        case status
        case ext
    }

    private enum ExtKeys: String, CodingKey {
        case bio
    }

    public init(userId: String, name: String?, avatar: String?, roles: [String]?, status: String? = nil, bio: String? = nil) {
        self.userId = userId
        self.name = name
        self.avatar = avatar
        self.roles = roles
        self.status = status
        self.bio = bio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        roles = try container.decodeIfPresent([String].self, forKey: .roles)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        // `ext` is free-form; a missing or odd `bio` never drops the user.
        let ext = try? container.nestedContainer(keyedBy: ExtKeys.self, forKey: .ext)
        bio = (try? ext?.decodeIfPresent(String.self, forKey: .bio)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encodeIfPresent(roles, forKey: .roles)
        try container.encodeIfPresent(status, forKey: .status)
        if let bio {
            var ext = container.nestedContainer(keyedBy: ExtKeys.self, forKey: .ext)
            try ext.encode(bio, forKey: .bio)
        }
    }

    /// A current object from a `user` notification merged into the kept one: carried fields replace (§3.3.1).
    func merging(_ update: ApronUser) -> ApronUser {
        ApronUser(
            userId: userId,
            name: update.name ?? name,
            avatar: update.avatar ?? avatar,
            roles: update.roles ?? roles,
            status: update.status ?? status,
            bio: update.bio ?? bio,
        )
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return userId
    }

    /// `https:` images, or small inline `data:image/…;base64,` images (§4.8.6).
    public var avatarURL: URL? {
        guard let avatar, let url = URL(string: avatar) else { return nil }
        if url.scheme == "https" || url.scheme == "http" {
            return url
        }
        let inline = ["data:image/png;", "data:image/jpeg;", "data:image/gif;", "data:image/webp;"]
        return inline.contains { avatar.hasPrefix($0) } ? url : nil
    }

    public var isSystem: Bool {
        userId.hasPrefix("~")
    }
}

public enum ApronMention {
    /// `@` then an ID of `[A-Za-z0-9_.+@:-]` that starts and ends with a letter, digit or `_`,
    /// not preceded by a letter or digit, so `foo@bar.com` is not a mention (Appendix A.3).
    public static let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])@[A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?")
}

/// The status others see, for online indicators (§4.5.1).
public enum ApronPresence: Hashable, Sendable {
    case online
    case idle
    case doNotDisturb
    case offline
    /// A value this client doesn't know, shown as written.
    case other(String)

    /// `""` and `nil` are no known status.
    init?(status: String?) {
        switch status {
        case "online": self = .online
        case "idle": self = .idle
        case "dnd": self = .doNotDisturb
        case "offline": self = .offline
        case nil, "": return nil
        case let value?: self = .other(value)
        }
    }

    public var isConnected: Bool {
        switch self {
        case .online, .idle, .doNotDisturb: true
        case .offline, .other: false
        }
    }
}

public struct ApronRoom: Decodable, Hashable, Sendable {
    public let roomId: String
    public let title: String?
    public let description: String?
    public let parentRoomId: String?
    public let latestLogId: String?
    /// Users who joined, possibly only `user_id`; present with `members: true` (§4.2.1).
    public let members: [ApronUser]?
    /// How many users joined, when the server truncated `members`.
    public let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case title
        case description
        case parentRoomId = "parent_room_id"
        case latestLogId = "latest_log_id"
        case members
        case memberCount = "member_count"
    }

    public init(roomId: String) {
        self.roomId = roomId
        title = nil
        description = nil
        parentRoomId = nil
        latestLogId = nil
        members = nil
        memberCount = nil
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return roomId
    }
}

public struct ApronMessageBody: Codable, Hashable, Sendable {
    public let text: String?
    public let format: String?
    public let mentions: [String]?
    public let embeds: [ApronEmbed]?

    public init(text: String, format: String? = nil, mentions: [String]? = nil, embeds: [ApronEmbed]? = nil) {
        self.text = text
        self.format = format
        self.mentions = mentions
        self.embeds = embeds
    }
}

/// Rich content on a message (§4.8). Decoding is lenient, so one odd embed never drops its message.
public struct ApronEmbed: Codable, Hashable, Sendable {
    public let kind: String
    public let embedId: String?
    public let title: String?
    public let url: String?
    public let og: ApronOpenGraph?
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case embedId = "embed_id"
        case title
        case url
        case og
        case text
    }

    /// A new `upload` embed; the server replies with its write URL (§4.8.3).
    public static func upload(title: String) -> ApronEmbed {
        ApronEmbed(kind: "upload", embedId: nil, title: title, url: nil, og: nil, text: nil)
    }

    init(kind: String, embedId: String?, title: String?, url: String?, og: ApronOpenGraph?, text: String?) {
        self.kind = kind
        self.embedId = embedId
        self.title = title
        self.url = url
        self.og = og
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        embedId = try? container.decodeIfPresent(String.self, forKey: .embedId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        og = try? container.decodeIfPresent(ApronOpenGraph.self, forKey: .og)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }

    /// An upload without `url` is still being written (§4.8.4).
    public var isPendingUpload: Bool {
        kind == "upload" && url == nil
    }
}

/// The OpenGraph properties clients use (§4.8.1).
public struct ApronOpenGraph: Codable, Hashable, Sendable {
    public let title: String?
    public let description: String?
    public let image: ApronOpenGraphMedia?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        image = try? container.decodeIfPresent(ApronOpenGraphMedia.self, forKey: .image)
    }
}

public struct ApronOpenGraphMedia: Codable, Hashable, Sendable {
    public let url: String?
    public let width: Double?
    public let height: Double?
    public let alt: String?
}

/// The `ext` fields this app reads. Servers define `ext` freely (§4.12), so decoding never fails.
public struct ApronServerExt: Decodable, Equatable, Sendable {
    public let mediaOrigins: [URL]
    public let uploadLimits: [String: Int]
    /// The demo server's `ext.settings.read_cursors: false` says it keeps no read cursors.
    public let readCursorsDisabled: Bool

    private enum CodingKeys: String, CodingKey {
        case media
        case settings
    }

    private struct Settings: Decodable {
        let readCursors: Bool?

        enum CodingKeys: String, CodingKey {
            case readCursors = "read_cursors"
        }
    }

    private struct Media: Decodable {
        let origins: [String]?
        let upload: [String: Limit]?
    }

    private struct Limit: Decodable {
        let maxBytes: Int?

        enum CodingKeys: String, CodingKey {
            case maxBytes = "max_bytes"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let media = try? container?.decodeIfPresent(Media.self, forKey: .media)
        let settings = try? container?.decodeIfPresent(Settings.self, forKey: .settings)
        readCursorsDisabled = settings?.readCursors == false
        mediaOrigins = (media?.origins ?? []).compactMap(URL.init(string:))
        uploadLimits = (media?.upload ?? [:]).compactMapValues(\.maxBytes)
    }
}

public struct ApronMessageReference: Codable, Hashable, Sendable {
    public let messageId: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

public struct ApronMessage: Codable, Hashable, Identifiable, Sendable {
    public let messageId: String?
    public let logId: String?
    public let roomId: String?
    public let from: ApronUser
    public let body: ApronMessageBody?
    public let replyTo: ApronMessageReference?
    public let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case logId = "log_id"
        case roomId = "room_id"
        case from
        case body
        case replyTo = "reply_to"
        case deleted
    }

    /// Transient notices (no `message_id`) get a per-instance id so they still render.
    public var id: String {
        messageId ?? "notice:\(logId ?? "")\(from.userId):\(body?.text?.hashValue ?? 0)"
    }

    public var isDeleted: Bool {
        deleted ?? false
    }

    public var isMarkdown: Bool {
        body?.format == "markdown"
    }

    /// `log_id` is Unix epoch milliseconds and is the protocol's only timestamp (§2.1).
    public var timestamp: Date? {
        ApronLogId.date(logId)
    }

    /// Ascending log order for sorting; transient notices sort last.
    public var sortKey: Int64 {
        logId.flatMap(Int64.init) ?? .max
    }
}

public enum ApronLogId {
    public static func date(_ logId: String?) -> Date? {
        guard let logId, let millis = Double(logId) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

struct ApronAuthParams: Encodable {
    let scheme: String
    let token: String?
    let name: String?
    let agent: String
}

struct ApronAuthResult: Decodable {
    let you: ApronUser?
    let token: String?
}

struct ApronRoomListParams: Encodable {
    let filter: String
    let members: Bool
}

struct ApronRoomListResult: Decodable {
    let joined: [ApronRoom]?
    /// Complete current user objects of the listed members, with `members: true` (§4.2.1).
    let users: [ApronUser]?
}

struct ApronHistoryParams: Encodable {
    /// Omitted, the server's default room (§3.5.1).
    let roomId: String?
    let after: String?
    let before: String?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case after
        case before
        case limit
    }
}

public struct ApronHistoryResult: Decodable, Sendable {
    public let rooms: [ApronRoom]?
    public let messages: [ApronMessage]?
    public let reactions: [ApronReactionRecord]?
    public let firstLogId: String?
    public let lastLogId: String?
    public let more: Bool?

    enum CodingKeys: String, CodingKey {
        case rooms
        case messages
        case reactions
        case firstLogId = "first_log_id"
        case lastLogId = "last_log_id"
        case more
    }
}

struct ApronSendParams: Encodable {
    let roomId: String
    let body: ApronMessageBody
    /// Sent bare, with only `message_id` (§3.5.4).
    let replyTo: ApronMessageReference?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case body
        case replyTo = "reply_to"
    }
}

/// One user's complete emoji set on one message, logged per user (§4.7).
public struct ApronReactionSet: Codable, Sendable {
    public let from: ApronUser
    public let emojis: [String]
}

/// A logged reactions record. Live broadcasts carry one set; compacted history may carry several.
public struct ApronReactionRecord: Codable, Sendable {
    public let logId: String?
    public let messageId: String
    public let roomId: String?
    public let reactions: [ApronReactionSet]

    enum CodingKeys: String, CodingKey {
        case logId = "log_id"
        case messageId = "message_id"
        case roomId = "room_id"
        case reactions
    }
}

struct ApronReactionsParams: Encodable {
    let messageId: String
    let emojis: [String]

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case emojis
    }
}

struct ApronSendResult: Decodable {
    let messageId: String?
    let embeds: [ApronEmbedWrite]?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case embeds
    }
}

/// Write URLs for new `upload` embeds, in request order (§4.8.3).
struct ApronEmbedWrite: Decodable {
    let embedId: String?
    let writeUrl: String?

    enum CodingKeys: String, CodingKey {
        case embedId = "embed_id"
        case writeUrl = "write_url"
    }
}

struct ApronRoomIdParams: Encodable {
    let roomId: String

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
    }
}

struct ApronActivityParams: Encodable {
    let roomId: String
    let readMessageId: String

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case readMessageId = "read_message_id"
    }
}

struct ApronEmptyResult: Decodable {}

/// A `user` notification: `new` is another user's current object (§3.3.3).
struct ApronUserUpdate: Decodable {
    let new: ApronUser?
}

/// A `room_update` frame; only the parts the chat uses (§4.2.3).
struct ApronRoomUpdate: Decodable {
    let joined: [ApronRoom]?
    let memberships: [ApronMembershipRecord]?
    let users: [ApronUser]?
}

/// One logged membership change; each entry replaces that user's membership (§4.2.2).
struct ApronMembershipRecord: Decodable {
    struct Entry: Decodable {
        let user: ApronUser
        let joined: Bool
    }

    let roomId: String
    let members: [Entry]

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case members
    }
}

/// An `activity` frame: typing and read cursors (§4.6).
struct ApronActivity: Decodable {
    let roomId: String?
    let from: ApronUser?
    let readMessageId: String?
    /// Seconds to show the user as typing; `0` stops it.
    let typing: Double?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case from
        case readMessageId = "read_message_id"
        case typing
    }
}

struct ApronTypingParams: Encodable {
    let roomId: String
    let typing: Int

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case typing
    }
}
