import Foundation
@testable import StupidSocialCore
import XCTest

final class ApronThreadsTests: XCTestCase {
    private func message(_ json: String) throws -> ApronMessage {
        try JSONDecoder().decode(ApronMessage.self, from: Data(json.utf8))
    }

    /// A thread's history page as the demo server sent it after messages were moved into it from its room
    /// (observed 2026-11-18): the moved snapshots keep their ids and carry `prev_room_id`; an edit of one later
    /// doesn't, but is older than the thread's `history_log_id`.
    func testMessagesMovedIntoAThreadAreMovedIn() throws {
        let page = try JSONDecoder().decode(ApronHistoryResult.self, from: Data(#"""
        {"messages": [
          {"message_id": "1795026809700", "log_id": "1795027313454", "room_id": "1795027313155", "prev_room_id": "1793555674934", "from": {"user_id": "a"}, "body": {"text": "moved"}},
          {"message_id": "1795026849771", "log_id": "1795027400000", "room_id": "1795027313155", "from": {"user_id": "a"}, "body": {"text": "moved, then edited"}},
          {"message_id": "1795027323164", "log_id": "1795027323164", "room_id": "1795027313155", "from": {"user_id": "a"}, "body": {"text": "posted here"}}
        ], "first_log_id": "1795027313454", "last_log_id": "1795027400000", "more": true, "history_log_id": "1795027313155"}
        """#.utf8))
        let start = page.historyLogId.flatMap(Int64.init)
        XCTAssertEqual(page.messages?.map { ApronChatAdapter.movedIn($0, roomId: "1795027313155", historyStart: start) }, [true, true, false])
        XCTAssertEqual(page.messages?.first?.prevRoomId, "1793555674934")
    }

    func testAnEditInTheSameRoomIsNotMovedIn() throws {
        let edit = try message(#"{"message_id": "100", "log_id": "500", "room_id": "general", "from": {"user_id": "a"}, "body": {"text": "edited"}}"#)
        XCTAssertFalse(ApronChatAdapter.movedIn(edit, roomId: "general", historyStart: 50))
        let back = try message(#"{"message_id": "100", "log_id": "600", "room_id": "general", "prev_room_id": "t1", "from": {"user_id": "a"}}"#)
        XCTAssertTrue(ApronChatAdapter.movedIn(back, roomId: "general", historyStart: 50), "moved back from a thread")
    }

    func testThreadSubtitleIsTheDescriptionsFirstLine() {
        XCTAssertNil(ApronChatAdapter.threadSubtitle(nil))
        XCTAssertNil(ApronChatAdapter.threadSubtitle("\n  \n"))
        XCTAssertEqual(ApronChatAdapter.threadSubtitle("> Why the 4pm deploy failed\n> more"), "Why the 4pm deploy failed")
        XCTAssertEqual(ApronChatAdapter.threadSubtitle(String(repeating: "a", count: 200))?.count, 120)
    }
}
