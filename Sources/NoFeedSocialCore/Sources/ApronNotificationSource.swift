import Foundation
import OSLog

/// Lists the joined rooms of every saved Apron server for the Chats screen, each with its latest message and
/// unread count, and reports whether any server is configured.
@MainActor
public final class ApronNotificationSource: ChatListProvider {
    public let network: SocialNetwork = .apron

    private let service: ApronService
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "Apron")
    /// Enough to count unread messages up to "50+" without paging further.
    private let historyLimit = 50
    public static let unreadCap = 50
    /// Whether a server's live connection keeps its rows current (`ApronLiveFeed`), so a reload keeps them
    /// instead of reading each room's history again: servers allow few history pages a day (the public demo,
    /// 1,000 per user across all their devices).
    var keepsRowsCurrent: (URL) -> Bool = { _ in false }

    public init(service: ApronService) {
        self.service = service
    }

    /// Every joined room on every server with its latest message, for the Chats list. Unlike the feed, rooms
    /// stay listed however old their latest message is. Each server is its own account, and one that fails
    /// doesn't fail the rest.
    public func chatList() async throws -> ChatListPage {
        let servers = service.servers
        guard !servers.isEmpty else { throw SourceError.notConfigured }
        var summaries: [ChatSummary] = []
        var accounts: [ChatListPage.AccountResult] = []
        for server in servers {
            let accountId = Account.apronId(serverURL: server.serverURL)
            let label = "\(network.displayName) \(server.displayTitle)"
            if keepsRowsCurrent(server.serverURL) {
                accounts.append(.init(accountId: accountId, label: label, error: nil, isCurrent: true))
                continue
            }
            do {
                // The shared connection stays open for live updates and chat; it isn't closed here.
                let session = try await service.session(serverURL: server.serverURL)
                try await summaries.append(contentsOf: chatSummariesTrackingCursors(in: session))
                accounts.append(.init(accountId: accountId, label: label, error: nil))
            } catch {
                logger.error("Apron chat list failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                accounts.append(.init(accountId: accountId, label: label, error: error))
            }
        }
        return ChatListPage(chats: summaries, archived: [], accounts: accounts)
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

    /// One server's rooms, or only `roomIds` among them, such as the rooms a new message arrived in; the live
    /// connection calls this on its open session.
    public func chatSummaries(in session: ApronSession, roomIds: Set<String>? = nil) async throws -> [ChatSummary] {
        // Without `history` the latest message can't be read on a short-lived connection.
        guard session.server.has("history") else { return [] }
        let rooms: [ApronRoom]
        var users: [String: ApronUser] = [:]
        var firstPage: ApronHistoryResult?
        if session.server.has("rooms") {
            let listing = try await session.connection.joinedRooms()
            rooms = listing.rooms
            users = Dictionary(listing.users.map { ($0.userId, $0) }, uniquingKeysWith: { _, last in last })
        } else {
            // A server without `rooms` may have only its default room; learn it from the messages (§3.4).
            let page = try await session.connection.history(roomId: nil, limit: historyLimit)
            guard let roomId = latestMessage(in: page)?.roomId else { return [] }
            rooms = [page.rooms?.first { $0.roomId == roomId } ?? ApronRoom(roomId: roomId)]
            firstPage = page
        }
        let own = service.readStore.ownUserIds(serverURL: session.serverURL).union([session.you.userId])
        let serverTitle = session.serverTitle
        let serverAvatarURL = (session.connection.server ?? session.server).avatarURL
        var summaries: [ChatSummary] = []
        for room in rooms where roomIds?.contains(room.roomId) ?? true {
            let page = if let firstPage { firstPage } else { try await session.connection.history(roomId: room.roomId, limit: historyLimit) }
            let latest = latestMessage(in: page)
            let preview = latest.map { preview(of: $0, isOwn: own.contains($0.from.userId)) }
            let unread = latest.flatMap { message in
                message.messageId.flatMap(Int64.init).map { unreadCount(in: page, roomId: room.roomId, latest: $0, session: session) }
            } ?? 0
            // A DM shows the other person's avatar, as apron-web does; rooms have none of their own (§4.2), so
            // they show the server's (§3.1).
            let others = room.isNamedForMembers ? room.otherMembers(you: session.you.userId) : []
            let avatarURL = others.count == 1 ? (users[others[0].userId] ?? others[0]).avatarURL : serverAvatarURL
            summaries.append(ChatSummary(
                id: Self.chatId(serverURL: session.serverURL, roomId: room.roomId),
                network: .apron,
                title: room.displayTitle(users: users, you: session.you.userId),
                titlePrefix: serverTitle,
                avatarURL: avatarURL,
                avatarColorKey: others.count == 1 ? others[0].userId : nil,
                preview: preview,
                timestamp: latest?.timestamp,
                unreadCount: unread,
                unseenReactionCount: unseenReactionCount(in: page, roomId: room.roomId, ownUserIds: own, serverURL: session.serverURL),
                destination: .apron(serverURL: session.serverURL, roomId: room.roomId),
                titleNamesPeople: room.isNamedForMembers,
                // A room set to None is muted on the server (§4.5.3).
                isMuted: session.connection.mutedRooms.contains(room.roomId),
            ).scoped(to: Account.apronId(serverURL: session.serverURL)))
        }
        return summaries
    }

    /// The room's row with a new message a live connection delivered, built from the message alone so a
    /// delivery costs no history page. `nil` for an edit, deletion or move (a later `log_id` than its
    /// `message_id`, §4.3.1), which the caller rebuilds from history.
    public func summary(_ row: ChatSummary, adding message: ApronMessage, session: ApronSession) -> ChatSummary? {
        guard let messageId = message.messageId, let id = Int64(messageId), let roomId = message.roomId,
              message.logId == nil || message.logId == messageId, !message.isDeleted
        else { return nil }
        var row = row
        let isOwn = service.readStore.ownUserIds(serverURL: session.serverURL).union([session.you.userId]).contains(message.from.userId)
        if !(message.body?.text ?? "").isEmpty {
            row.preview = preview(of: message, isOwn: isOwn)
            row.timestamp = message.timestamp ?? row.timestamp
        }
        if isOwn {
            // Later reactions to it are the user's to see.
            service.reactionStore.addOwnMessageIds([messageId], serverURL: session.serverURL, roomId: roomId)
        } else if !message.from.isSystem, let cursor = service.readStore.cursor(serverURL: session.serverURL, roomId: roomId), id > cursor {
            row.unreadCount = min(row.unreadCount + 1, Self.unreadCap)
        }
        return row
    }

    private func preview(of message: ApronMessage, isOwn: Bool) -> String {
        let text = (message.body?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return isOwn ? "You: \(text)" : "\(message.from.displayName): \(text)"
    }

    /// A room's Chats row id, before it is scoped to its server's account.
    private static func chatId(serverURL: URL, roomId: String) -> String {
        "apron:\(serverURL.absoluteString)|\(roomId)"
    }

    private func latestMessage(in page: ApronHistoryResult) -> ApronMessage? {
        (page.messages ?? [])
            .filter { $0.messageId != nil && !$0.isDeleted && !($0.body?.text ?? "").isEmpty }
            .max { $0.sortKey < $1.sortKey }
    }

    /// The user's messages with unseen reactions from others among the page's reaction records, which can be on
    /// messages older than the page; the store knows which of those are the user's (`ApronReactionStore`).
    private func unseenReactionCount(in page: ApronHistoryResult, roomId: String, ownUserIds: Set<String>, serverURL: URL) -> Int {
        let store = service.reactionStore
        if let last = page.lastLogId.flatMap(Int64.init) {
            store.setBaselineIfNeeded(last, serverURL: serverURL, roomId: roomId)
        }
        let ownInPage = (page.messages ?? []).filter { ownUserIds.contains($0.from.userId) }.compactMap(\.messageId)
        store.addOwnMessageIds(ownInPage, serverURL: serverURL, roomId: roomId)
        let ownMessages = store.ownMessageIds(serverURL: serverURL, roomId: roomId)
        // Each user's latest set per message, as the chat keeps them (§4.7).
        var entries: [String: [String: (logId: Int64, emojis: [String])]] = [:]
        for record in page.reactions ?? [] where record.roomId == nil || record.roomId == roomId {
            let logId = record.logId.flatMap(Int64.init) ?? 0
            for set in record.reactions where (entries[record.messageId]?[set.from.userId]?.logId ?? .min) <= logId {
                entries[record.messageId, default: [:]][set.from.userId] = (logId, set.emojis)
            }
        }
        return store.unseenMessageIds(
            in: entries,
            isOwnMessage: ownMessages.contains,
            isOwnUser: ownUserIds.contains,
            serverURL: serverURL,
            roomId: roomId,
        ).count
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

public extension ChatSummary {
    /// Whether the row is one of the server's rooms, which its live connection rebuilds together.
    func isApronRoom(on serverURL: URL) -> Bool {
        guard case let .apron(chatServerURL, _) = destination else { return false }
        return chatServerURL == serverURL
    }
}

extension ApronNotificationSource: ChatListResolving {
    /// A room the list doesn't have yet is titled by its id, and a direct chat with no room yet by the other
    /// person, until the list loads them.
    public func chat(for destination: ChatSummary.Destination, in _: [ChatSummary]) -> ChatSummary? {
        switch destination {
        case let .apron(serverURL, roomId):
            ChatSummary(
                id: Self.chatId(serverURL: serverURL, roomId: roomId),
                network: .apron,
                title: roomId,
                titlePrefix: serverURL.host() ?? serverURL.absoluteString,
                avatarURL: service.server(for: serverURL)?.avatarURL,
                preview: nil,
                timestamp: nil,
                unreadCount: 0,
                destination: destination,
            ).scoped(to: Account.apronId(serverURL: serverURL))
        case let .apronDirect(serverURL, user):
            ChatSummary(
                id: Self.chatId(serverURL: serverURL, roomId: "direct:\(user.userId)"),
                network: .apron,
                title: user.displayName,
                titlePrefix: serverURL.host() ?? serverURL.absoluteString,
                avatarURL: user.avatarURL,
                preview: nil,
                timestamp: nil,
                unreadCount: 0,
                destination: destination,
            ).scoped(to: Account.apronId(serverURL: serverURL))
        default:
            nil
        }
    }
}
