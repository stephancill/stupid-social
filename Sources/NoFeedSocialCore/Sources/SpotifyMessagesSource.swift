import Foundation

/// Lists Spotify Messages chats for the Chats screen, each with its latest message.
@MainActor
public final class SpotifyMessagesSource {
    private static let chatListLimit = 50

    private let client: SpotifyClient
    private let metadataStore: AccountMetadataStore
    private var senderCache: [String: NotificationActor] = [:]
    private var shareCache: [String: SpotifyShareMetadata] = [:]

    public init(client: SpotifyClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    /// Every chat with its latest message, for the Chats list. DMs are titled with the other member.
    public func chatSummaries() async throws -> [ChatSummary] {
        let chats = try await client.latestChats(limit: Self.chatListLimit)
        guard let viewer = metadataStore.spotifyAccount?.username else {
            throw SourceError.serviceError("Spotify username unavailable")
        }
        var summaries: [ChatSummary] = []
        for chat in chats {
            let partner = chat.isGroup ? nil : chat.members.first { $0 != viewer }
            var partnerActor: NotificationActor?
            if let partner {
                partnerActor = await senderActor(username: partner)
            }
            var preview: String?
            if let latest = chat.latestMessage {
                preview = await self.preview(of: latest, in: chat, viewer: viewer)
            }
            let title = chat.isGroup ? chat.name ?? "Group" : partnerActor.map { $0.displayName ?? $0.id } ?? "Chat"
            summaries.append(ChatSummary(
                id: "spotify:chat:\(chat.id)",
                network: .spotify,
                title: title,
                avatarURL: partnerActor?.avatarURL,
                preview: preview,
                timestamp: chat.latestMessage?.sentAt,
                unreadCount: chat.unseenCount,
                destination: .spotify(chatId: chat.id),
                namesSenderInPreview: chat.isGroup,
                titleNamesPeople: !chat.isGroup,
            ))
        }
        return summaries
    }

    private func preview(of message: SpotifyChatMessage, in chat: SpotifyChat, viewer: String) async -> String {
        let body: String
        switch message.content {
        case let .text(text):
            body = text.replacingOccurrences(of: "\n", with: " ")
        case let .share(uri):
            let url = Self.openURL(forShareURI: uri)
            let kind = url?.pathComponents.dropFirst().first ?? "something"
            body = await shareMetadata(url: url)?.title.map { "Shared “\($0)”" } ?? "Shared a \(kind)"
        case .other:
            body = "Message"
        }
        guard let sender = message.sender else { return body }
        if sender == viewer { return "You: \(body)" }
        guard chat.isGroup else { return body }
        let actor = await senderActor(username: sender)
        return "\(actor.displayName ?? actor.id): \(body)"
    }

    /// `spotify:track:<id>?si=...` → `https://open.spotify.com/track/<id>`.
    nonisolated static func openURL(forShareURI uri: String) -> URL? {
        let base = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let parts = base.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    /// Spotify usernames are often random IDs, so the actor carries the profile name as its display name.
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
