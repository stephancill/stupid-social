import Foundation

public enum ApronError: LocalizedError, Equatable {
    case invalidURL
    case rpc(code: Int, message: String)
    case timedOut
    case closed
    case noUsableAuthScheme([String])

    public static let deniedCode = -32001

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a ws:// or wss:// server URL."
        case let .rpc(_, message): message
        case .timedOut: "The Apron server did not respond."
        case .closed: "The connection to the Apron server closed."
        case let .noUsableAuthScheme(schemes): "This server needs a sign-in method the app does not support (\(schemes.joined(separator: ", ")))."
        }
    }

    public var isDenied: Bool {
        if case let .rpc(code, _) = self { return code == Self.deniedCode }
        return false
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

    private let task: URLSessionWebSocketTask
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var serverWaiters: [CheckedContinuation<ApronServerInfo, Error>] = []
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var isClosed = false
    private let requestTimeout: Duration = .seconds(15)

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

    public func request<Result: Decodable>(_ method: String, params: some Encodable, as _: Result.Type) async throws -> Result {
        guard !isClosed else { throw ApronError.closed }
        let id = "c\(UUID().uuidString.prefix(12))"
        let frame = try encoder.encode(OutgoingFrame(method: method, id: id, params: params))
        let text = String(decoding: frame, as: UTF8.self)
        let timeout = requestTimeout
        // Register before sending so a fast reply can never arrive unmatched.
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
        return try decoder.decode(Result.self, from: data)
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
                switch message {
                case let .string(text): handle(Data(text.utf8))
                case let .data(data): handle(data)
                @unknown default: break
                }
            } catch {
                finish(error: error)
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = frame["method"] as? String

        if let id = frame["id"] as? String, method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = frame["error"] as? [String: Any] {
                continuation.resume(throwing: ApronError.rpc(
                    code: error["code"] as? Int ?? 0,
                    message: error["message"] as? String ?? "Request failed",
                ))
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
        for observer in notificationObservers.values {
            observer(method, params)
        }
    }

    private func startPinging(every seconds: Double) {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !self.isClosed else { return }
                // Exactly `{"method":"ping"}` (§1).
                try? await task.send(.string(#"{"method":"ping"}"#))
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
