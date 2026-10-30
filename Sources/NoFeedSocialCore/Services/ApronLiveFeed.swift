import Foundation
import OSLog

/// Keeps one WebSocket open to each saved Apron server while the app is in the foreground, so the Chats list
/// (latest message, unread count) updates in realtime instead of on the next reload.
///
/// A new message updates its room's row from the message itself; edits, reactions and room changes rebuild
/// rows from history on the already-open connection, debounced so a burst costs one rebuild. Servers allow few
/// history pages a day, so once a connection's rows are built, Chats reloads keep them instead of reading every
/// room again. Read cursors the server sends for the user update unread badges directly. Dropped connections
/// reconnect with backoff; a `denied` sign-in stops until the user acts (§1.1).
@MainActor
public final class ApronLiveFeed {
    /// Posted by settings after a server is added or removed.
    public static let serversDidChangeNotification = Notification.Name("ApronLiveFeed.serversDidChange")

    private let service: ApronService
    private let source: ApronNotificationSource
    private let chatList: ChatListViewModel
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "ApronLiveFeed")
    private let rebuildDelay: Duration = .milliseconds(800)
    /// How long a connection must stay up before a drop counts as the first failure again.
    private let stableConnection: Duration = .seconds(120)

    private var isRunning = false
    private var loops: [URL: Task<Void, Never>] = [:]
    private var sessions: [URL: ApronSession] = [:]
    private var rebuilds: [URL: Task<Void, Never>] = [:]
    /// Rooms with new messages since the last rebuild; `nil` rebuilds every room, as after `room_update`.
    private var pendingRooms: [URL: Set<String>?] = [:]
    /// Servers whose rows were built on the open connection, which keeps them current until it closes.
    private var currentServers: Set<URL> = []

    public init(service: ApronService, source: ApronNotificationSource, chatList: ChatListViewModel) {
        self.service = service
        self.source = source
        self.chatList = chatList
        source.keepsRowsCurrent = { [weak self] url in self?.currentServers.contains(url) ?? false }
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
        currentServers.remove(url)
        sessions[url] = nil
        // In the background the shared connection closes too; chat reopens it on demand.
        service.closeSessions(for: url)
    }

    /// Reconnects with exponential backoff and jitter (1 s doubling to 60 s, ±50%), reset only by a connection that
    /// stayed up a while, and never sooner than the server asked (docs/limits.md, Checklist).
    private func run(_ url: URL) async {
        var failures = 0
        while isRunning, !Task.isCancelled, service.server(for: url) != nil {
            var error: Error?
            do {
                let session = try await service.session(serverURL: url)
                guard isRunning, !Task.isCancelled else { return }
                sessions[url] = session
                let connectedAt = ContinuousClock.now
                // Catch up on anything that arrived while disconnected, then follow live deliveries until
                // the shared connection closes.
                error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
                    guard session.connection.isOpen else {
                        continuation.resume(returning: nil)
                        return
                    }
                    session.connection.observe(
                        notifications: { [weak self] method, params in self?.handle(method: method, params: params, session: session) },
                        onClose: { continuation.resume(returning: $0) },
                    )
                    scheduleRebuild(url, immediately: true)
                }
                sessions[url] = nil
                currentServers.remove(url)
                if ContinuousClock.now - connectedAt >= stableConnection {
                    failures = 0
                }
            } catch let caught as ApronError where caught.isDenied {
                logger.info("Apron live feed stopped for \(url.host() ?? "server", privacy: .public): sign-in denied")
                return
            } catch let caught {
                error = caught
            }
            guard isRunning, !Task.isCancelled else { return }
            if let apronError = error as? ApronError, apronError.endsSignIn {
                logger.info("Apron live feed stopped for \(url.host() ?? "server", privacy: .public): signed out by the server")
                service.signInEnded(serverURL: url)
                return
            }
            if let error {
                logger.info("Apron live feed disconnected from \(url.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            let backoff = min(pow(2, Double(failures)), 60) * Double.random(in: 0.5 ... 1.5)
            try? await Task.sleep(for: max(.seconds(backoff), (error as? ApronError)?.reconnectDelay ?? .zero))
            failures += 1
        }
    }

    private func handle(method: String, params: Data, session: ApronSession) {
        switch method {
        case "message":
            // Only logged messages change a room's latest message; transient notices don't (§3.5.3).
            guard let message = try? JSONDecoder().decode(ApronMessage.self, from: params), let roomId = message.roomId, message.messageId != nil else { return }
            let destination = ChatSummary.Destination.apron(serverURL: session.serverURL, roomId: roomId)
            // Before the rows are built, the rebuild under way may predate the message.
            if currentServers.contains(session.serverURL),
               let row = chatList.chats.first(where: { $0.destination == destination }),
               let updated = source.summary(row, adding: message, session: session)
            {
                chatList.updateChats([updated])
            } else {
                // Only that room changed; rebuilding just it keeps within the server's frame budget.
                scheduleRebuild(session.serverURL, roomId: roomId)
            }
        case "reactions":
            // A reaction to the user's message changes the room's unseen reactions.
            guard let record = try? JSONDecoder().decode(ApronReactionRecord.self, from: params) else { return }
            scheduleRebuild(session.serverURL, roomId: record.roomId)
        case "room_update":
            // A room renamed or someone joining or leaving changes only those rooms' rows; rebuilding every
            // room would read a history page for each.
            guard let changed = (try? JSONDecoder().decode(ApronRoomUpdate.self, from: params))?.changedRoomIds else {
                scheduleRebuild(session.serverURL)
                return
            }
            for roomId in changed {
                scheduleRebuild(session.serverURL, roomId: roomId)
            }
            if !changed.isEmpty, session.server.has("rooms") {
                Task { try? await service.push.updateRoomTitles(session: session, rooms: session.connection.joinedRooms()) }
            }
        case "activity":
            guard service.serverTracksCursors(session),
                  let activity = try? JSONDecoder().decode(ApronActivity.self, from: params),
                  activity.from?.userId == session.you.userId,
                  let roomId = activity.roomId,
                  let cursor = activity.readMessageId.flatMap(Int64.init)
            else { return }
            service.readStore.setServerCursor(cursor, serverURL: session.serverURL, roomId: roomId)
            // Read on another device: only history says what is still unread. Read here, the open chat already
            // cleared the row.
            let destination = ChatSummary.Destination.apron(serverURL: session.serverURL, roomId: roomId)
            if chatList.chats.first(where: { $0.destination == destination })?.unreadCount ?? 0 > 0 {
                scheduleRebuild(session.serverURL, roomId: roomId)
            }
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
                    // Only while that connection is still open.
                    if sessions[url] != nil {
                        currentServers.insert(url)
                    }
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
