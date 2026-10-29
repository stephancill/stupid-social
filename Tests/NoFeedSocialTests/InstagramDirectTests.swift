import Foundation
@testable import NoFeedSocialCore
import XCTest

final class InstagramDirectTests: XCTestCase {
    private let viewerFbid = "900"
    private let friendFbid = "100"

    private func thread(messages: [String], viewerReadAt: String, isGroup: Bool = false, markedAsUnread: Bool = false) throws -> InstagramDirectThread {
        let json = """
        {
          "thread_fbid": "555",
          "thread_id": "340282366841710300000000000000000001",
          "thread_title": "Friend",
          "is_group": \(isGroup),
          "marked_as_unread": \(markedAsUnread),
          "thread_image_url": null,
          "users": [{"id": "1", "interop_messaging_user_fbid": "\(friendFbid)", "username": "friend", "full_name": "Friend Name", "profile_pic_url": "https://example.com/friend.jpg"}],
          "viewer": {"id": "9", "interop_messaging_user_fbid": "\(viewerFbid)", "profile_pic_url": "https://example.com/me.jpg"},
          "slide_read_receipts": [
            {"participant_fbid": "\(friendFbid)", "watermark_timestamp_ms": "1800000000000"},
            {"participant_fbid": "\(viewerFbid)", "watermark_timestamp_ms": "\(viewerReadAt)"}
          ],
          "slide_messages": {
            "edges": [\(messages.map { "{\"node\": \($0), \"cursor\": \"c\"}" }.joined(separator: ","))],
            "page_info": {"end_cursor": "older", "has_next_page": true}
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(InstagramDirectThread.self, from: Data(json.utf8))
    }

    private func text(id: String, sender: String, ms: String, body: String) -> String {
        """
        {"id": "\(id)", "message_id": "\(id)", "sender_fbid": "\(sender)", "timestamp_ms": "\(ms)", "content_type": "TEXT", "text_body": "\(body)",
         "content": {"__typename": "SlideMessageText", "text_body": "\(body)"}, "reactions": [{"reaction": "❤️", "sender_fbid": "\(viewerFbid)"}]}
        """
    }

    private func reelShare(id: String, sender: String, ms: String) -> String {
        """
        {"id": "\(id)", "sender_fbid": "\(sender)", "timestamp_ms": "\(ms)", "content_type": "MESSAGE_INLINE_SHARE", "text_body": "",
         "igd_snippet": "Friend sent an attachment.",
         "content": {"__typename": "SlideMessageXMAContent", "xma_text_body": "",
           "xma": {"__typename": "SlideMessagePortraitXMA", "header_title_text": "creator", "target_url": "https://www.instagram.com/reel/abc/",
             "preview_image": {"url": "https://example.com/reel.jpg", "width": 150, "height": 266, "preview_image_decoration_type": "REEL"}}}}
        """
    }

    func testDecodesThreadAndReadState() throws {
        let thread = try thread(
            messages: [text(id: "m2", sender: friendFbid, ms: "1800000002000", body: "New"), text(id: "m1", sender: friendFbid, ms: "1800000001000", body: "Old")],
            viewerReadAt: "1800000001500",
        )

        XCTAssertEqual(thread.threadFbid, "555")
        XCTAssertEqual(thread.viewerFbid, viewerFbid)
        XCTAssertEqual(thread.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(thread.unreadMessages.map(\.id), ["m2"])
        XCTAssertEqual(thread.others.map(\.username), ["friend"])
        XCTAssertEqual(thread.slideMessages?.pageInfo?.endCursor, "older")
        XCTAssertEqual(thread.messages.first?.reactions?.first?.reaction, "❤️")
    }

    func testFeedShowsUnreadIncomingMessagesOnly() throws {
        let unread = try thread(messages: [text(id: "m2", sender: friendFbid, ms: "1800000002000", body: "Hi")], viewerReadAt: "1800000001000")
        let read = try thread(messages: [text(id: "m2", sender: friendFbid, ms: "1800000002000", body: "Hi")], viewerReadAt: "1800000002000")
        let own = try thread(messages: [text(id: "m3", sender: viewerFbid, ms: "1800000003000", body: "Yo")], viewerReadAt: "0")

        let items = InstagramDirectMessageParser.parse(threads: [unread, read, own], accountId: "9", includeMediaShares: true)

        XCTAssertEqual(items.map(\.id), ["instagram:direct:555:m2"])
        XCTAssertEqual(items.first?.text, "friend sent you a message")
        XCTAssertEqual(items.first?.target?.text, "Hi")
        XCTAssertEqual(items.first?.actors.first?.id, "1")
    }

    func testFeedDescribesAndFiltersReelShares() throws {
        let share = try thread(messages: [reelShare(id: "m4", sender: friendFbid, ms: "1800000004000")], viewerReadAt: "0")

        let items = InstagramDirectMessageParser.parse(threads: [share], accountId: "9", includeMediaShares: true)
        XCTAssertEqual(items.first?.text, "friend sent you a reel")
        XCTAssertEqual(items.first?.target?.text, "Sent a reel")
        XCTAssertEqual(items.first?.target?.url?.absoluteString, "https://www.instagram.com/reel/abc/")
        XCTAssertEqual(items.first?.target?.imageURL?.absoluteString, "https://example.com/reel.jpg")

        XCTAssertTrue(InstagramDirectMessageParser.parse(threads: [share], accountId: "9", includeMediaShares: false).isEmpty)
    }

    @MainActor
    func testChatSummary() throws {
        let summary = try InstagramClient.chatSummary(thread(
            messages: [text(id: "m3", sender: viewerFbid, ms: "1800000003000", body: "Yo"), text(id: "m2", sender: friendFbid, ms: "1800000002000", body: "Hi")],
            viewerReadAt: "1800000001000",
        ))

        XCTAssertEqual(summary.id, "instagram:direct:555")
        XCTAssertEqual(summary.destination, .instagram(threadFbid: "555"))
        XCTAssertEqual(summary.title, "Friend")
        XCTAssertEqual(summary.preview, "You: Yo")
        XCTAssertEqual(summary.unreadCount, 1)
        XCTAssertEqual(summary.avatarURL?.absoluteString, "https://example.com/friend.jpg")
        XCTAssertFalse(summary.namesSenderInPreview)
    }

    @MainActor
    func testOfflineThreadingIDEncodesMilliseconds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try XCTUnwrap(UInt64(InstagramClient.offlineThreadingID(now: now)))
        XCTAssertEqual(id >> 22, 1_800_000_000_000)
    }

    @MainActor
    func testStoredEmojiMatchesQuickReaction() {
        XCTAssertEqual(InstagramChatAdapter.displayEmoji("❤"), "❤️")
        XCTAssertEqual(InstagramChatAdapter.displayEmoji("❤️"), "❤️")
        XCTAssertEqual(InstagramChatAdapter.displayEmoji("👍"), "👍")
        XCTAssertEqual(InstagramChatAdapter.displayEmoji("🥲"), "🥲")
    }
}
