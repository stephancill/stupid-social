import Foundation
@testable import NoFeedSocialCore
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    private func chat(restored: Int, unread: Int = 0) -> ChatViewModel {
        let viewModel = ChatViewModel(network: .apron, chatKey: "test:chat", title: "Chat", subtitle: "Test", canReply: true, draftStore: ChatDraftStore(defaults: freshDefaults()))
        let sender = ChatUser(id: "ada", name: "Ada", avatarURL: nil)
        viewModel.history = (0 ..< restored).map { ChatMessage(id: "\($0)", sender: sender, timestamp: nil, text: "Message \($0)", isOwn: false) }
        viewModel.unreadCount = unread
        return viewModel
    }

    func testRestoredMessagesWithoutTheUnreadWaitForHistory() {
        let viewModel = chat(restored: 2)
        viewModel.expectUnread()
        XCTAssertTrue(viewModel.messages.isEmpty)
        viewModel.history += [ChatMessage(id: "2", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: nil, text: "New", isOwn: false)]
        XCTAssertTrue(viewModel.messages.isEmpty, "history arriving page by page stays held until the chat is connected")
        viewModel.state = .connected
        XCTAssertEqual(viewModel.messages.map(\.id), ["0", "1", "2"])
    }

    func testRestoredMessagesShowAfterAFailedConnection() {
        let viewModel = chat(restored: 2)
        viewModel.expectUnread()
        viewModel.state = .disconnected("Offline")
        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testRestoredMessagesHoldingTheUnreadShowAtOnce() {
        let viewModel = chat(restored: 2, unread: 1)
        viewModel.expectUnread()
        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testHeldMessagesShowAfterTheWait() async throws {
        let viewModel = chat(restored: 2)
        viewModel.expectUnread()
        try await Task.sleep(for: .milliseconds(1700))
        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testDividerIsPlacedWhileRestoredMessagesAreHeld() {
        let viewModel = ReadPositionChat(readUpTo: 1)
        viewModel.expectUnread()
        let sender = ChatUser(id: "ada", name: "Ada", avatarURL: nil)
        viewModel.history = (0 ..< 4).map { ChatMessage(id: "\($0)", sender: sender, timestamp: nil, text: "Message \($0)", isOwn: false) }
        XCTAssertTrue(viewModel.messages.isEmpty)
        viewModel.placeUnreadDivider()
        viewModel.updateUnreadCount()
        XCTAssertEqual(viewModel.firstUnreadMessageId, "2")
        XCTAssertEqual(viewModel.unreadCount, 2)
    }

    func testOwnMessagesAreNeverUnread() {
        let viewModel = ReadPositionChat(readUpTo: 0)
        viewModel.history = [ChatMessage(id: "1", sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: nil, text: "Hi", isOwn: true)]
        viewModel.updateUnreadCount()
        XCTAssertEqual(viewModel.unreadCount, 0)
    }

    func testDraftIsKeptPerChat() {
        let store = ChatDraftStore(defaults: freshDefaults())
        let first = ChatViewModel(network: .telegram, chatKey: "telegram:1", title: "A", subtitle: "", canReply: true, draftStore: store)
        first.draft = "Half a thought"
        XCTAssertEqual(ChatViewModel(network: .telegram, chatKey: "telegram:1", title: "A", subtitle: "", canReply: true, draftStore: store).draft, "Half a thought")
        XCTAssertEqual(ChatViewModel(network: .telegram, chatKey: "telegram:2", title: "B", subtitle: "", canReply: true, draftStore: store).draft, "")
        first.draft = "  "
        XCTAssertEqual(store.draft(key: "telegram:1"), "")
    }

    func testRemovingDraftsByPrefix() {
        let store = ChatDraftStore(defaults: freshDefaults())
        store.setDraft("a", key: "apron:wss://one|room")
        store.setDraft("b", key: "apron:wss://two|room")
        store.removeDrafts(keyPrefix: "apron:wss://one|")
        XCTAssertEqual(store.draft(key: "apron:wss://one|room"), "")
        XCTAssertEqual(store.draft(key: "apron:wss://two|room"), "b")
    }

    func testReadMarkerSendsOnlyTheLastOfABurst() async throws {
        let viewModel = chat(restored: 0)
        var sent: [Int] = []
        for id in 1 ... 3 {
            viewModel.scheduleReadMarker { sent.append(id) }
        }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(sent, [3])
    }

    func testPollingRunsUntilStopped() async throws {
        let viewModel = ReadPositionChat(readUpTo: 0)
        viewModel.startPolling(every: .milliseconds(20))
        XCTAssertTrue(viewModel.isPolling)
        try await Task.sleep(for: .milliseconds(150))
        viewModel.stopPolling()
        let polls = viewModel.polls
        XCTAssertGreaterThan(polls, 0)
        XCTAssertFalse(viewModel.isPolling)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.polls, polls)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ChatViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// A network whose read position is a message id, like Telegram's.
@MainActor
private final class ReadPositionChat: ChatViewModel {
    let readUpTo: Int
    private(set) var polls = 0

    init(readUpTo: Int) {
        self.readUpTo = readUpTo
        let suite = "ReadPositionChat-\(UUID().uuidString)"
        super.init(network: .telegram, chatKey: "test:read", title: "Chat", subtitle: "Test", canReply: true, draftStore: ChatDraftStore(defaults: UserDefaults(suiteName: suite)!))
    }

    override func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int(message.id) ?? 0) > readUpTo
    }

    override func poll() async {
        polls += 1
    }
}
