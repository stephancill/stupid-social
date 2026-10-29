import Foundation
@testable import NoFeedSocialCore
import XCTest

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
        x.error = SourceError.notConfigured
        await list.load()
        XCTAssertTrue(list.chats.isEmpty)
        XCTAssertTrue(list.archivedChats.isEmpty)
        XCTAssertTrue(list.connections.isEmpty, "an account that isn't connected has no status")
    }

    func testRowsThatNameTheirAccountKeepItAndAFailureKeepsThemByNetwork() async throws {
        let one = try XCTUnwrap(URL(string: "wss://one.example"))
        let two = try XCTUnwrap(URL(string: "wss://two.example"))
        let apron = FakeProvider(network: .apron, page: .init(chats: [
            row("a", .apron, minutesAgo: 1, destination: .apron(serverURL: one, roomId: "a")).scoped(to: Account.apronId(serverURL: one)),
            row("b", .apron, minutesAgo: 2, destination: .apron(serverURL: two, roomId: "b")).scoped(to: Account.apronId(serverURL: two)),
        ], archived: []))
        let list = makeList([(apron, nil)])
        await list.load()
        XCTAssertEqual(list.chats.map(\.accountId), [Account.apronId(serverURL: one), Account.apronId(serverURL: two)])
        apron.error = URLError(.timedOut)
        await list.load()
        XCTAssertEqual(list.chats.count, 2)
        list.replaceChats(where: { $0.isApronRoom(on: one) }, with: [])
        XCTAssertEqual(list.chats.map(\.accountId), [Account.apronId(serverURL: two)])
    }

    func testAFailingAccountInAPageKeepsItsRowsAndIsReported() async throws {
        let one = try XCTUnwrap(URL(string: "wss://one.example"))
        let two = try XCTUnwrap(URL(string: "wss://two.example"))
        let oneId = Account.apronId(serverURL: one)
        let twoId = Account.apronId(serverURL: two)
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
            .init(accountId: twoId, label: "two", error: ApronError.rejected(status: 503)),
        ])
        await list.load()
        XCTAssertEqual(list.chats.map(\.accountId), [oneId, twoId], "the failing server's rows stay")
        XCTAssertEqual(list.connections.map(\.id), [oneId, twoId])
        XCTAssertNil(list.connections[0].error)
        XCTAssertEqual(list.connections[1].error, ApronError.rejected(status: 503).localizedDescription)
    }

    func testTheLastListShowsAtLaunch() async {
        let first = makeList([(FakeProvider(network: .spotify, page: .init(chats: [row("s", .spotify, minutesAgo: 1)], archived: [])), "spotify")])
        await first.load()
        let relaunched = makeList([])
        XCTAssertTrue(relaunched.hasLoaded)
        XCTAssertEqual(relaunched.chats.map(\.id), ["spotify|s"])
    }

    private func makeList(_ providers: [(FakeProvider, String?)]) -> ChatListViewModel {
        ChatListViewModel(sources: {
            providers.map { ChatListSource(provider: $0.0, accountId: $0.1, label: $0.0.network.displayName) }
        }, caches: caches)
    }

    private func row(_ id: String, _ network: SocialNetwork, minutesAgo: Double, destination: ChatSummary.Destination? = nil) -> ChatSummary {
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
    let network: SocialNetwork
    var page: ChatListPage
    var error: Error?

    init(network: SocialNetwork, page: ChatListPage) {
        self.network = network
        self.page = page
    }

    func chatList() async throws -> ChatListPage {
        if let error {
            throw error
        }
        return page
    }
}
