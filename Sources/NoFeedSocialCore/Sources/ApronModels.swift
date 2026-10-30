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
    /// Push kinds and wake scopes; absent when the server doesn't push (§4.9).
    public let push: ApronPushInfo?
    /// The server's display name, CommonMark description and icon (§3.1); they may change after sign-in.
    public let title: String?
    public let description: String?
    public let avatar: String?

    public func has(_ capability: String) -> Bool {
        capabilities?.contains(capability) ?? false
    }

    public var acceptedSchemes: Set<String> {
        Set(auth).union(signup ?? [])
    }

    public var avatarURL: URL? {
        ApronUser.avatarURL(avatar)
    }

    /// The server's `title`, or its host without one (§3.1).
    public func displayTitle(serverURL: URL) -> String {
        Self.displayTitle(title, serverURL: serverURL)
    }

    static func displayTitle(_ title: String?, serverURL: URL) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return serverURL.host() ?? serverURL.absoluteString
    }
}

public struct ApronPushInfo: Decodable, Equatable, Sendable {
    public let webpush: WebPush?
    public let wake: [String]?
    /// The proposed per-room wake scopes, set with `status` `wake` and a `room_id` (see `ApronRoomNotifications`).
    public let roomWake: Bool?

    public struct WebPush: Decodable, Equatable, Sendable {
        /// The server's VAPID public key, unpadded base64url (§4.9.2).
        public let key: String
    }

    enum CodingKeys: String, CodingKey {
        case webpush
        case wake
        case roomWake = "room_wake"
    }

    public func wakes(_ scope: String) -> Bool {
        wake?.contains(scope) ?? false
    }
}

public struct ApronUser: Codable, Hashable, Sendable {
    public let userId: String
    public let name: String?
    public let avatar: String?
    public let roles: [String]?
    /// What others see, in current objects only; `nil` when unknown (§4.5).
    public let status: String?
    /// When the shown status last became `offline`, in `log_id` format; only with a shown `offline` (§4.5.2).
    public let seen: String?
    /// `ext.bio`, the profile text apron-web shows; `""` clears it (§4.12).
    public let bio: String?
    /// `ext.permissions.write` on `you`: `false` for a guest who can only read, as on the demo server; `nil` when
    /// the server doesn't say.
    public let canWrite: Bool?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case avatar
        case roles
        case status
        case seen
        case ext
    }

    private enum ExtKeys: String, CodingKey {
        case bio
        case permissions
    }

    private enum PermissionKeys: String, CodingKey {
        case write
    }

    public init(userId: String, name: String?, avatar: String?, roles: [String]?, status: String? = nil, seen: String? = nil, bio: String? = nil, canWrite: Bool? = nil) {
        self.userId = userId
        self.name = name
        self.avatar = avatar
        self.roles = roles
        self.status = status
        self.seen = seen
        self.bio = bio
        self.canWrite = canWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        roles = try container.decodeIfPresent([String].self, forKey: .roles)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        seen = try? container.decodeIfPresent(String.self, forKey: .seen)
        // `ext` is free-form; a missing or odd `bio` never drops the user.
        let ext = try? container.nestedContainer(keyedBy: ExtKeys.self, forKey: .ext)
        bio = (try? ext?.decodeIfPresent(String.self, forKey: .bio)) ?? nil
        let permissions = try? ext?.nestedContainer(keyedBy: PermissionKeys.self, forKey: .permissions)
        canWrite = (try? permissions?.decodeIfPresent(Bool.self, forKey: .write)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encodeIfPresent(roles, forKey: .roles)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(seen, forKey: .seen)
        if bio != nil || canWrite != nil {
            var ext = container.nestedContainer(keyedBy: ExtKeys.self, forKey: .ext)
            try ext.encodeIfPresent(bio, forKey: .bio)
            if let canWrite {
                var permissions = ext.nestedContainer(keyedBy: PermissionKeys.self, forKey: .permissions)
                try permissions.encode(canWrite, forKey: .write)
            }
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
            seen: update.seen ?? seen,
            bio: update.bio ?? bio,
            canWrite: update.canWrite ?? canWrite,
        )
    }

    /// `seen` as a date, shown only while the shown status is `offline` (§4.5.2).
    public var lastSeen: Date? {
        guard status == "offline", let millis = seen.flatMap(Int64.init) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return userId
    }

    public var avatarURL: URL? {
        Self.avatarURL(avatar)
    }

    /// `https:` images, or small inline `data:image/…;base64,` images (§4.8.6), for users and servers.
    static func avatarURL(_ avatar: String?) -> URL? {
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

    /// The status as a DM's subtitle shows it, lowercase like Telegram's "online".
    public var text: String {
        switch self {
        case .online: "online"
        case .idle: "idle"
        case .doNotDisturb: "do not disturb"
        case .offline: "offline"
        case let .other(value): value
        }
    }
}

public struct ApronRoom: Decodable, Hashable, Sendable {
    public let roomId: String
    public let title: String?
    public let description: String?
    public let parentRoomId: String?
    public let latestLogId: String?
    /// Visible only to members (§4.2.4).
    public let isPrivate: Bool
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
        case isPrivate = "private"
        case members
        case memberCount = "member_count"
    }

    public init(roomId: String) {
        self.roomId = roomId
        title = nil
        description = nil
        parentRoomId = nil
        latestLogId = nil
        isPrivate = false
        members = nil
        memberCount = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try container.decode(String.self, forKey: .roomId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        parentRoomId = try container.decodeIfPresent(String.self, forKey: .parentRoomId)
        latestLogId = try container.decodeIfPresent(String.self, forKey: .latestLogId)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        members = try container.decodeIfPresent([ApronUser].self, forKey: .members)
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount)
    }

    /// An untitled top-level private room, such as a DM, is named for its members, as in apron-web.
    public var isNamedForMembers: Bool {
        isPrivate && parentRoomId == nil && (title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether this is the room `you` talk to `userId` in, as apron-web's `directRoomWith` finds it: a room named
    /// for its members whose complete member list (no `member_count`) is exactly the two of them.
    public func isDirect(with userId: String, you: String) -> Bool {
        guard isNamedForMembers, userId != you, let members, memberCount == nil else { return false }
        return Set(members.map(\.userId)) == [you, userId]
    }

    /// Members other than `you`; empty while they aren't known.
    public func otherMembers(you: String) -> [ApronUser] {
        (members ?? []).filter { $0.userId != you }
    }

    /// The room's title, else its `room_id` (§3.4). A room named for its members takes the names of the others,
    /// sorted and joined with ", ", or "You" when no one else is left (apron-web's `peopleTitle`).
    public func displayTitle(users: [String: ApronUser], you: String) -> String {
        guard isNamedForMembers else {
            if let title, !title.isEmpty { return title }
            return roomId
        }
        guard members != nil else { return "Private room" }
        let names = otherMembers(you: you).map { (users[$0.userId] ?? $0).displayName }
        guard !names.isEmpty else { return "You" }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
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
    /// `ext.emoji.catalog_url` (EXTENSIONS.md `ext:emoji`); use it only while the server lists `ext:emoji`.
    public let emojiCatalogURL: URL?

    private enum CodingKeys: String, CodingKey {
        case media
        case settings
        case emoji
    }

    private struct Emoji: Decodable {
        let catalogURL: String?

        enum CodingKeys: String, CodingKey {
            case catalogURL = "catalog_url"
        }
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
        let emoji = try? container?.decodeIfPresent(Emoji.self, forKey: .emoji)
        emojiCatalogURL = ApronEmojiCatalog.catalogURL(emoji?.catalogURL)
        mediaOrigins = (media?.origins ?? []).compactMap(URL.init(string:))
        uploadLimits = (media?.upload ?? [:]).compactMapValues(\.maxBytes)
    }
}

/// Custom emoji (EXTENSIONS.md `ext:emoji`): the catalog a server's `catalog_url` returns, keyed by `:name:`.
public enum ApronEmojiCatalog {
    private static let keyPattern = try! NSRegularExpression(pattern: "^:[A-Za-z0-9_+-]+:$")

    /// `https:`, `http:` on a loopback host, or `data:application/json`.
    static func catalogURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string) else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "") ? url : nil
        case "data": return string.lowercased().hasPrefix("data:application/json") ? url : nil
        default: return nil
        }
    }

    /// Entries with an invalid key or no usable `url` are left out; other fields of the wrong type take their
    /// defaults.
    public static func parse(_ data: Data) throws -> [String: ChatCustomEmoji] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var catalog: [String: ChatCustomEmoji] = [:]
        for (key, value) in object {
            guard keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil,
                  let entry = value as? [String: Any],
                  let url = ApronUser.avatarURL(entry["url"] as? String)
            else { continue }
            let width = (entry["width"] as? NSNumber)?.doubleValue
            let height = (entry["height"] as? NSNumber)?.doubleValue
            let aspectRatio = if let width, let height, width > 0, height > 0 { width / height } else { 1.0 }
            catalog[key] = ChatCustomEmoji(
                key: key,
                url: url,
                staticURL: ApronUser.avatarURL(entry["static_url"] as? String),
                alt: (entry["alt"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                aspectRatio: aspectRatio,
                category: (entry["category"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                tags: (entry["tags"] as? [Any])?.compactMap { $0 as? String } ?? [],
                isHidden: entry["hidden"] as? Bool ?? false,
            )
        }
        return catalog
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
    /// Lists only this room, in the array that matches the user's membership (§4.2.1).
    var roomId: String?

    enum CodingKeys: String, CodingKey {
        case filter
        case members
        case roomId = "room_id"
    }
}

struct ApronRoomListResult: Decodable {
    let joined: [ApronRoom]?
    let notJoined: [ApronRoom]?
    /// Complete current user objects of the listed members, with `members: true` (§4.2.1).
    let users: [ApronUser]?

    enum CodingKeys: String, CodingKey {
        case joined
        case notJoined = "not_joined"
        case users
    }
}

/// One room as the server lists it to the user, joined or not, with its members' user objects.
public struct ApronRoomListing: Equatable, Sendable {
    public let room: ApronRoom
    public let users: [ApronUser]
    public let isJoined: Bool
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
    /// Another user to add or remove, where the server allows it (§4.2.2).
    var userId: String?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case userId = "user_id"
    }
}

struct ApronRoomSetResult: Decodable {
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

struct ApronPushRegisterParams: Encodable {
    let kind = "webpush"
    let url: String
    let pushId: String
    let keys: Keys
    let wake: [String]

    struct Keys: Encodable {
        let p256dh: String
        let auth: String
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case url
        case pushId = "push_id"
        case keys
        case wake
    }
}

/// A room's `status`: `mute`, or the proposed room `wake`, where `.some(nil)` sends `null` to clear it.
struct ApronRoomStatusParams: Encodable {
    let roomId: String
    var mute: Bool?
    var wake: [String]??

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case mute
        case wake
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomId, forKey: .roomId)
        try container.encodeIfPresent(mute, forKey: .mute)
        if let wake {
            try container.encode(wake, forKey: .wake)
        }
    }
}

/// A `user` notification: `new` is another user's current object (§3.3.3).
struct ApronUserUpdate: Decodable {
    let new: ApronUser?
}

/// A `room_update` frame; only the parts the chat uses (§4.2.3).
struct ApronRoomUpdate: Decodable {
    struct Left: Decodable {
        let roomId: String

        enum CodingKeys: String, CodingKey {
            case roomId = "room_id"
        }
    }

    let joined: [ApronRoom]?
    let left: [Left]?
    let memberships: [ApronMembershipRecord]?
    /// Room records that changed while the user's membership didn't (§4.2.3).
    let updated: [ApronRoom]?
    let users: [ApronUser]?

    /// The rooms whose records or members changed, when the user's own rooms didn't; `nil` when the user
    /// joined or left a room, which changes which rooms there are.
    var changedRoomIds: Set<String>? {
        guard (joined ?? []).isEmpty, (left ?? []).isEmpty else { return nil }
        return Set((updated ?? []).map(\.roomId) + (memberships ?? []).map(\.roomId))
    }
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
