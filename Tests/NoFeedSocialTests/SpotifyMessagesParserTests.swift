import Foundation
@testable import NoFeedSocialCore
import XCTest

final class SpotifyMessagesParserTests: XCTestCase {
    func testParsesLatestChatsResponse() throws {
        let response = Proto()
            .message(1, latestNode(chatId: "chatA", members: ["me", "friend"], isGroup: false, messageId: "m1", sender: "friend", seconds: 1_800_000_000, contribution: Proto().message(2, Proto().string(1, "spotify:track:abc?si=xyz"))))
            .message(1, latestNode(chatId: "chatB", members: ["me", "a", "b"], isGroup: true, groupName: "Crew", messageId: "m2", sender: "a", seconds: 1_800_000_100, contribution: Proto().message(3, Proto().string(1, "spotify:episode:def").string(3, "copy-link"))))
            .message(1, latestNode(chatId: "chatC", members: ["me", "friend"], isGroup: false, messageId: "m3", sender: "me", seconds: 1_800_000_200, contribution: Proto().message(1, Proto().string(1, "Fire"))))
            .message(1, latestNode(chatId: "chatD", members: ["me", "friend"], isGroup: false, messageId: "m4", sender: "friend", seconds: 1_800_000_300, contribution: Proto().message(6, Proto().string(1, "gif"))))

        let chats = try SpotifyMessagesParser.parseLatestChats(response.data)

        XCTAssertEqual(chats.map(\.id), ["chatA", "chatB", "chatC", "chatD"])
        XCTAssertEqual(chats[0].members, ["me", "friend"])
        XCTAssertFalse(chats[0].isGroup)
        XCTAssertEqual(chats[0].latestMessage, SpotifyChatMessage(
            id: "m1",
            sender: "friend",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000.5),
            content: .share(uri: "spotify:track:abc?si=xyz"),
        ))
        XCTAssertTrue(chats[1].isGroup)
        XCTAssertEqual(chats[1].name, "Crew")
        XCTAssertEqual(chats[1].latestMessage?.content, .share(uri: "spotify:episode:def"))
        XCTAssertEqual(chats[2].latestMessage?.content, .text("Fire"))
        XCTAssertEqual(chats[3].latestMessage?.content, .other)
    }

    func testLatestChatsRequestEncodesDescendingSortAndLimit() {
        XCTAssertEqual([UInt8](SpotifyMessagesParser.latestChatsRequest(limit: 20)), [0x08, 0x02, 0x10, 0x14])
    }

    func testRejectsTruncatedMessages() {
        XCTAssertThrowsError(try SpotifyMessagesParser.parseLatestChats(Data([0x0A, 0x05, 0x01])))
    }

    func testBuildsOpenURLFromShareURI() {
        XCTAssertEqual(SpotifyMessagesSource.openURL(forShareURI: "spotify:track:abc?si=xyz"), URL(string: "https://open.spotify.com/track/abc"))
        XCTAssertEqual(SpotifyMessagesSource.openURL(forShareURI: "spotify:playlist:def"), URL(string: "https://open.spotify.com/playlist/def"))
        XCTAssertNil(SpotifyMessagesSource.openURL(forShareURI: "https://example.com"))
    }

    func testChatRequestsMatchProbe() {
        // `spotify-web-client.py chat-seen exampleChatId0000000001 --dry-run`.
        let seen = "0a211a1f121d0a176578616d706c654368617449643030303030303030303112021801"
        XCTAssertEqual(SpotifyMessagesParser.markSeenRequest(chatId: "exampleChatId0000000001").map { String(format: "%02x", $0) }.joined(), seen)

        let freeText = Proto().message(1, Proto().string(1, "hi there"))
        let send = Proto().message(1, Proto().message(2, Proto().message(1, Proto().string(1, "chatA").message(2, freeText))))
        XCTAssertEqual(SpotifyMessagesParser.sendTextRequest(chatId: "chatA", text: "hi there"), send.data)

        let history = Proto().string(1, "chatA").varint(5, 2).string(8, "token").varint(9, 30)
        XCTAssertEqual(SpotifyMessagesParser.chatHistoryRequest(chatId: "chatA", pageSize: 30, pageToken: "token"), history.data)
    }

    func testParsesChatHistoryWithReactionsAndPageToken() throws {
        let hierarchy = Proto()
            .message(1, Proto().string(1, "chatB"))
            .message(4, Proto().varint(5, 2))
            .message(5, Proto().string(1, "Crew").message(2, Proto().string(1, "me")).message(2, Proto().string(1, "a")))
        let reaction = Proto()
            .message(1, Proto().string(1, "r1"))
            .message(6, Proto().string(1, "me").message(2, Proto().message(1, Proto().varint(1, 1_800_000_050))))
            .message(8, Proto().message(2, Proto().message(1, Proto().string(2, "me").string(3, "🔥"))))
        let receipt = Proto()
            .message(1, Proto().string(1, "r2"))
            .message(8, Proto().message(2, Proto().message(2, Proto().varint(1, 1).string(2, "b"))))
        let node = Proto()
            .message(1, Proto().string(1, "m1"))
            .message(3, reaction)
            .message(3, receipt)
            .message(6, Proto().string(1, "a").message(2, Proto().message(1, Proto().varint(1, 1_800_000_000))))
            .message(8, Proto().message(1, Proto().message(1, Proto().string(1, "Fire"))))
        let response = Proto().message(1, hierarchy).message(2, node).string(3, "next")

        let page = try SpotifyMessagesParser.parseChatHistory(response.data)

        XCTAssertEqual(page.chat?.name, "Crew")
        XCTAssertEqual(page.chat?.isGroup, true)
        XCTAssertEqual(page.nextPageToken, "next")
        XCTAssertEqual(page.messages.map(\.content), [.text("Fire")])
        XCTAssertEqual(page.messages.first?.reactions, [SpotifyChatReaction(username: "me", emoji: "🔥", sentAt: Date(timeIntervalSince1970: 1_800_000_050))])
    }

    @MainActor
    func testConvertsBase62IdToMetadataGid() {
        // `spotify-web-client.py track-metadata 6cEX8cGCDhORY2dGLpd1jx` requests this gid.
        XCTAssertEqual(SpotifyClient.gid(fromBase62: "6cEX8cGCDhORY2dGLpd1jx"), "cbd9bfa17aaf43d79654ef6d7b3c0c07")
        XCTAssertNil(SpotifyClient.gid(fromBase62: "not-base62"))
    }

    private func latestNode(
        chatId: String,
        members: [String],
        isGroup: Bool,
        groupName: String? = nil,
        messageId: String,
        sender: String,
        seconds: UInt64,
        contribution: Proto,
    ) -> Proto {
        var group = Proto()
        if let groupName { group = group.string(1, groupName) }
        for member in members {
            group = group.message(2, Proto().string(1, member))
        }
        let hierarchy = Proto()
            .message(1, Proto().string(1, chatId).varint(2, 1).string(3, "spotify:chat:\(chatId)"))
            .message(4, Proto().varint(5, isGroup ? 2 : 1))
            .message(5, group)
        let node = Proto()
            .message(1, Proto().string(1, messageId).message(2, Proto().varint(2, 1)))
            .message(6, Proto().string(1, sender).message(2, Proto().message(1, Proto().varint(1, seconds).varint(2, 500_000_000))))
            .message(8, Proto().message(1, contribution))
        return Proto().message(1, hierarchy).message(2, node)
    }
}

/// Builds protobuf fixtures without real Spotify data.
private struct Proto {
    var data = Data()

    func varint(_ field: Int, _ value: UInt64) -> Proto {
        var copy = self
        copy.data += Self.encode(UInt64(field << 3)) + Self.encode(value)
        return copy
    }

    func string(_ field: Int, _ value: String) -> Proto {
        bytes(field, Data(value.utf8))
    }

    func message(_ field: Int, _ value: Proto) -> Proto {
        bytes(field, value.data)
    }

    private func bytes(_ field: Int, _ value: Data) -> Proto {
        var copy = self
        copy.data += Self.encode(UInt64(field << 3 | 2)) + Self.encode(UInt64(value.count)) + value
        return copy
    }

    private static func encode(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }
}
