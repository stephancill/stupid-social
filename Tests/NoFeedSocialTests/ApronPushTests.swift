import Foundation
@testable import NoFeedSocialCore
import NoFeedSocialPush
import XCTest

final class ApronPushTests: XCTestCase {
    // MARK: Web Push decryption

    /// RFC 8291 Appendix A.
    func testDecryptsRFC8291Example() throws {
        let keys = try WebPushKeys(
            privateKey: XCTUnwrap(Data(base64URLEncoded: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")),
            auth: XCTUnwrap(Data(base64URLEncoded: "BTBZMqHH6r4Tts7J_aSIgg")),
        )
        XCTAssertEqual(try keys.publicKey.base64URLEncodedString, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let body = try XCTUnwrap(Data(base64URLEncoded: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"))
        let plaintext = try WebPushDecryptor.decrypt(body, keys: keys)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "When I grow up, I want to be a watermelon")
    }

    func testOtherKeysFailToDecrypt() throws {
        let body = try XCTUnwrap(Data(base64URLEncoded: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"))
        XCTAssertThrowsError(try WebPushDecryptor.decrypt(body, keys: .generate()))
        XCTAssertThrowsError(try WebPushDecryptor.decrypt(Data([1, 2, 3]), keys: .generate()))
    }

    // MARK: Notification content

    private let serverURL = URL(string: "wss://server.apron.chat/")!

    private func registration(serverURL: URL? = nil, pushId: String = "t65S5XBst9bSDpjJ") -> ApronPushRegistration {
        var registration = ApronPushRegistration(pushId: pushId, serverURL: serverURL ?? self.serverURL, userId: "me", keys: .generate())
        registration.roomTitles = ["general": "General", "dm1": "Alice", "team": "Team"]
        registration.directRooms = ["dm1"]
        registration.userNames = ["alice": "Alice", "bob_1": "Bob"]
        registration.avatarURLs = ["alice": URL(string: "https://media.apron.chat/a.png")!]
        return registration
    }

    private func registrations() -> [String: ApronPushRegistration] {
        let registration = registration()
        return [registration.pushId: registration]
    }

    private func payload(room: String, from: String = #"{"user_id":"alice","name":"Alice"}"#, body: String = #"{"text":"Deploy is done"}"#, replyTo: Bool = false) -> Data {
        let reply = replyTo ? #","reply_to":{"message_id":"7"}"# : ""
        return Data(#"{"push_id":"t65S5XBst9bSDpjJ","message":{"message_id":"9","room_id":"\#(room)","from":\#(from),"body":\#(body)\#(reply)}}"#.utf8)
    }

    func testRoomMessageIsTitledBySenderInRoom() throws {
        let notification = try XCTUnwrap(ApronPushNotification.make(payload: payload(room: "general"), registrations: registrations()))
        XCTAssertEqual(notification.title, "Alice in General")
        XCTAssertEqual(notification.subtitle, "server.apron.chat")
        XCTAssertEqual(notification.body, "Deploy is done")
        XCTAssertFalse(notification.isDirect)
        XCTAssertEqual(notification.senderAvatarURL?.absoluteString, "https://media.apron.chat/a.png")
        XCTAssertEqual(notification.threadIdentifier, "apron|wss://server.apron.chat/|general")
        XCTAssertEqual(notification.userInfo["apron"], ["server": "wss://server.apron.chat/", "room": "general", "message": "9", "direct": "0"])
    }

    func testDirectMessageIsTitledBySender() throws {
        let notification = try XCTUnwrap(ApronPushNotification.make(payload: payload(room: "dm1", body: #"{"text":"hi","mentions":["me"]}"#), registrations: registrations()))
        XCTAssertEqual(notification.title, "Alice")
        XCTAssertEqual(notification.subtitle, "server.apron.chat")
        XCTAssertEqual(notification.body, "hi")
        XCTAssertTrue(notification.isDirect)
        XCTAssertEqual(notification.userInfo["apron"]?["direct"], "1")
    }

    /// Mentions and replies show in the text and the app, not as a label.
    func testMentionsAndRepliesLookLikeOtherMessages() throws {
        let mention = try XCTUnwrap(ApronPushNotification.make(payload: payload(room: "general", body: #"{"text":"@me look","mentions":["me"]}"#, replyTo: true), registrations: registrations()))
        XCTAssertEqual(mention.title, "Alice in General")
        XCTAssertEqual(mention.subtitle, "server.apron.chat")
        let privateRoom = try XCTUnwrap(ApronPushNotification.make(payload: payload(room: "team", replyTo: true), registrations: registrations()))
        XCTAssertEqual(privateRoom.title, "Alice in Team")
    }

    func testSubtitleNamesTheRegistrationsServer() throws {
        let other = try registration(serverURL: XCTUnwrap(URL(string: "wss://chat.example.com/ws")), pushId: "other")
        var both = registrations()
        both[other.pushId] = other
        let notification = try XCTUnwrap(ApronPushNotification.make(payload: payload(room: "general"), registrations: both))
        XCTAssertEqual(notification.subtitle, "server.apron.chat")
    }

    /// Servers may leave out everything but `message_id`, `room_id` and `from.user_id` to fit (§4.9.3).
    func testTruncatedMessageFallsBack() throws {
        let data = Data(#"{"push_id":"t65S5XBst9bSDpjJ","message":{"message_id":"3","room_id":"new-room","from":{"user_id":"bob_1"}}}"#.utf8)
        let notification = try XCTUnwrap(ApronPushNotification.make(payload: data, registrations: registrations()))
        XCTAssertEqual(notification.title, "Bob in new-room")
        XCTAssertEqual(notification.subtitle, "server.apron.chat")
        XCTAssertEqual(notification.body, "New message")
    }

    func testIgnoresUnknownPushIdsAndBadgePushes() {
        let unknown = Data(#"{"push_id":"other","message":{"message_id":"1","room_id":"general","from":{"user_id":"alice"}}}"#.utf8)
        XCTAssertNil(ApronPushNotification.make(payload: unknown, registrations: registrations()))
        let badge = Data(#"{"push_id":"t65S5XBst9bSDpjJ","unread":0}"#.utf8)
        XCTAssertNil(ApronPushNotification.make(payload: badge, registrations: registrations()))
    }

    func testPlainTextNamesMentionsAndDropsMarkdown() {
        let names = ["alice": "Alice", "bob_1": "Bob"]
        XCTAssertEqual(ApronPushText.plain("hey @alice and @bob_1, ping @carol", names: names), "hey @Alice and @Bob, ping @carol")
        XCTAssertEqual(ApronPushText.plain("mail a@alice.com", names: names), "mail a@alice.com")
        XCTAssertEqual(ApronPushText.plain("**Deploy** is `done`, see [the dashboard](https://x.example) ~~now~~", names: [:]), "Deploy is done, see the dashboard now")
        XCTAssertEqual(ApronPushText.plain("> quoted\n# Title\n```swift\nlet x = 1\n```", names: [:]), "quoted\nTitle\nlet x = 1")
        XCTAssertEqual(ApronPushText.plain("![cat](https://x.example/c.png)", names: [:]), "cat")
    }

    func testStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApronPushStore(directory: directory)
        XCTAssertTrue(store.load().isEmpty)
        let saved = registrations()
        try store.save(saved)
        XCTAssertEqual(store.load(), saved)
    }

    /// The first build stored registrations without users or private rooms; those still decrypt.
    func testStoreReadsEarlierRegistrations() throws {
        let json = #"{"p":{"pushId":"p","serverURL":"wss://server.apron.chat/","userId":"me","keys":{"privateKey":"AAAA","auth":"AAAA"},"roomTitles":{"general":"General"},"directRooms":[]}}"#
        let decoded = try JSONDecoder().decode([String: ApronPushRegistration].self, from: Data(json.utf8))
        XCTAssertEqual(decoded["p"]?.roomTitles, ["general": "General"])
        XCTAssertEqual(decoded["p"]?.userNames, [:])
    }

    // MARK: Room notification levels

    private func room(isPrivate: Bool = false, isMuted: Bool = false, roomWake: [String]? = nil, roomWakeSupported: Bool = false) -> ApronRoomNotifications {
        ApronRoomNotifications(
            isPrivate: isPrivate,
            isMuted: isMuted,
            roomWake: roomWake,
            serverWake: ["mentions", "replies", "private"],
            supportsRoomWake: roomWakeSupported,
            supportsMute: true,
        )
    }

    func testDefaults() {
        XCTAssertEqual(room().level, .mentions)
        XCTAssertEqual(room(isPrivate: true).level, .all)
        XCTAssertEqual(room(isMuted: true).level, .none)
        XCTAssertEqual(room(roomWake: ["joined", "mentions", "replies"]).level, .all)
    }

    /// Without per-room wake scopes, a room keeps the registration's level or is muted.
    func testOptionsWithoutRoomWake() {
        XCTAssertEqual(room().options, [.mentions, .none])
        XCTAssertEqual(room(isPrivate: true).options, [.all, .none])
        XCTAssertEqual(room(roomWakeSupported: true).options, [.all, .mentions, .none])
    }

    func testChanges() {
        XCTAssertEqual(room().changes(to: .none), [.mute(true)])
        XCTAssertEqual(room(isMuted: true).changes(to: .mentions), [.mute(false)])
        XCTAssertEqual(room(isMuted: true).changes(to: .none), [])
        XCTAssertEqual(room(roomWakeSupported: true).changes(to: .all), [.wake(["joined", "mentions", "replies"])])
        XCTAssertEqual(room(isPrivate: true, roomWakeSupported: true).changes(to: .mentions), [.wake(["mentions", "replies"])])
        XCTAssertEqual(room(isMuted: true, roomWake: ["joined", "mentions", "replies"], roomWakeSupported: true).changes(to: .mentions), [.mute(false), .wake(nil)])
    }

    func testStatusParamsEncodeClearAsNull() throws {
        let clear = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ApronRoomStatusParams(roomId: "r", wake: .some(nil)))) as? [String: Any]
        XCTAssertTrue(clear?["wake"] is NSNull)
        XCTAssertNil(clear?["mute"])
        let mute = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ApronRoomStatusParams(roomId: "r", mute: true))) as? [String: Any]
        XCTAssertEqual(mute?["mute"] as? Bool, true)
        XCTAssertNil(mute?["wake"])
    }

    @MainActor
    func testConnectionAppliesStatus() {
        let connection = ApronConnection(url: serverURL)
        connection.applyStatus(["room_id": "random", "mute": true])
        connection.applyStatus(["room_id": "timed", "mute": 3600])
        connection.applyStatus(["room_id": "general", "wake": ["joined"]])
        XCTAssertEqual(connection.mutedRooms, ["random", "timed"])
        XCTAssertEqual(connection.roomWakes["general"], ["joined"])
        connection.applyStatus(["room_id": "random", "mute": false])
        connection.applyStatus(["room_id": "general", "wake": NSNull()])
        XCTAssertEqual(connection.mutedRooms, ["timed"])
        XCTAssertNil(connection.roomWakes["general"])
    }

    func testDecodesServerPush() throws {
        let json = #"{"apron":9,"auth":["token"],"push":{"webpush":{"key":"BF-z"},"wake":["mentions","replies","private"]}}"#
        let info = try JSONDecoder().decode(ApronServerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.push?.webpush?.key, "BF-z")
        XCTAssertTrue(info.push?.wakes("private") == true)
        XCTAssertNil(info.push?.roomWake)
    }

    func testDecodesServerMetadata() throws {
        let serverURL = try XCTUnwrap(URL(string: "wss://server.apron.chat/"))
        let json = #"{"apron":9,"auth":["guest"],"title":"Apron Demo","description":"The public *demo*.","avatar":"https://web.apron.chat/icon-512.png"}"#
        let info = try JSONDecoder().decode(ApronServerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.displayTitle(serverURL: serverURL), "Apron Demo")
        XCTAssertEqual(info.description, "The public *demo*.")
        XCTAssertEqual(info.avatarURL?.absoluteString, "https://web.apron.chat/icon-512.png")

        let untitled = try JSONDecoder().decode(ApronServerInfo.self, from: Data(#"{"apron":9,"auth":["guest"],"title":"  ","avatar":"javascript:alert(1)"}"#.utf8))
        XCTAssertEqual(untitled.displayTitle(serverURL: serverURL), "server.apron.chat")
        XCTAssertNil(untitled.avatarURL)
    }
}
