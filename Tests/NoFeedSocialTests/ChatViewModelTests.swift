import Foundation
@testable import NoFeedSocialCore
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    private func chat(restored: Int, unread: Int = 0) -> ChatViewModel {
        let viewModel = ChatViewModel(network: .apron, title: "Chat", subtitle: "Test", canReply: true)
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
}
