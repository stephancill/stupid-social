import Foundation

/// An Apron room's members, profiles and notification level, for the screens opened from its chat. The room's
/// `ApronChatAdapter` keeps it current from the same connection.
@MainActor
public final class ApronRoomViewModel: ObservableObject {
    /// The room's members, you first, then by name; `nil` until the server has listed them (§4.2.1).
    @Published public internal(set) var members: [ApronUser]?
    /// The total when the server listed only some members.
    @Published public internal(set) var memberCount: Int?
    /// This room's notification level and the levels it offers; `nil` where the server doesn't push to this account.
    @Published public internal(set) var notifications: ApronRoomNotifications?
    @Published public internal(set) var notificationError: String?
    @Published public internal(set) var isConnected = false

    public let serverURL: URL
    /// Empty in a new direct chat until its first message starts the room.
    @Published public internal(set) var roomId: String
    weak var adapter: ApronChatAdapter?

    init(serverURL: URL, roomId: String) {
        self.serverURL = serverURL
        self.roomId = roomId
    }

    /// Whether the user is reachable now, `nil` when the server doesn't say (§4.5.1). Your own entry follows
    /// your setting, since the server never reports your status as others see it to you.
    public func presence(of user: ApronUser) -> ApronPresence? {
        adapter?.presence(of: user)
    }

    public func isOwnUser(_ user: ApronUser) -> Bool {
        adapter?.isOwnUserId(user.userId) ?? false
    }

    /// The kept current object, falling back to a recorded one such as a message's `from` (§3.3.1).
    public func currentUser(_ user: ApronUser) -> ApronUser {
        adapter?.currentUser(user) ?? user
    }

    /// The kept user object's avatar, falling back to the recorded `from` (§3.3.1).
    public func avatarURL(for user: ApronUser) -> URL? {
        adapter?.currentUser(user).avatarURL ?? user.avatarURL
    }

    /// The kept or recorded user behind a chat user, such as a tapped avatar, for the profile screen.
    public func apronUser(for user: ChatUser) -> ApronUser {
        adapter?.apronUser(for: user)
            ?? ApronUser(userId: user.id, name: user.name == user.id ? nil : user.name, avatar: user.avatarURL?.absoluteString, roles: nil)
    }

    /// Whether the profile offers a direct message: the server has rooms, it's someone else, and this isn't
    /// already your room with them.
    public func canMessage(_ user: ApronUser) -> Bool {
        isConnected && adapter?.canOpenDirectRoom(with: user) == true
    }

    /// The private room you talk to the user in, `nil` when there is none yet; one is started by the first message.
    public func existingDirectRoom(with user: ApronUser) async throws -> String? {
        guard let adapter else { throw ApronError.closed }
        return try await adapter.existingDirectRoom(with: user)
    }

    /// Applies a notification level with `status` (`ApronRoomNotifications`); the server keeps it for every device.
    public func setNotificationLevel(_ level: ApronNotificationLevel) async {
        await adapter?.setNotificationLevel(level)
    }
}
