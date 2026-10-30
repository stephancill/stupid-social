import Combine
import Foundation
import Network
import NoFeedSocialCore
import NoFeedSocialPush

struct ChatControlError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

/// Command-line access to chats while the app runs on a Mac (the `stupid-social` CLI in `cli/`): one JSON
/// request per line over TCP on 127.0.0.1. macOS protects the app's containers from other apps, so a terminal
/// can't reach a Unix socket in them; instead each request carries a token the user copies from Settings.
@MainActor
final class ChatControlServer: ObservableObject {
    static let port: UInt16 = 47823
    /// On a Mac, and in the simulator, which shares the Mac's loopback network.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    private static let enabledKey = "chatControlEnabled"
    private static let tokenKey = "chatControlToken"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    /// Kept on this device only: it's for this Mac's command line, and the container is private to the app.
    @Published private(set) var token: String

    private let chatList: ChatListViewModel
    private let openChat: (ChatSummary) throws -> ChatViewModel
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ChatControlClient] = [:]
    /// Held while a client is connected, so App Nap doesn't stall a watch while the app is in the background.
    private var activity: NSObjectProtocol?

    init(chatList: ChatListViewModel, openChat: @escaping (ChatSummary) throws -> ChatViewModel) {
        self.chatList = chatList
        self.openChat = openChat
        token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        isEnabled = Self.isAvailable && UserDefaults.standard.bool(forKey: Self.enabledKey)
        if token.isEmpty {
            resetToken()
        }
        if isEnabled {
            start()
        }
    }

    /// A new token; connected clients are dropped and must pair again.
    func resetToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("SecRandomCopyBytes failed")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        for client in clients.values {
            client.close()
        }
    }

    private func start() {
        guard Self.isAvailable, listener == nil else { return }
        error = nil
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        for client in clients.values {
            client.close()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case let .failed(error):
            self.error = error.localizedDescription
            listener?.cancel()
            listener = nil
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = ChatControlClient(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        activity = activity ?? ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Command-line chat access")
        client.onLine = { [weak self, weak client] line in
            guard let self, let client else { return }
            handle(line: line, client: client)
        }
        client.whenClosed { [weak self] in
            guard let self else { return }
            clients[id] = nil
            if clients.isEmpty, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
        client.start()
    }

    // MARK: Requests

    private struct Request: Decodable {
        let id: Int?
        let token: String?
        let command: String
        /// A chat's id, else its exact title, else a unique part of its title.
        let chat: String?
        let text: String?
        let limit: Int?
        let archived: Bool?
        /// Whether `chats` reloads every account first rather than answering from the last load.
        let refresh: Bool?
        let markRead: Bool?
        let replyTo: String?
        /// Seconds between reloads of the chat list while watching every chat.
        let interval: Double?
    }

    private func handle(line: String, client: ChatControlClient) {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
            client.send(ChatControlReply<Empty>(id: nil, error: "Invalid request"))
            return
        }
        guard let token = request.token, Self.constantTimeEquals(token, self.token) else {
            client.send(ChatControlReply<Empty>(id: request.id, error: "Invalid token. Copy it from Settings → Command Line on the Mac and run `stupid-social pair <token>`."), thenClose: true)
            return
        }
        client.track(Task {
            do {
                try await run(request, client: client)
            } catch is CancellationError {
            } catch {
                client.send(ChatControlReply<Empty>(id: request.id, error: error.localizedDescription))
            }
        })
    }

    private func run(_ request: Request, client: ChatControlClient) async throws {
        switch request.command {
        case "status":
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            client.send(ChatControlReply(id: request.id, result: ["app": "stupid social", "build": build ?? ""]))
        case "chats":
            if request.refresh ?? true {
                await chatList.load()
            }
            let archived = request.archived ?? false
            let chats = archived ? chatList.archivedChats : chatList.chats
            client.send(ChatControlReply(id: request.id, result: ChatsResult(
                chats: chats.map { ChatRow($0, isArchived: archived) },
                errors: chatList.connections.compactMap { connection in
                    connection.error.map { ConnectionError(label: connection.label, network: connection.network.rawValue, error: $0) }
                },
            )))
        case "read":
            let chat = try await chat(matching: request.chat)
            try await withChat(chat) { viewModel in
                let limit = max(1, request.limit ?? 20)
                while viewModel.messages.count < limit, viewModel.hasEarlierMessages {
                    let count = viewModel.messages.count
                    await viewModel.loadEarlier()
                    if let error = viewModel.errorMessage {
                        throw ChatControlError(error)
                    }
                    if viewModel.messages.count == count { break }
                }
                let unreadCount = viewModel.unreadCount
                let messages = Self.messages(of: viewModel).suffix(limit)
                if request.markRead ?? false {
                    try await markRead(viewModel)
                }
                client.send(ChatControlReply(id: request.id, result: ReadResult(chat: ChatRow(chat), unreadCount: unreadCount, messages: Array(messages))))
            }
        case "send":
            let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ChatControlError("Nothing to send") }
            let chat = try await chat(matching: request.chat)
            try await withChat(chat) { viewModel in
                let message = try await send(text, replyTo: request.replyTo, in: viewModel)
                client.send(ChatControlReply(id: request.id, result: SendResult(chat: ChatRow(chat), message: message)))
            }
        case "mark-read":
            let chat = try await chat(matching: request.chat)
            try await withChat(chat) { viewModel in
                let unreadCount = viewModel.unreadCount
                try await markRead(viewModel)
                client.send(ChatControlReply(id: request.id, result: MarkReadResult(chat: ChatRow(chat), markedCount: unreadCount)))
            }
        case "watch":
            if request.chat == nil {
                try await watchChats(request: request, client: client)
            } else {
                try await watch(chat(matching: request.chat), request: request, client: client)
            }
        default:
            throw ChatControlError("Unknown command \(request.command)")
        }
    }

    /// The chat by id, exact title, or a unique part of its title, reloading the list once when nothing matches.
    private func chat(matching query: String?) async throws -> ChatSummary {
        guard let query, !query.isEmpty else { throw ChatControlError("Name a chat by its id or title") }
        if let chat = try matches(query) {
            return chat
        }
        await chatList.load()
        if let chat = try matches(query) {
            return chat
        }
        throw ChatControlError("No chat matches “\(query)”")
    }

    private func matches(_ query: String) throws -> ChatSummary? {
        let all = chatList.chats + chatList.archivedChats
        if let chat = all.first(where: { $0.id == query }) {
            return chat
        }
        var matches = all.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
        if matches.isEmpty {
            matches = all.filter { $0.title.localizedStandardContains(query) }
        }
        guard matches.count <= 1 else {
            let candidates = matches.prefix(10).map { "\($0.title) (\($0.network.rawValue)): \($0.id)" }.joined(separator: "\n  ")
            throw ChatControlError("“\(query)” matches \(matches.count) chats; use an id:\n  \(candidates)")
        }
        return matches.first
    }

    /// Opens the chat as its screen would and closes it after `body`.
    private func withChat<T>(_ chat: ChatSummary, _ body: (ChatViewModel) async throws -> T) async throws -> T {
        let viewModel = try openChat(chat)
        await viewModel.connect()
        defer { viewModel.disconnect() }
        if case let .disconnected(reason) = viewModel.state {
            throw ChatControlError(reason ?? "Couldn't connect to the chat")
        }
        return try await body(viewModel)
    }

    private func markRead(_ viewModel: ChatViewModel) async throws {
        guard let latest = viewModel.messages.last(where: { $0.isUserMessage && !$0.isSending }) else { return }
        viewModel.markRead(upTo: latest)
        await viewModel.sendPendingReadMarker()
    }

    /// Sends through the chat's composer, so it goes as it would from the screen; the chat's draft is kept.
    private func send(_ text: String, replyTo: String?, in viewModel: ChatViewModel) async throws -> ChatControlMessage? {
        guard !viewModel.isReadOnly else { throw ChatControlError("This chat is read-only") }
        if let replyTo {
            guard viewModel.canReply else { throw ChatControlError("This chat doesn't support replies") }
            guard let message = viewModel.message(withId: replyTo) else { throw ChatControlError("No loaded message has id \(replyTo)") }
            viewModel.startReply(to: message)
        }
        let draft = viewModel.draft
        let ownIds = Set(viewModel.messages.filter(\.isOwn).map(\.id))
        viewModel.draft = text
        await viewModel.send()
        let wasSent = viewModel.draft != text
        let error = viewModel.errorMessage
        viewModel.draft = draft
        if let error {
            throw ChatControlError(error)
        }
        guard wasSent else { throw ChatControlError("The chat didn't send the message") }
        let sent = viewModel.messages.last { $0.isOwn && !ownIds.contains($0.id) }
        return sent.map { ChatControlMessage($0, in: viewModel, isUnread: false) }
    }

    /// New messages in one chat until the client disconnects or the chat's connection fails.
    private func watch(_ chat: ChatSummary, request: Request, client: ChatControlClient) async throws {
        try await withChat(chat) { viewModel in
            var seen = Set(viewModel.messages.map(\.id))
            var failure: String?
            let (done, finish) = AsyncStream<Void>.makeStream()
            var subscriptions = Set<AnyCancellable>()
            viewModel.$messages.sink { messages in
                for message in messages where !message.isSending && !seen.contains(message.id) {
                    seen.insert(message.id)
                    client.send(ChatControlEvent(id: request.id, event: "message", chatId: chat.id, message: ChatControlMessage(message, in: viewModel, isUnread: false)))
                }
            }.store(in: &subscriptions)
            viewModel.$state.dropFirst().sink { state in
                switch state {
                case .connected:
                    break
                case .connecting:
                    // The app closed the connection, such as on going to the background: open it again.
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        await viewModel.connect()
                    }
                case let .disconnected(reason):
                    failure = reason ?? "The chat disconnected"
                    finish.finish()
                }
            }.store(in: &subscriptions)
            client.whenClosed { finish.finish() }
            client.send(ChatControlReply(id: request.id, result: WatchResult(chat: ChatRow(chat))))
            for await _ in done {}
            if let failure {
                throw ChatControlError(failure)
            }
        }
    }

    /// Rows that change (a new message, a read) across every chat, reloading the list every `interval` seconds
    /// for networks that don't push.
    private func watchChats(request: Request, client: ChatControlClient) async throws {
        func rows(_ chats: [ChatSummary], _ archived: [ChatSummary]) -> [ChatRow] {
            chats.map { ChatRow($0) } + archived.map { ChatRow($0, isArchived: true) }
        }
        var last = Dictionary(rows(chatList.chats, chatList.archivedChats).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var subscriptions = Set<AnyCancellable>()
        chatList.$chats.combineLatest(chatList.$archivedChats).sink { chats, archived in
            for row in rows(chats, archived) where last[row.id] != row {
                last[row.id] = row
                client.send(ChatControlEvent(id: request.id, event: "chat", chat: row))
            }
        }.store(in: &subscriptions)
        let interval = max(5, request.interval ?? 30)
        let reload = Task { [chatList] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await chatList.load()
            }
        }
        defer { reload.cancel() }
        client.send(ChatControlReply<WatchResult>(id: request.id, result: WatchResult(chat: nil)))
        await client.waitUntilClosed()
    }

    /// The messages loaded, without sending copies, each marked unread from the "New Messages" divider on.
    private static func messages(of viewModel: ChatViewModel) -> [ChatControlMessage] {
        let messages = viewModel.messages.filter { !$0.isSending }
        let firstUnread = viewModel.firstUnreadMessageId.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.endIndex
        return messages.enumerated().map { index, message in
            ChatControlMessage(message, in: viewModel, isUnread: index >= firstUnread && !message.isOwn && message.isUserMessage)
        }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = Array(lhs.utf8), rhs = Array(rhs.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One command-line connection: lines in, JSON lines out.
@MainActor
private final class ChatControlClient {
    var onLine: ((String) -> Void)?
    private let connection: NWConnection
    private var buffer = Data()
    private var tasks: [Task<Void, Never>] = []
    private var closeHandlers: [() -> Void] = []
    private(set) var isClosed = false
    private static let maxLineLength = 1 << 20

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state {
                    self?.close()
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func track(_ task: Task<Void, Never>) {
        tasks.append(task)
    }

    func whenClosed(_ handler: @escaping () -> Void) {
        if isClosed {
            handler()
        } else {
            closeHandlers.append(handler)
        }
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            whenClosed { continuation.resume() }
        }
    }

    /// `thenClose` closes once the line is out, since cancelling the connection drops what it hasn't sent.
    func send(_ value: some Encodable, thenClose: Bool = false) {
        guard !isClosed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else {
            preconditionFailure("Couldn't encode \(type(of: value))")
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil || thenClose else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for task in tasks {
            task.cancel()
        }
        connection.cancel()
        let handlers = closeHandlers
        closeHandlers = []
        for handler in handlers {
            handler()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.received(data, isComplete: isComplete || error != nil)
            }
        }
    }

    private func received(_ data: Data?, isComplete: Bool) {
        guard !isClosed else { return }
        if let data {
            buffer.append(data)
            readLines()
        }
        if isComplete || buffer.count > Self.maxLineLength {
            close()
        } else {
            receive()
        }
    }

    private func readLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ... newline)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                onLine?(line)
            }
        }
    }
}

// MARK: Wire format

private struct Empty: Encodable {}

private struct ChatControlReply<Result: Encodable>: Encodable {
    let id: Int?
    let ok: Bool
    let result: Result?
    let error: String?

    init(id: Int?, result: Result) {
        self.id = id
        ok = true
        self.result = result
        error = nil
    }

    init(id: Int?, error: String) where Result == Empty {
        self.id = id
        ok = false
        result = nil
        self.error = error
    }
}

private struct ChatControlEvent: Encodable {
    let id: Int?
    let event: String
    var chatId: String?
    var chat: ChatRow?
    var message: ChatControlMessage?
}

private struct ChatRow: Encodable, Equatable {
    let id: String
    let accountId: String
    let network: String
    let title: String
    let titlePrefix: String?
    let preview: String?
    let timestamp: Date?
    let unreadCount: Int
    let isMuted: Bool
    let isArchived: Bool

    init(_ chat: ChatSummary, isArchived: Bool = false) {
        id = chat.id
        accountId = chat.accountId
        network = chat.network.rawValue
        title = chat.title
        titlePrefix = chat.titlePrefix
        preview = chat.preview
        // To the second, as encoded, so a sending copy and its confirmed message are one change.
        timestamp = chat.timestamp.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        unreadCount = chat.unreadCount
        isMuted = chat.isMuted
        self.isArchived = isArchived
    }
}

private struct ConnectionError: Encodable {
    let label: String
    let network: String
    let error: String
}

private struct ChatsResult: Encodable {
    let chats: [ChatRow]
    let errors: [ConnectionError]
}

private struct ReadResult: Encodable {
    let chat: ChatRow
    let unreadCount: Int
    let messages: [ChatControlMessage]
}

private struct SendResult: Encodable {
    let chat: ChatRow
    let message: ChatControlMessage?
}

private struct MarkReadResult: Encodable {
    let chat: ChatRow
    let markedCount: Int
}

private struct WatchResult: Encodable {
    let chat: ChatRow?
}

private struct ChatControlMessage: Encodable {
    struct Sender: Encodable {
        let id: String
        let name: String
    }

    struct Embed: Encodable {
        let type: String
        var title: String?
        var text: String?
        var url: URL?
    }

    struct Reaction: Encodable {
        let emoji: String
        let count: Int
        let includesYou: Bool
    }

    let id: String
    let sender: Sender
    let timestamp: Date?
    /// With mentions by name and spoilers masked, as the chat's previews show them.
    let text: String?
    let isOwn: Bool
    let isUnread: Bool
    let isDeleted: Bool
    let isNotice: Bool
    let replyToId: String?
    let embeds: [Embed]
    let reactions: [Reaction]

    @MainActor
    init(_ message: ChatMessage, in viewModel: ChatViewModel, isUnread: Bool) {
        id = message.id
        sender = Sender(id: message.sender.id, name: message.sender.name)
        timestamp = message.timestamp
        text = message.text.map { viewModel.showingMentionNames(SpoilerText.mask($0, ranges: message.spoilers)) }
        isOwn = message.isOwn
        self.isUnread = isUnread
        isDeleted = message.isDeleted
        isNotice = message.isNotice
        replyToId = message.replyToId
        embeds = message.embeds.map { embed in
            switch embed {
            case let .image(url, _, alt, _, _): Embed(type: "image", title: alt, url: url.isFileURL ? nil : url)
            case let .pending(title): Embed(type: "pending", title: title)
            case let .card(title, subtitle, _, _, link): Embed(type: "card", title: title, text: subtitle, url: link)
            case let .audio(_, title, subtitle, _, _, link): Embed(type: "audio", title: title, text: subtitle, url: link)
            case let .message(title, text, link): Embed(type: "message", title: title, text: text, url: link)
            case let .video(url, _, _, duration, isGIF): Embed(type: isGIF ? "gif" : "video", text: duration, url: Self.webURL(url))
            case let .file(url, filename, subtitle, _): Embed(type: "file", title: filename, text: subtitle, url: Self.webURL(url))
            case let .voice(_, duration, _): Embed(type: "voice", text: duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) })
            }
        }
        reactions = (viewModel.reactions[message.id] ?? []).map { Reaction(emoji: $0.emoji, count: $0.count, includesYou: $0.includesYou) }
    }

    /// Only web links leave the app; a network's own scheme (`tgfile:`) means nothing to the caller.
    private static func webURL(_ url: URL) -> URL? {
        ["http", "https"].contains(url.scheme) ? url : nil
    }
}
