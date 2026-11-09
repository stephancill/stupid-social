import Foundation

// LinkedIn's messenger GraphQL answers (`voyagerMessagingGraphQL/graphql`) and its Voyager REST notification cards,
// as `scripts/linkedin-web-client.py` records them (observed 2026-11-09). Unions and fields the app doesn't show are
// left out, and members that don't decode are skipped rather than failing the page.

/// `{text, attributes}`; the attributes (bold, links) aren't shown.
struct LinkedInText: Codable, Hashable {
    let text: String
}

/// `com.linkedin.common.VectorImage`: a root URL and sized variants whose path segments complete it.
struct LinkedInVectorImage: Codable, Hashable {
    struct Artifact: Codable, Hashable {
        let width: Int?
        let height: Int?
        let fileIdentifyingUrlPathSegment: String
    }

    let rootUrl: String?
    let artifacts: [Artifact]?

    /// The smallest variant at least `width` wide, else the largest; the root URL alone when there are none.
    func url(width: Int) -> URL? {
        let sorted = (artifacts ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let artifact = sorted.first(where: { ($0.width ?? 0) >= width }) ?? sorted.last else {
            return rootUrl.flatMap(URL.init(string:))
        }
        return URL(string: (rootUrl ?? "") + artifact.fileIdentifyingUrlPathSegment)
    }

    var aspectRatio: Double? {
        guard let largest = (artifacts ?? []).max(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
              let width = largest.width, let height = largest.height, height > 0
        else { return nil }
        return Double(width) / Double(height)
    }
}

/// Someone in a conversation: a member, a company page, or a LinkedIn system sender.
struct LinkedInParticipant: Codable, Hashable {
    struct Member: Codable, Hashable {
        let firstName: LinkedInText?
        let lastName: LinkedInText?
        let profilePicture: LinkedInVectorImage?
        let profileUrl: URL?
    }

    struct Organization: Codable, Hashable {
        let name: LinkedInText?
        let logo: LinkedInVectorImage?
        let pageUrl: URL?
    }

    struct Custom: Codable, Hashable {
        let name: LinkedInText?
        let image: LinkedInVectorImage?
    }

    struct Kind: Codable, Hashable {
        let member: Member?
        let organization: Organization?
        let custom: Custom?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            member = try? container.decodeIfPresent(Member.self, forKey: .member)
            organization = try? container.decodeIfPresent(Organization.self, forKey: .organization)
            custom = try? container.decodeIfPresent(Custom.self, forKey: .custom)
        }
    }

    /// `urn:li:fsd_profile:<id>` for members.
    let hostIdentityUrn: String
    /// `urn:li:msg_messagingParticipant:<host urn>`, which a reply names its quoted sender by.
    let entityUrn: String
    let participantType: Kind?

    var name: String {
        if let member = participantType?.member {
            let name = [member.firstName?.text, member.lastName?.text].compactMap(\.self).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "LinkedIn Member" : name
        }
        return participantType?.organization?.name?.text ?? participantType?.custom?.name?.text ?? "LinkedIn Member"
    }

    var avatarURL: URL? {
        let image = participantType?.member?.profilePicture ?? participantType?.organization?.logo ?? participantType?.custom?.image
        return image?.url(width: 200)
    }

    var profileURL: URL? {
        participantType?.member?.profileUrl ?? participantType?.organization?.pageUrl
    }
}

/// A message's sender, by reference.
struct LinkedInSenderRef: Codable, Hashable {
    let hostIdentityUrn: String
    let entityUrn: String
}

/// One `renderContent` member. LinkedIn sends a union with every kind as a key, all but one null; unknown kinds
/// and shapes that don't decode stay nil.
struct LinkedInRenderContent: Codable, Hashable {
    struct ExternalMedia: Codable, Hashable {
        struct Media: Codable, Hashable {
            let url: URL?
            let originalWidth: Int?
            let originalHeight: Int?
        }

        let title: String?
        let media: Media?
        let previewMedia: Media?
    }

    struct File: Codable, Hashable {
        let name: String?
        let url: URL?
        let byteSize: Int64?
        let mediaType: String?
    }

    struct Audio: Codable, Hashable {
        let url: URL?
        /// Milliseconds.
        let duration: Int64?
    }

    struct Video: Codable, Hashable {
        struct Stream: Codable, Hashable {
            struct Location: Codable, Hashable {
                let url: URL?
            }

            let streamingLocations: [Location]?
            let width: Int?
            let height: Int?
        }

        let progressiveStreams: [Stream]?
        let thumbnail: LinkedInVectorImage?
        /// Milliseconds.
        let duration: Int64?
    }

    struct Forwarded: Codable, Hashable {
        let forwardedBody: LinkedInText?
        let originalSender: LinkedInParticipant?
    }

    struct Replied: Codable, Hashable {
        struct Original: Codable, Hashable {
            let entityUrn: String
        }

        let messageBody: LinkedInText?
        let originalMessage: Original?
        let originalSender: LinkedInParticipant?
        /// Milliseconds.
        let originalSendAt: Int64?
    }

    /// Something on LinkedIn the message shares, such as a post (`FEED_UPDATE`).
    struct HostUrnData: Codable, Hashable {
        let type: String?
        let hostUrn: String?
    }

    let vectorImage: LinkedInVectorImage?
    let externalMedia: ExternalMedia?
    let file: File?
    let audio: Audio?
    let video: Video?
    let forwardedMessageContent: Forwarded?
    let repliedMessageContent: Replied?
    let hostUrnData: HostUrnData?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vectorImage = try? container.decodeIfPresent(LinkedInVectorImage.self, forKey: .vectorImage)
        externalMedia = try? container.decodeIfPresent(ExternalMedia.self, forKey: .externalMedia)
        file = try? container.decodeIfPresent(File.self, forKey: .file)
        audio = try? container.decodeIfPresent(Audio.self, forKey: .audio)
        video = try? container.decodeIfPresent(Video.self, forKey: .video)
        forwardedMessageContent = try? container.decodeIfPresent(Forwarded.self, forKey: .forwardedMessageContent)
        repliedMessageContent = try? container.decodeIfPresent(Replied.self, forKey: .repliedMessageContent)
        hostUrnData = try? container.decodeIfPresent(HostUrnData.self, forKey: .hostUrnData)
    }
}

/// A message (`com.linkedin.messenger.Message`).
struct LinkedInMessage: Codable, Hashable {
    struct ReactionSummary: Codable, Hashable {
        let emoji: String
        let count: Int
        let viewerReacted: Bool
    }

    /// `urn:li:msg_message:(<mailbox>,<id>)`: what reactions, edits and recalls name.
    let entityUrn: String
    /// Milliseconds.
    let deliveredAtMs: Int64
    let sender: LinkedInSenderRef
    /// The sender in full.
    let actor: LinkedInParticipant?
    let body: LinkedInText?
    let subject: String?
    /// `DEFAULT`, `EDITED` or `RECALLED`.
    let messageBodyRenderFormat: String?
    var reactionSummaries: [ReactionSummary]
    let renderContent: [LinkedInRenderContent]
    let renderContentFallbackText: String?

    enum CodingKeys: String, CodingKey {
        case entityUrn, sender, actor, body, subject, messageBodyRenderFormat, reactionSummaries, renderContent, renderContentFallbackText
        case deliveredAtMs = "deliveredAt"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityUrn = try container.decode(String.self, forKey: .entityUrn)
        deliveredAtMs = try container.decode(Int64.self, forKey: .deliveredAtMs)
        sender = try container.decode(LinkedInSenderRef.self, forKey: .sender)
        actor = try? container.decodeIfPresent(LinkedInParticipant.self, forKey: .actor)
        body = try? container.decodeIfPresent(LinkedInText.self, forKey: .body)
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        messageBodyRenderFormat = try? container.decodeIfPresent(String.self, forKey: .messageBodyRenderFormat)
        reactionSummaries = (try? container.decodeIfPresent(LinkedInLossyList<ReactionSummary>.self, forKey: .reactionSummaries))?.elements ?? []
        renderContent = (try? container.decodeIfPresent(LinkedInLossyList<LinkedInRenderContent>.self, forKey: .renderContent))?.elements ?? []
        renderContentFallbackText = try? container.decodeIfPresent(String.self, forKey: .renderContentFallbackText)
    }

    var deliveredAt: Date {
        Date(timeIntervalSince1970: Double(deliveredAtMs) / 1000)
    }

    var isRecalled: Bool {
        messageBodyRenderFormat == "RECALLED"
    }

    var isEdited: Bool {
        messageBodyRenderFormat == "EDITED"
    }

    var text: String? {
        let text = body?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : body?.text
    }

    /// One line for the Chats list.
    var preview: String {
        if isRecalled { return "Message deleted" }
        if let text { return text.replacingOccurrences(of: "\n", with: " ") }
        for content in renderContent {
            if content.vectorImage != nil { return "Photo" }
            if content.externalMedia != nil { return "GIF" }
            if content.video != nil { return "Video" }
            if content.audio != nil { return "Voice message" }
            if let file = content.file { return file.name ?? "File" }
            if content.hostUrnData != nil { return "Shared a post" }
            if content.forwardedMessageContent != nil { return "Forwarded message" }
        }
        return renderContentFallbackText ?? subject ?? "Message"
    }
}

/// A conversation (`com.linkedin.messenger.Conversation`).
struct LinkedInConversation: Decodable {
    struct Messages: Decodable {
        let elements: [LinkedInMessage]
    }

    /// `urn:li:msg_conversation:(<mailbox>,<thread id>)`.
    let entityUrn: String
    let conversationParticipants: [LinkedInParticipant]
    let unreadCount: Int?
    let lastActivityAt: Int64?
    let lastReadAt: Int64?
    let read: Bool?
    let groupChat: Bool?
    let title: String?
    /// `ACTIVE`, or `MUTE` for a muted chat.
    let notificationStatus: String?
    let conversationUrl: URL?
    /// The newest message, for the Chats list.
    let messages: Messages?

    enum CodingKeys: String, CodingKey {
        case entityUrn, conversationParticipants, unreadCount, lastActivityAt, lastReadAt, read, groupChat, title, notificationStatus, conversationUrl, messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityUrn = try container.decode(String.self, forKey: .entityUrn)
        conversationParticipants = (try? container.decodeIfPresent(LinkedInLossyList<LinkedInParticipant>.self, forKey: .conversationParticipants))?.elements ?? []
        unreadCount = try? container.decodeIfPresent(Int.self, forKey: .unreadCount)
        lastActivityAt = try? container.decodeIfPresent(Int64.self, forKey: .lastActivityAt)
        lastReadAt = try? container.decodeIfPresent(Int64.self, forKey: .lastReadAt)
        read = try? container.decodeIfPresent(Bool.self, forKey: .read)
        groupChat = try? container.decodeIfPresent(Bool.self, forKey: .groupChat)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        notificationStatus = try? container.decodeIfPresent(String.self, forKey: .notificationStatus)
        conversationUrl = try? container.decodeIfPresent(URL.self, forKey: .conversationUrl)
        messages = try? container.decodeIfPresent(Messages.self, forKey: .messages)
    }

    func others(viewerUrn: String) -> [LinkedInParticipant] {
        conversationParticipants.filter { $0.hostIdentityUrn != viewerUrn }
    }

    func isGroup(viewerUrn: String) -> Bool {
        groupChat == true || others(viewerUrn: viewerUrn).count > 1
    }

    func displayTitle(viewerUrn: String) -> String {
        if let title, !title.isEmpty { return title }
        let names = others(viewerUrn: viewerUrn).map(\.name)
        return names.isEmpty ? "LinkedIn Chat" : names.joined(separator: ", ")
    }

    var lastReadDate: Date? {
        lastReadAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var lastActivityDate: Date? {
        lastActivityAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// What `createMessage` answers.
struct LinkedInSentMessage: Decodable {
    let entityUrn: String
    /// Milliseconds.
    let deliveredAt: Int64
}

struct LinkedInSentResponse: Decodable {
    let value: LinkedInSentMessage
}

// MARK: GraphQL envelopes

struct LinkedInGraphQL<T: Decodable>: Decodable {
    let data: T
}

struct LinkedInGraphQLErrors: Decodable {
    struct Error: Decodable {
        let message: String
    }

    let errors: [Error]?
}

struct LinkedInConversationsData: Decodable {
    struct Page: Decodable {
        struct Metadata: Decodable {
            let nextCursor: String?
        }

        let elements: [LinkedInConversation]
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case elements, metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elements = try container.decode(LinkedInLossyList<LinkedInConversation>.self, forKey: .elements).elements
            metadata = try? container.decodeIfPresent(Metadata.self, forKey: .metadata)
        }
    }

    let messengerConversationsByCategoryQuery: Page
}

struct LinkedInConversationData: Decodable {
    let messengerConversationsById: LinkedInConversation
}

struct LinkedInMessagesSyncData: Decodable {
    struct Page: Decodable {
        let elements: [LinkedInMessage]

        enum CodingKeys: String, CodingKey {
            case elements
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elements = try container.decode(LinkedInLossyList<LinkedInMessage>.self, forKey: .elements).elements
        }
    }

    let messengerMessagesBySyncToken: Page
}

struct LinkedInMessagesByTimeData: Decodable {
    struct Page: Decodable {
        struct Metadata: Decodable {
            let prevCursor: String?
        }

        let elements: [LinkedInMessage]
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case elements, metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elements = try container.decode(LinkedInLossyList<LinkedInMessage>.self, forKey: .elements).elements
            metadata = try? container.decodeIfPresent(Metadata.self, forKey: .metadata)
        }
    }

    let messengerMessagesByAnchorTimestamp: Page
}

/// A list that skips entries it can't decode.
struct LinkedInLossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(LinkedInSkipped.self)
            }
        }
        self.elements = elements
    }
}

private struct LinkedInSkipped: Decodable {}

// MARK: Notifications

/// One card on the Notifications tab (`com.linkedin.voyager.dash.identity.notifications.Card`).
struct LinkedInNotificationCard: Hashable {
    /// `urn:li:fsd_notificationCard:(<TYPE>,<group>)`.
    let entityUrn: String
    /// Such as `JOB_CHANGE_PROP` or `REACTION`, from the urn.
    let kind: String
    let headline: String
    let read: Bool
    let publishedAt: Date
    /// Where tapping the card goes on linkedin.com.
    let url: URL?
    let actorName: String?
    let actorURL: URL?
    let imageURL: URL?
    /// A quoted post or comment, when the card shows one.
    let content: String?
}

/// Parses Voyager's normalized JSON (`data` plus an `included` list of entities that `*key` fields refer to by urn).
enum LinkedInParser {
    static func me(from data: Data) throws -> LinkedInMe {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let included = root["included"] as? [[String: Any]],
              let mini = included.first(where: { $0["dashEntityUrn"] is String }),
              let profileUrn = mini["dashEntityUrn"] as? String
        else { throw SourceError.invalidResponse }
        let name = [mini["firstName"] as? String, mini["lastName"] as? String].compactMap(\.self).joined(separator: " ")
        let picture = (mini["picture"] as? [String: Any]).flatMap(vectorImage(in:))
        return LinkedInMe(profileUrn: profileUrn, publicIdentifier: mini["publicIdentifier"] as? String, name: name, avatarURL: picture?.url(width: 200))
    }

    static func notificationCards(from data: Data) throws -> [LinkedInNotificationCard] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any]
        else { throw SourceError.invalidResponse }
        let included = root["included"] as? [[String: Any]] ?? []
        let entities = Dictionary(included.compactMap { entity in (entity["entityUrn"] as? String).map { ($0, entity) } }, uniquingKeysWith: { first, _ in first })
        let urns = body["*elements"] as? [String] ?? []
        return urns.compactMap { urn in entities[urn].flatMap { card(urn: urn, $0, entities: entities) } }
    }

    private static func card(urn: String, _ card: [String: Any], entities: [String: [String: Any]]) -> LinkedInNotificationCard? {
        guard let headline = (card["headline"] as? [String: Any])?["text"] as? String,
              let published = card["publishedAt"] as? Double
        else { return nil }
        let header = card["headerImage"] as? [String: Any]
        var imageURL: URL?
        for attribute in header?["attributes"] as? [[String: Any]] ?? [] {
            if let image = image(in: attribute, entities: entities) {
                imageURL = image.url(width: 200)
                break
            }
        }
        let content = [card["contentPrimaryText"], card["contentSecondaryText"]]
            .compactMap { ($0 as? [String: Any])?["text"] as? String }
            .first { !$0.isEmpty }
        return LinkedInNotificationCard(
            entityUrn: urn,
            kind: kind(of: urn),
            headline: headline,
            read: card["read"] as? Bool ?? true,
            publishedAt: Date(timeIntervalSince1970: published / 1000),
            url: link((card["cardAction"] as? [String: Any])?["actionTarget"] as? String),
            actorName: (header?["accessibilityText"] as? String).flatMap(actorName(fromAccessibilityText:)),
            actorURL: link(header?["actionTarget"] as? String),
            imageURL: imageURL,
            content: content,
        )
    }

    /// `urn:li:fsd_notificationCard:(JOB_CHANGE_PROP,urn:li:…)` → `JOB_CHANGE_PROP`.
    static func kind(of urn: String) -> String {
        guard let open = urn.firstIndex(of: "(") else { return "UNKNOWN" }
        let rest = urn[urn.index(after: open)...]
        return String(rest.prefix { $0 != "," && $0 != ")" })
    }

    /// "View Nathanael Thomas’ profile" → "Nathanael Thomas".
    static func actorName(fromAccessibilityText text: String) -> String? {
        guard text.hasPrefix("View "), text.hasSuffix(" profile") else { return nil }
        var name = text.dropFirst("View ".count).dropLast(" profile".count)
        for suffix in ["’s", "'s", "’", "'"] where name.hasSuffix(suffix) {
            name = name.dropLast(suffix.count)
            break
        }
        return name.isEmpty ? nil : String(name)
    }

    /// A path such as `/in/someone` on linkedin.com; full URLs pass through.
    static func link(_ target: String?) -> URL? {
        guard let target, !target.isEmpty else { return nil }
        if target.hasPrefix("http") { return URL(string: target) }
        return URL(string: target, relativeTo: LinkedInClient.baseURL)?.absoluteURL
    }

    /// The image an image attribute shows: inline, or on an included entity its `*` field names.
    private static func image(in attribute: [String: Any], entities: [String: [String: Any]]) -> LinkedInVectorImage? {
        guard let detail = attribute["detailData"] as? [String: Any] else { return nil }
        for (key, value) in detail {
            if key.hasPrefix("*"), let urn = value as? String, let entity = entities[urn], let image = vectorImage(in: entity) {
                return image
            }
            if let nested = value as? [String: Any], let image = vectorImage(in: nested) {
                return image
            }
        }
        return nil
    }

    /// The first `{rootUrl, artifacts}` anywhere inside.
    static func vectorImage(in object: [String: Any]) -> LinkedInVectorImage? {
        if object["rootUrl"] is String, let artifacts = object["artifacts"] as? [[String: Any]] {
            return LinkedInVectorImage(
                rootUrl: object["rootUrl"] as? String,
                artifacts: artifacts.compactMap { artifact in
                    (artifact["fileIdentifyingUrlPathSegment"] as? String).map {
                        LinkedInVectorImage.Artifact(width: artifact["width"] as? Int, height: artifact["height"] as? Int, fileIdentifyingUrlPathSegment: $0)
                    }
                },
            )
        }
        for value in object.values {
            if let nested = value as? [String: Any], let image = vectorImage(in: nested) {
                return image
            }
        }
        return nil
    }
}
