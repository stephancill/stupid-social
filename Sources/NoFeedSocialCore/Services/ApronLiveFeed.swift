import Foundation
import OSLog

/// Keeps one WebSocket open to each saved Apron server while the app is in the foreground, so the Chats list
/// (latest message, unread count) updates in realtime instead of on the next reload.
///
/// New messages and room changes rebuild that server's rows on the already-open connection, debounced so
/// a burst of messages costs one rebuild. Read cursors the server sends for the user update unread badges
/// directly. Dropped connections reconnect with backoff; a `denied` sign-in stops until the user acts (§1.1).
@MainActor
public final class ApronLiveFeed {
    /// Posted by settings after a server is added or removed.
    public static let serversDidChangeNotification = Notification.Name("ApronLiveFeed.serversDidChange")

    private let service: ApronService
    private let source: ApronNotificationSource
    private let chatList: ChatListViewModel
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "ApronLiveFeed")
    private let rebuildDelay: Duration = .milliseconds(800)

    private var isRunning = false
    private var loops: [URL: Task<Void, Never>] = [:]
    private var sessions: [URL: ApronSession] = [:]
    private var rebuilds: [URL: Task<Void, Never>] = [:]
    /// Rooms with new messages since the last rebuild; `nil` rebuilds every room, as after `room_update`.
    private var pendingRooms: [URL: Set<String>?] = [:]

    public init(service: ApronService, source: ApronNotificationSource, chatList: ChatListViewModel) {
        self.service = service
        self.source = source
        self.chatList = chatList
        NotificationCenter.default.addObserver(forName: Self.serversDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    public func start() {
        guard !isRunning, !DemoData.isDemoMode else { return }
        isRunning = true
        sync()
    }

    public func stop() {
        isRunning = false
        for url in Array(loops.keys) {
            disconnect(url)
        }
    }

    /// Connects to newly added servers and drops removed ones.
    public func sync() {
        guard isRunning else { return }
        let saved = Set(service.servers.map(\.serverURL))
        for url in loops.keys where !saved.contains(url) {
            disconnect(url)
            // Removed here or on another device.
            chatList.replaceChats(where: { $0.isApronRoom(on: url) }, with: [])
        }
        for url in saved where loops[url] == nil {
            loops[url] = Task { [weak self] in await self?.run(url) }
        }
    }

    private func disconnect(_ url: URL) {
        loops.removeValue(forKey: url)?.cancel()
        rebuilds.removeValue(forKey: url)?.cancel()
        pendingRooms[url] = nil
        sessions[url] = nil
        // In the background the shared connection closes too; chat reopens it on demand.
        service.closeSessions(for: url)
    }

    private func run(_ url: URL) async {
        var delay: Duration = .seconds(1)
        while isRunning, !Task.isCancelled, service.server(for: url) != nil {
            do {
                let session = try await service.session(serverURL: url)
                guard isRunning, !Task.isCancelled else { return }
                sessions[url] = session
                delay = .seconds(1)
                // Catch up on anything that arrived while disconnected, then follow live deliveries until
                // the shared connection closes.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard session.connection.isOpen else {
                        continuation.resume()
                        return
                    }
                    session.connection.observe(
                        notifications: { [weak self] method, params in self?.handle(method: method, params: params, session: session) },
                        onClose: { _ in continuation.resume() },
                    )
                    scheduleRebuild(url, immediately: true)
                }
                sessions[url] = nil
            } catch let error as ApronError where error.isDenied {
                logger.info("Apron live feed stopped for \(url.host() ?? "server", privacy: .public): sign-in denied")
                return
            } catch {
                logger.info("Apron live feed connect failed for \(url.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            guard isRunning, !Task.isCancelled else { return }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

    private func handle(method: String, params: Data, session: ApronSession) {
        switch method {
        case "message":
            // Only logged messages change a room's latest message; transient notices don't (§3.5.3).
            guard let message = try? JSONDecoder().decode(ApronMessage.self, from: params), message.messageId != nil else { return }
            // Only that room changed; rebuilding just it keeps within the server's frame budget.
            scheduleRebuild(session.serverURL, roomId: message.roomId)
        case "reactions":
            // A reaction to the user's message changes the room's unseen reactions.
            guard let record = try? JSONDecoder().decode(ApronReactionRecord.self, from: params) else { return }
            scheduleRebuild(session.serverURL, roomId: record.roomId)
        case "room_update":
            scheduleRebuild(session.serverURL)
        case "activity":
            guard service.serverTracksCursors(session),
                  let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
                  activity.from?.userId == session.you.userId,
                  let roomId = activity.roomId,
                  let cursor = activity.readMessageId.flatMap(Int64.init)
            else { return }
            service.readStore.setServerCursor(cursor, serverURL: session.serverURL, roomId: roomId)
        default:
            break
        }
    }

    /// Without a `roomId`, rebuilds every room on the server.
    private func scheduleRebuild(_ url: URL, roomId: String? = nil, immediately: Bool = false) {
        let pending = pendingRooms[url] ?? Set<String>()
        pendingRooms[url] = if let roomId, let pending { pending.union([roomId]) } else { Set<String>?.none }
        rebuilds[url]?.cancel()
        let delay = immediately ? .zero : rebuildDelay
        rebuilds[url] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, let session = sessions[url] else { return }
            let roomIds = pendingRooms.removeValue(forKey: url) ?? nil
            do {
                if let roomIds {
                    try await chatList.updateChats(source.chatSummaries(in: session, roomIds: roomIds))
                } else {
                    try await chatList.replaceChats(where: { $0.isApronRoom(on: url) }, with: source.chatSummaries(in: session))
                    // Rooms changed: notifications title new rooms, such as a new DM, by name.
                    if session.server.has("rooms") {
                        try await service.push.updateRoomTitles(session: session, rooms: session.connection.joinedRooms())
                    }
                }
            } catch {
                logger.info("Apron live rebuild failed for \(url.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
