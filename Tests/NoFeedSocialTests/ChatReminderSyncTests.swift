import CryptoKit
import Foundation
@testable import NoFeedSocialCore
import NoFeedSocialPush
import XCTest

final class ChatReminderSyncTests: XCTestCase {
    private typealias State = ChatReminderStore.SyncState

    private func reminder(_ id: String, due: TimeInterval, text: String = "") -> ChatReminder {
        ChatReminder(
            id: id,
            destination: .spotify(chatId: "chat"),
            accountId: "account",
            network: .spotify,
            chatTitle: "Chat",
            messageId: "m-\(id)",
            senderName: nil,
            senderAvatarURL: nil,
            text: text,
            dueDate: Date(timeIntervalSince1970: due),
            pushedTo: nil,
        )
    }

    func testMergedUnionsRemindersByDueDate() {
        let merged = State.merged(
            State(reminders: [reminder("a", due: 200)], removed: [:]),
            State(reminders: [reminder("b", due: 100), reminder("a", due: 200)], removed: [:]),
            now: Date(timeIntervalSince1970: 0),
        )
        XCTAssertEqual(merged.reminders.map(\.id), ["b", "a"])
    }

    func testRemovalOnEitherSideWins() {
        let now = Date(timeIntervalSince1970: 1000)
        let merged = State.merged(
            State(reminders: [reminder("a", due: 200), reminder("b", due: 300)], removed: ["c": 900]),
            State(reminders: [reminder("c", due: 100)], removed: ["a": 950]),
            now: now,
        )
        XCTAssertEqual(merged.reminders.map(\.id), ["b"])
        XCTAssertEqual(merged.removed, ["a": 950, "c": 900])
    }

    func testOldTombstonesArePruned() {
        let now = Date(timeIntervalSince1970: ChatReminderStore.tombstoneLifetime + 1000)
        let merged = State.merged(State(reminders: [], removed: ["old": 500, "new": 2000]), State(reminders: [], removed: [:]), now: now)
        XCTAssertEqual(merged.removed, ["new": 2000])
    }

    func testPushedReminderDecryptsToItsNotification() throws {
        let keys = WebPushKeys.generate()
        let original = reminder("a", due: 100, text: "See you at 5")
        let payload = try JSONEncoder().encode(original.truncatedForPush(maxTextBytes: 600))
        let ciphertext = try WebPushEncryptor.encrypt(payload, publicKey: keys.publicKey, auth: keys.auth)
        let decrypted = try WebPushDecryptor.decrypt(ciphertext, keys: keys)

        XCTAssertEqual(try ChatReminderNotification(payload: decrypted), original.notification)
        XCTAssertEqual(try JSONDecoder().decode(ChatReminder.self, from: decrypted), original)
        XCTAssertThrowsError(try WebPushDecryptor.decrypt(ciphertext, keys: .generate()))
    }

    func testPushTextIsCutToWholeCharacters() {
        let cut = reminder("a", due: 0, text: String(repeating: "👍", count: 10)).truncatedForPush(maxTextBytes: 10)
        XCTAssertEqual(cut.text, "👍👍…")
        XCTAssertEqual(reminder("a", due: 0, text: "short").truncatedForPush(maxTextBytes: 10).text, "short")
    }

    @MainActor
    func testVapidAuthorizationVerifiesWithItsKey() throws {
        let key = P256.Signing.PrivateKey()
        let authorization = try ChatReminderPush.vapidAuthorization(key: key, now: Date(timeIntervalSince1970: 1000))
        let token = try XCTUnwrap(authorization.split(separator: " ")[1].split(separator: ",").first).dropFirst(2)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64URLEncoded: parts[2])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URLEncoded: parts[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://push.stupidtech.net")
        XCTAssertEqual(claims["exp"] as? Int, 1000 + 12 * 60 * 60)
        XCTAssertTrue(authorization.hasSuffix("k=\(key.publicKey.x963Representation.base64URLEncodedString)"))
    }
}
