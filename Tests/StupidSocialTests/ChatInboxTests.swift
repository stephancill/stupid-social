import Foundation
import StupidSocialCore
import StupidSocialPush
import XCTest

@MainActor
final class ChatInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: URL!
    private var store: ChatStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ChatInboxTests-\(UUID().uuidString)")
        inbox = directory.appending(path: "chat-inbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try ChatStore(url: directory.appending(path: "chat-store.sqlite"))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: Int64) -> ChatRecord {
        ChatRecord(id: String(id), sortKey: id, data: Data("{}".utf8))
    }

    private var inboxFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: inbox.path())) ?? []
    }

    func testImportsMessagesAndEmptiesTheInbox() throws {
        try store.write([record(0)], chatKey: "a|apron:room")
        try SharedChatStore.leave(record(1), chatKey: "a|apron:room", inbox: inbox)
        try SharedChatStore.leave(record(2), chatKey: "a|apron:room", inbox: inbox)
        XCTAssertEqual(inboxFiles.count, 2)

        try SharedChatStore.importInbox(into: store, inbox: inbox)

        XCTAssertNotNil(try store.record(id: "1", chatKey: "a|apron:room"))
        XCTAssertNotNil(try store.record(id: "2", chatKey: "a|apron:room"))
        XCTAssertEqual(inboxFiles, [])
    }

    /// A pushed message doesn't make its chat current, so loading ahead fetches it on opening the app and it opens on
    /// its stored history, not on the pushed messages alone with the rest filling in above.
    func testPushedMessagesShowAfterTheStoredOnesWithoutMakingTheChatCurrent() throws {
        try store.write([record(1)], chatKey: "a|apron:room")
        try SharedChatStore.leave(record(5), chatKey: "a|apron:room", inbox: inbox)

        try SharedChatStore.importInbox(into: store, inbox: inbox)

        XCTAssertEqual(try store.window(chatKey: "a|apron:room", at: .newest(count: 10)).records.map(\.id), ["1", "5"])
        XCTAssertFalse(try store.isCurrent(chatKey: "a|apron:room", latestMessageId: "5"))
    }

    func testProvisionalMessagesGoToEveryStoredChatWithThePeer() throws {
        try store.write([record(10)], chatKey: "one|telegram:user:7")
        try store.write([record(10)], chatKey: "two|telegram:user:7")
        try SharedChatStore.leaveProvisional(record(11), chatKeySuffix: "|telegram:user:7", inbox: inbox)

        try SharedChatStore.importInbox(into: store, inbox: inbox)

        XCTAssertNotNil(try store.record(id: "11", chatKey: "one|telegram:user:7"))
        XCTAssertNotNil(try store.record(id: "11", chatKey: "two|telegram:user:7"))
    }

    func testABadEntryIsRemovedWithoutBlockingTheRest() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: inbox.appending(path: "000000000000000000-bad.json"))
        try store.write([record(0)], chatKey: "a|apron:room")
        try SharedChatStore.leave(record(3), chatKey: "a|apron:room", inbox: inbox)

        XCTAssertThrowsError(try SharedChatStore.importInbox(into: store, inbox: inbox))

        XCTAssertNotNil(try store.record(id: "3", chatKey: "a|apron:room"))
        XCTAssertEqual(inboxFiles, [])
    }
}
