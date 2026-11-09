import Foundation
@_exported import StupidChatKit

/// The network's id for a chat, which `ChatsView` turns into the chat.
public enum ChatDestination: Hashable, Codable, Sendable {
    case apron(serverURL: URL, roomId: String)
    /// A direct chat with an Apron user that has no room yet; its first message starts one.
    case apronDirect(serverURL: URL, user: ApronUser)
    /// The base62 id from `spotify:chat:<id>`.
    case spotify(chatId: String)
    /// The id in `/direct/t/<thread_fbid>/`.
    case instagram(threadFbid: String)
    case telegram(peer: TelegramPeer)
    /// An XChat conversation id: "<user id>:<user id>" for one-to-one chats.
    case x(conversationId: String)
    /// A `chat.bsky.convo` id.
    case bluesky(convoId: String)
    /// A Discord channel id: a DM, group DM or guild text channel.
    case discord(channelId: String)
    /// A LinkedIn `urn:li:msg_conversation:(<mailbox>,<thread id>)`.
    case linkedin(conversationUrn: String)
    /// A preview chat in demo mode (`DemoChats`).
    case demo(chatId: String)
}

public typealias ChatSummary = StupidChatKit.ChatSummary<ChatDestination>
public typealias ChatListPage = StupidChatKit.ChatListPage<ChatDestination>
public typealias ChatListSource = StupidChatKit.ChatListSource<ChatDestination>
public typealias ChatListViewModel = StupidChatKit.ChatListViewModel<ChatDestination>

public extension SocialNetwork {
    var chatNetwork: ChatNetwork {
        ChatNetwork(rawValue: rawValue)
    }
}

/// Every chat network here is a `SocialNetwork`, so `chat.network == .telegram` reads as before.
public extension ChatNetwork {
    static let x = SocialNetwork.x.chatNetwork
    static let instagram = SocialNetwork.instagram.chatNetwork
    static let spotify = SocialNetwork.spotify.chatNetwork
    static let bluesky = SocialNetwork.bluesky.chatNetwork
    static let apron = SocialNetwork.apron.chatNetwork
    static let telegram = SocialNetwork.telegram.chatNetwork
    static let discord = SocialNetwork.discord.chatNetwork
    static let linkedin = SocialNetwork.linkedin.chatNetwork
    static let debug = SocialNetwork.debug.chatNetwork

    var displayName: String {
        socialNetwork.displayName
    }

    /// The app only makes chat networks from its `SocialNetwork`s.
    var socialNetwork: SocialNetwork {
        guard let network = SocialNetwork(rawValue: rawValue) else { preconditionFailure("Unknown chat network \(rawValue)") }
        return network
    }
}

extension SourceError: ChatNotConnectedError {
    public var isNotConnected: Bool {
        if case .notConfigured = self { true } else { false }
    }
}
