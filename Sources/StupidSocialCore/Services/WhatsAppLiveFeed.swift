import Foundation

/// Keeps the account's WhatsApp connection open while the app is in the foreground. WhatsApp delivers messages
/// only to connected devices (queued ones arrive on the next login) and doesn't push to linked third-party
/// devices, so this connection is how chats stay current. Open chats and the Chats list refresh as the
/// connection stores what arrives.
@MainActor
public final class WhatsAppLiveFeed: LiveConnecting {
    private let client: WhatsAppClient
    private let accountId: String
    private let chatList: ChatListViewModel?
    private(set) var connection: LiveConnection<WhatsAppChanges>!
    private var observation: UUID?

    public init(client: WhatsAppClient, accountId: String, chatList: ChatListViewModel?) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        connection = LiveConnection(name: "WhatsApp", canConnect: { [client] in client.isLinked }, outcome: Self.outcome(for:)) { [weak self] connection in
            try await self?.follow(connection)
        }
        observation = connection.observe { [weak self] update in self?.updateChatList(update) }
    }

    /// Connects when the device is linked; call again after linking.
    public func start() {
        connection.start()
    }

    public func stop() {
        connection.stop()
    }

    public enum State: Sendable {
        case connected
        /// Opening, or waiting to retry after the connection closed.
        case connecting
        /// Not connecting: stopped, in the background, or ended by WhatsApp (logged out, banned, replaced).
        case offline
    }

    public var state: State {
        connection.isOpen ? .connected : connection.isRunning ? .connecting : .offline
    }

    /// A logged-out device won't come back by retrying, and whatsmeow doesn't reconnect after a temporary ban or
    /// while another connection holds the device either: wait for the next launch or foreground.
    private static func outcome(for error: Error) -> LiveOutcome {
        switch error as? WhatsAppError {
        case .loggedOut, .banned, .replaced, .notLinked: .stop
        default: .retry
        }
    }

    private func follow(_ connection: LiveConnection<WhatsAppChanges>) async throws {
        try await client.run(
            onLoggedIn: { Task { @MainActor [weak connection] in connection?.opened() } },
            onChanges: { changes in Task { @MainActor [weak connection] in connection?.deliver(changes) } },
        )
    }

    private func updateChatList(_ update: LiveUpdate<WhatsAppChanges>) {
        guard let chatList else { return }
        switch update {
        case let .event(changes) where changes.reloadList:
            Task { await chatList.load() }
        case let .event(changes) where !changes.chats.isEmpty:
            Task {
                let summaries = await client.chatSummaries(for: changes.chats)
                chatList.updateChats(summaries, accountId: accountId)
            }
        case .event:
            break
        case .catchUp:
            Task { await chatList.load() }
        }
    }
}
