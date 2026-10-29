import Foundation
@testable import NoFeedSocialCore
import XCTest

@MainActor
final class AdapterChatViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "AdapterChatViewModelTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConnectLoadsAndShowsTheAdaptersChat() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        XCTAssertEqual(chat.title, "Loaded")
        XCTAssertFalse(chat.canReact, "the adapter can't react")
        chat.disconnect()
    }

    func testAFailedLoadDisconnectsWithTheReason() async {
        let adapter = FakeAdapter()
        adapter.error = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
    }

    func testReactingAdaptersEnableReactions() async {
        let adapter = FakeReactingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertTrue(chat.canReact)
        await chat.toggleReaction("👍", on: "1")
        XCTAssertEqual(chat.reactions["1"]?.first?.emoji, "👍")
        chat.disconnect()
    }

    func testTheSnapshotRestoresWithItsDividerInTheFirstRender() async {
        let adapter = FakeAdapter()
        adapter.readUpTo = 1
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeAdapter()
        reopened.readUpTo = 1
        let chat = makeChat(reopened)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"], "opens with the snapshot")
        XCTAssertEqual(chat.firstUnreadMessageId, "2")
        XCTAssertEqual(chat.unreadCount, 2)
    }

    func testAdapterChangesOutsideCallsReachTheScreen() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.info.title = "Renamed"
        adapter.onChange?()
        XCTAssertEqual(chat.title, "Renamed")
        chat.disconnect()
    }

    func testSendingShowsAtOnceThenTheNetworksCopy() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Hello"
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.text), ["Hello"])
        XCTAssertEqual(chat.messages.last?.id, "sent-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "")
        chat.disconnect()
    }

    func testMarkingReadMovesTheCountAtOnceAndSendsOnce() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.unreadCount, 3)
        chat.markRead(upTo: message(2))
        chat.markRead(upTo: message(3))
        XCTAssertEqual(chat.unreadCount, 0)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.readMarks, [3])
        chat.disconnect()
    }

    func testLiveAdaptersFollowWhileOpenAndPushedMessagesShow() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 1, "connecting again while open doesn't follow twice")
        adapter.push(message(2))
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        chat.disconnect()
        XCTAssertFalse(adapter.isFollowing)
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 2, "reconnects after leaving")
        chat.disconnect()
    }

    func testALostConnectionShowsAndReconnectsOnTheNextConnect() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.onConnectionLost?(URLError(.networkConnectionLost))
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
        adapter.onConnectionLost?(nil)
        XCTAssertEqual(chat.state, .connecting, "closed by the app itself: nothing to report")
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        chat.disconnect()
    }

    func testCommandsRunWithoutASendingCopy() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "/nick ada"
        await chat.send()
        XCTAssertEqual(adapter.commands, ["/nick ada"])
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        chat.disconnect()
    }

    func testJumpingOutsideTheLoadedMessagesShowsAWindow() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(50)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.jump(to: "10")
        XCTAssertEqual(chat.jumpTarget, "10")
        XCTAssertTrue(chat.hasLaterMessages)
        await chat.jump(to: "404")
        XCTAssertEqual(chat.errorMessage, "That message is no longer available.")
        await chat.jumpToLatest()
        XCTAssertFalse(chat.hasLaterMessages)
        XCTAssertEqual(chat.messages.map(\.id), ["50"])
        chat.disconnect()
    }

    func testReferencedMessagesComeFromTheAdapter() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)]]
        adapter.referencedMessages = ["0": message(0)]
        adapter.unavailableReferences = ["-1"]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.message(withId: "0")?.text, "Message 0")
        XCTAssertTrue(chat.isUnavailableReference("-1"))
        chat.disconnect()
    }

    private func makeChat(_ adapter: FakeAdapter) -> AdapterChatViewModel<FakeAdapter> {
        let suite = "AdapterChatViewModelTests-\(UUID().uuidString)"
        return AdapterChatViewModel(
            adapter: adapter,
            accountId: "test",
            snapshotCache: ChatSnapshotCache(directory: directory),
            draftStore: ChatDraftStore(defaults: UserDefaults(suiteName: suite)!),
        )
    }
}

private func message(_ id: Int, own: Bool = false) -> ChatMessage {
    ChatMessage(id: "\(id)", sender: ChatUser(id: own ? "you" : "ada", name: own ? "You" : "Ada", avatarURL: nil), timestamp: Date(timeIntervalSince1970: Double(id)), text: "Message \(id)", isOwn: own)
}

/// Read position is a message id, like Telegram's.
@MainActor
private class FakeAdapter: ChatAdapter {
    let network = SocialNetwork.telegram
    let key = "fake:1"
    let canReply = true
    let acceptsAttachments = false
    let pollInterval: Duration? = .seconds(60)
    var onChange: (() -> Void)?
    var info = ChatInfo(title: "Fake", subtitle: "Test")
    private(set) var messages: [ChatMessage] = []
    var reactions: [String: [ChatReaction]] = [:]
    var hasEarlierMessages = false

    var pages: [[ChatMessage]] = []
    var error: Error?
    var readUpTo = 0
    private(set) var sent: [ChatOutgoing] = []
    private(set) var readMarks: [Int] = []

    func loadNewest() async throws {
        if let error {
            throw error
        }
        info.title = "Loaded"
        if !pages.isEmpty {
            messages = pages.removeFirst()
        }
    }

    func loadEarlier() async throws {}

    func append(_ message: ChatMessage) {
        messages.append(message)
    }

    func replace(with messages: [ChatMessage]) {
        self.messages = messages
    }

    func send(_ message: ChatOutgoing) async throws -> String? {
        sent.append(message)
        let id = "sent-\(sent.count)"
        messages.append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: message.text, isOwn: true))
        return id
    }

    func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int(message.id) ?? 0) > readUpTo
    }

    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let id = Int(message.id), id > readUpTo else { return nil }
        readUpTo = id
        return { [weak self] in self?.readMarks.append(id) }
    }

    func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    private struct Snapshot: Codable {
        let ids: [Int]
    }

    func snapshot() -> Data? {
        try? JSONEncoder().encode(Snapshot(ids: messages.compactMap { Int($0.id) }))
    }

    func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        messages = snapshot.ids.map { message($0) }
    }
}

@MainActor
private final class FakeLiveAdapter: FakeAdapter, ChatLiveUpdating, ChatReferenceResolving {
    var onConnectionLost: ((Error?) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var followCount = 0
    private(set) var isFollowing = false
    var referencedMessages: [String: ChatMessage] = [:]
    var unavailableReferences: Set<String> = []

    func startFollowing() async {
        followCount += 1
        isFollowing = true
    }

    func stopFollowing() {
        isFollowing = false
    }

    func push(_ pushed: ChatMessage) {
        append(pushed)
        onChange?()
    }
}

/// Messages 1–100 exist on the "network"; a window holds the message and the five after it.
@MainActor
private final class FakeWindowingAdapter: FakeAdapter, ChatWindowing, ChatCommanding {
    private(set) var hasLaterMessages = false
    private(set) var commands: [String] = []
    private var latest: [ChatMessage] = []

    override func loadNewest() async throws {
        try await super.loadNewest()
        latest = messages
    }

    func loadLater() async throws {}

    func showWindow(around messageId: String) async throws -> Bool {
        guard let id = Int(messageId), (1 ... 100).contains(id) else { return false }
        replace(with: (id ... id + 5).map { message($0) })
        hasLaterMessages = true
        return true
    }

    func showLatest() async throws {
        replace(with: latest)
        hasLaterMessages = false
    }

    func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/")
    }

    func sendCommand(_ text: String, replyToId _: String?) async throws {
        commands.append(text)
    }
}

@MainActor
private final class FakeReactingAdapter: FakeAdapter, ChatReactionSending {
    let acceptsReactions = true

    func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId]?.filter(\.includesYou).map(\.emoji) ?? []
    }

    func toggleReaction(_ emoji: String, on messageId: String) async throws {
        reactions[messageId] = [ChatReaction(emoji: emoji, count: 1, includesYou: true)]
    }
}
