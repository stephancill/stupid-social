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

    func testSelectsRecentIncomingShowableMessages() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func chat(_ id: String, sender: String, age: TimeInterval, content: SpotifyChatMessage.Content) -> SpotifyChat {
            SpotifyChat(id: id, isGroup: false, name: nil, members: ["me", sender], latestMessage: SpotifyChatMessage(
                id: "\(id)-message",
                sender: sender,
                sentAt: now.addingTimeInterval(-age),
                content: content,
            ))
        }
        let chats = [
            chat("share", sender: "friend", age: 60, content: .share(uri: "spotify:track:abc")),
            chat("text", sender: "friend", age: SpotifyMessagesSource.recentWindow, content: .text("hi")),
            chat("own", sender: "me", age: 60, content: .share(uri: "spotify:track:abc")),
            chat("old", sender: "friend", age: SpotifyMessagesSource.recentWindow + 1, content: .share(uri: "spotify:track:abc")),
            chat("gif", sender: "friend", age: 60, content: .other),
            SpotifyChat(id: "empty", isGroup: false, name: nil, members: [], latestMessage: nil),
        ]

        let selected = SpotifyMessagesSource.recentIncomingMessages(in: chats, viewer: "me", now: now)

        XCTAssertEqual(selected.map(\.0.id), ["share", "text"])
    }

    func testBuildsOpenURLFromShareURI() {
        XCTAssertEqual(SpotifyMessagesSource.openURL(forShareURI: "spotify:track:abc?si=xyz"), URL(string: "https://open.spotify.com/track/abc"))
        XCTAssertEqual(SpotifyMessagesSource.openURL(forShareURI: "spotify:playlist:def"), URL(string: "https://open.spotify.com/playlist/def"))
        XCTAssertNil(SpotifyMessagesSource.openURL(forShareURI: "https://example.com"))
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
