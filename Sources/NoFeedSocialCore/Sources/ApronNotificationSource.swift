import Foundation
import OSLog

/// Lists the joined rooms of every saved Apron server for the Chats screen, each with its latest message and
/// unread count, and reports whether any server is configured.
@MainActor
public final class ApronNotificationSource: AccountValidating {
    public let network: SocialNetwork = .apron

    private let service: ApronService
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "Apron")
    /// Enough to count unread messages up to "50+" without paging further.
    private let historyLimit = 50
    public static let unreadCap = 50

    public init(service: ApronService) {
        self.service = service
    }

    public func validateAccount() async throws -> AccountStatus {
        service.servers.isEmpty ? .notConfigured : .valid
    }

    /// Every joined room on every server with its latest message, for the Chats list. Unlike the feed, rooms
    /// stay listed however old their latest message is.
    public func chatSummaries() async throws -> [ChatSummary] {
        let servers = service.servers
        guard !servers.isEmpty else { throw SourceError.notConfigured }
        var summaries: [ChatSummary] = []
        var firstError: Error?
        var succeeded = false
        for server in servers {
            do {
                // The shared connection stays open for live updates and chat; it isn't closed here.
                let session = try await service.session(serverURL: server.serverURL)
                try await summaries.append(contentsOf: chatSummariesTrackingCursors(in: session))
                succeeded = true
            } catch {
                logger.error("Apron chat list failed for \(server.serverURL.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }
        if !succeeded, let firstError {
            throw firstError
        }
        return summaries
    }

    /// On a short-lived read, also stores the read cursors the server sends after `room_list` (§4.6); they
    /// arrive before later results, so the unread counts use them.
    private func chatSummariesTrackingCursors(in session: ApronSession) async throws -> [ChatSummary] {
        var token: UUID?
        if service.serverTracksCursors(session) {
            let readStore = service.readStore
            let you = session.you.userId
            let serverURL = session.serverURL
            token = session.connection.observe(notifications: { method, params in
                guard method == "activity",
                      let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
                      activity.from?.userId == you,
                      let roomId = activity.roomId,
                      let cursor = activity.readMessageId.flatMap(Int64.init)
                else { return }
                readStore.setServerCursor(cursor, serverURL: serverURL, roomId: roomId)
            })
        }
        defer { token.map(session.connection.removeObserver) }
        return try await chatSummaries(in: session)
    }

    /// One server's rooms; the live connection calls this on its open session when rooms change.
    public func chatSummaries(in session: ApronSession) async throws -> [ChatSummary] {
        // Without `history` the latest message can't be read on a short-lived connection.
        guard session.server.has("history") else { return [] }
        let rooms: [ApronRoom]
        var firstPage: ApronHistoryResult?
        if session.server.has("rooms") {
            rooms = try await session.connection.joinedRooms(members: false).rooms
        } else {
            // A server without `rooms` may have only its default room; learn it from the messages (§3.4).
            let page = try await session.connection.history(roomId: nil, limit: historyLimit)
            guard let roomId = latestMessage(in: page)?.roomId else { return [] }
            rooms = [page.rooms?.first { $0.roomId == roomId } ?? ApronRoom(roomId: roomId)]
            firstPage = page
        }
        let own = service.readStore.ownUserIds(serverURL: session.serverURL).union([session.you.userId])
        let host = session.serverURL.host() ?? session.serverURL.absoluteString
        var summaries: [ChatSummary] = []
        for room in rooms {
            let page = if let firstPage { firstPage } else { try await session.connection.history(roomId: room.roomId, limit: historyLimit) }
            let latest = latestMessage(in: page)
            let preview = latest.map { message in
                let text = (message.body?.text ?? "").replacingOccurrences(of: "\n", with: " ")
                return own.contains(message.from.userId) ? "You: \(text)" : "\(message.from.displayName): \(text)"
            }
            let unread = latest.flatMap { message in
                message.messageId.flatMap(Int64.init).map { unreadCount(in: page, roomId: room.roomId, latest: $0, session: session) }
            } ?? 0
            summaries.append(ChatSummary(
                id: "apron:\(session.serverURL.absoluteString)|\(room.roomId)",
                network: .apron,
                title: room.displayTitle,
                subtitle: host,
                avatarURL: nil,
                preview: preview,
                timestamp: latest?.timestamp,
                unreadCount: unread,
                destination: .apron(serverURL: session.serverURL, roomId: room.roomId),
            ))
        }
        return summaries
    }

    private func latestMessage(in page: ApronHistoryResult) -> ApronMessage? {
        (page.messages ?? [])
            .filter { $0.messageId != nil && !$0.isDeleted && !($0.body?.text ?? "").isEmpty }
            .max { $0.sortKey < $1.sortKey }
    }

    /// Messages from others after the read cursor, capped at the page size (§4.6).
    private func unreadCount(in page: ApronHistoryResult, roomId: String, latest: Int64, session: ApronSession) -> Int {
        let readStore = service.readStore
        // A room never read before starts at its latest message, so adding a server doesn't mark everything unread.
        let newest = (page.messages ?? []).compactMap { $0.messageId.flatMap(Int64.init) }.max() ?? latest
        readStore.setBaselineIfNeeded(newest, serverURL: session.serverURL, roomId: roomId)
        let cursor = readStore.cursor(serverURL: session.serverURL, roomId: roomId) ?? latest
        let own = readStore.ownUserIds(serverURL: session.serverURL)
        let unread = (page.messages ?? []).filter { message in
            guard let id = message.messageId.flatMap(Int64.init), id > cursor else { return false }
            return !message.isDeleted && !message.from.isSystem && !own.contains(message.from.userId)
        }
        return min(unread.count, Self.unreadCap)
    }
}
