import Foundation

public struct ApronSession: Sendable {
    public let serverURL: URL
    public let connection: ApronConnection
    public let server: ApronServerInfo
    public let you: ApronUser
    /// The server issued or rotated a bearer token during this sign-in (§3.2.1).
    let issuedToken: Bool
}

/// Owns the user's Apron server list and opens authenticated connections to them.
@MainActor
public final class ApronService {
    private let metadataStore: AccountMetadataStore
    private let keychainStore: KeychainCredentialStore
    private let agent: String
    private var sharedSessions: [URL: ApronSession] = [:]
    private var pendingSessions: [URL: Task<ApronSession, Error>] = [:]
    public let readStore: ApronReadStore
    public let messageCache = ApronMessageCache()

    public init(metadataStore: AccountMetadataStore, keychainStore: KeychainCredentialStore, readStore: ApronReadStore = ApronReadStore()) {
        self.metadataStore = metadataStore
        self.keychainStore = keychainStore
        self.readStore = readStore
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        agent = "stupid-social/\(version)"
    }

    public var servers: [ApronServerMetadata] {
        metadataStore.apronServers
    }

    public func server(for serverURL: URL) -> ApronServerMetadata? {
        servers.first { $0.serverURL == serverURL }
    }

    public func hasToken(serverURL: URL) -> Bool {
        ((try? keychainStore.loadApronToken(serverURL: serverURL)) ?? nil) != nil
    }

    /// Accepts `server.apron.chat`, `https://…`, or `wss://…` and returns a WebSocket URL.
    public static func normalizeServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "wss://\(text)"
        }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "wss"
        case "ws", "http": components.scheme = "ws"
        default: return nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    /// Connects and signs in, then records the server. Throws without saving if sign-in fails.
    public func addServer(input: String, token: String?, name: String?) async throws -> ApronServerMetadata {
        guard let serverURL = Self.normalizeServerURL(input) else { throw ApronError.invalidURL }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let session = try await signIn(serverURL: serverURL, token: token, requestedName: name)
        session.connection.close()
        return try saveSignIn(session, token: token, requestedName: name)
    }

    public func updateToken(serverURL: URL, token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let requestedName = server(for: serverURL)?.requestedName
        let session = try await signIn(serverURL: serverURL, token: token, requestedName: requestedName)
        session.connection.close()
        _ = try saveSignIn(session, token: token, requestedName: requestedName)
        // Reconnect with the new token on next use.
        closeSessions(for: serverURL)
    }

    /// Whether the server's read cursor is the truth for this session: it relays `activity`, hasn't said it keeps
    /// no cursors, and the user has a stable identity (a token). Guests become a new user on every connection.
    public func serverTracksCursors(_ session: ApronSession) -> Bool {
        session.server.has("activity") && session.server.ext?.readCursorsDisabled != true && hasToken(serverURL: session.serverURL)
    }

    public func removeServer(serverURL: URL) {
        closeSessions(for: serverURL)
        readStore.removeServer(serverURL)
        messageCache.removeServer(serverURL)
        try? keychainStore.deleteApronToken(serverURL: serverURL)
        metadataStore.apronServers.removeAll { $0.serverURL == serverURL }
    }

    /// The app's one signed-in connection to a saved server, opened on first use and shared by the feed,
    /// live updates and chat. Servers may limit connections per account, so nothing else opens its own.
    /// Callers observe it and remove their observers when done; only `closeSessions` closes it.
    public func session(serverURL: URL) async throws -> ApronSession {
        if let shared = sharedSessions[serverURL], shared.connection.isOpen {
            return shared
        }
        if let pending = pendingSessions[serverURL] {
            return try await pending.value
        }
        let task = Task { try await open(serverURL: serverURL) }
        pendingSessions[serverURL] = task
        defer { pendingSessions[serverURL] = nil }
        let session = try await task.value
        sharedSessions[serverURL] = session
        session.connection.observe(notifications: { _, _ in }, onClose: { [weak self] _ in
            if self?.sharedSessions[serverURL]?.connection === session.connection {
                self?.sharedSessions[serverURL] = nil
            }
        })
        return session
    }

    /// Closes shared connections, such as when the app goes to the background; the next use reopens them.
    public func closeSessions(for serverURL: URL? = nil) {
        for (url, session) in sharedSessions where serverURL == nil || url == serverURL {
            sharedSessions[url] = nil
            session.connection.close()
        }
    }

    /// Opens a new signed-in connection to a saved server.
    private func open(serverURL: URL) async throws -> ApronSession {
        guard let metadata = server(for: serverURL) else { throw SourceError.notConfigured }
        let token = try keychainStore.loadApronToken(serverURL: serverURL)
        do {
            let session = try await signIn(serverURL: serverURL, token: token, requestedName: metadata.requestedName)
            _ = try saveSignIn(session, token: nil, requestedName: metadata.requestedName)
            readStore.addOwnUserId(session.you.userId, serverURL: serverURL)
            return session
        } catch let error as ApronError where error.isDenied {
            updateStatus(serverURL: serverURL, status: .invalidCredentials)
            throw error
        }
    }

    private func signIn(serverURL: URL, token: String?, requestedName: String?) async throws -> ApronSession {
        let connection = ApronConnection(url: serverURL)
        do {
            let server = try await connection.connect()
            let scheme: String
            if token != nil, server.acceptedSchemes.contains("token") {
                scheme = "token"
            } else if server.acceptedSchemes.contains("guest") {
                scheme = "guest"
            } else {
                throw ApronError.noUsableAuthScheme(server.auth)
            }
            let result = try await connection.request(
                "auth",
                params: ApronAuthParams(scheme: scheme, token: scheme == "token" ? token : nil, name: requestedName, agent: agent),
                as: ApronAuthResult.self,
            )
            guard let you = result.you else { throw ApronError.rpc(code: ApronError.deniedCode, message: "The server did not sign you in.") }
            if let issued = result.token {
                _ = try keychainStore.saveApronToken(issued, serverURL: serverURL)
            }
            return ApronSession(serverURL: serverURL, connection: connection, server: server, you: you, issuedToken: result.token != nil)
        } catch {
            connection.close()
            throw error
        }
    }

    private func saveSignIn(_ session: ApronSession, token: String?, requestedName: String?) throws -> ApronServerMetadata {
        // A token the server issued during sign-in was already saved and replaces the pasted one.
        if let token, !session.issuedToken {
            _ = try keychainStore.saveApronToken(token, serverURL: session.serverURL)
        }
        let metadata = ApronServerMetadata(
            serverURL: session.serverURL,
            requestedName: requestedName,
            user: session.you,
            agent: session.server.agent,
            welcome: session.server.welcome,
            status: .valid,
        )
        var servers = metadataStore.apronServers
        if let index = servers.firstIndex(where: { $0.serverURL == session.serverURL }) {
            servers[index] = metadata
        } else {
            servers.append(metadata)
        }
        metadataStore.apronServers = servers
        return metadata
    }

    private func updateStatus(serverURL: URL, status: AccountStatusSnapshot) {
        var servers = metadataStore.apronServers
        guard let index = servers.firstIndex(where: { $0.serverURL == serverURL }) else { return }
        servers[index].status = status
        metadataStore.apronServers = servers
    }
}

public extension ApronConnection {
    /// Joined rooms, and with `members` the complete user objects of their members, which carry avatars (§4.2.1).
    internal func joinedRooms(members: Bool = false) async throws -> (rooms: [ApronRoom], users: [ApronUser]) {
        let result = try await request("room_list", params: ApronRoomListParams(filter: "joined", members: members), as: ApronRoomListResult.self)
        return (result.joined ?? [], result.users ?? [])
    }

    /// A window of a room's log with inclusive bounds: the oldest matches with `after`, otherwise the newest (§4.3.2).
    func history(roomId: String?, after: String? = nil, before: String? = nil, limit: Int) async throws -> ApronHistoryResult {
        try await request("history", params: ApronHistoryParams(roomId: roomId, after: after, before: before, limit: limit), as: ApronHistoryResult.self)
    }

    func joinRoom(roomId: String) async throws {
        _ = try await request("room_join", params: ApronRoomIdParams(roomId: roomId), as: ApronEmptyResult.self)
    }

    /// Sends a `message` or `command` (§4.1); the result lists write URLs for new upload embeds.
    internal func post(method: String, roomId: String, body: ApronMessageBody, replyTo: String? = nil) async throws -> ApronSendResult {
        let params = ApronSendParams(roomId: roomId, body: body, replyTo: replyTo.map(ApronMessageReference.init(messageId:)))
        return try await request(method, params: params, as: ApronSendResult.self)
    }

    /// Replies with `{}`; the change arrives as a `reactions` broadcast (§4.7).
    func setReactions(messageId: String, emojis: [String]) async throws {
        _ = try await request("reactions", params: ApronReactionsParams(messageId: messageId, emojis: emojis), as: ApronEmptyResult.self)
    }

    func markRead(roomId: String, messageId: String) async throws {
        try await notify("activity", params: ApronActivityParams(roomId: roomId, readMessageId: messageId))
    }
}

public enum ApronUploader {
    /// Writes an upload's content as the body of an HTTP `PUT` to its `write_url` (§4.8.3).
    public static func put(data: Data, mimeType: String, to writeURL: URL, session: URLSession = .shared) async throws {
        var request = URLRequest(url: writeURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SourceError.serviceError("Upload failed (HTTP \(status)).")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
