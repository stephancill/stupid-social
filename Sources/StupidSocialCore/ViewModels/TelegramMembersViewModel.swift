import Foundation

/// A Telegram group's details and member list, opened from the chat's title.
@MainActor
public final class TelegramMembersViewModel: ObservableObject {
    /// `nil` while loading.
    @Published public private(set) var members: TelegramMemberList?
    @Published public private(set) var errorMessage: String?
    /// The group's title, description and photo; `nil` while loading or when they couldn't load.
    @Published public private(set) var info: TelegramGroupInfo?

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

    /// Fetches the details and member list each time they open, so statuses are current. A group that hides its
    /// members still shows its details.
    public func load() async {
        guard isGroup else { return }
        errorMessage = nil
        async let info = try? client.groupInfo(peer: peer)
        do {
            members = try await client.members(peer: peer)
        } catch {
            errorMessage = Self.errorText(error)
        }
        if let info = await info {
            self.info = info
        }
    }

    /// Sends the parts that changed; a title change posts a service message in the group, as in Telegram's apps.
    public func edit(title: String, about: String) async throws {
        guard let info else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.editGroup(
            peer: peer,
            title: title == info.title ? nil : title,
            about: about == (info.about ?? "") ? nil : about,
        )
        self.info = await (try? client.groupInfo(peer: peer)) ?? info
    }

    private static func errorText(_ error: Error) -> String {
        if case let TelegramError.rpc(_, message) = error, message == "CHAT_ADMIN_REQUIRED" {
            return "This group's admins have hidden its member list."
        }
        return error.localizedDescription
    }
}
