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

    public let link: ApronLink
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?

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
