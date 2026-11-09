import Foundation

/// A Discord user's profile, opened from a chat's avatars, mentions or a DM's title, and the DM it can open.
@MainActor
public final class DiscordProfileViewModel: ObservableObject {
    public struct Profile: Equatable {
        public let id: String
        public let name: String
        public let username: String?
        public let avatarURL: URL?
        public let fullAvatarURL: URL?
        public let pronouns: String?
        public let bio: String?
        public let mutualServers: Int
        public let isYou: Bool
        public let isBot: Bool
    }

    /// `nil` while loading.
    @Published public private(set) var profile: Profile?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isOpeningChat = false

    private let gateway: DiscordGateway
    public let userId: String

    public init(gateway: DiscordGateway, userId: String) {
        self.gateway = gateway
        self.userId = userId
    }

    public func load() async {
        errorMessage = nil
        do {
            let loaded = try await gateway.client.profile(userId: userId)
            let user = loaded.user
            profile = Profile(
                id: user.id,
                name: user.name,
                username: user.username,
                avatarURL: user.avatarURL,
                fullAvatarURL: user.avatar.flatMap { URL(string: "https://cdn.discordapp.com/avatars/\(user.id)/\($0).png?size=1024") },
                pronouns: loaded.userProfile?.pronouns.flatMap { $0.isEmpty ? nil : $0 },
                bio: (loaded.userProfile?.bio ?? "").isEmpty ? nil : loaded.userProfile?.bio,
                mutualServers: loaded.mutualGuilds?.count ?? 0,
                isYou: user.id == gateway.me?.id,
                isBot: user.bot == true,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Your DM with them: the one the gateway knows, else the one Discord opens (no message is sent until you
    /// write one). Returns the destination to open.
    public func openChat() async -> ChatDestination? {
        if let existing = gateway.privateChannels.values.first(where: { $0.type == DiscordChannel.dm && $0.recipients?.contains { $0.id == userId } == true }) {
            return .discord(channelId: existing.id)
        }
        isOpeningChat = true
        defer { isOpeningChat = false }
        do {
            let channel = try await gateway.client.openDM(userId: userId)
            gateway.remember(channel)
            return .discord(channelId: channel.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The other person in a DM, whose profile the chat's title opens; `nil` for other chats.
    public static func dmRecipient(channelId: String, gateway: DiscordGateway) -> String? {
        guard let channel = gateway.channel(id: channelId), channel.type == DiscordChannel.dm else { return nil }
        return channel.recipients?.first { $0.id != gateway.me?.id }?.id
    }
}
