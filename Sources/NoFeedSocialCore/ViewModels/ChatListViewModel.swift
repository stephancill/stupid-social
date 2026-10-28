import Foundation

/// One conversation in the Chats list.
public struct ChatSummary: Identifiable, Hashable, Codable, Sendable {
    public enum Destination: Hashable, Codable, Sendable {
        case apron(serverURL: URL, roomId: String)
        /// The base62 id from `spotify:chat:<id>`.
        case spotify(chatId: String)
        /// The id in `/direct/t/<thread_fbid>/`.
        case instagram(threadFbid: String)
        case telegram(peer: TelegramPeer)
        /// An XChat conversation id: "<user id>:<user id>" for one-to-one chats.
        case x(conversationId: String)
    }

    public let id: String
    public let network: SocialNetwork
    public let title: String
    /// Shown under the title when there is no message yet, such as the Apron server.
    public let subtitle: String?
    public let avatarURL: URL?
    /// The latest message, prefixed with "You: " or the sender in a group.
    public internal(set) var preview: String?
    public internal(set) var timestamp: Date?
    public internal(set) var unreadCount: Int
    public let destination: Destination
    /// Whether previews of others' messages start with the sender's name: in rooms and groups, not in DMs.
    public let namesSenderInPreview: Bool
    /// Whether the title is a person's name or a list of members' names, which "Redact names" hides.
    public let titleNamesPeople: Bool
    /// Optional so chat lists cached before it existed still decode.
    private let muted: Bool?
    /// The other person's last-seen status in a Telegram private chat, so the chat opens showing it.
    public let telegramUserStatus: TelegramMember.Status?

    /// Whether the user muted the chat on its network, so its unread count is shown quietly.
    public var isMuted: Bool {
        muted == true
    }

    public init(
        id: String,
        network: SocialNetwork,
        title: String,
        subtitle: String? = nil,
        avatarURL: URL?,
        preview: String?,
        timestamp: Date?,
        unreadCount: Int,
        destination: Destination,
        namesSenderInPreview: Bool = true,
        titleNamesPeople: Bool = false,
        isMuted: Bool = false,
        telegramUserStatus: TelegramMember.Status? = nil,
    ) {
        self.id = id
        self.network = network
        self.title = title
        self.subtitle = subtitle
        self.avatarURL = avatarURL
        self.preview = preview
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.destination = destination
        self.namesSenderInPreview = namesSenderInPreview
        self.titleNamesPeople = titleNamesPeople
        muted = isMuted
        self.telegramUserStatus = telegramUserStatus
    }
}

/// Every chat across Apron servers, Spotify Messages, Instagram Direct, Telegram and X Chat, newest first.
@MainActor
public final class ChatListViewModel: ObservableObject {
    @Published public private(set) var chats: [ChatSummary] = []
    /// Chats the user archived on their network (Telegram's Archive folder, archived X chats), shown apart from
    /// `chats`.
    @Published public private(set) var archivedChats: [ChatSummary] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    /// Networks that failed to load, with the reason.
    @Published public private(set) var errorMessage: String?

    private let apronSource: ApronNotificationSource
    private let spotifySource: SpotifyMessagesSource
    private let instagramClient: InstagramClient
    private let telegramClient: TelegramClient
    private let xChatClient: XChatClient
    /// The last loaded list, shown at launch while it refreshes, so only the very first load waits.
    private let cacheURL: URL
    private let archiveCacheURL: URL

    public init(apronSource: ApronNotificationSource, spotifySource: SpotifyMessagesSource, instagramClient: InstagramClient, telegramClient: TelegramClient, xChatClient: XChatClient, fileManager: FileManager = .default) {
        self.apronSource = apronSource
        self.spotifySource = spotifySource
        self.instagramClient = instagramClient
        self.telegramClient = telegramClient
        self.xChatClient = xChatClient
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appending(path: "chat-list.json")
        archiveCacheURL = caches.appending(path: "chat-list-archived.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            chats = cached
            hasLoaded = true
        }
        if let data = try? Data(contentsOf: archiveCacheURL), let cached = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            archivedChats = cached
        }
    }

    /// Reloads every network; each keeps its previous chats when it fails.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let apron = Self.result { try await self.apronSource.chatSummaries() }
        async let spotify = Self.result { try await self.spotifySource.chatSummaries() }
        async let instagram = Self.result { try await self.instagramClient.directChatSummaries() }
        async let telegram = Self.result { try await self.telegramClient.chatSummaries() }
        async let telegramArchive = Self.result { try await self.telegramClient.chatSummaries(archived: true) }
        async let x = Self.result { try await self.xChatClient.chatSummaries(archived: false) }
        let results: [(SocialNetwork, Result<[ChatSummary], Error>)] = await [(.apron, apron), (.spotify, spotify), (.instagram, instagram), (.telegram, telegram), (.x, x)]

        var merged: [ChatSummary] = []
        var failures: [String] = []
        for (network, result) in results {
            switch result {
            case let .success(summaries):
                merged += summaries
            case let .failure(error):
                merged += chats.filter { $0.network == network }
                // A reload cut short (such as by opening a chat) isn't a failure worth showing.
                if !Self.isCancellation(error) {
                    failures.append("\(network.displayName): \(error.localizedDescription)")
                }
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        setChats(merged)
        // A failed archive keeps its rows; the main list's failure already reports the network.
        var archived = archivedChats
        if case let .success(summaries) = await telegramArchive {
            archived = archived.filter { $0.network != .telegram } + summaries
        }
        // X's archived chats come with the inbox the main list just loaded.
        if case .success = await x, let summaries = try? await xChatClient.chatSummaries(archived: true) {
            archived = archived.filter { $0.network != .x } + summaries
        }
        setArchivedChats(archived)
    }

    /// Keeps the chat's row current while it is open, so returning to the list shows its latest message and
    /// read state without waiting for the reload.
    public func follow<ViewModel: ChatViewModel>(_ viewModel: ViewModel, chatId: String) -> ViewModel {
        viewModel.summaryDidChange = { [weak self] latest, body, unreadCount in
            self?.updateChat(id: chatId, latest: latest, body: body, unreadCount: unreadCount)
        }
        return viewModel
    }

    private func updateChat(id: String, latest: ChatMessage?, body: String?, unreadCount: Int) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let chat = Self.updated(chats[index], latest: latest, body: body, unreadCount: unreadCount)
            guard chat != chats[index] else { return }
            var updated = chats
            updated[index] = chat
            setChats(updated)
        } else if let index = archivedChats.firstIndex(where: { $0.id == id }) {
            let chat = Self.updated(archivedChats[index], latest: latest, body: body, unreadCount: unreadCount)
            guard chat != archivedChats[index] else { return }
            var updated = archivedChats
            updated[index] = chat
            setArchivedChats(updated)
        }
    }

    private static func updated(_ chat: ChatSummary, latest: ChatMessage?, body: String?, unreadCount: Int) -> ChatSummary {
        var chat = chat
        if let latest, let body {
            chat.preview = if latest.isOwn {
                "You: \(body)"
            } else if chat.namesSenderInPreview {
                "\(latest.sender.name): \(body)"
            } else {
                body
            }
            chat.timestamp = latest.timestamp ?? chat.timestamp
        }
        chat.unreadCount = unreadCount
        return chat
    }

    /// Whether the chat is listed, such as an Apron room the user has joined.
    public func contains(_ destination: ChatSummary.Destination) -> Bool {
        (chats + archivedChats).contains { $0.destination == destination }
    }

    /// One Apron server's rooms, rebuilt by the live connection when its rooms change.
    public func replaceApronChats(serverURL: URL, with summaries: [ChatSummary]) {
        let others = chats.filter { chat in
            guard case let .apron(chatServerURL, _) = chat.destination else { return true }
            return chatServerURL != serverURL
        }
        setChats(others + summaries)
    }

    /// Rows rebuilt for rooms with new messages, replacing those rooms' rows.
    public func updateChats(_ summaries: [ChatSummary]) {
        let ids = Set(summaries.map(\.id))
        setChats(chats.filter { !ids.contains($0.id) } + summaries)
    }

    private func setChats(_ summaries: [ChatSummary]) {
        chats = summaries.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        hasLoaded = true
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func setArchivedChats(_ summaries: [ChatSummary]) {
        archivedChats = summaries.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        if let data = try? JSONEncoder().encode(archivedChats) {
            try? data.write(to: archiveCacheURL, options: .atomic)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func result(_ load: @escaping () async throws -> [ChatSummary]) async -> Result<[ChatSummary], Error> {
        do {
            return try await .success(load())
        } catch SourceError.notConfigured {
            return .success([])
        } catch {
            return .failure(error)
        }
    }
}
