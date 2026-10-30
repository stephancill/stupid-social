import Foundation

public enum ApronError: LocalizedError, Equatable {
    case invalidURL
    case rpc(code: Int, message: String)
    case timedOut
    case closed
    case noUsableAuthScheme([String])
    /// The server answered the WebSocket handshake with this HTTP status instead of upgrading, with its
    /// `Retry-After` seconds when the refusal is temporary.
    case rejected(status: Int, retryAfter: Int? = nil)
    /// A `retry_after` (-32002) refusal: wait `retryAfter` seconds. `category` is `ext.limits` (`read`, `write`
    /// or `upload`), the kind of request to hold back.
    case limited(message: String, retryAfter: Int, category: String?)
    /// The server closed the socket with this code and reason (docs/limits.md, Closed connections).
    case closedByServer(code: Int, reason: String)

    public static let deniedCode = -32001
    public static let retryAfterCode = -32002

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a ws:// or wss:// server URL."
        case let .rpc(_, message): message
        case .timedOut: "The Apron server did not respond."
        case .closed: "The connection to the Apron server closed."
        case let .noUsableAuthScheme(schemes): "This server needs a sign-in method the app does not support (\(schemes.joined(separator: ", ")))."
        case let .rejected(status, _) where status == 503 || status == 429:
            "The Apron server is too busy to accept connections right now (HTTP \(status)). Try again later."
        case let .rejected(status, _): "The Apron server refused the connection (HTTP \(status))."
        case let .limited(message, retryAfter, _): "\(message). Try again in \(retryAfter) seconds."
        case let .closedByServer(code, reason): reason.isEmpty ? "The Apron server closed the connection (\(code))." : reason
        }
    }

    public var isDenied: Bool {
        if case let .rpc(code, _) = self { return code == Self.deniedCode }
        return false
    }

    /// The least time to wait before connecting again, as the server asks: `Retry-After`, `retry_after`, or a
    /// close for a rate or capacity limit, where 1013 means minutes rather than seconds.
    public var reconnectDelay: Duration? {
        switch self {
        case let .rejected(_, retryAfter): retryAfter.map { .seconds($0) }
        case let .limited(_, retryAfter, _): .seconds(retryAfter)
        case let .closedByServer(code, _) where code == 1013: .seconds(300)
        case let .closedByServer(code, reason) where code == 1008 && !endsSignIn && reason != "Authentication timed out": .seconds(60)
        default: nil
        }
    }

    /// A 1008 close because the account changed (removed, token replaced, signed out): reconnecting with the same
    /// credentials only fails again, so the user has to act.
    public var endsSignIn: Bool {
        guard case let .closedByServer(1008, reason) = self else { return false }
        return ["Removed by an admin", "Device token replaced", "Bot token replaced", "Signed out"].contains { reason.hasPrefix($0) }
    }
}

/// One WebSocket connection to an Apron server. Requests are matched to replies by `id`;
/// every other frame is delivered to each observer as `(method, params JSON)`. One connection per server is
/// shared across the app (`ApronService.session(serverURL:)`), so several features observe it at once.
@MainActor
public final class ApronConnection {
    public private(set) var server: ApronServerInfo?
    private var notificationObservers: [UUID: (String, Data) -> Void] = [:]
    private var closeObservers: [UUID: (Error?) -> Void] = [:]

    /// Registers handlers for notifications and for the connection closing; remove them with the returned token.
    @discardableResult
    public func observe(notifications: @escaping (String, Data) -> Void, onClose: ((Error?) -> Void)? = nil) -> UUID {
        let token = UUID()
        notificationObservers[token] = notifications
        if let onClose {
            closeObservers[token] = onClose
        }
        return token
    }

    public func removeObserver(_ token: UUID) {
        notificationObservers[token] = nil
        closeObservers[token] = nil
    }

    /// The last joined-rooms listing, shared by everything on this connection (chat, Chats list, live
    /// updates) and dropped when a `room_update` changes rooms or memberships. Servers rate-limit `room_list`;
    /// the reference server allows 6 a minute per user, besides the first joined listing after sign-in.
    var joinedRoomsListing: (rooms: [ApronRoom], users: [ApronUser])?
    var joinedRoomsRequest: Task<(rooms: [ApronRoom], users: [ApronUser]), Error>?
    /// Bumped by each `room_update`, so a listing requested before one isn't kept.
    var roomsGeneration = 0
    /// Rooms the user muted, and their per-room wake scopes, as the server last sent them in `status`; each
    /// sign-in sends the ones in effect (§4.5.4).
    public private(set) var mutedRooms: Set<String> = []
    public private(set) var roomWakes: [String: [String]] = [:]

    private let task: URLSessionWebSocketTask
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var serverWaiters: [CheckedContinuation<ApronServerInfo, Error>] = []
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// When the last frame arrived; a ping with nothing back by the next one means the socket is dead.
    private var lastFrameAt = ContinuousClock.now
    private var isClosed = false
    private let requestTimeout: Duration = .seconds(15)
    /// The longest `retry_after` a request waits out and resends with the same `id` before failing.
    private let longestRetryWait = 5
    /// Texts of `message` bodies over this many UTF-8 bytes are refused as `too_large` (SPEC §6).
    public static let maxTextBytes = 4096

    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
    }

    /// Opens the socket and waits for the server's greeting frame (§3.1).
    public func connect() async throws -> ApronServerInfo {
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        let timeout = requestTimeout
        let info = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ApronServerInfo, Error>) in
            if let server {
                continuation.resume(returning: server)
                return
            }
            serverWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, server == nil else { return }
                finish(error: ApronError.timedOut)
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        if let ping = info.ping, ping > 0 {
            startPinging(every: ping)
        }
        return info
    }

    /// A short `retry_after`, such as for a `history` while another is in progress, is waited out and the request
    /// sent again with the same `id`, so a mutation the server already accepted isn't applied twice.
    public func request<Result: Decodable>(_ method: String, params: some Encodable, as _: Result.Type) async throws -> Result {
        guard !isClosed else { throw ApronError.closed }
        let id = "c\(UUID().uuidString.prefix(12))"
        let frame = try encoder.encode(OutgoingFrame(method: method, id: id, params: params))
        let text = String(decoding: frame, as: UTF8.self)
        var retries = 0
        while true {
            do {
                return try decoder.decode(Result.self, from: await send(text, id: id))
            } catch let ApronError.limited(_, retryAfter, _) where retryAfter <= longestRetryWait && retries < 2 && !isClosed {
                retries += 1
                try await Task.sleep(for: .seconds(max(retryAfter, 1)))
            }
        }
    }

    private func send(_ text: String, id: String) async throws -> Data {
        let timeout = requestTimeout
        // Register before sending so a fast reply can never arrive unmatched.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pending[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await task.send(.string(text))
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                    return
                }
                try? await Task.sleep(for: timeout)
                pending.removeValue(forKey: id)?.resume(throwing: ApronError.timedOut)
            }
        }
    }

    public func notify(_ method: String, params: some Encodable) async throws {
        guard !isClosed else { throw ApronError.closed }
        let frame = try encoder.encode(OutgoingFrame(method: method, id: nil, params: params))
        try await task.send(.string(String(decoding: frame, as: UTF8.self)))
    }

    public var isOpen: Bool {
        !isClosed
    }

    public func close() {
        guard !isClosed else { return }
        task.cancel(with: .normalClosure, reason: nil)
        finish(error: nil)
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                let message = try await task.receive()
                lastFrameAt = .now
                switch message {
                case let .string(text): handle(Data(text.utf8))
                case let .data(data): handle(data)
                @unknown default: break
                }
            } catch {
                finish(error: handshakeRejection ?? serverClose ?? error)
                return
            }
        }
    }

    /// URLSession reports a refused upgrade as `badServerResponse`; the status says why (a 503 when a
    /// server is at capacity, a 401, a 404 for a wrong path), and `Retry-After` how long to stay away.
    private var handshakeRejection: ApronError? {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return nil }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return .rejected(status: response.statusCode, retryAfter: retryAfter)
    }

    private var serverClose: ApronError? {
        guard task.closeCode != .invalid else { return nil }
        return .closedByServer(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = frame["method"] as? String

        if let id = frame["id"] as? String, method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = frame["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                let message = error["message"] as? String ?? "Request failed"
                let data = error["data"] as? [String: Any]
                if code == ApronError.retryAfterCode, let retryAfter = data?["retry_after"] as? Int {
                    let category = (data?["ext"] as? [String: Any])?["limits"] as? String
                    continuation.resume(throwing: ApronError.limited(message: message, retryAfter: retryAfter, category: category))
                } else {
                    continuation.resume(throwing: ApronError.rpc(code: code, message: message))
                }
            } else {
                continuation.resume(returning: Self.json(frame["result"] ?? [String: Any]()))
            }
            return
        }

        if method == nil, let error = frame["error"] as? [String: Any] {
            // A connection-level error with no id; the server may close after it (§1.1).
            let rpcError = ApronError.rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "Server error")
            finish(error: rpcError)
            return
        }

        guard let method else { return }
        let params = Self.json(frame["params"] ?? [String: Any]())
        if method == "server", let info = try? decoder.decode(ApronServerInfo.self, from: params) {
            server = info
            let waiters = serverWaiters
            serverWaiters = []
            waiters.forEach { $0.resume(returning: info) }
        }
        if method == "room_update" {
            joinedRoomsListing = nil
            roomsGeneration += 1
        }
        if method == "status", let status = frame["params"] as? [String: Any] {
            applyStatus(status)
        }
        for observer in notificationObservers.values {
            observer(method, params)
        }
    }

    /// A room's `mute` is `true`, `false`, or seconds left; a missing field changes nothing (§4.5.3).
    func applyStatus(_ status: [String: Any]) {
        guard let roomId = status["room_id"] as? String else { return }
        if let mute = status["mute"] as? NSNumber {
            if mute.boolValue {
                mutedRooms.insert(roomId)
            } else {
                mutedRooms.remove(roomId)
            }
        }
        if let wake = status["wake"] {
            roomWakes[roomId] = wake as? [String]
        }
    }

    /// Pings at the server's interval, and closes the connection when a ping got nothing back by the next one:
    /// a socket whose peer vanished (sleep, a network change) otherwise looks open until iOS gives up on it.
    private func startPinging(every seconds: Double) {
        pingTask = Task { [weak self] in
            var lastPingAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !isClosed, !Task.isCancelled else { return }
                if let lastPingAt, lastFrameAt < lastPingAt {
                    finish(error: ApronError.timedOut)
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                lastPingAt = .now
                do {
                    // Exactly `{"method":"ping"}`, which doesn't count against the frame limits (§1).
                    try await task.send(.string(#"{"method":"ping"}"#))
                } catch {
                    finish(error: error)
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private func finish(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        pingTask?.cancel()
        receiveTask?.cancel()
        let failure = error ?? ApronError.closed
        pending.values.forEach { $0.resume(throwing: failure) }
        pending = [:]
        serverWaiters.forEach { $0.resume(throwing: failure) }
        serverWaiters = []
        let observers = closeObservers.values
        notificationObservers = [:]
        closeObservers = [:]
        for observer in observers {
            observer(error)
        }
    }

    private static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    }
}

private struct OutgoingFrame<Params: Encodable>: Encodable {
    let method: String
    let id: String?
    let params: Params
}
