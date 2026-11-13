import Foundation
import OSLog

/// A Discord user token, from the web login (`DiscordLoginWebView`).
public struct DiscordCredentials: Codable, Equatable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

/// Discord's REST API v9 as discord.com's web client calls it: the token in `Authorization`, a Chrome user agent and
/// `X-Super-Properties` describing that client (validated with `scripts/discord-web-client.py`, observed
/// 2026-11-07). The gateway (`DiscordGateway`) carries the account's state and live events.
public final class DiscordClient: @unchecked Sendable {
    static let apiURL = URL(string: "https://discord.com/api/v9")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
    static let buildNumber = 667_580

    static var superProperties: [String: Any] {
        [
            "os": "Mac OS X",
            "browser": "Chrome",
            "device": "",
            "system_locale": Locale.current.identifier(.bcp47),
            "has_client_mods": false,
            "browser_user_agent": userAgent,
            "browser_version": "156.0.0.0",
            "os_version": "10.15.7",
            "referrer": "",
            "referring_domain": "",
            "referrer_current": "",
            "referring_domain_current": "",
            "release_channel": "stable",
            "client_build_number": buildNumber,
            "client_event_source": NSNull(),
        ]
    }

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    public init(credentialStore: KeychainCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    func token() throws -> String {
        guard let token = try credentialStore.loadDiscordCredentials()?.token, !token.isEmpty else { throw SourceError.notConfigured }
        return token
    }

    // MARK: Calls

    /// The signed-in user, which also checks the token.
    public func currentUser(token: String? = nil) async throws -> DiscordUser {
        try await request("GET", "/users/@me", token: token)
    }

    /// Newest first, as Discord returns them.
    func messages(channelId: String, before: String? = nil, after: String? = nil, around: String? = nil, limit: Int = 50) async throws -> [DiscordMessage] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if let around { query.append(URLQueryItem(name: "around", value: around)) }
        return try await request("GET", "/channels/\(channelId)/messages", query: query)
    }

    /// A message with text, an uploaded file (`upload(channelId:attachment:)`) and stickers, as the web client
    /// sends them.
    func send(channelId: String, content: String, replyTo: String?, nonce: String, upload: DiscordUploaded? = nil, stickerIds: [String] = []) async throws -> DiscordMessage {
        var body: [String: Any] = ["content": content, "nonce": nonce, "tts": false, "flags": 0]
        if let replyTo {
            body["message_reference"] = ["channel_id": channelId, "message_id": replyTo]
        }
        if let upload {
            body["attachments"] = [["id": "0", "filename": upload.filename, "uploaded_filename": upload.uploadedFilename]]
        }
        if !stickerIds.isEmpty {
            body["sticker_ids"] = stickerIds
        }
        return try await request("POST", "/channels/\(channelId)/messages", body: body)
    }

    /// A forward (`message_reference` type 1, probe `forward`, observed 2026-11-07): empty content, and Discord copies
    /// the original into `message_snapshots`. `guild_id` names a server channel's guild; DMs leave it out.
    func forward(channelId: String, from source: DiscordForwardReference, nonce: String) async throws -> DiscordMessage {
        var reference: [String: Any] = ["type": 1, "channel_id": source.channelId, "message_id": source.messageId]
        if let guildId = source.guildId {
            reference["guild_id"] = guildId
        }
        return try await request("POST", "/channels/\(channelId)/messages", body: [
            "content": "", "nonce": nonce, "tts": false, "flags": 0, "message_reference": reference,
        ])
    }

    /// A voice message (probe `send-voice`, observed 2026-11-07): an uploaded Ogg Opus file named
    /// `voice-message.ogg`, flagged `IS_VOICE_MESSAGE`, with its length and a waveform of 0–255 levels in base64.
    func sendVoice(channelId: String, upload: DiscordUploaded, duration: Double, waveform: Data, replyTo: String?, nonce: String) async throws -> DiscordMessage {
        var body: [String: Any] = [
            "content": "", "nonce": nonce, "channel_id": channelId, "type": 0, "flags": DiscordMessage.voiceMessageFlag, "sticker_ids": [] as [String],
            "attachments": [[
                "id": "0", "filename": upload.filename, "uploaded_filename": upload.uploadedFilename,
                "duration_secs": duration, "waveform": waveform.base64EncodedString(),
            ]],
        ]
        if let replyTo {
            body["message_reference"] = ["channel_id": channelId, "message_id": replyTo]
        }
        return try await request("POST", "/channels/\(channelId)/messages", body: body)
    }

    /// Uploads a file as the web client does: Discord names a storage URL for it (`POST /channels/{id}/attachments`),
    /// the bytes go there with a `PUT`, and the message then names the uploaded file.
    func upload(channelId: String, data: Data, mimeType: String, filename: String) async throws -> DiscordUploaded {
        let slots: DiscordUploadSlots = try await request("POST", "/channels/\(channelId)/attachments", body: [
            "files": [["filename": filename, "file_size": data.count, "id": "0", "is_clip": false]],
        ])
        guard let slot = slots.attachments.first, let url = URL(string: slot.uploadUrl) else { throw SourceError.invalidResponse }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        put.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.upload(for: put, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw DiscordError.http(status: status, message: "The upload failed.") }
        return DiscordUploaded(filename: filename, uploadedFilename: slot.uploadFilename)
    }

    func stickerPacks() async throws -> [DiscordStickerPack] {
        struct Page: Decodable {
            let stickerPacks: [DiscordStickerPack]
        }
        let page: Page = try await request("GET", "/sticker-packs")
        return page.stickerPacks
    }

    /// The DM channel with the user, which Discord creates if there is none; no message is sent.
    func openDM(userId: String) async throws -> DiscordChannel {
        try await request("POST", "/users/@me/channels", body: ["recipients": [userId]])
    }

    func profile(userId: String) async throws -> DiscordProfile {
        try await request("GET", "/users/\(userId)/profile", query: [
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ])
    }

    /// A forum's posts with the newest activity first, archived ones included, as the forum view lists them.
    func forumThreads(channelId: String, limit: Int) async throws -> DiscordThreadSearch {
        try await request("GET", "/channels/\(channelId)/threads/search", query: [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(name: "sort_by", value: "last_message_time"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "tag_setting", value: "match_some"),
            URLQueryItem(name: "offset", value: "0"),
        ])
    }

    func edit(channelId: String, messageId: String, content: String) async throws -> DiscordMessage {
        try await request("PATCH", "/channels/\(channelId)/messages/\(messageId)", body: ["content": content])
    }

    func delete(channelId: String, messageId: String) async throws {
        try await requestNoContent("DELETE", "/channels/\(channelId)/messages/\(messageId)")
    }

    func setReaction(channelId: String, messageId: String, emoji: DiscordEmoji, remove: Bool) async throws {
        guard let name = emoji.routeName?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return }
        try await requestNoContent(
            remove ? "DELETE" : "PUT",
            "/channels/\(channelId)/messages/\(messageId)/reactions/\(name)/@me",
            query: [URLQueryItem(name: "location", value: "Message Reaction Picker"), URLQueryItem(name: "type", value: "0")],
        )
    }

    func reactors(channelId: String, messageId: String, emoji: DiscordEmoji) async throws -> [DiscordUser] {
        guard let name = emoji.routeName?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return [] }
        return try await request("GET", "/channels/\(channelId)/messages/\(messageId)/reactions/\(name)", query: [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "type", value: "0")])
    }

    /// Mutes a channel or DM until turned back on, or unmutes it, as the web client's Mute Channel does: an override
    /// in the user's settings for the channel's guild (`@me` for DMs). Unmuting drops the override. Returns the
    /// guild's settings (scripts/discord-web-client.py `mute`, observed 2026-11-13).
    func setMuted(channelId: String, guildId: String?, muted: Bool) async throws -> DiscordGuildSettings {
        var override: [String: Any] = ["muted": muted]
        if muted {
            override["mute_config"] = ["selected_time_window": -1, "end_time": NSNull()]
        }
        return try await request("PATCH", "/users/@me/guilds/\(guildId ?? "@me")/settings", body: ["channel_overrides": [channelId: override]])
    }

    /// Moves the read position to the message (`{"token": null}`, as the web client sends).
    func ack(channelId: String, messageId: String) async throws {
        try await requestNoContent("POST", "/channels/\(channelId)/messages/\(messageId)/ack", body: ["token": NSNull()])
    }

    func typing(channelId: String) async throws {
        try await requestNoContent("POST", "/channels/\(channelId)/typing")
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, token: String? = nil) async throws -> T {
        let data = try await send(method, path, query: query, body: body, token: token)
        do {
            return try JSONDecoder.discord.decode(T.self, from: data)
        } catch {
            throw SourceError.invalidResponse
        }
    }

    private func requestNoContent(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws {
        _ = try await send(method, path, query: query, body: body, token: nil)
    }

    /// Waits out one rate limit of up to 5 s, as the web client does.
    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?, token: String?, retried: Bool = false) async throws -> Data {
        var components = URLComponents(url: Self.apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        // `appending(path:)` escapes the reaction route's percent signs again; the path is built already escaped.
        components.percentEncodedPath = Self.apiURL.path() + path
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        try Self.headers(token: token ?? self.token()).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300:
            return data
        case 401:
            throw SourceError.notConfigured
        case 429:
            let retryAfter = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["retry_after"] as? Double ?? 1
            guard !retried, retryAfter <= 5 else { throw DiscordError.rateLimited(retryAfter: retryAfter) }
            try await Task.sleep(for: .seconds(retryAfter))
            return try await send(method, path, query: query, body: body, token: token, retried: true)
        default:
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw DiscordError.http(status: status, message: message)
        }
    }

    static func headers(token: String) -> [String: String] {
        let properties = (try? JSONSerialization.data(withJSONObject: superProperties, options: [.sortedKeys])) ?? Data()
        return [
            "Authorization": token,
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "X-Discord-Locale": "en-US",
            "X-Discord-Timezone": TimeZone.current.identifier,
            "X-Debug-Options": "bugReporterEnabled",
            "X-Super-Properties": properties.base64EncodedString(),
            "Origin": "https://discord.com",
            "Referer": "https://discord.com/channels/@me",
        ]
    }
}

/// The account's gateway connection while the app is in the foreground: its `READY` state (guilds, channels, DMs,
/// read states, mutes), kept current by the events after it, and those events for open chats and the Chats list.
/// Identifies as the web client does, without capabilities so `READY` has its plain shape and without
/// compression (scripts/discord-web-client.py `ready` and `follow`). `LiveConnection` identifies again on a new
/// connection with backoff when one drops, and tells observers to catch up.
@MainActor
public final class DiscordGateway: LiveConnecting {
    enum Event {
        case message(DiscordMessage)
        case messageUpdate(DiscordMessageUpdate)
        case messageDelete(channelId: String, messageId: String)
        case reaction(channelId: String, messageId: String, userId: String, emoji: DiscordEmoji, added: Bool)
        case typing(channelId: String, userId: String, name: String?)
        /// The user read up to the message, here or on another device.
        case ack(channelId: String, messageId: String)
    }

    private static let url = URL(string: "wss://gateway.discord.gg/?encoding=json&v=9")!

    let client: DiscordClient
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "DiscordGateway")
    private var connection: LiveConnection<Event>!
    private var socket: URLSessionWebSocketTask?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    /// The last dispatch's sequence number, which heartbeats carry.
    private var sequence: Int?
    private var stickerPacks: [DiscordStickerPack]?
    /// Why the last connection failed to identify, such as a token Discord no longer takes.
    private var identifyError: Error?

    private(set) var me: DiscordUser?
    private(set) var guilds: [String: DiscordGuild] = [:]
    private(set) var privateChannels: [String: DiscordChannel] = [:]
    private(set) var readStates: [String: DiscordReadState] = [:]
    /// By guild id; DMs' under "".
    private(set) var guildSettings: [String: DiscordGuildSettings] = [:]
    private(set) var isReady = false

    public init(client: DiscordClient) {
        self.client = client
        connection = LiveConnection(
            name: "Discord gateway",
            outcome: Self.outcome(for:),
        ) { [weak self] connection in
            try await self?.follow(connection)
        }
    }

    public func start() {
        connection.start()
    }

    public func stop() {
        connection.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Connects if needed and waits for `READY`.
    func waitUntilReady(timeout: Duration = .seconds(20)) async throws {
        if isReady { return }
        if let identifyError {
            self.identifyError = nil
            throw identifyError
        }
        start()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.failWaiters(DiscordError.notConnected)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    /// Discord's standard sticker packs, loaded once.
    func standardStickerPacks() async throws -> [DiscordStickerPack] {
        if let stickerPacks { return stickerPacks }
        let packs = try await client.stickerPacks()
        stickerPacks = packs
        return packs
    }

    func observe(_ handler: @escaping (LiveUpdate<Event>) -> Void) -> UUID {
        connection.observe(handler)
    }

    func removeObserver(_ id: UUID) {
        connection.removeObserver(id)
    }

    // MARK: State

    func channel(id: String) -> DiscordChannel? {
        if let channel = privateChannels[id] { return channel }
        for guild in guilds.values {
            if let channel = guild.channels.first(where: { $0.id == id }) { return channel }
        }
        return nil
    }

    func guild(id: String?) -> DiscordGuild? {
        id.flatMap { guilds[$0] }
    }

    /// Mutes or unmutes the channel, keeping the settings Discord returns so its row shows it.
    func setMuted(_ channel: DiscordChannel, muted: Bool) async throws {
        let settings = try await client.setMuted(channelId: channel.id, guildId: channel.guildId, muted: muted)
        guildSettings[channel.guildId ?? ""] = settings
    }

    /// Whether the channel's guild is muted, which a channel can't override.
    func isGuildMuted(_ channel: DiscordChannel) -> Bool {
        channel.guildId != nil && guildSettings[channel.guildId ?? ""]?.muted == true
    }

    func isMuted(_ channel: DiscordChannel) -> Bool {
        let settings = guildSettings[channel.guildId ?? ""]
        if channel.guildId != nil, settings?.muted == true { return true }
        return settings?.channelOverrides?.first { $0.channelId == channel.id }?.muted == true
    }

    func canView(_ channel: DiscordChannel) -> Bool {
        guard let guildId = channel.guildId else { return true }
        guard let guild = guilds[guildId], let me else { return false }
        return DiscordPermissions.of(userId: me.id, in: guild, channel: channel) & DiscordPermissions.viewChannel != 0
    }

    func permissions(in channel: DiscordChannel) -> UInt64 {
        guard let guildId = channel.guildId else { return .max }
        guard let guild = guilds[guildId], let me else { return 0 }
        return DiscordPermissions.of(userId: me.id, in: guild, channel: channel)
    }

    /// Moves the read position here, ahead of Discord's `MESSAGE_ACK`.
    func setRead(channelId: String, messageId: String) {
        guard DiscordSnowflake.isAfter(messageId, readStates[channelId]?.lastMessageId) else { return }
        readStates[channelId] = DiscordReadState(id: channelId, lastMessageId: messageId, mentionCount: 0)
    }

    /// Subscribes to a guild's typing and message events, as the web client does when one of its channels opens
    /// (`op 37`); large guilds send them only after this.
    func subscribe(guildId: String) {
        let frame: [String: Any] = ["op": 37, "d": ["subscriptions": [guildId: ["typing": true, "threads": true, "activities": true, "members": [], "member_updates": false, "channels": [:], "thread_member_lists": []]]]]
        send(frame)
    }

    func apply(ready: DiscordReady) {
        me = ready.user
        guilds = Dictionary(ready.guilds.map { ($0.id, $0.withGuildIds) }, uniquingKeysWith: { _, last in last })
        privateChannels = Dictionary(ready.privateChannels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        readStates = Dictionary(ready.readState.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guildSettings = Dictionary(ready.userGuildSettings.map { ($0.guildId ?? "", $0) }, uniquingKeysWith: { _, last in last })
        isReady = true
    }

    // MARK: Connection

    private static func outcome(for error: Error) -> LiveOutcome {
        (error as? GatewayClosed)?.isAuthenticationFailure == true ? .stop : .retry
    }

    private struct GatewayClosed: Error {
        let code: Int

        /// 4004 authentication failed.
        var isAuthenticationFailure: Bool {
            code == 4004
        }
    }

    private struct Frame: Decodable {
        let op: Int
        let s: Int?
        let t: String?
    }

    private struct Payload<T: Decodable>: Decodable {
        let d: T
    }

    private struct Hello: Decodable {
        let heartbeatInterval: Double
    }

    /// One connection: identify, then dispatch until it closes. A refused token stops reconnecting
    /// (`LiveOutcome.stop`) and fails whoever waits for `READY`.
    private func follow(_ connection: LiveConnection<Event>) async throws {
        defer { isReady = false }
        do {
            try await identifyAndDispatch(connection)
        } catch let error as GatewayClosed where error.isAuthenticationFailure {
            logger.info("Discord gateway refused the token")
            identifyError = SourceError.notConfigured
            failWaiters(SourceError.notConfigured)
            throw error
        }
    }

    private func identifyAndDispatch(_ connection: LiveConnection<Event>) async throws {
        let token = try client.token()
        var request = URLRequest(url: Self.url)
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.setValue(DiscordClient.userAgent, forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        // READY lists every guild's channels and DMs; hundreds of kilobytes for a modest account.
        socket.maximumMessageSize = 64 << 20
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        sequence = nil
        var heartbeat: Task<Void, Never>?
        defer { heartbeat?.cancel() }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if socket.closeCode != .invalid { throw GatewayClosed(code: socket.closeCode.rawValue) }
                throw error
            }
            let data: Data = switch message {
            case let .string(text): Data(text.utf8)
            case let .data(data): data
            @unknown default: Data()
            }
            guard let frame = try? JSONDecoder.discord.decode(Frame.self, from: data) else { continue }
            if let s = frame.s { sequence = s }
            switch frame.op {
            case 10:
                let hello = try JSONDecoder.discord.decode(Payload<Hello>.self, from: data).d
                let interval = Duration.milliseconds(Int(hello.heartbeatInterval))
                heartbeat = Task { [weak self] in
                    try? await Task.sleep(for: interval * 0.5)
                    while !Task.isCancelled {
                        self?.sendHeartbeat()
                        try? await Task.sleep(for: interval)
                    }
                }
                send(["op": 2, "d": [
                    "token": token,
                    "capabilities": 0,
                    "properties": DiscordClient.superProperties.merging(["client_app_state": "focused"]) { _, new in new },
                    "presence": ["status": "unknown", "since": 0, "activities": [], "afk": false],
                    "compress": false,
                    "client_state": ["guild_versions": [:]],
                ]])
            case 1:
                sendHeartbeat()
            case 7, 9:
                // Reconnect, or an invalid session: identify again on a new connection.
                throw GatewayClosed(code: 0)
            case 0:
                if frame.t == "READY" {
                    let ready = try JSONDecoder.discord.decode(Payload<DiscordReady>.self, from: data).d
                    apply(ready: ready)
                    let waiters = readyWaiters
                    readyWaiters = []
                    waiters.forEach { $0.resume() }
                    connection.opened()
                } else if let name = frame.t {
                    dispatch(name, data: data)
                }
            default:
                break
            }
        }
    }

    private func sendHeartbeat() {
        send(["op": 1, "d": sequence.map { $0 as Any } ?? NSNull()])
    }

    private func send(_ frame: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func failWaiters(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }

    private struct ReactionEvent: Decodable {
        let channelId: String
        let messageId: String
        let userId: String
        let emoji: DiscordEmoji
    }

    private struct DeleteEvent: Decodable {
        let id: String
        let channelId: String
    }

    private struct TypingEvent: Decodable {
        struct Member: Decodable {
            let nick: String?
            let user: DiscordUser?
        }

        let channelId: String
        let userId: String
        let member: Member?
    }

    private struct AckEvent: Decodable {
        let channelId: String
        let messageId: String
    }

    private struct GuildDeleteEvent: Decodable {
        let id: String
    }

    private struct ThreadListSync: Decodable {
        let guildId: String
        let threads: [DiscordChannel]
        let members: [DiscordThreadMemberEntry]?
    }

    private struct ThreadMemberUpdate: Decodable {
        /// The thread's id.
        let id: String
        let guildId: String
        let userId: String?
    }

    private struct ThreadMembersUpdate: Decodable {
        struct Added: Decodable {
            let userId: String?
        }

        let id: String
        let guildId: String
        let addedMembers: [Added]?
        let removedMemberIds: [String]?
    }

    /// Adds or replaces a channel, such as a DM the user started or a forum's post, so chats can open it. A thread
    /// keeps the membership it had when the update doesn't say.
    func remember(_ channel: DiscordChannel) {
        guard let guildId = channel.guildId else {
            privateChannels[channel.id] = channel
            return
        }
        var channel = channel
        if channel.member == nil {
            channel.member = guilds[guildId]?.channels.first { $0.id == channel.id }?.member
        }
        guilds[guildId]?.channels.removeAll { $0.id == channel.id }
        guilds[guildId]?.channels.append(channel)
    }

    private func setThreadMember(threadId: String, guildId: String, joined: Bool) {
        guard let index = guilds[guildId]?.channels.firstIndex(where: { $0.id == threadId }) else { return }
        guilds[guildId]?.channels[index].member = joined ? DiscordChannel.ThreadMember(userId: me?.id) : nil
    }

    /// Applies an event to the state and hands it to observers.
    func dispatch(_ name: String, data: Data) {
        let decoder = JSONDecoder.discord
        switch name {
        case "MESSAGE_CREATE":
            guard let message = try? decoder.decode(Payload<DiscordMessage>.self, from: data).d else { return }
            setLastMessage(channelId: message.channelId, messageId: message.id)
            if message.author.id == me?.id {
                // Sending reads the channel, on Discord's own clients too.
                setRead(channelId: message.channelId, messageId: message.id)
            }
            deliver(.message(message))
        case "MESSAGE_UPDATE":
            guard let update = try? decoder.decode(Payload<DiscordMessageUpdate>.self, from: data).d else { return }
            deliver(.messageUpdate(update))
        case "MESSAGE_DELETE":
            guard let event = try? decoder.decode(Payload<DeleteEvent>.self, from: data).d else { return }
            deliver(.messageDelete(channelId: event.channelId, messageId: event.id))
        case "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE":
            guard let event = try? decoder.decode(Payload<ReactionEvent>.self, from: data).d else { return }
            deliver(.reaction(channelId: event.channelId, messageId: event.messageId, userId: event.userId, emoji: event.emoji, added: name == "MESSAGE_REACTION_ADD"))
        case "TYPING_START":
            guard let event = try? decoder.decode(Payload<TypingEvent>.self, from: data).d, event.userId != me?.id else { return }
            deliver(.typing(channelId: event.channelId, userId: event.userId, name: event.member?.nick ?? event.member?.user?.name))
        case "MESSAGE_ACK":
            guard let event = try? decoder.decode(Payload<AckEvent>.self, from: data).d else { return }
            setRead(channelId: event.channelId, messageId: event.messageId)
            deliver(.ack(channelId: event.channelId, messageId: event.messageId))
        case "CHANNEL_CREATE", "CHANNEL_UPDATE", "THREAD_CREATE", "THREAD_UPDATE":
            guard let channel = try? decoder.decode(Payload<DiscordChannel>.self, from: data).d else { return }
            remember(channel)
        case "THREAD_DELETE":
            guard let channel = try? decoder.decode(Payload<DiscordChannel>.self, from: data).d, let guildId = channel.guildId else { return }
            guilds[guildId]?.channels.removeAll { $0.id == channel.id }
        case "THREAD_LIST_SYNC":
            guard let sync = try? decoder.decode(Payload<ThreadListSync>.self, from: data).d else { return }
            let joined = Set((sync.members ?? []).filter { $0.userId == me?.id }.map(\.id))
            for var thread in sync.threads {
                thread.guildId = sync.guildId
                if joined.contains(thread.id) { thread.member = DiscordChannel.ThreadMember(userId: me?.id) }
                remember(thread)
            }
        case "THREAD_MEMBER_UPDATE":
            guard let member = try? decoder.decode(Payload<ThreadMemberUpdate>.self, from: data).d, member.userId == me?.id else { return }
            setThreadMember(threadId: member.id, guildId: member.guildId, joined: true)
        case "THREAD_MEMBERS_UPDATE":
            guard let update = try? decoder.decode(Payload<ThreadMembersUpdate>.self, from: data).d, let me = me?.id else { return }
            if update.addedMembers?.contains(where: { $0.userId == me }) == true {
                setThreadMember(threadId: update.id, guildId: update.guildId, joined: true)
            } else if update.removedMemberIds?.contains(me) == true {
                setThreadMember(threadId: update.id, guildId: update.guildId, joined: false)
            }
        case "CHANNEL_DELETE":
            guard let channel = try? decoder.decode(Payload<DiscordChannel>.self, from: data).d else { return }
            if let guildId = channel.guildId {
                guilds[guildId]?.channels.removeAll { $0.id == channel.id }
            } else {
                privateChannels[channel.id] = nil
            }
        case "GUILD_CREATE":
            guard let guild = try? decoder.decode(Payload<DiscordGuild>.self, from: data).d else { return }
            guilds[guild.id] = guild.withGuildIds
        case "GUILD_DELETE":
            guard let event = try? decoder.decode(Payload<GuildDeleteEvent>.self, from: data).d else { return }
            guilds[event.id] = nil
        default:
            break
        }
    }

    private func setLastMessage(channelId: String, messageId: String) {
        if privateChannels[channelId] != nil {
            privateChannels[channelId]?.lastMessageId = messageId
            return
        }
        for (guildId, guild) in guilds {
            if let index = guild.channels.firstIndex(where: { $0.id == channelId }) {
                guilds[guildId]?.channels[index].lastMessageId = messageId
                return
            }
        }
    }

    private func deliver(_ event: Event) {
        connection.deliver(event)
    }
}
