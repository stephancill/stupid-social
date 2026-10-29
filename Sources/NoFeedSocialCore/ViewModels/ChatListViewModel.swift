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
    /// The other person's presence in a one-to-one chat, so the chat opens showing it.
    public let presence: ChatPresence?

    /// Whether the user muted the chat on its network, so its unread count is shown quietly.
    public var isMuted: Bool {
        muted == true
    }

    /// The chat as one account's; `nil` keeps the account a provider already set, such as an Apron server's.
    public func scoped(to accountId: String?) -> ChatSummary {
        var chat = self
        guard let owner = accountId, chat.accountId != owner else { return chat }
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
        presence: ChatPresence? = nil,
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
        self.presence = presence
    }
}

/// One network's rows for the Chats list.
public struct ChatListPage: Sendable {
    public let chats: [ChatSummary]
    /// The chats the user archived on the network; `nil` when the archive didn't load, so the rows already
    /// listed stay. Networks without an archive return none.
    public let archived: [ChatSummary]?
    /// The accounts a provider without one lists apart, such as each Apron server, with how each one's load
    /// went; `nil` when the page is all one account's.
    public let accounts: [AccountResult]?

    public struct AccountResult: Sendable {
        public let accountId: String
        public let label: String
        /// Why the account's rows didn't load; `nil` when they did.
        public let error: Error?

        public init(accountId: String, label: String, error: Error?) {
            self.accountId = accountId
            self.label = label
            self.error = error
        }
    }

    public init(chats: [ChatSummary], archived: [ChatSummary]?, accounts: [AccountResult]? = nil) {
        self.chats = chats
        self.archived = archived
        self.accounts = accounts
    }
}

/// A chat network's part of the Chats list. Each network conforms its client or source; the list knows networks
/// only through this.
public protocol ChatListProvider: Sendable {
    var network: SocialNetwork { get }
    /// The network's rows. Throws `SourceError.notConfigured` when the network isn't connected, which lists none.
    func chatList() async throws -> ChatListPage
}

/// One account's provider, as the Chats list loads it.
public struct ChatListSource {
    public let provider: any ChatListProvider
    /// The account the rows belong to; `nil` when the provider names each row's account itself, as Apron's
    /// does for its servers.
    public let accountId: String?
    /// Names the account in errors, such as "Telegram" or, with several, "Telegram Alice".
    public let label: String

    public init(provider: any ChatListProvider, accountId: String?, label: String) {
        self.provider = provider
        self.accountId = accountId
        self.label = label
    }
}

/// How one connection's chats last loaded, for the Chats list's status indicator.
public struct ChatConnectionStatus: Identifiable, Equatable, Sendable {
    /// The account id, or the network's name for a provider that lists no accounts apart.
    public let id: String
    public let network: SocialNetwork
    public let label: String
    /// Why the last load failed; `nil` when it loaded.
    public let error: String?
}

/// Every chat across every account's chat networks, newest first.
@MainActor
public final class ChatListViewModel: ObservableObject {
    @Published public private(set) var chats: [ChatSummary] = []
    /// Chats the user archived on their network (Telegram's Archive folder, archived X chats), shown apart from
    /// `chats`.
    @Published public private(set) var archivedChats: [ChatSummary] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    /// Every connected account as of the last load, in source order, with the reason for any failure.
    /// Accounts that aren't connected aren't listed.
    @Published public private(set) var connections: [ChatConnectionStatus] = []

    /// The accounts' providers as of each load, since accounts come and go.
    private let sources: () -> [ChatListSource]
    /// The last loaded list, shown at launch while it refreshes, so only the very first load waits.
    private let cacheURL: URL
    private let archiveCacheURL: URL

    public init(sources: @escaping () -> [ChatListSource], caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        self.sources = sources
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

    /// Reloads every account at once; each keeps its previous chats when it fails.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let sources = sources()
        let providers = sources.map(\.provider)
        let results = await withTaskGroup(of: (Int, Result<ChatListPage, Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, Self.result { try await provider.chatList() }) }
            }
            var results: [Result<ChatListPage, Error>?] = Array(repeating: nil, count: providers.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap(\.self)
        }

        var merged: [ChatSummary] = []
        var archived: [ChatSummary] = []
        var statuses: [ChatConnectionStatus] = []
        let previous = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func status(id: String, network: SocialNetwork, label: String, error: Error?) -> ChatConnectionStatus {
            // A reload cut short (such as by opening a chat) isn't a failure worth showing; the last status stays.
            if let error, Self.isCancellation(error) {
                return previous[id] ?? ChatConnectionStatus(id: id, network: network, label: label, error: nil)
            }
            return ChatConnectionStatus(id: id, network: network, label: label, error: error?.localizedDescription)
        }
        for (source, result) in zip(sources, results) {
            let network = source.provider.network
            // Without an account, the source's rows are those of its network, such as every Apron server's.
            let belongs: (ChatSummary) -> Bool = { chat in
                source.accountId.map { chat.accountId == $0 } ?? (chat.network == network)
            }
            let sourceId = source.accountId ?? network.rawValue
            switch result {
            case let .success(page):
                merged += page.chats.map { $0.scoped(to: source.accountId) }
                if let pageArchived = page.archived {
                    archived += pageArchived.map { $0.scoped(to: source.accountId) }
                } else {
                    archived += archivedChats.filter(belongs)
                }
                guard let accounts = page.accounts else {
                    statuses.append(status(id: sourceId, network: network, label: source.label, error: nil))
                    continue
                }
                for account in accounts {
                    statuses.append(status(id: account.accountId, network: network, label: account.label, error: account.error))
                    // An account that failed keeps the rows it had.
                    if account.error != nil {
                        merged += chats.filter { $0.accountId == account.accountId }
                        archived += archivedChats.filter { $0.accountId == account.accountId }
                    }
                }
            case let .failure(error):
                merged += chats.filter(belongs)
                archived += archivedChats.filter(belongs)
                statuses.append(status(id: sourceId, network: network, label: source.label, error: error))
            }
        }
        connections = statuses
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

    /// Replaces a set of rows that a live connection rebuilt, such as one Apron server's rooms. The rows name
    /// their account.
    public func replaceChats(where isReplaced: (ChatSummary) -> Bool, with summaries: [ChatSummary]) {
        setChats(chats.filter { !isReplaced($0) } + summaries)
    }

    /// Rows rebuilt for chats with new messages, replacing those chats' rows. `accountId` names the account
    /// they came from, unless the rows already do.
    public func updateChats(_ summaries: [ChatSummary], accountId: String? = nil) {
        let summaries = summaries.map { $0.scoped(to: accountId) }
        let ids = Set(summaries.map(\.id))
        replaceChats(where: { ids.contains($0.id) }, with: summaries)
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

    private nonisolated static func result(_ load: () async throws -> ChatListPage) async -> Result<ChatListPage, Error> {
        do {
            return try await .success(load())
        } catch SourceError.notConfigured {
            return .success(ChatListPage(chats: [], archived: [], accounts: []))
        } catch {
            return .failure(error)
        }
    }
}
