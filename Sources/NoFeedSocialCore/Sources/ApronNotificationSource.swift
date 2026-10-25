import Foundation
import OSLog

/// Surfaces each joined room's latest message from every saved Apron server as one feed item.
/// Items keep the server URL in `accountId`, the room in `target.id`, and the room title in `parentTarget`.
@MainActor
public final class ApronNotificationSource: NotificationFetching, AccountValidating {
    public let network: SocialNetwork = .apron

    private let service: ApronService
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "Apron")
    /// Enough to count unread messages up to "50+" without paging further.
    private let historyLimit = 50
    public static let unreadCap = 50
    private let maxAge: TimeInterval = 86400

    public init(service: ApronService) {
        self.service = service
    }

    public func validateAccount() async throws -> AccountStatus {
        service.servers.isEmpty ? .notConfigured : .valid
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        let servers = service.servers
        guard !servers.isEmpty else { throw SourceError.notConfigured }

        var items: [NotificationItem] = []
        var firstError: Error?
        var succeeded = false
        for server in servers {
            do {
                try await items.append(contentsOf: fetchRooms(serverURL: server.serverURL))
                succeeded = true
            } catch {
                logger.error("Apron refresh failed for \(server.serverURL.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }
        if !succeeded, let firstError {
            throw firstError
        }
        return items
    }

    private func fetchRooms(serverURL: URL) async throws -> [NotificationItem] {
        let session = try await service.open(serverURL: serverURL)
        defer { session.connection.close() }
        let tracksCursors = service.serverTracksCursors(session)
        if tracksCursors {
            // The server sends the cursors it keeps after `room_list` (§4.6); they arrive before later results.
            let readStore = service.readStore
            let you = session.you.userId
            session.connection.onNotification = { method, params in
                guard method == "activity",
                      let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
                      activity.from?.userId == you,
                      let roomId = activity.roomId,
                      let cursor = activity.readMessageId.flatMap(Int64.init)
                else { return }
                readStore.setServerCursor(cursor, serverURL: serverURL, roomId: roomId)
            }
        }
        return try await items(in: session)
    }

    /// Builds the feed items for a signed-in session; the live feed calls this on its open connection.
    public func items(in session: ApronSession) async throws -> [NotificationItem] {
        // Without `history` the latest message can't be read on a short-lived connection.
        guard session.server.has("history") else { return [] }

        guard session.server.has("rooms") else {
            // A server without `rooms` may have only its default room; learn it from the messages (§3.4).
            let page = try await session.connection.history(roomId: nil, limit: historyLimit)
            guard let latest = latestMessage(in: page), let roomId = latest.roomId else { return [] }
            let room = page.rooms?.first { $0.roomId == roomId } ?? ApronRoom(roomId: roomId)
            return item(for: latest, room: room, page: page, session: session, users: [:]).map { [$0] } ?? []
        }

        var items: [NotificationItem] = []
        let joined = try await session.connection.joinedRooms(members: true)
        // A message's `from` is a recorded object that may omit the avatar; prefer the member's current object (§3.3.1).
        let users = Dictionary(joined.users.map { ($0.userId, $0) }, uniquingKeysWith: { _, latest in latest })
        for room in joined.rooms {
            let page = try await session.connection.history(roomId: room.roomId, limit: historyLimit)
            if let latest = latestMessage(in: page), let item = item(for: latest, room: room, page: page, session: session, users: users) {
                items.append(item)
            }
        }
        return items
    }

    private func latestMessage(in page: ApronHistoryResult) -> ApronMessage? {
        (page.messages ?? [])
            .filter { $0.messageId != nil && !$0.isDeleted && !($0.body?.text ?? "").isEmpty }
            .max { $0.sortKey < $1.sortKey }
    }

    /// Messages from others after the read cursor, capped at the page size (§4.6).
    private func unreadCount(in page: ApronHistoryResult, roomId: String, latest: Int64, session: ApronSession) -> Int {
        let readStore = service.readStore
        // A room never read before starts at its latest message, so adding a server doesn't flood the feed.
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

    private func item(for message: ApronMessage, room: ApronRoom, page: ApronHistoryResult, session: ApronSession, users: [String: ApronUser]) -> NotificationItem? {
        guard let messageId = message.messageId, let latestId = Int64(messageId), let timestamp = message.timestamp,
              timestamp > Date().addingTimeInterval(-maxAge)
        else { return nil }
        let unread = unreadCount(in: page, roomId: room.roomId, latest: latestId, session: session)
        let author = users[message.from.userId]
        let actor = NotificationActor(
            id: message.from.userId,
            network: .apron,
            // Feed rows bold `username`; Apron has no profile handle beyond the opaque `user_id`.
            username: message.from.displayName,
            displayName: message.from.displayName,
            avatarURL: author?.avatarURL ?? message.from.avatarURL,
        )
        let mentioned = message.body?.mentions?.contains(session.you.userId) ?? false
        let verb = mentioned ? "mentioned you in" : "in"
        return NotificationItem(
            id: "apron:\(session.serverURL.absoluteString)|\(room.roomId)",
            network: .apron,
            accountId: session.serverURL.absoluteString,
            sourceId: messageId,
            type: .message,
            timestamp: timestamp,
            text: "\(message.from.displayName) \(verb) \(room.displayTitle)",
            actors: [actor],
            target: NotificationTarget(id: room.roomId, text: message.body?.text, url: nil, author: actor, postedAt: timestamp),
            parentTarget: NotificationTarget(id: room.roomId, text: room.displayTitle, url: session.serverURL),
            unreadCount: unread,
        )
    }
}
