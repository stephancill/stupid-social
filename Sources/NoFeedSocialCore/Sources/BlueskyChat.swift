import Foundation

// Bluesky chat (DMs) through the `chat.bsky.convo.*` XRPC methods. They live on Bluesky's chat service, which the
// user's PDS forwards to when asked with the `atproto-proxy` header; the OAuth session needs the
// `transition:chat.bsky` scope, which sessions signed in before chat support lack.

struct BlueskyChatMember: Codable {
    let did: String
    let handle: String?
    let displayName: String?
    let avatar: URL?

    /// Deleted accounts come back with the handle `missing.invalid` (observed 2026-10-29).
    var name: String {
        if handle == "missing.invalid" { return "Deleted Account" }
        return displayName.flatMap { $0.isEmpty ? nil : $0 } ?? handle ?? did
    }
}

/// A conversation (`chat.bsky.convo.defs#convoView`).
struct BlueskyConvo: Decodable {
    let id: String
    let members: [BlueskyChatMember]
    let lastMessage: BlueskyChatMessage?
    let muted: Bool?
    /// `accepted`, or `request` for message requests.
    let status: String?
    let unreadCount: Int

    func others(viewerDid: String) -> [BlueskyChatMember] {
        members.filter { $0.did != viewerDid }
    }

    func isGroup(viewerDid: String) -> Bool {
        others(viewerDid: viewerDid).count > 1
    }

    func title(viewerDid: String) -> String {
        let names = others(viewerDid: viewerDid).map(\.name)
        return names.isEmpty ? "Chat" : names.joined(separator: ", ")
    }

    /// The oldest unread message's time, just before it, from `unreadCount` and a page of messages (newest first);
    /// the newest message's when nothing is unread.
    func readPosition(messages: [BlueskyChatMessage], viewerDid: String) -> Date? {
        guard unreadCount > 0 else { return messages.first?.sentAt }
        let fromOthers = messages.filter { $0.sender.did != viewerDid && !$0.isDeleted }
        guard unreadCount <= fromOthers.count else { return nil }
        return fromOthers[unreadCount - 1].sentAt.addingTimeInterval(-0.001)
    }
}

/// A message (`#messageView`) or a deleted one (`#deletedMessageView`).
struct BlueskyChatMessage: Codable {
    struct Sender: Codable {
        let did: String
    }

    struct Reaction: Codable {
        let value: String
        let sender: Sender
        let createdAt: Date?
    }

    /// `app.bsky.embed.record#view`: a shared post.
    struct Embed: Codable {
        struct Record: Codable {
            struct Author: Codable {
                let did: String?
                let handle: String?
                let displayName: String?
                let avatar: URL?
            }

            struct Value: Codable {
                let text: String?
            }

            /// Such as `app.bsky.embed.record#viewRecord` or `#viewNotFound`.
            let type: String?
            let uri: String?
            let author: Author?
            let value: Value?

            enum CodingKeys: String, CodingKey {
                case type = "$type"
                case uri, author, value
            }

            /// `at://<did>/app.bsky.feed.post/<rkey>` as its bsky.app page.
            var postURL: URL? {
                guard let uri, uri.hasPrefix("at://") else { return nil }
                let parts = uri.dropFirst("at://".count).split(separator: "/")
                guard parts.count == 3, parts[1] == "app.bsky.feed.post" else { return nil }
                return URL(string: "https://bsky.app/profile/\(parts[0])/post/\(parts[2])")
            }
        }

        let record: Record?
    }

    let type: String?
    let id: String
    let text: String?
    let sender: Sender
    let sentAt: Date
    var reactions: [Reaction]?
    let embed: Embed?

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case id, text, sender, sentAt, reactions, embed
    }

    var isDeleted: Bool {
        type == "chat.bsky.convo.defs#deletedMessageView"
    }

    /// One line for the Chats list.
    var preview: String {
        if isDeleted { return "Message deleted" }
        let body = (text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !body.isEmpty { return body }
        return embed?.record == nil ? "Message" : "Shared a post"
    }
}

/// A list that skips entries it can't decode, such as union members newer than the app.
struct BlueskyLossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(BlueskySkipped.self)
            }
        }
        self.elements = elements
    }
}

private struct BlueskySkipped: Decodable {}

struct BlueskyConvosPage: Decodable {
    let convos: BlueskyLossyList<BlueskyConvo>
    let cursor: String?
}

/// Newest first.
struct BlueskyMessagesPage: Decodable {
    let messages: BlueskyLossyList<BlueskyChatMessage>
    let cursor: String?
}

private struct BlueskyConvoResponse: Decodable {
    let convo: BlueskyConvo
}

private struct BlueskyReactionResponse: Decodable {
    let message: BlueskyChatMessage
}

extension BlueskyClient {
    static let chatProxy = "did:web:api.bsky.chat#bsky_chat"
    static let chatScope = "transition:chat.bsky"

    /// The signed-in account's DID, which tells the viewer's messages apart.
    func viewerDid() async throws -> String {
        try await validCredentials().did
    }

    /// Accepted chats, newest first; message requests are left out.
    func convos(limit: Int = 50) async throws -> [BlueskyConvo] {
        let page: BlueskyConvosPage = try await chat("GET", "chat.bsky.convo.listConvos", query: ["limit": String(limit), "status": "accepted"])
        return page.convos.elements
    }

    func convo(id: String) async throws -> BlueskyConvo {
        let response: BlueskyConvoResponse = try await chat("GET", "chat.bsky.convo.getConvo", query: ["convoId": id])
        return response.convo
    }

    func messages(convoId: String, cursor: String? = nil, limit: Int = 50) async throws -> BlueskyMessagesPage {
        var query = ["convoId": convoId, "limit": String(limit)]
        query["cursor"] = cursor
        return try await chat("GET", "chat.bsky.convo.getMessages", query: query)
    }

    func sendMessage(convoId: String, text: String) async throws -> BlueskyChatMessage {
        try await chat("POST", "chat.bsky.convo.sendMessage", body: ["convoId": convoId, "message": ["text": text]])
    }

    func markConvoRead(convoId: String, messageId: String) async throws {
        let _: BlueskyConvoResponse = try await chat("POST", "chat.bsky.convo.updateRead", body: ["convoId": convoId, "messageId": messageId])
    }

    /// Adds or removes one of the viewer's reactions and returns the message with its reactions.
    func setReaction(convoId: String, messageId: String, emoji: String, remove: Bool) async throws -> BlueskyChatMessage {
        let response: BlueskyReactionResponse = try await chat(
            "POST",
            remove ? "chat.bsky.convo.removeReaction" : "chat.bsky.convo.addReaction",
            body: ["convoId": convoId, "messageId": messageId, "value": emoji],
        )
        return response.message
    }

    private func chat<T: Decodable>(_ method: String, _ name: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> T {
        var credentials = try await validCredentials()
        guard credentials.scope.split(separator: " ").contains(Substring(Self.chatScope)) else {
            throw SourceError.serviceError("Sign in to Bluesky again to use chats.")
        }
        var components = URLComponents(url: credentials.pdsURL.appending(path: "/xrpc/\(name)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let data = try await authorizedData(
            method: method,
            url: components.url!,
            body: body.map { try JSONSerialization.data(withJSONObject: $0) },
            proxy: Self.chatProxy,
            credentials: &credentials,
        )
        return try decoder.decode(T.self, from: data)
    }
}

extension BlueskyClient: ChatListProvider {
    public var network: SocialNetwork {
        .bluesky
    }

    /// The newest 50 accepted chats. Bluesky has no archive.
    public func chatList() async throws -> ChatListPage {
        let viewerDid = try await viewerDid()
        return try await ChatListPage(chats: convos().map { Self.chatSummary($0, viewerDid: viewerDid) }, archived: [])
    }

    static func chatSummary(_ convo: BlueskyConvo, viewerDid: String) -> ChatSummary {
        let isGroup = convo.isGroup(viewerDid: viewerDid)
        var preview: String?
        if let last = convo.lastMessage {
            if last.sender.did == viewerDid {
                preview = "You: \(last.preview)"
            } else if isGroup, let sender = convo.members.first(where: { $0.did == last.sender.did }) {
                preview = "\(sender.name): \(last.preview)"
            } else {
                preview = last.preview
            }
        }
        return ChatSummary(
            id: "bluesky:convo:\(convo.id)",
            network: .bluesky,
            title: convo.title(viewerDid: viewerDid),
            avatarURL: isGroup ? nil : convo.others(viewerDid: viewerDid).first?.avatar,
            preview: preview,
            timestamp: convo.lastMessage?.sentAt,
            unreadCount: convo.unreadCount,
            destination: .bluesky(convoId: convo.id),
            namesSenderInPreview: isGroup,
            titleNamesPeople: true,
            isMuted: convo.muted == true,
        )
    }
}
