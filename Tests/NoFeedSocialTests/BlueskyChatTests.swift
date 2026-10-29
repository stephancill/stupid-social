import Foundation
@testable import NoFeedSocialCore
import XCTest

/// Bluesky chat pages shaped like `chat.bsky.convo.*` responses, mapped without the network or the UI.
@MainActor
final class BlueskyChatTests: XCTestCase {
    private let viewer = "did:plc:viewer"
    private let friend = "did:plc:friend"
    private let client = BlueskyClient(credentialStore: KeychainCredentialStore(service: "bluesky-chat-tests", prefersSynchronizable: false, allowsInsecureFallback: true))

    private func message(id: String, sender: String, at seconds: Int, text: String = "Hi", reactions: String = "[]", embed: String? = nil) -> String {
        """
        {"$type": "chat.bsky.convo.defs#messageView", "id": "\(id)", "rev": "r\(id)", "text": "\(text)",
         "sender": {"did": "\(sender)"}, "sentAt": "2026-10-29T10:00:\(String(format: "%02d", seconds)).000Z",
         "reactions": \(reactions)\(embed.map { ", \"embed\": \($0)" } ?? "")}
        """
    }

    private func deleted(id: String, sender: String, at seconds: Int) -> String {
        """
        {"$type": "chat.bsky.convo.defs#deletedMessageView", "id": "\(id)", "rev": "r\(id)",
         "sender": {"did": "\(sender)"}, "sentAt": "2026-10-29T10:00:\(String(format: "%02d", seconds)).000Z"}
        """
    }

    private func convo(lastMessage: String, unreadCount: Int, muted: Bool = false) -> String {
        """
        {"id": "c1", "rev": "r", "status": "accepted", "muted": \(muted), "unreadCount": \(unreadCount),
         "members": [
           {"did": "\(viewer)", "handle": "me.bsky.social", "displayName": "Me"},
           {"did": "\(friend)", "handle": "friend.bsky.social", "displayName": "", "avatar": "https://cdn.bsky.app/friend.jpg"}
         ],
         "lastMessage": \(lastMessage)}
        """
    }

    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try client.decoder.decode(T.self, from: Data(json.utf8))
    }

    func testChatSummaryFromConvo() throws {
        let page = try decode(BlueskyConvosPage.self, """
        {"cursor": "next", "convos": [
          \(convo(lastMessage: message(id: "m2", sender: viewer, at: 2, text: "Line one\\nline two"), unreadCount: 0, muted: true)),
          {"id": "future", "unknownShape": true}
        ]}
        """)

        XCTAssertEqual(page.convos.elements.count, 1, "entries that don't decode are skipped")
        let summary = BlueskyClient.chatSummary(page.convos.elements[0], viewerDid: viewer)
        XCTAssertEqual(summary.id, "bluesky:convo:c1")
        XCTAssertEqual(summary.title, "friend.bsky.social", "an empty display name falls back to the handle")
        XCTAssertEqual(summary.avatarURL, URL(string: "https://cdn.bsky.app/friend.jpg"))
        XCTAssertEqual(summary.preview, "You: Line one line two")
        XCTAssertEqual(summary.destination, .bluesky(convoId: "c1"))
        XCTAssertTrue(summary.isMuted)
        XCTAssertFalse(summary.namesSenderInPreview)
    }

    func testDeletedLastMessagePreview() throws {
        let convo = try decode(BlueskyConvo.self, convo(lastMessage: deleted(id: "m1", sender: friend, at: 1), unreadCount: 1))
        XCTAssertEqual(BlueskyClient.chatSummary(convo, viewerDid: viewer).preview, "Message deleted")
        XCTAssertEqual(BlueskyClient.chatSummary(convo, viewerDid: viewer).unreadCount, 1)
    }

    func testReadPositionFromUnreadCount() throws {
        let page = try decode(BlueskyMessagesPage.self, """
        {"messages": [
          \(message(id: "m4", sender: friend, at: 4)),
          \(message(id: "m3", sender: viewer, at: 3)),
          \(message(id: "m2", sender: friend, at: 2)),
          \(message(id: "m1", sender: friend, at: 1))
        ]}
        """)
        let messages = page.messages.elements
        let base = try decode(BlueskyConvo.self, convo(lastMessage: message(id: "m4", sender: friend, at: 4), unreadCount: 2))

        let position = try XCTUnwrap(base.readPosition(messages: messages, viewerDid: viewer))
        XCTAssertLessThan(position, messages[2].sentAt, "the second-newest message from the friend is unread")
        XCTAssertGreaterThan(position, messages[3].sentAt)

        let read = try decode(BlueskyConvo.self, convo(lastMessage: message(id: "m4", sender: friend, at: 4), unreadCount: 0))
        XCTAssertEqual(read.readPosition(messages: messages, viewerDid: viewer), messages[0].sentAt)

        let beyondPage = try decode(BlueskyConvo.self, convo(lastMessage: message(id: "m4", sender: friend, at: 4), unreadCount: 9))
        XCTAssertNil(beyondPage.readPosition(messages: messages, viewerDid: viewer))
    }

    func testAdapterMapsMessagesReactionsAndPosts() throws {
        let post = """
        {"$type": "app.bsky.embed.record#view", "record": {"$type": "app.bsky.embed.record#viewRecord",
          "uri": "at://did:plc:author/app.bsky.feed.post/3abc", "cid": "x",
          "author": {"did": "did:plc:author", "handle": "author.bsky.social", "displayName": "Author"},
          "value": {"$type": "app.bsky.feed.post", "text": "A post"}}}
        """
        let reactions = """
        [{"value": "👍", "sender": {"did": "\(viewer)"}, "createdAt": "2026-10-29T10:00:05.000Z"},
         {"value": "👍", "sender": {"did": "\(friend)"}, "createdAt": "2026-10-29T10:00:06.000Z"},
         {"value": "😂", "sender": {"did": "\(friend)"}, "createdAt": "2026-10-29T10:00:07.000Z"}]
        """
        let page = try decode(BlueskyMessagesPage.self, """
        {"messages": [
          \(message(id: "m3", sender: viewer, at: 3, text: "", embed: post)),
          \(deleted(id: "m2", sender: friend, at: 2)),
          \(message(id: "m1", sender: friend, at: 1, reactions: reactions))
        ]}
        """)
        let snapshot: [String: Any] = try [
            "messages": JSONSerialization.jsonObject(with: JSONEncoder().encode(page.messages.elements)),
            "members": [
                viewer: ["id": viewer, "name": "You", "isSystem": false],
                friend: ["id": friend, "name": "Friend", "isSystem": false],
            ],
            "viewerDid": viewer,
            "title": "Friend",
            "subtitle": "@friend.bsky.social",
            "showsSenderNames": false,
        ]
        let adapter = BlueskyChatAdapter(client: client, convoId: "c1", title: "Friend")
        try adapter.restore(snapshot: JSONSerialization.data(withJSONObject: snapshot))

        XCTAssertEqual(adapter.key, "bluesky:c1")
        XCTAssertEqual(adapter.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(adapter.messages[0].sender.name, "Friend")
        XCTAssertFalse(adapter.messages[0].isOwn)
        XCTAssertEqual(adapter.reactions["m1"], [
            ChatReaction(emoji: "👍", count: 2, includesYou: true),
            ChatReaction(emoji: "😂", count: 1, includesYou: false),
        ])
        XCTAssertEqual(adapter.yourEmojis(on: "m1"), ["👍"])
        XCTAssertEqual(adapter.reactors(of: "😂", on: "m1").map(\.user.name), ["Friend"])
        XCTAssertTrue(adapter.messages[1].isDeleted)
        XCTAssertTrue(adapter.messages[2].isOwn)
        XCTAssertNil(adapter.messages[2].text)
        XCTAssertEqual(adapter.messages[2].embeds, [
            .card(title: "A post", subtitle: "Author", systemImage: "text.bubble", imageURL: nil, link: URL(string: "https://bsky.app/profile/did:plc:author/post/3abc")),
        ])
        XCTAssertEqual(adapter.info.subtitle, "@friend.bsky.social")

        let reopened = BlueskyChatAdapter(client: client, convoId: "c1", title: "Friend")
        try reopened.restore(snapshot: XCTUnwrap(adapter.snapshot()))
        XCTAssertEqual(reopened.messages, adapter.messages)
    }
}
