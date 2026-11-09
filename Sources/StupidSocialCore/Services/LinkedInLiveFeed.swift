import Foundation
import OSLog

/// An event from LinkedIn's realtime stream that chats follow.
enum LinkedInLiveEvent {
    /// A new message, or a change to one (an edit, or `RECALLED` when unsent), with its conversation.
    case message(conversationUrn: String, LinkedInMessage)
    /// One emoji's new total on a message.
    case reaction(messageUrn: String, LinkedInMessage.ReactionSummary)
    /// A conversation changed, such as its read state or latest activity.
    case conversation(LinkedInConversation)
    /// Someone started typing; LinkedIn's web client shows it for 5 s.
    case typing(conversationUrn: String, LinkedInParticipant)
}

/// Keeps LinkedIn's realtime stream (`/realtime/connect`, server-sent events) open while the app is in the
/// foreground, so open chats and the Chats list update as messages, reactions, typing and read state change
/// (validated with `scripts/linkedin-web-client.py stream`, observed 2026-11-09). The stream sends a heartbeat
/// every 15 s; LinkedIn's web client treats 30 s without one as a dropped connection, and so does this, with
/// some margin. Messaging topics arrive without subscribing: the web client only subscribes to presence.
@MainActor
public final class LinkedInLiveFeed: LiveConnecting {
    /// Longer than the web client's 30 s, so one late heartbeat doesn't drop the connection.
    static let silenceLimit: Duration = .seconds(45)

    private let client: LinkedInClient
    private let accountId: String
    private let chatList: ChatListViewModel?
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "LinkedInLiveFeed")
    private(set) var connection: LiveConnection<LinkedInLiveEvent>!
    private var observation: UUID?
    private var lastActivity = ContinuousClock.now
    private var wentQuiet = false
    /// Rows to fetch again after new messages, debounced so a burst costs one request per conversation.
    private var pendingRows: Set<String> = []
    private var rowRefresh: Task<Void, Never>?

    public init(client: LinkedInClient, accountId: String, chatList: ChatListViewModel?) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        connection = LiveConnection(name: "LinkedIn realtime", outcome: Self.outcome(for:)) { [weak self] connection in
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

    /// A signed-out session won't come back by retrying.
    private static func outcome(for error: Error) -> LiveOutcome {
        if case SourceError.notConfigured = error { return .stop }
        return .retry
    }

    private struct Silent: LocalizedError {
        var errorDescription: String? {
            "LinkedIn's realtime stream went quiet."
        }
    }

    /// One connection: read events until the stream ends or goes quiet.
    private func follow(_ connection: LiveConnection<LinkedInLiveEvent>) async throws {
        let bytes = try await client.realtimeStream(sessionId: UUID().uuidString.lowercased())
        let dataTask = bytes.task
        lastActivity = .now
        wentQuiet = false
        // Ends the stream when it goes quiet; reading then fails and the connection closes.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - lastActivity > Self.silenceLimit {
                    wentQuiet = true
                    dataTask.cancel()
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            dataTask.cancel()
        }
        do {
            try await withTaskCancellationHandler {
                for try await line in bytes.lines {
                    lastActivity = .now
                    handle(line: line, connection: connection)
                }
            } onCancel: {
                dataTask.cancel()
            }
        } catch where wentQuiet {
            throw Silent()
        }
        if wentQuiet { throw Silent() }
    }

    private func handle(line: String, connection: LiveConnection<LinkedInLiveEvent>) {
        guard line.hasPrefix("data:") else { return }
        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        switch Self.parse(payload) {
        case .opened:
            connection.opened()
        case let .event(event):
            connection.deliver(event)
        case nil:
            break
        }
    }

    enum Parsed {
        /// `ClientConnection`, which the stream sends first.
        case opened
        case event(LinkedInLiveEvent)
    }

    /// One `data:` line's JSON. Heartbeats, badge updates and topics chats don't follow parse to `nil`.
    static func parse(_ data: Data) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["com.linkedin.realtimefrontend.ClientConnection"] != nil { return .opened }
        guard let decorated = object["com.linkedin.realtimefrontend.DecoratedEvent"] as? [String: Any],
              let topic = (decorated["topic"] as? String).map(topicName(_:)),
              let fields = (decorated["payload"] as? [String: Any])?["data"] as? [String: Any],
              let result = fields.values.lazy.compactMap({ ($0 as? [String: Any])?["result"] }).first,
              let resultData = try? JSONSerialization.data(withJSONObject: result)
        else { return nil }
        let decoder = JSONDecoder()
        switch topic {
        case "messagesTopic", "messagesBroadcastTopic":
            guard let message = try? decoder.decode(LinkedInMessage.self, from: resultData),
                  let conversation = try? decoder.decode(ConversationRef.self, from: resultData).conversation.entityUrn
            else { return nil }
            return .event(.message(conversationUrn: conversation, message))
        case "messageReactionSummariesTopic", "messageReactionSummariesBroadcastTopic":
            guard let reaction = try? decoder.decode(ReactionEvent.self, from: resultData) else { return nil }
            return .event(.reaction(messageUrn: reaction.message.entityUrn, reaction.reactionSummary))
        case "conversationsTopic", "conversationsBroadcastTopic":
            return (try? decoder.decode(LinkedInConversation.self, from: resultData)).map { .event(.conversation($0)) }
        case "typingIndicatorsTopic", "typingIndicatorsBroadcastTopic":
            guard let typing = try? decoder.decode(TypingEvent.self, from: resultData) else { return nil }
            return .event(.typing(conversationUrn: typing.conversation.entityUrn, typing.typingParticipant))
        default:
            return nil
        }
    }

    /// `urn:li-realtime:messagesTopic:urn:li-realtime:myself` → `messagesTopic`.
    static func topicName(_ urn: String) -> String {
        let parts = urn.split(separator: ":")
        return parts.count > 2 ? String(parts[2]) : urn
    }

    private struct Ref: Decodable {
        let entityUrn: String
    }

    private struct ConversationRef: Decodable {
        let conversation: Ref
    }

    /// `doDecorateRealtimeReactionSummaryMessengerRealtimeDecoration` (observed 2026-11-09).
    private struct ReactionEvent: Decodable {
        let message: Ref
        let reactionSummary: LinkedInMessage.ReactionSummary
    }

    /// `doDecorateTypingIndicatorMessengerRealtimeDecoration`, as the web bundle reads it (not observed: only
    /// others' typing is sent).
    private struct TypingEvent: Decodable {
        let conversation: Ref
        let typingParticipant: LinkedInParticipant
    }

    // MARK: Chats list

    private func updateChatList(_ update: LiveUpdate<LinkedInLiveEvent>) {
        guard let chatList else { return }
        switch update {
        case let .event(.conversation(conversation)):
            Task {
                guard let viewer = try? await client.me().profileUrn else { return }
                chatList.updateChats([LinkedInClient.chatSummary(conversation, viewerUrn: viewer)], accountId: accountId)
            }
        case let .event(.message(conversationUrn, _)):
            pendingRows.insert(conversationUrn)
            scheduleRowRefresh()
        case .catchUp:
            Task { await chatList.load() }
        case .event:
            break
        }
    }

    /// A message event doesn't carry the row's unread count, so the conversation is read again.
    private func scheduleRowRefresh() {
        rowRefresh?.cancel()
        rowRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, let chatList else { return }
            let urns = pendingRows
            pendingRows = []
            guard let viewer = try? await client.me().profileUrn else { return }
            var rows: [ChatSummary] = []
            for urn in urns {
                do {
                    try await rows.append(LinkedInClient.chatSummary(client.conversation(urn: urn), viewerUrn: viewer))
                } catch {
                    logger.info("LinkedIn row refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !rows.isEmpty {
                chatList.updateChats(rows, accountId: accountId)
            }
        }
    }
}
