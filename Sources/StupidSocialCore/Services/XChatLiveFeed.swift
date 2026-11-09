import Foundation
import OSLog

/// Keeps X's chat WebSocket open while the app is in the foreground. X pushes every conversation's events on it
/// as binary Thrift `Message`s (validated with `scripts/xchat-client.py listen`), so open chats and the Chats
/// list update as events arrive.
///
/// The socket only carries what happens while it is open: after every reconnect, and when X sends a pull
/// instruction, open chats fetch their newest page and the Chats list reloads to catch up. The connection
/// sends X's keep-alive every 30 s; `LiveConnection` reconnects a dropped one with backoff, with a fresh token.
@MainActor
public final class XChatLiveFeed: LiveConnecting {
    private static let url = URL(string: "wss://chat-ws.x.com/ws")!
    /// `Message{2: MessageInstruction{2: KeepAliveInstruction{}}}`, which X's web client sends every 30 s.
    private static let keepAlive = Data([12, 0, 2, 12, 0, 2, 0, 0, 0])

    private let client: XChatClient
    private let accountId: String
    private let chatList: ChatListViewModel
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "XChatLiveFeed")
    /// Every conversation's events, as X sends them.
    private(set) var connection: LiveConnection<[XChatEvent]>!
    private var chatListObservation: UUID?

    public init(client: XChatClient, accountId: String, chatList: ChatListViewModel, keychainStore: KeychainCredentialStore) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        connection = LiveConnection(name: "X Chat", canConnect: { keychainStore.hasXChatKeys() }) { [weak self] connection in
            try await self?.follow(connection)
        }
        chatListObservation = connection.observe { update in
            if case .catchUp = update {
                Task { await chatList.load() }
            }
        }
    }

    /// Connects when X Chat is unlocked; call again after unlocking.
    public func start() {
        connection.start()
    }

    public func stop() {
        connection.stop()
    }

    /// Runs one connection until it closes.
    private func follow(_ connection: LiveConnection<[XChatEvent]>) async throws {
        let token = try await client.socketToken()
        var components = URLComponents(url: Self.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.setValue("https://x.com", forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
        try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    try? await socket.send(.data(Self.keepAlive))
                }
            }
            defer { heartbeat.cancel() }

            // X sends nothing on open, so a keep-alive that goes through is what shows the connection is up.
            try await socket.send(.data(Self.keepAlive))
            connection.opened()
            while !Task.isCancelled {
                guard case let .data(data) = try await socket.receive() else { continue }
                await handle(data, connection: connection)
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func handle(_ data: Data, connection: LiveConnection<[XChatEvent]>) async {
        guard let message = try? ThriftCoder.decode(data) else {
            logger.error("X Chat socket sent a frame that isn't a Thrift Message")
            return
        }
        let structures: [ThriftStruct] = if let event = message.structure(1) {
            [event]
        } else if let batch = message.structure(3) {
            batch.structures(1)
        } else {
            []
        }
        if let instruction = message.structure(2), instruction.structure(1) != nil {
            // PullMessagesInstruction: X wants the client to fetch what it missed.
            connection.requestCatchUp()
        }
        let events = structures.compactMap { try? XChatEvent($0) }
        guard !events.isEmpty else { return }
        // Ingesting first also takes in key changes, which open chats need to decrypt the events.
        await updateChatList(events)
        connection.deliver(events)
    }

    private func updateChatList(_ events: [XChatEvent]) async {
        if let summaries = await client.ingest(events) {
            chatList.updateChats(summaries, accountId: accountId)
        } else {
            // A conversation the inbox hasn't loaded, such as a new chat.
            await chatList.load()
        }
    }
}
