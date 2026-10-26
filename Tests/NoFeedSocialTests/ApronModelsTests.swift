import Foundation
@testable import NoFeedSocialCore
import XCTest

final class ApronModelsTests: XCTestCase {
    private let users: [String: ApronUser] = [
        "alice": ApronUser(userId: "alice", name: "Alice", avatar: nil, roles: nil),
        "bob": ApronUser(userId: "bob", name: "bob", avatar: nil, roles: nil),
        "me": ApronUser(userId: "me", name: "Me", avatar: nil, roles: nil),
    ]

    private func room(_ json: String) throws -> ApronRoom {
        try JSONDecoder().decode(ApronRoom.self, from: Data(json.utf8))
    }

    func testUntitledPrivateRoomIsNamedForOtherMembers() throws {
        // The shape of a DM in the demo server's `room_list`: members carry only `user_id`.
        let dm = try room(#"{"room_id": "private_1", "private": true, "members": [{"user_id": "me"}, {"user_id": "bob"}, {"user_id": "alice"}]}"#)
        XCTAssertTrue(dm.isNamedForMembers)
        XCTAssertEqual(dm.displayTitle(users: users, you: "me"), "Alice, bob")
        XCTAssertEqual(dm.otherMembers(you: "me").map(\.userId), ["bob", "alice"])
    }

    func testPrivateRoomFallbacks() throws {
        let alone = try room(#"{"room_id": "private_1", "private": true, "members": [{"user_id": "me"}]}"#)
        XCTAssertEqual(alone.displayTitle(users: users, you: "me"), "You")
        let unlisted = try room(#"{"room_id": "private_1", "private": true}"#)
        XCTAssertEqual(unlisted.displayTitle(users: users, you: "me"), "Private room")
        let unknown = try room(#"{"room_id": "private_1", "private": true, "members": [{"user_id": "me"}, {"user_id": "carol"}]}"#)
        XCTAssertEqual(unknown.displayTitle(users: users, you: "me"), "carol")
    }

    func testTitledAndPublicRoomsKeepTheirTitles() throws {
        let titled = try room(#"{"room_id": "private_1", "private": true, "title": "Plans", "members": [{"user_id": "alice"}]}"#)
        XCTAssertEqual(titled.displayTitle(users: users, you: "me"), "Plans")
        let thread = try room(#"{"room_id": "t1", "private": true, "parent_room_id": "private_1", "members": [{"user_id": "alice"}]}"#)
        XCTAssertEqual(thread.displayTitle(users: users, you: "me"), "t1")
        let general = try room(#"{"room_id": "general", "members": [{"user_id": "alice"}]}"#)
        XCTAssertFalse(general.isNamedForMembers)
        XCTAssertEqual(general.displayTitle(users: users, you: "me"), "general")
    }

    func testSeenShowsOnlyWhileOffline() throws {
        let offline = try JSONDecoder().decode(ApronUser.self, from: Data(#"{"user_id": "alice", "status": "offline", "seen": "1724803600000"}"#.utf8))
        XCTAssertEqual(offline.lastSeen, Date(timeIntervalSince1970: 1_724_803_600))
        // A kept `seen` outlives the change back online, but isn't shown then (§4.5.2).
        let online = offline.merging(ApronUser(userId: "alice", name: nil, avatar: nil, roles: nil, status: "online"))
        XCTAssertEqual(online.seen, "1724803600000")
        XCTAssertNil(online.lastSeen)
    }

    func testServerSyncKeepsTheNewerChangePerServer() {
        typealias Entry = ApronServerSync.Entry
        let local = [
            "wss://a/": Entry(requestedName: "me", removed: false, changedAt: 100),
            "wss://b/": Entry(requestedName: nil, removed: false, changedAt: 100),
        ]
        let remote = [
            // Removed on another device after this one added it: the removal wins.
            "wss://a/": Entry(requestedName: nil, removed: true, changedAt: 200),
            // Removed there before this device re-added it: the server stays.
            "wss://b/": Entry(requestedName: nil, removed: true, changedAt: 50),
            "wss://c/": Entry(requestedName: "other", removed: false, changedAt: 10),
        ]
        let merged = ApronServerSync.merged(local, remote)
        XCTAssertEqual(merged["wss://a/"]?.removed, true)
        XCTAssertEqual(merged["wss://b/"]?.removed, false)
        XCTAssertEqual(merged["wss://c/"]?.requestedName, "other")
    }

    func testLoopbackServersStayOnTheDevice() throws {
        XCTAssertFalse(try ApronServerSync.isSynced(XCTUnwrap(URL(string: "ws://127.0.0.1:8765/"))))
        XCTAssertFalse(try ApronServerSync.isSynced(XCTUnwrap(URL(string: "ws://localhost:8765/"))))
        XCTAssertTrue(try ApronServerSync.isSynced(XCTUnwrap(URL(string: "wss://server.apron.chat/"))))
    }
}
