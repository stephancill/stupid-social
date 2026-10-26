import Foundation

/// Shows each Spotify Messages chat's latest incoming share or text from the last week in the
/// notifications feed, whether or not it has been seen in Spotify.
@MainActor
public final class SpotifyMessagesSource: NotificationFetching {
    public let network: SocialNetwork = .spotify

    nonisolated static let recentWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let chatLimit = 20

    private let client: SpotifyClient
    private let metadataStore: AccountMetadataStore
    private var senderCache: [String: NotificationActor] = [:]
    private var shareCache: [String: SpotifyShareMetadata] = [:]

    public init(client: SpotifyClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let chats: [SpotifyChat]
        do {
            chats = try await RefreshTiming.measure("spotify-chats") {
                try await client.latestChats(limit: Self.chatLimit)
            }
        } catch SourceError.notConfigured {
            return []
        }
        guard let viewer = metadataStore.spotifyAccount?.username else {
            throw SourceError.serviceError("Spotify username unavailable")
        }

        var items: [NotificationItem] = []
        for (chat, message) in Self.recentIncomingMessages(in: chats, viewer: viewer, now: Date()) {
            guard let sender = message.sender, let sentAt = message.sentAt else { continue }
            let actor = await senderActor(username: sender)
            switch message.content {
            case let .share(uri):
                await items.append(shareItem(chat: chat, message: message, uri: uri, actor: actor, sentAt: sentAt))
            case let .text(text):
                items.append(textItem(chat: chat, message: message, text: text, actor: actor, sentAt: sentAt))
            case .other:
                continue
            }
        }
        return items
    }

    /// Each chat's latest message when someone else sent it within `recentWindow` and the feed can show it.
    nonisolated static func recentIncomingMessages(in chats: [SpotifyChat], viewer: String, now: Date) -> [(SpotifyChat, SpotifyChatMessage)] {
        chats.compactMap { chat in
            guard let message = chat.latestMessage,
                  let sender = message.sender, sender != viewer,
                  let sentAt = message.sentAt, now.timeIntervalSince(sentAt) <= recentWindow,
                  message.content != .other
            else { return nil }
            return (chat, message)
        }
    }

    /// `spotify:track:<id>?si=...` → `https://open.spotify.com/track/<id>`.
    nonisolated static func openURL(forShareURI uri: String) -> URL? {
        let base = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let parts = base.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    private func shareItem(chat: SpotifyChat, message: SpotifyChatMessage, uri: String, actor: NotificationActor, sentAt: Date) async -> NotificationItem {
        let url = Self.openURL(forShareURI: uri)
        let metadata = await shareMetadata(url: url)
        let name = actor.displayName ?? actor.id
        let kind = url?.pathComponents.dropFirst().first ?? "something"
        let text = if let title = metadata?.title, !title.isEmpty {
            "\(name) shared “\(title)”"
        } else {
            "\(name) shared a \(kind)"
        }
        return NotificationItem(
            id: "spotify:chat:\(chat.id):\(message.id)",
            network: .spotify,
            accountId: "spotify",
            sourceId: message.id,
            type: .message,
            timestamp: sentAt,
            text: text,
            actors: [actor],
            target: NotificationTarget(
                id: url?.absoluteString ?? uri,
                text: nil,
                url: url,
                imageURL: metadata?.thumbnailURL.flatMap(URL.init(string:)),
                author: actor,
                postedAt: sentAt,
            ),
        )
    }

    private func textItem(chat: SpotifyChat, message: SpotifyChatMessage, text: String, actor: NotificationActor, sentAt: Date) -> NotificationItem {
        NotificationItem(
            id: "spotify:chat:\(chat.id):\(message.id)",
            network: .spotify,
            accountId: "spotify",
            sourceId: message.id,
            type: .message,
            timestamp: sentAt,
            text: "\(actor.displayName ?? actor.id) sent a message",
            actors: [actor],
            target: NotificationTarget(id: message.id, text: text, url: nil, author: actor, postedAt: sentAt),
        )
    }

    /// Spotify usernames are often random IDs, so the actor carries the profile name as its
    /// display name and leaves `username` empty; the feed shows `username` first when present.
    private func senderActor(username: String) async -> NotificationActor {
        if let cached = senderCache[username] { return cached }
        let profile = try? await client.userProfile(username: username)
        let actor = NotificationActor(
            id: username,
            network: .spotify,
            username: nil,
            displayName: profile?.display_name ?? username,
            avatarURL: profile?.images?.first.flatMap { URL(string: $0.url) },
        )
        if profile != nil { senderCache[username] = actor }
        return actor
    }

    private func shareMetadata(url: URL?) async -> SpotifyShareMetadata? {
        guard let url else { return nil }
        if let cached = shareCache[url.absoluteString] { return cached }
        guard let metadata = try? await client.shareMetadata(url: url) else { return nil }
        shareCache[url.absoluteString] = metadata
        return metadata
    }
}
