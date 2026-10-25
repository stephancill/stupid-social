import Foundation
import OSLog

/// Keeps one WebSocket open to each saved Apron server while the app is in the foreground, so feed items
/// (latest message, unread count) update in realtime instead of on the next refresh.
///
/// New messages and room changes rebuild that server's items on the already-open connection, debounced so
/// a burst of messages costs one rebuild. Read cursors the server sends for the user update unread badges
/// directly. Dropped connections reconnect with backoff; a `denied` sign-in stops until the user acts (§1.1).
@MainActor
public final class ApronLiveFeed {
    /// Posted after the cached Apron items changed; observers reload the feed from the cache.
    public static let didUpdateNotification = Notification.Name("ApronLiveFeed.didUpdate")
    /// Posted by settings after a server is added or removed.
    public static let serversDidChangeNotification = Notification.Name("ApronLiveFeed.serversDidChange")

    private let service: ApronService
    private let source: ApronNotificationSource
    private let cacheStore: NotificationCacheStore
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "ApronLiveFeed")
    private let rebuildDelay: Duration = .milliseconds(800)

    private var isRunning = false
    private var loops: [URL: Task<Void, Never>] = [:]
    private var sessions: [URL: ApronSession] = [:]
    private var rebuilds: [URL: Task<Void, Never>] = [:]

    public init(service: ApronService, source: ApronNotificationSource, cacheStore: NotificationCacheStore) {
        self.service = service
        self.source = source
        self.cacheStore = cacheStore
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
        }
        for url in saved where loops[url] == nil {
            loops[url] = Task { [weak self] in await self?.run(url) }
        }
    }

    private func disconnect(_ url: URL) {
        loops.removeValue(forKey: url)?.cancel()
        rebuilds.removeValue(forKey: url)?.cancel()
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
            scheduleRebuild(session.serverURL)
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

    private func scheduleRebuild(_ url: URL, immediately: Bool = false) {
        rebuilds[url]?.cancel()
        let delay = immediately ? .zero : rebuildDelay
        rebuilds[url] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, let session = sessions[url] else { return }
            do {
                let items = try await source.items(in: session)
                try cacheStore.replaceAccount(items, network: .apron, accountId: url.absoluteString)
                NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
            } catch {
                logger.info("Apron live rebuild failed for \(url.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
