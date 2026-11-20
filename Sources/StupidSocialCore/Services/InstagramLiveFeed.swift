import Foundation
import OSLog

/// Keeps Instagram Direct's realtime socket open while the app is in the foreground, as Instagram's web client
/// does instead of polling (validated with `scripts/instagram-web-client.py direct-live`, observed 2026-11-20):
/// `gateway.instagram.com/ws/lightspeed`, a sync request from the inbox's sequence id, then each change pushed
/// as an `IGDSlideDeltaProcessorQuery` result. Open chats write pushed messages straight into their history, and
/// the Chats list fetches the changed thread's row. The client pings every 10 s, as the web client does.
///
/// The socket carries only what happens while it is open, so after a reconnect open chats load their newest page
/// and the Chats list reloads. Nothing connects while the account is rate limited, and a signed-out session stops
/// the connection until the app starts it again.
@MainActor
public final class InstagramLiveFeed: LiveConnecting {
    static let pingInterval: Duration = .seconds(10)

    private let client: InstagramClient
    private let accountId: String
    private let chatList: ChatListViewModel?
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "InstagramLiveFeed")
    /// Every change Instagram pushes, in the order it sends them.
    private(set) var connection: LiveConnection<[InstagramDirectDelta]>!
    private var observation: UUID?
    /// Threads whose Chats row to fetch again, debounced so a burst costs one request per thread.
    private var pendingRows: Set<String> = []
    private var rowRefresh: Task<Void, Never>?

    public init(client: InstagramClient, accountId: String, chatList: ChatListViewModel?) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        connection = LiveConnection(name: "Instagram Direct", outcome: Self.outcome(for:)) { [weak self] connection in
            try await self?.follow(connection)
        }
        observation = connection.observe { [weak self] update in self?.updateChatList(update) }
    }

    public func start() {
        connection.start()
    }

    public func stop() {
        connection.stop()
    }

    /// A signed-out session won't come back by retrying; a rate limit waits for its cooldown.
    static func outcome(for error: Error) -> LiveOutcome {
        switch error {
        case SourceError.notConfigured:
            .stop
        case let SourceError.rateLimited(until):
            .retry(minimum: .seconds(max(until.timeIntervalSinceNow, 0)))
        default:
            .retry
        }
    }

    /// One connection: subscribe, then read frames until the socket closes.
    private func follow(_ connection: LiveConnection<[InstagramDirectDelta]>) async throws {
        let subscription = try await client.directRealtimeSubscription()
        let socket = client.session.webSocketTask(with: subscription.request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
        try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            try await socket.send(.data(subscription.opening))
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pingInterval)
                    try? await socket.send(.data(Data([InstagramDGW.ping])))
                }
            }
            defer { heartbeat.cancel() }
            while !Task.isCancelled {
                guard case let .data(message) = try await socket.receive() else { continue }
                for frame in InstagramDGW.frames(message) {
                    try await handle(frame, socket: socket, connection: connection)
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func handle(_ frame: InstagramDGW.Frame, socket: URLSessionWebSocketTask, connection: LiveConnection<[InstagramDirectDelta]>) async throws {
        guard frame.kind == InstagramDGW.data, let (id, wantsAck, body) = InstagramDGW.split(dataPayload: frame.payload) else { return }
        if wantsAck {
            try await socket.send(.data(InstagramDGW.ackFrame(id: id)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let encoded = object["payload"] as? String, let payload = Data(base64Encoded: encoded)
        else { return }
        let (deltas, _) = InstagramDirectSync.deltas(fromPayload: payload)
        if object["request_id"] is NSNumber {
            // The answer to the sync request: the subscription is up.
            connection.opened()
        }
        if !deltas.isEmpty {
            connection.deliver(deltas)
        }
    }

    // MARK: Chats list

    private func updateChatList(_ update: LiveUpdate<[InstagramDirectDelta]>) {
        guard let chatList else { return }
        switch update {
        case let .event(deltas):
            let threads = Set(deltas.compactMap(\.threadFbid))
            guard !threads.isEmpty else { return }
            pendingRows.formUnion(threads)
            scheduleRowRefresh()
        case .catchUp:
            Task { await chatList.load() }
        }
    }

    /// A pushed change doesn't carry the row's unread count, so the thread is read again.
    private func scheduleRowRefresh() {
        rowRefresh?.cancel()
        rowRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, let chatList else { return }
            let threads = pendingRows
            pendingRows = []
            var rows: [ChatSummary] = []
            for threadFbid in threads.sorted() {
                do {
                    try await rows.append(InstagramClient.chatSummary(client.directThread(threadFbid: threadFbid)))
                } catch {
                    logger.info("Instagram row refresh failed: \(String(describing: error), privacy: .public)")
                }
            }
            if !rows.isEmpty {
                chatList.updateChats(rows, accountId: accountId)
            }
        }
    }
}
