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

    func testDirectRoomIsUntitledPrivateRoomOfExactlyTwo() throws {
        let dm = try room(#"{"room_id": "1", "private": true, "members": [{"user_id": "me"}, {"user_id": "bob"}]}"#)
        XCTAssertTrue(dm.isDirect(with: "bob", you: "me"))
        XCTAssertFalse(dm.isDirect(with: "alice", you: "me"))
        XCTAssertFalse(dm.isDirect(with: "me", you: "me"))
        let group = try room(#"{"room_id": "2", "private": true, "members": [{"user_id": "me"}, {"user_id": "bob"}, {"user_id": "alice"}]}"#)
        XCTAssertFalse(group.isDirect(with: "bob", you: "me"))
        let titled = try room(#"{"room_id": "3", "private": true, "title": "Plans", "members": [{"user_id": "me"}, {"user_id": "bob"}]}"#)
        XCTAssertFalse(titled.isDirect(with: "bob", you: "me"))
        let truncated = try room(#"{"room_id": "4", "private": true, "member_count": 40, "members": [{"user_id": "me"}, {"user_id": "bob"}]}"#)
        XCTAssertFalse(truncated.isDirect(with: "bob", you: "me"))
        let open = try room(#"{"room_id": "5", "members": [{"user_id": "me"}, {"user_id": "bob"}]}"#)
        XCTAssertFalse(open.isDirect(with: "bob", you: "me"))
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

    func testGuestPermissionsSurviveEncoding() throws {
        let json = #"{"user_id":"guest_1","name":"guest_1","ext":{"permissions":{"write":false}}}"#
        let guest = try JSONDecoder().decode(ApronUser.self, from: Data(json.utf8))
        XCTAssertEqual(guest.canWrite, false)
        let restored = try JSONDecoder().decode(ApronUser.self, from: JSONEncoder().encode(guest))
        XCTAssertEqual(restored.canWrite, false)
        XCTAssertEqual(guest.merging(ApronUser(userId: "guest_1", name: "Guest", avatar: nil, roles: nil)).canWrite, false)
        XCTAssertNil(users["alice"]?.canWrite)
    }

    func testReconnectDelayFollowsServerLimits() {
        XCTAssertEqual(ApronError.rejected(status: 429, retryAfter: 60).reconnectDelay, .seconds(60))
        XCTAssertNil(ApronError.rejected(status: 503).reconnectDelay)
        XCTAssertEqual(ApronError.limited(message: "Connection limit reached for this account", retryAfter: 60, category: nil).reconnectDelay, .seconds(60))
        XCTAssertEqual(ApronError.closedByServer(code: 1013, reason: "Frame rate limit reached").reconnectDelay, .seconds(300))
        XCTAssertEqual(ApronError.closedByServer(code: 1008, reason: "Frame rate limit reached").reconnectDelay, .seconds(60))
        XCTAssertNil(ApronError.closedByServer(code: 1001, reason: "Connection idle; reconnect to recover").reconnectDelay)
    }

    func testCredentialClosesEndSignIn() {
        XCTAssertTrue(ApronError.closedByServer(code: 1008, reason: "Device token replaced").endsSignIn)
        XCTAssertTrue(ApronError.closedByServer(code: 1008, reason: "Signed out after a week without signing in or posting").endsSignIn)
        XCTAssertFalse(ApronError.closedByServer(code: 1008, reason: "Too many pending frames").endsSignIn)
        XCTAssertFalse(ApronError.closedByServer(code: 1011, reason: "Delivery failed").endsSignIn)
    }

    func testSeenShowsOnlyWhileOffline() throws {
        let offline = try JSONDecoder().decode(ApronUser.self, from: Data(#"{"user_id": "alice", "status": "offline", "seen": "1724803600000"}"#.utf8))
        XCTAssertEqual(offline.lastSeen, Date(timeIntervalSince1970: 1_724_803_600))
        // A kept `seen` outlives the change back online, but isn't shown then (§4.5.2).
        let online = offline.merging(ApronUser(userId: "alice", name: nil, avatar: nil, roles: nil, status: "online"))
        XCTAssertEqual(online.seen, "1724803600000")
        XCTAssertNil(online.lastSeen)
    }

    /// One room by `room_id`, as a link preview asks for it, comes back in `not_joined` until the user joins.
    func testOneRoomListing() throws {
        let params = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ApronRoomListParams(filter: "all", members: true, roomId: "1793058106801"))) as? [String: Any]
        XCTAssertEqual(params?["room_id"] as? String, "1793058106801")
        let all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ApronRoomListParams(filter: "joined", members: true))) as? [String: Any]
        XCTAssertNil(all?["room_id"])

        let json = #"{"not_joined":[{"room_id":"1793058106801","title":"The Watchlist","description":"Share what's worth watching.","members":[{"user_id":"ada"}]}],"users":[{"user_id":"ada","name":"Ada","avatar":"https://example.com/ada.png"}]}"#
        let result = try JSONDecoder().decode(ApronRoomListResult.self, from: Data(json.utf8))
        XCTAssertNil(result.joined)
        XCTAssertEqual(result.notJoined?.first?.title, "The Watchlist")
        XCTAssertEqual(result.notJoined?.first?.members?.count, 1)
        XCTAssertEqual(result.users?.first?.avatarURL?.absoluteString, "https://example.com/ada.png")
    }

    func testARoomUpdateNamesOnlyTheRoomsThatChangedUnlessTheUsersRoomsDid() throws {
        func update(_ json: String) throws -> ApronRoomUpdate {
            try JSONDecoder().decode(ApronRoomUpdate.self, from: Data(json.utf8))
        }
        let renamed = try update(#"{"updated":[{"room_id":"general","title":"General (ops)"}]}"#)
        XCTAssertEqual(renamed.changedRoomIds, ["general"])
        let membership = try update(#"{"memberships":[{"room_id":"dm","members":[{"user":{"user_id":"ada"},"joined":false}]}]}"#)
        XCTAssertEqual(membership.changedRoomIds, ["dm"])
        XCTAssertNil(try update(#"{"left":[{"room_id":"general"}]}"#).changedRoomIds)
        XCTAssertNil(try update(#"{"joined":[{"room_id":"new"}]}"#).changedRoomIds)
    }
}
