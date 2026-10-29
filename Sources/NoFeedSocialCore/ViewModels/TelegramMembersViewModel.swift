import Foundation

/// A Telegram group's member list, opened from the chat's title.
@MainActor
public final class TelegramMembersViewModel: ObservableObject {
    /// `nil` while loading.
    @Published public private(set) var members: TelegramMemberList?
    @Published public private(set) var errorMessage: String?

    let client: TelegramClient
    public let peer: TelegramPeer

    public init(client: TelegramClient, peer: TelegramPeer) {
        self.client = client
        self.peer = peer
    }

    /// Groups list their members; private chats have none to list.
    public var isGroup: Bool {
        peer.kind != .user
    }

    /// Fetches the member list each time it opens, so statuses are current.
    public func load() async {
        guard isGroup else { return }
        errorMessage = nil
        do {
            members = try await client.members(peer: peer)
        } catch {
            errorMessage = Self.errorText(error)
        }
    }

    private static func errorText(_ error: Error) -> String {
        if case let TelegramError.rpc(_, message) = error, message == "CHAT_ADMIN_REQUIRED" {
            return "This group's admins have hidden its member list."
        }
        return error.localizedDescription
    }
}
