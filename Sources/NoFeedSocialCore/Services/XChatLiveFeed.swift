import Foundation
import OSLog

/// Keeps X's chat WebSocket open while the app is in the foreground. X pushes every conversation's events on it
/// as binary Thrift `Message`s (validated with `scripts/xchat-client.py listen`), so open chats and the Chats
/// list update as events arrive.
///
/// The socket only carries what happens while it is open: on every connect, and when X sends a pull
/// instruction, open chats fetch their newest page and the Chats list reloads to catch up. The connection
/// sends X's keep-alive every 30 s, and a dropped one reconnects with backoff and a fresh token.
@MainActor
public final class XChatLiveFeed {
    private struct Observer {
        let conversationId: String
        let onEvents: ([XChatEvent]) -> Void
        let onCatchUp: () -> Void
    }

    private static let url = URL(string: "wss://chat-ws.x.com/ws")!
    /// `Message{2: MessageInstruction{2: KeepAliveInstruction{}}}`, which X's web client sends every 30 s.
    private static let keepAlive = Data([12, 0, 2, 12, 0, 2, 0, 0, 0])

    private let client: XChatClient
    private let accountId: String
    private let chatList: ChatListViewModel
    private let keychainStore: KeychainCredentialStore
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "XChatLiveFeed")
    private var loop: Task<Void, Never>?
    private var observers: [UUID: Observer] = [:]
    /// Whether a connection has opened before, so the next one has something to catch up on.
    private var hasConnected = false

    public init(client: XChatClient, accountId: String, chatList: ChatListViewModel, keychainStore: KeychainCredentialStore) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        self.keychainStore = keychainStore
    }

    /// Connects when X Chat is unlocked; call again after unlocking.
    public func start() {
        guard loop == nil, !DemoData.isDemoMode, keychainStore.hasXChatKeys() else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Delivers a conversation's events to an open chat, and asks it to catch up after each (re)connect.
    func observe(conversationId: String, onEvents: @escaping ([XChatEvent]) -> Void, onCatchUp: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = Observer(conversationId: conversationId, onEvents: onEvents, onCatchUp: onCatchUp)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func run() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled, keychainStore.hasXChatKeys() {
            do {
                let token = try await client.socketToken()
                try await follow(token: token) {
                    delay = .seconds(1)
                }
            } catch {
                logger.info("X Chat socket closed: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
        loop = nil
    }

    /// Runs one connection until it closes or the feed stops.
    private func follow(token: String, onOpen: () -> Void) async throws {
        var components = URLComponents(url: Self.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.setValue("https://x.com", forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
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
        onOpen()
        if hasConnected {
            catchUp()
        }
        hasConnected = true

        while !Task.isCancelled {
            guard case let .data(data) = try await socket.receive() else { continue }
            await handle(data)
        }
    }

    private func handle(_ data: Data) async {
        guard let message = try? ThriftCoder.decode(data) else {
            logger.error("X Chat socket sent a frame that isn't a Thrift Message")
            return
        }
        if let event = message.structure(1) {
            await deliver([event])
        } else if let batch = message.structure(3) {
            await deliver(batch.structures(1))
        } else if let instruction = message.structure(2), instruction.structure(1) != nil {
            // PullMessagesInstruction: X wants the client to fetch what it missed.
            catchUp()
        }
    }

    private func deliver(_ structures: [ThriftStruct]) async {
        let events = structures.compactMap { try? XChatEvent($0) }
        guard !events.isEmpty else { return }
        if let summaries = await client.ingest(events) {
            chatList.updateChats(summaries, accountId: accountId)
        } else {
            // A conversation the inbox hasn't loaded, such as a new chat.
            Task { await chatList.load() }
        }
        for observer in observers.values {
            let own = events.filter { $0.conversationId == observer.conversationId }
            if !own.isEmpty {
                observer.onEvents(own)
            }
        }
    }

    private func catchUp() {
        Task { await chatList.load() }
        for observer in observers.values {
            observer.onCatchUp()
        }
    }
}
