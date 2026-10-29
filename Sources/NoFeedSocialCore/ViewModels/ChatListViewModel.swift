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

    /// Prefixed with the account's id, as two accounts can share a chat.
    public internal(set) var id: String
    /// The account the chat belongs to (`Account.id`).
    public internal(set) var accountId: String
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

    /// The chat as one account's. Apron rows belong to their server's account.
    func scoped(to accountId: String?) -> ChatSummary {
        var chat = self
        let owner: String? = if case let .apron(serverURL, _) = destination {
            Account.apronId(serverURL: serverURL)
        } else {
            accountId
        }
        guard let owner, chat.accountId != owner else { return chat }
        chat.accountId = owner
        chat.id = "\(owner)|\(id)"
        return chat
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
        accountId = ""
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
    private let services: AccountServices
    /// The last loaded list, shown at launch while it refreshes, so only the very first load waits.
    private let cacheURL: URL
    private let archiveCacheURL: URL

    public init(apronSource: ApronNotificationSource, services: AccountServices, fileManager: FileManager = .default) {
        self.apronSource = apronSource
        self.services = services
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

    /// One account's (or every Apron server's) chats to load.
    private struct Loader {
        let network: SocialNetwork
        /// `nil` for Apron, whose rows name their server's account.
        let accountId: String?
        let label: String
        let chats: @MainActor @Sendable () async throws -> [ChatSummary]
        /// Archived chats, loaded after the main list succeeded.
        let archived: (@MainActor @Sendable () async throws -> [ChatSummary])?
    }

    private func loaders() -> [Loader] {
        var loaders = [Loader(network: .apron, accountId: nil, label: SocialNetwork.apron.displayName, chats: { [apronSource] in try await apronSource.chatSummaries() }, archived: nil)]
        let multiple = Dictionary(grouping: services.components, by: \.network).mapValues { $0.count > 1 }
        for component in services.components {
            let account = component.metadata.account
            let label = multiple[component.network] == true
                ? "\(component.network.displayName) \(account?.label ?? "")"
                : component.network.displayName
            let id = component.accountId
            if let source = component.spotifyMessagesSource {
                loaders.append(Loader(network: .spotify, accountId: id, label: label, chats: { try await source.chatSummaries() }, archived: nil))
            }
            if let client = component.instagramClient {
                loaders.append(Loader(network: .instagram, accountId: id, label: label, chats: { try await client.directChatSummaries() }, archived: nil))
            }
            if let client = component.telegramClient {
                loaders.append(Loader(network: .telegram, accountId: id, label: label, chats: { try await client.chatSummaries() }, archived: { try await client.chatSummaries(archived: true) }))
            }
            if let client = component.xChatClient {
                // X's archived chats come with the inbox the main list just loaded.
                loaders.append(Loader(network: .x, accountId: id, label: label, chats: { try await client.chatSummaries(archived: false) }, archived: { try await client.chatSummaries(archived: true) }))
            }
        }
        return loaders
    }

    /// Reloads every account; each keeps its previous chats when it fails.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let loaders = loaders()
        let results = await withTaskGroup(of: (Int, Result<[ChatSummary], Error>, [ChatSummary]?).self) { group in
            for (index, loader) in loaders.enumerated() {
                group.addTask {
                    let result = await Self.result(loader.chats)
                    var archived: [ChatSummary]?
                    if case .success = result, let loadArchived = loader.archived {
                        archived = try? await loadArchived()
                    }
                    return (index, result, archived)
                }
            }
            var results: [(Int, Result<[ChatSummary], Error>, [ChatSummary]?)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }

        var merged: [ChatSummary] = []
        var archived: [ChatSummary] = []
        var failures: [String] = []
        for (index, result, archivedResult) in results {
            let loader = loaders[index]
            let belongs: (ChatSummary) -> Bool = { chat in
                loader.accountId.map { chat.accountId == $0 } ?? (chat.network == loader.network)
            }
            switch result {
            case let .success(summaries):
                merged += summaries.map { $0.scoped(to: loader.accountId) }
            case let .failure(error):
                merged += chats.filter(belongs)
                // A reload cut short (such as by opening a chat) isn't a failure worth showing.
                if !Self.isCancellation(error) {
                    failures.append("\(loader.label): \(error.localizedDescription)")
                }
            }
            // A failed archive keeps its rows; the main list's failure already reports the account.
            if let archivedResult {
                archived += archivedResult.map { $0.scoped(to: loader.accountId) }
            } else {
                archived += archivedChats.filter(belongs)
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        setChats(merged)
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
        setChats(others + summaries.map { $0.scoped(to: nil) })
    }

    /// Rows rebuilt for chats with new messages, replacing those chats' rows. `accountId` names the account
    /// they came from; Apron rows know their server's.
    public func updateChats(_ summaries: [ChatSummary], accountId: String? = nil) {
        let summaries = summaries.map { $0.scoped(to: accountId) }
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

    private static func result(_ load: @MainActor @Sendable () async throws -> [ChatSummary]) async -> Result<[ChatSummary], Error> {
        do {
            return try await .success(load())
        } catch SourceError.notConfigured {
            return .success([])
        } catch {
            return .failure(error)
        }
    }
}
