import Foundation

/// One conversation in the Chats list. `Destination` is the app's id for a chat across its networks, which it
/// turns into the chat when the row is opened.
public struct ChatSummary<Destination: Hashable & Codable & Sendable>: Identifiable, Hashable, Codable, Sendable {
    /// Prefixed with the account's id, as two accounts can share a chat.
    public internal(set) var id: String
    /// The account the chat belongs to (`Account.id`).
    public internal(set) var accountId: String
    public let network: ChatNetwork
    public let title: String
    /// Shown muted before the title, as "<prefix> / <title>", such as the Apron server a room is on.
    public let titlePrefix: String?
    /// Shown under the title when there is no message yet.
    public let subtitle: String?
    public let avatarURL: URL?
    /// Colors the initials that stand in for a missing picture, as in Telegram: the other person's id in a DM
    /// (the id their messages carry, so it matches their bubbles), else the chat's own.
    public let avatarColorKey: String?
    /// The latest message, prefixed with "You: " or the sender in a group.
    public var preview: String?
    public var timestamp: Date?
    public var unreadCount: Int
    public let destination: Destination
    /// Whether previews of others' messages start with the sender's name: in rooms and groups, not in DMs.
    public let namesSenderInPreview: Bool
    /// Whether the title is a person's name or a list of members' names, which "Redact names" hides.
    public let titleNamesPeople: Bool
    /// Optional so chat lists cached before it existed still decode.
    private let muted: Bool?
    /// Optional so chat lists cached before it existed still decode.
    private var unseenReactions: Int?
    /// The other person's presence in a one-to-one chat, so the chat opens showing it.
    public let presence: ChatPresence?

    /// Whether the user muted the chat on its network, so its unread count is shown quietly.
    public var isMuted: Bool {
        muted == true
    }

    /// Messages of the user's that others reacted to since the user last saw them.
    public internal(set) var unseenReactionCount: Int {
        get { unseenReactions ?? 0 }
        set { unseenReactions = newValue }
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
        network: ChatNetwork,
        title: String,
        titlePrefix: String? = nil,
        subtitle: String? = nil,
        avatarURL: URL?,
        avatarColorKey: String? = nil,
        preview: String?,
        timestamp: Date?,
        unreadCount: Int,
        unseenReactionCount: Int = 0,
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
        self.titlePrefix = titlePrefix
        self.subtitle = subtitle
        self.avatarURL = avatarURL
        self.avatarColorKey = avatarColorKey
        self.preview = preview
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        unseenReactions = unseenReactionCount
        self.destination = destination
        self.namesSenderInPreview = namesSenderInPreview
        self.titleNamesPeople = titleNamesPeople
        muted = isMuted
        self.presence = presence
    }
}

/// One network's rows for the Chats list.
public struct ChatListPage<Destination: Hashable & Codable & Sendable>: Sendable {
    public let chats: [ChatSummary<Destination>]
    /// The chats the user archived on the network; `nil` when the archive didn't load, so the rows already
    /// listed stay. Networks without an archive return none.
    public let archived: [ChatSummary<Destination>]?
    /// The accounts a provider without one lists apart, such as each Apron server, with how each one's load
    /// went; `nil` when the page is all one account's.
    public let accounts: [AccountResult]?

    public struct AccountResult: Sendable {
        public let accountId: String
        public let label: String
        /// Why the account's rows didn't load; `nil` when they did.
        public let error: Error?
        /// Whether the rows already listed for the account are current, kept so by a live connection; the page
        /// then has none of them and the list keeps them, so a reload doesn't read them again.
        public let isCurrent: Bool

        public init(accountId: String, label: String, error: Error?, isCurrent: Bool = false) {
            self.accountId = accountId
            self.label = label
            self.error = error
            self.isCurrent = isCurrent
        }
    }

    public init(chats: [ChatSummary<Destination>], archived: [ChatSummary<Destination>]?, accounts: [AccountResult]? = nil) {
        self.chats = chats
        self.archived = archived
        self.accounts = accounts
    }
}

/// A chat network's part of the Chats list. Each network conforms its client or source; the list knows networks
/// only through this.
public protocol ChatListProvider<Destination>: Sendable {
    associatedtype Destination: Hashable & Codable & Sendable

    var chatNetwork: ChatNetwork { get }
    /// The network's rows. Throws a `ChatNotConnectedError` when the network isn't connected, which lists none.
    func chatList() async throws -> ChatListPage<Destination>
}

/// A provider that finds the chat a notification or link names when it isn't listed under exactly that
/// destination, or stands in for one the list doesn't have yet.
public protocol ChatListResolving<Destination>: ChatListProvider {
    /// The chat among `chats` (this provider's rows) that `destination` names, or a row standing in for it;
    /// `nil` when the destination isn't this provider's.
    @MainActor func chat(for destination: Destination, in chats: [ChatSummary<Destination>]) -> ChatSummary<Destination>?
}

/// One account's provider, as the Chats list loads it.
public struct ChatListSource<Destination: Hashable & Codable & Sendable> {
    public let provider: any ChatListProvider<Destination>
    /// The account the rows belong to; `nil` when the provider names each row's account itself, as Apron's
    /// does for its servers.
    public let accountId: String?
    /// Names the account in errors, such as "Telegram" or, with several, "Telegram Alice".
    public let label: String

    public init(provider: any ChatListProvider<Destination>, accountId: String?, label: String) {
        self.provider = provider
        self.accountId = accountId
        self.label = label
    }

    /// Whether the row is this source's. Without an account, the source's rows are those of its network, such
    /// as every Apron server's.
    func owns(_ chat: ChatSummary<Destination>) -> Bool {
        accountId.map { chat.accountId == $0 } ?? (chat.network == provider.chatNetwork)
    }
}

/// How one connection's chats last loaded, for the Chats list's status indicator.
public struct ChatConnectionStatus: Identifiable, Equatable, Sendable {
    /// The account id, or the network's name for a provider that lists no accounts apart.
    public let id: String
    public let network: ChatNetwork
    public let label: String
    /// Why the last load failed; `nil` when it loaded.
    public let error: String?
}

/// Every chat across every account's chat networks, newest first.
@MainActor
public final class ChatListViewModel<Destination: Hashable & Codable & Sendable>: ObservableObject {
    public typealias Summary = ChatSummary<Destination>

    @Published public private(set) var chats: [Summary] = []
    /// Chats the user archived on their network (Telegram's Archive folder, archived X chats), shown apart from
    /// `chats`.
    @Published public private(set) var archivedChats: [Summary] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    /// Every connected account as of the last load, in source order, with the reason for any failure.
    /// Accounts that aren't connected aren't listed.
    @Published public private(set) var connections: [ChatConnectionStatus] = []

    /// Each open chat's latest row state, numbered by `followedUpdateCount` when it came. A load that began
    /// before an update keeps it, rather than putting back what it fetched earlier: at launch from a notification,
    /// the first load can finish after the opened chat was read.
    private var followedRows: [String: FollowedRow] = [:]
    private var followedUpdateCount = 0

    private struct FollowedRow {
        let update: Int
        let latest: ChatMessage?
        let body: String?
        let unreadCount: Int
        let unseenReactionCount: Int?
    }

    /// The accounts' providers as of each load, since accounts come and go.
    private let sources: () -> [ChatListSource<Destination>]
    /// The last loaded list, shown at launch while it refreshes, so only the very first load waits.
    private let cacheURL: URL
    private let archiveCacheURL: URL

    public init(sources: @escaping () -> [ChatListSource<Destination>], caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        self.sources = sources
        cacheURL = caches.appending(path: "chat-list.json")
        archiveCacheURL = caches.appending(path: "chat-list-archived.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([Summary].self, from: data) {
            chats = cached
            hasLoaded = true
        }
        if let data = try? Data(contentsOf: archiveCacheURL), let cached = try? JSONDecoder().decode([Summary].self, from: data) {
            archivedChats = cached
        }
    }

    /// The chat a notification or link names: the listed one, else what its provider finds or stands in for.
    public func chat(for destination: Destination) -> Summary? {
        let all = chats + archivedChats
        if let listed = all.first(where: { $0.destination == destination }) {
            return listed
        }
        for source in sources() {
            guard let provider = source.provider as? any ChatListResolving<Destination>,
                  let chat = provider.chat(for: destination, in: all.filter(source.owns)) else { continue }
            return chat.scoped(to: source.accountId)
        }
        return nil
    }

    /// Reloads every account at once; each keeps its previous chats when it fails.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let startedAfter = followedUpdateCount
        let sources = sources()
        let providers = sources.map(\.provider)
        let results = await withTaskGroup(of: (Int, Result<ChatListPage<Destination>, Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, Self.result { try await provider.chatList() }) }
            }
            var results: [Result<ChatListPage<Destination>, Error>?] = Array(repeating: nil, count: providers.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap(\.self)
        }

        var merged: [Summary] = []
        var archived: [Summary] = []
        var statuses: [ChatConnectionStatus] = []
        let previous = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func status(id: String, network: ChatNetwork, label: String, error: Error?) -> ChatConnectionStatus {
            // A reload cut short (such as by opening a chat) isn't a failure worth showing; the last status stays.
            if let error, Self.isCancellation(error) {
                return previous[id] ?? ChatConnectionStatus(id: id, network: network, label: label, error: nil)
            }
            return ChatConnectionStatus(id: id, network: network, label: label, error: error?.localizedDescription)
        }
        for (source, result) in zip(sources, results) {
            let network = source.provider.chatNetwork
            let sourceId = source.accountId ?? network.rawValue
            switch result {
            case let .success(page):
                merged += page.chats.map { $0.scoped(to: source.accountId) }
                if let pageArchived = page.archived {
                    archived += pageArchived.map { $0.scoped(to: source.accountId) }
                } else {
                    archived += archivedChats.filter(source.owns)
                }
                guard let accounts = page.accounts else {
                    statuses.append(status(id: sourceId, network: network, label: source.label, error: nil))
                    continue
                }
                for account in accounts {
                    statuses.append(status(id: account.accountId, network: network, label: account.label, error: account.error))
                    // An account that failed, or whose rows are kept current, keeps the rows it had.
                    if account.error != nil || account.isCurrent {
                        merged += chats.filter { $0.accountId == account.accountId }
                        archived += archivedChats.filter { $0.accountId == account.accountId }
                    }
                }
            case let .failure(error):
                merged += chats.filter(source.owns)
                archived += archivedChats.filter(source.owns)
                statuses.append(status(id: sourceId, network: network, label: source.label, error: error))
            }
        }
        connections = statuses
        followedRows = followedRows.filter { $0.value.update > startedAfter }
        setChats(merged.map(keepingFollowedState))
        setArchivedChats(archived.map(keepingFollowedState))
    }

    /// The row as its open chat last reported it, for updates the finishing load doesn't include.
    private func keepingFollowedState(_ chat: Summary) -> Summary {
        guard let row = followedRows[chat.id] else { return chat }
        return Self.updated(chat, latest: row.latest, body: row.body, unreadCount: row.unreadCount, unseenReactionCount: row.unseenReactionCount)
    }

    /// Keeps the chat's row current while it is open, so returning to the list shows its latest message and
    /// read state without waiting for the reload.
    public func follow<ViewModel: ChatViewModel>(_ viewModel: ViewModel, chatId: String) -> ViewModel {
        viewModel.summaryDidChange = { [weak self] latest, body, unreadCount, unseenReactionCount in
            guard let self else { return }
            followedUpdateCount += 1
            followedRows[chatId] = FollowedRow(update: followedUpdateCount, latest: latest, body: body, unreadCount: unreadCount, unseenReactionCount: unseenReactionCount)
            updateChat(id: chatId, latest: latest, body: body, unreadCount: unreadCount, unseenReactionCount: unseenReactionCount)
        }
        return viewModel
    }

    private func updateChat(id: String, latest: ChatMessage?, body: String?, unreadCount: Int, unseenReactionCount: Int?) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let chat = Self.updated(chats[index], latest: latest, body: body, unreadCount: unreadCount, unseenReactionCount: unseenReactionCount)
            guard chat != chats[index] else { return }
            var updated = chats
            updated[index] = chat
            setChats(updated)
        } else if let index = archivedChats.firstIndex(where: { $0.id == id }) {
            let chat = Self.updated(archivedChats[index], latest: latest, body: body, unreadCount: unreadCount, unseenReactionCount: unseenReactionCount)
            guard chat != archivedChats[index] else { return }
            var updated = archivedChats
            updated[index] = chat
            setArchivedChats(updated)
        }
    }

    /// `unseenReactionCount` is `nil` for chats that don't track unseen reactions, which keep the row's.
    private static func updated(_ chat: Summary, latest: ChatMessage?, body: String?, unreadCount: Int, unseenReactionCount: Int?) -> Summary {
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
        if let unseenReactionCount {
            chat.unseenReactionCount = unseenReactionCount
        }
        return chat
    }

    /// Whether the chat is listed, such as an Apron room the user has joined.
    public func contains(_ destination: Destination) -> Bool {
        (chats + archivedChats).contains { $0.destination == destination }
    }

    /// Replaces a set of rows that a live connection rebuilt, such as one Apron server's rooms. The rows name
    /// their account.
    public func replaceChats(where isReplaced: (Summary) -> Bool, with summaries: [Summary]) {
        setChats(chats.filter { !isReplaced($0) } + summaries)
    }

    /// Rows rebuilt for chats with new messages, replacing those chats' rows. `accountId` names the account
    /// they came from, unless the rows already do.
    public func updateChats(_ summaries: [Summary], accountId: String? = nil) {
        let summaries = summaries.map { $0.scoped(to: accountId) }
        let ids = Set(summaries.map(\.id))
        replaceChats(where: { ids.contains($0.id) }, with: summaries)
    }

    private func setChats(_ summaries: [Summary]) {
        chats = summaries.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        hasLoaded = true
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func setArchivedChats(_ summaries: [Summary]) {
        archivedChats = summaries.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        if let data = try? JSONEncoder().encode(archivedChats) {
            try? data.write(to: archiveCacheURL, options: .atomic)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private nonisolated static func result(_ load: () async throws -> ChatListPage<Destination>) async -> Result<ChatListPage<Destination>, Error> {
        do {
            return try await .success(load())
        } catch let error as any ChatNotConnectedError where error.isNotConnected {
            return .success(ChatListPage(chats: [], archived: [], accounts: []))
        } catch {
            return .failure(error)
        }
    }
}
