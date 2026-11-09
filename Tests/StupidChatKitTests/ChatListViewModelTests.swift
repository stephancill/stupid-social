import Foundation
@testable import StupidChatKit
import XCTest

/// An app's destinations, as the tests need them.
private enum TestDestination: Hashable, Codable {
    case spotify(chatId: String)
    case apron(serverURL: URL, roomId: String)
}

private typealias ChatSummary = StupidChatKit.ChatSummary<TestDestination>
private typealias ChatListPage = StupidChatKit.ChatListPage<TestDestination>
private typealias ChatListSource = StupidChatKit.ChatListSource<TestDestination>
private typealias ChatListViewModel = StupidChatKit.ChatListViewModel<TestDestination>

@MainActor
final class ChatListViewModelTests: XCTestCase {
    private var caches: URL!

    override func setUp() {
        caches = FileManager.default.temporaryDirectory.appending(path: "ChatListViewModelTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: caches)
    }

    func testMergesEveryAccountNewestFirst() async {
        let list = makeList([
            (FakeProvider(network: .spotify, page: .init(chats: [row("s", .spotify, minutesAgo: 5)], archived: [])), "spotify"),
            (FakeProvider(network: .telegram, page: .init(chats: [row("t", .telegram, minutesAgo: 1)], archived: [row("ta", .telegram, minutesAgo: 9)])), "telegram"),
        ])
        await list.load()
        XCTAssertEqual(list.chats.map(\.id), ["telegram|t", "spotify|s"])
        XCTAssertEqual(list.chats.map(\.accountId), ["telegram", "spotify"])
        XCTAssertEqual(list.archivedChats.map(\.id), ["telegram|ta"])
        XCTAssertEqual(list.connections.map(\.id), ["spotify", "telegram"])
        XCTAssertTrue(list.connections.allSatisfy { $0.error == nil })
    }

    func testTwoAccountsListTheSameChatApart() async {
        let shared = row("group", .telegram, minutesAgo: 1)
        let list = makeList([
            (FakeProvider(network: .telegram, page: .init(chats: [shared], archived: [])), "telegram-1"),
            (FakeProvider(network: .telegram, page: .init(chats: [shared], archived: [])), "telegram-2"),
        ])
        await list.load()
        XCTAssertEqual(Set(list.chats.map(\.id)), ["telegram-1|group", "telegram-2|group"])
    }

    func testAFailingAccountKeepsItsRowsAndIsReported() async {
        let first = FakeProvider(network: .telegram, page: .init(chats: [row("t1", .telegram, minutesAgo: 1)], archived: [row("ta", .telegram, minutesAgo: 2)]))
        let second = FakeProvider(network: .telegram, page: .init(chats: [row("t2", .telegram, minutesAgo: 3)], archived: []))
        let list = ChatListViewModel(sources: {
            [ChatListSource(provider: first, accountId: "telegram-1", label: "Telegram Alice"), ChatListSource(provider: second, accountId: "telegram-2", label: "Telegram Bob")]
        }, caches: caches)
        await list.load()
        first.error = URLError(.notConnectedToInternet)
        second.page = .init(chats: [], archived: [])
        await list.load()
        XCTAssertEqual(list.chats.map(\.id), ["telegram-1|t1"], "the other Telegram account's rows go, the failing one's stay")
        XCTAssertEqual(list.archivedChats.map(\.id), ["telegram-1|ta"])
        XCTAssertEqual(list.connections.map(\.label), ["Telegram Alice", "Telegram Bob"])
        XCTAssertNotNil(list.connections[0].error)
        XCTAssertNil(list.connections[1].error)
    }

    func testAnArchiveThatDidNotLoadKeepsItsRows() async {
        let telegram = FakeProvider(network: .telegram, page: .init(chats: [], archived: [row("ta", .telegram, minutesAgo: 2)]))
        let list = makeList([(telegram, "telegram")])
        await list.load()
        telegram.page = .init(chats: [row("t", .telegram, minutesAgo: 1)], archived: nil)
        await list.load()
        XCTAssertEqual(list.chats.map(\.id), ["telegram|t"])
        XCTAssertEqual(list.archivedChats.map(\.id), ["telegram|ta"])
    }

    func testAnAccountThatIsNotConnectedListsNothing() async {
        let x = FakeProvider(network: .x, page: .init(chats: [row("x", .x, minutesAgo: 1)], archived: [row("xa", .x, minutesAgo: 2)]))
        let list = makeList([(x, "x")])
        await list.load()
        x.error = NotConnected()
        await list.load()
        XCTAssertTrue(list.chats.isEmpty)
        XCTAssertTrue(list.archivedChats.isEmpty)
        XCTAssertTrue(list.connections.isEmpty, "an account that isn't connected has no status")
    }

    func testRowsThatNameTheirAccountKeepItAndAFailureKeepsThemByNetwork() async throws {
        let one = try XCTUnwrap(URL(string: "wss://one.example"))
        let two = try XCTUnwrap(URL(string: "wss://two.example"))
        let apron = FakeProvider(network: .apron, page: .init(chats: [
            row("a", .apron, minutesAgo: 1, destination: .apron(serverURL: one, roomId: "a")).scoped(to: one.absoluteString),
            row("b", .apron, minutesAgo: 2, destination: .apron(serverURL: two, roomId: "b")).scoped(to: two.absoluteString),
        ], archived: []))
        let list = makeList([(apron, nil)])
        await list.load()
        XCTAssertEqual(list.chats.map(\.accountId), [one.absoluteString, two.absoluteString])
        apron.error = URLError(.timedOut)
        await list.load()
        XCTAssertEqual(list.chats.count, 2)
        list.replaceChats(where: { $0.destination == .apron(serverURL: one, roomId: "a") }, with: [])
        XCTAssertEqual(list.chats.map(\.accountId), [two.absoluteString])
    }

    func testAFailingAccountInAPageKeepsItsRowsAndIsReported() async throws {
        let one = try XCTUnwrap(URL(string: "wss://one.example"))
        let two = try XCTUnwrap(URL(string: "wss://two.example"))
        let oneId = one.absoluteString
        let twoId = two.absoluteString
        let rowOne = row("a", .apron, minutesAgo: 1, destination: .apron(serverURL: one, roomId: "a")).scoped(to: oneId)
        let rowTwo = row("b", .apron, minutesAgo: 2, destination: .apron(serverURL: two, roomId: "b")).scoped(to: twoId)
        let apron = FakeProvider(network: .apron, page: .init(chats: [rowOne, rowTwo], archived: [], accounts: [
            .init(accountId: oneId, label: "one", error: nil),
            .init(accountId: twoId, label: "two", error: nil),
        ]))
        let list = makeList([(apron, nil)])
        await list.load()
        apron.page = .init(chats: [rowOne], archived: [], accounts: [
            .init(accountId: oneId, label: "one", error: nil),
            .init(accountId: twoId, label: "two", error: URLError(.badServerResponse)),
        ])
        await list.load()
        XCTAssertEqual(list.chats.map(\.accountId), [oneId, twoId], "the failing server's rows stay")
        XCTAssertEqual(list.connections.map(\.id), [oneId, twoId])
        XCTAssertNil(list.connections[0].error)
        XCTAssertEqual(list.connections[1].error, URLError(.badServerResponse).localizedDescription)
    }

    func testACurrentAccountInAPageKeepsTheRowsItHas() async throws {
        let server = try XCTUnwrap(URL(string: "wss://one.example"))
        let accountId = server.absoluteString
        let first = row("a", .apron, minutesAgo: 5, destination: .apron(serverURL: server, roomId: "a")).scoped(to: accountId)
        let apron = FakeProvider(network: .apron, page: .init(chats: [first], archived: [], accounts: [
            .init(accountId: accountId, label: "one", error: nil),
        ]))
        let list = makeList([(apron, nil)])
        await list.load()
        // A live connection updates the row, then a reload finds its rows current.
        var live = first
        live.preview = "live"
        list.updateChats([live])
        apron.page = .init(chats: [], archived: [], accounts: [
            .init(accountId: accountId, label: "one", error: nil, isCurrent: true),
        ])
        await list.load()
        XCTAssertEqual(list.chats.map(\.preview), ["live"])
        XCTAssertEqual(list.connections.map(\.id), [accountId])
        XCTAssertNil(list.connections[0].error)
    }

    func testTheLastListShowsAtLaunch() async {
        let first = makeList([(FakeProvider(network: .spotify, page: .init(chats: [row("s", .spotify, minutesAgo: 1)], archived: [])), "spotify")])
        await first.load()
        let relaunched = makeList([])
        XCTAssertTrue(relaunched.hasLoaded)
        XCTAssertEqual(relaunched.chats.map(\.id), ["spotify|s"])
    }

    func testAListedChatOpensByItsDestination() async {
        let list = makeList([(FakeProvider(network: .spotify, page: .init(chats: [row("s", .spotify, minutesAgo: 1)], archived: [])), "spotify")])
        await list.load()
        XCTAssertEqual(list.chat(for: .spotify(chatId: "s"))?.id, "spotify|s")
        XCTAssertNil(list.chat(for: .spotify(chatId: "other")))
    }

    func testAProviderResolvesADestinationAmongItsOwnRows() async {
        let first = ResolvingFakeProvider(network: .spotify, page: .init(chats: [row("a", .spotify, minutesAgo: 1)], archived: []))
        let second = ResolvingFakeProvider(network: .spotify, page: .init(chats: [row("b", .spotify, minutesAgo: 2)], archived: []))
        let list = ChatListViewModel(sources: {
            [ChatListSource(provider: first, accountId: "spotify-1", label: "Spotify"), ChatListSource(provider: second, accountId: "spotify-2", label: "Spotify")]
        }, caches: caches)
        await list.load()
        XCTAssertEqual(list.chat(for: .spotify(chatId: "B"))?.id, "spotify-2|b", "each provider sees only its own rows")
        XCTAssertEqual(first.offered.map(\.id), ["spotify-1|a"])
    }

    /// At launch from a notification, the first load can finish after the opened chat was read; its counts,
    /// fetched before reading, mustn't put the unread count back.
    func testALoadThatStartedBeforeAnOpenChatUpdatedItKeepsTheChatsState() async throws {
        var unread = row("t", .telegram, minutesAgo: 1)
        unread.unreadCount = 3
        let provider = FakeProvider(network: .telegram, page: .init(chats: [unread], archived: []))
        let list = makeList([(provider, "telegram")])
        await list.load()
        XCTAssertEqual(list.chats.first?.unreadCount, 3)

        provider.isHeld = true
        let loading = Task { await list.load() }
        while !provider.isWaiting {
            await Task.yield()
        }
        let chat = try ChatViewModel(network: .telegram, chatKey: "telegram|t", title: "t", subtitle: "", canReply: true, draftStore: ChatDraftStore(defaults: XCTUnwrap(UserDefaults(suiteName: "ChatListViewModelTests-\(UUID().uuidString)"))))
        _ = list.follow(chat, chatId: "telegram|t")
        chat.summaryDidChange?(nil, nil, 0, nil)
        XCTAssertEqual(list.chats.first?.unreadCount, 0)

        provider.release()
        await loading.value
        XCTAssertEqual(list.chats.first?.unreadCount, 0, "the load's stale count overwrote the read chat")

        await list.load()
        XCTAssertEqual(list.chats.first?.unreadCount, 3, "a load started after the update is the network's latest")
    }

    private func makeList(_ providers: [(FakeProvider, String?)]) -> ChatListViewModel {
        ChatListViewModel(sources: {
            providers.map { ChatListSource(provider: $0.0, accountId: $0.1, label: $0.0.chatNetwork.rawValue) }
        }, caches: caches)
    }

    private func row(_ id: String, _ network: ChatNetwork, minutesAgo: Double, destination: TestDestination? = nil) -> ChatSummary {
        ChatSummary(
            id: id,
            network: network,
            title: id,
            avatarURL: nil,
            preview: nil,
            timestamp: Date(timeIntervalSinceNow: -minutesAgo * 60),
            unreadCount: 0,
            destination: destination ?? .spotify(chatId: id),
        )
    }
}

@MainActor
private final class FakeProvider: ChatListProvider {
    let chatNetwork: ChatNetwork
    var page: ChatListPage
    var error: Error?

    init(network: ChatNetwork, page: ChatListPage) {
        chatNetwork = network
        self.page = page
    }

    /// While set, `chatList` waits for `release()`, as a slow network does.
    var isHeld = false
    private(set) var isWaiting = false
    private var waiter: CheckedContinuation<Void, Never>?

    func chatList() async throws -> ChatListPage {
        if isHeld {
            await withCheckedContinuation { waiter = $0; isWaiting = true }
        }
        if let error {
            throw error
        }
        return page
    }

    func release() {
        isHeld = false
        isWaiting = false
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class ResolvingFakeProvider: ChatListResolving {
    let chatNetwork: ChatNetwork
    let page: ChatListPage
    private(set) var offered: [ChatSummary] = []

    init(network: ChatNetwork, page: ChatListPage) {
        chatNetwork = network
        self.page = page
    }

    func chatList() async throws -> ChatListPage {
        page
    }

    /// Matches a Spotify chat id regardless of case.
    func chat(for destination: TestDestination, in chats: [ChatSummary]) -> ChatSummary? {
        offered = chats
        guard case let .spotify(chatId) = destination else { return nil }
        return chats.first { chat in
            guard case let .spotify(listed) = chat.destination else { return false }
            return listed.lowercased() == chatId.lowercased()
        }
    }
}

private struct NotConnected: ChatNotConnectedError {
    let isNotConnected = true
}
