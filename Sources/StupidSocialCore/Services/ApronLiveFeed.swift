import Foundation
import OSLog

/// Keeps one WebSocket open to each saved Apron server while the app is in the foreground, so the Chats list
/// (latest message, unread count) updates in realtime instead of on the next reload.
///
/// A new message updates its room's row from the message itself; edits, reactions and room changes rebuild
/// rows from history on the already-open connection, debounced so a burst costs one rebuild. Servers allow few
/// history pages a day, so once a connection's rows are built, Chats reloads keep them instead of reading every
/// room again. Read cursors the server sends for the user update unread badges directly. Each server's
/// connection runs on `LiveConnection`, which reconnects dropped ones with backoff; a `denied` sign-in stops
/// until the user acts (§1.1).
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
    private var connections: [URL: LiveConnection<Never>] = [:]
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
        NotificationCenter.default.addObserver(forName: ApronReactionStore.remoteDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["serverURL"] as? URL, let roomId = note.userInfo?["roomId"] as? String else { return }
            MainActor.assumeIsolated { self?.reactionsSeenElsewhere(serverURL: url, roomId: roomId) }
        }
    }

    /// Reactions seen on another device can only clear the row's unseen ones, and only history says which remain.
    private func reactionsSeenElsewhere(serverURL: URL, roomId: String) {
        let destination = ChatDestination.apron(serverURL: serverURL, roomId: roomId)
        guard sessions[serverURL] != nil, chatList.chats.first(where: { $0.destination == destination })?.unseenReactionCount ?? 0 > 0 else { return }
        scheduleRebuild(serverURL, roomId: roomId)
    }

    public func start() {
        guard !isRunning, !DemoData.isDemoMode else { return }
        isRunning = true
        sync()
    }

    public func stop() {
        isRunning = false
        for url in Array(connections.keys) {
            disconnect(url)
        }
    }

    /// Connects to newly added servers and drops removed ones.
    public func sync() {
        guard isRunning else { return }
        let saved = Set(service.servers.map(\.serverURL))
        for url in connections.keys where !saved.contains(url) {
            disconnect(url)
            // Removed here or on another device.
            chatList.replaceChats(where: { $0.isApronRoom(on: url) }, with: [])
        }
        for url in saved where connections[url] == nil {
            let connection = makeConnection(url)
            connections[url] = connection
            connection.start()
        }
    }

    private func disconnect(_ url: URL) {
        connections.removeValue(forKey: url)?.stop()
        rebuilds.removeValue(forKey: url)?.cancel()
        pendingRooms[url] = nil
        currentServers.remove(url)
        sessions[url] = nil
        // In the background the shared connection closes too; chat reopens it on demand.
        service.closeSessions(for: url)
    }

    /// One server's connection on `LiveConnection`: exponential backoff with jitter (1 s doubling to 60 s, ±50%),
    /// reset only by a connection that stayed up a while, and never sooner than the server asked (docs/limits.md,
    /// Checklist).
    private func makeConnection(_ url: URL) -> LiveConnection<Never> {
        LiveConnection(
            name: "Apron \(url.host() ?? "server")\(url.port.map { ":\($0)" } ?? "")",
            retry: LiveRetryPolicy(stableAfter: stableConnection),
            canConnect: { [weak self] in self.map { $0.isRunning && $0.service.server(for: url) != nil } ?? false },
            outcome: { [weak self] error in self?.outcome(for: error, serverURL: url) ?? .stop },
        ) { [weak self] connection in
            try await self?.follow(url, connection: connection)
        }
    }

    /// A denied sign-in, or one the server ended, stops until the user acts (§1.1).
    private func outcome(for error: Error, serverURL url: URL) -> LiveOutcome {
        guard let apronError = error as? ApronError else { return .retry }
        if apronError.isDenied {
            logger.info("Apron live feed stopped for \(url.host() ?? "server", privacy: .public): sign-in denied")
            return .stop
        }
        if apronError.endsSignIn {
            logger.info("Apron live feed stopped for \(url.host() ?? "server", privacy: .public): signed out by the server")
            service.signInEnded(serverURL: url)
            return .stop
        }
        return .retry(minimum: apronError.reconnectDelay ?? .zero)
    }

    /// Catches up on anything that arrived while disconnected, then follows live deliveries until the shared
    /// connection closes.
    private func follow(_ url: URL, connection: LiveConnection<Never>) async throws {
        let session = try await service.session(serverURL: url)
        guard isRunning, !Task.isCancelled else { return }
        sessions[url] = session
        defer {
            sessions[url] = nil
            currentServers.remove(url)
        }
        let closing: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            guard session.connection.isOpen else {
                continuation.resume(returning: nil)
                return
            }
            connection.opened()
            session.connection.observe(
                notifications: { [weak self] method, params in self?.handle(method: method, params: params, session: session) },
                onClose: { continuation.resume(returning: $0) },
            )
            scheduleRebuild(url, immediately: true)
        }
        if let closing { throw closing }
    }

    private func handle(method: String, params: Data, session: ApronSession) {
        switch method {
        case "message":
            // Only logged messages change a room's latest message; transient notices don't (§3.5.3).
            guard let message = try? JSONDecoder().decode(ApronMessage.self, from: params), let roomId = message.roomId, message.messageId != nil else { return }
            let destination = ChatDestination.apron(serverURL: session.serverURL, roomId: roomId)
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
            let destination = ChatDestination.apron(serverURL: session.serverURL, roomId: roomId)
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
