import Foundation

/// The confirmation for an opened Apron link (SPEC.md §6): it shows the server, and only connects, signs in or
/// joins when the user confirms.
@MainActor
public final class ApronLinkViewModel: ObservableObject {
    public enum Action: Equatable {
        /// A server the user hasn't used: add it, as a guest.
        case addServer
        /// Present the link's token, adding the server if it is new.
        case signIn
        /// A room on a saved server that the user hasn't joined; opening it joins.
        case joinRoom
        case openRoom
        /// A saved server, or a user without a room: nothing to do but show it.
        case none
    }

    /// What a saved server says about the link's room, shown before joining.
    public struct RoomPreview: Equatable {
        public let title: String
        public let description: String?
        public let memberCount: Int?
        /// Members to show as faces, those with avatars first.
        public let members: [ApronUser]
    }

    public enum PreviewState: Equatable {
        case none
        case loading
        case loaded(RoomPreview)
        /// The server doesn't list the room to this user: private, deleted, or never there.
        case unavailable
        case failed(String)
    }

    public let link: ApronLink
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?
    @Published public private(set) var preview: PreviewState = .none

    private let service: ApronService
    private let chatList: ChatListViewModel

    public init(link: ApronLink, service: ApronService, chatList: ChatListViewModel) {
        self.link = link
        self.service = service
        self.chatList = chatList
    }

    public var savedServer: ApronServerMetadata? {
        service.server(for: link.serverURL)
    }

    public var destination: ChatSummary.Destination? {
        link.room.map { .apron(serverURL: link.serverURL, roomId: $0) }
    }

    public var action: Action {
        if link.token != nil { return .signIn }
        guard savedServer != nil else { return .addServer }
        guard let destination else { return .none }
        return chatList.contains(destination) ? .openRoom : .joinRoom
    }

    /// Looks up the link's room on a server the user already uses. A server the user hasn't used isn't contacted
    /// until they confirm (PROTOCOL.md A.4), so its links show only what the link says.
    public func loadPreview() async {
        guard link.token == nil, savedServer != nil, let roomId = link.room, preview == .none else { return }
        preview = .loading
        do {
            let session = try await service.session(serverURL: link.serverURL)
            guard let listing = try await session.connection.room(roomId: roomId) else {
                preview = .unavailable
                return
            }
            let users = Dictionary(listing.users.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
            let members = (listing.room.members ?? []).map { users[$0.userId] ?? $0 }
            let description = listing.room.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            preview = .loaded(RoomPreview(
                title: listing.room.displayTitle(users: users, you: session.you.userId),
                description: description?.isEmpty == false ? description : nil,
                memberCount: listing.room.memberCount ?? listing.room.members?.count,
                members: members.filter { $0.avatarURL != nil } + members.filter { $0.avatarURL == nil },
            ))
        } catch let ApronError.rpc(code, _) where code == -32602 {
            preview = .unavailable
        } catch {
            preview = .failed(error.localizedDescription)
        }
    }

    /// Runs the confirmed action. Returns whether the link's room, if any, can now be opened.
    public func confirm() async -> Bool {
        switch action {
        case .addServer, .signIn:
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                if let token = link.token, savedServer != nil {
                    try await service.updateToken(serverURL: link.serverURL, token: token)
                } else {
                    _ = try await service.addServer(input: link.serverURL.absoluteString, token: link.token, name: nil)
                }
                NotificationCenter.default.post(name: ApronLiveFeed.serversDidChangeNotification, object: nil)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        case .joinRoom, .openRoom, .none:
            return true
        }
    }
}
