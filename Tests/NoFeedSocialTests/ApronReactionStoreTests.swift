import Foundation
@testable import NoFeedSocialCore
import XCTest

@MainActor
final class ApronReactionStoreTests: XCTestCase {
    private let server = URL(string: "wss://chat.example/ws")!
    private var store: ApronReactionStore!

    override func setUp() {
        store = ApronReactionStore(defaults: UserDefaults(suiteName: "ApronReactionStoreTests-\(UUID().uuidString)")!)
    }

    private func unseen(_ entries: [String: [String: (logId: Int64, emojis: [String])]], own: Set<String> = ["10", "20"]) -> [String] {
        store.unseenMessageIds(in: entries, isOwnMessage: own.contains, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "general")
    }

    func testARoomWithoutABaselineHasNothingUnseen() {
        XCTAssertEqual(unseen(["10": ["ada": (100, ["👍"])]]), [])
    }

    func testOnlyOthersReactionsToYourMessagesAfterTheBaselineAreUnseen() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        let entries: [String: [String: (logId: Int64, emojis: [String])]] = [
            "10": ["ada": (90, ["👍"])], // before the baseline
            "20": ["me": (110, ["👍"])], // your own reaction
            "30": ["ada": (120, ["👍"])], // someone else's message
            "40": ["ada": (130, [])], // removed
        ]
        XCTAssertEqual(unseen(entries, own: ["10", "20", "40"]), [])
        XCTAssertEqual(unseen(["20": ["ada": (110, ["❤️"])], "10": ["bob": (105, ["👍"])]]), ["10", "20"], "oldest message first")
    }

    func testSeeingAMessageHidesOnlyItsReactionsUntilANewOne() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.markSeen(["10": 110], serverURL: server, roomId: "general")
        XCTAssertEqual(unseen(["10": ["ada": (110, ["👍"])], "20": ["ada": (105, ["👍"])]]), ["20"])
        XCTAssertEqual(unseen(["10": ["ada": (110, ["👍"]), "bob": (115, ["🔥"])]]), ["10"], "a later reaction is unseen again")
    }

    func testTheBaselineIsSetOnce() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.setBaselineIfNeeded(200, serverURL: server, roomId: "general")
        XCTAssertEqual(unseen(["10": ["ada": (150, ["👍"])]]), ["10"])
    }

    func testOwnMessagesAreKeptOnlyForTrackedRooms() {
        store.addOwnMessageIds(["1"], serverURL: server, roomId: "general")
        XCTAssertEqual(store.ownMessageIds(serverURL: server, roomId: "general"), [])
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.addOwnMessageIds(["2", "1"], serverURL: server, roomId: "general")
        XCTAssertEqual(store.ownMessageIds(serverURL: server, roomId: "general"), ["1", "2"])
    }

    func testManySeenMessagesFoldIntoTheRoomsPosition() {
        store.setBaselineIfNeeded(0, serverURL: server, roomId: "general")
        let limit = ApronReactionStore.seenOnLimit
        let seen = Dictionary(uniqueKeysWithValues: (1 ... limit + 1).map { ("\($0)", Int64($0)) })
        store.markSeen(seen, serverURL: server, roomId: "general")
        // The oldest folded into the room's position, which still covers it.
        XCTAssertEqual(unseen(["1": ["ada": (1, ["👍"])]], own: ["1"]), [])
        XCTAssertEqual(unseen(["1": ["ada": (2, ["👍"])]], own: ["1"]), ["1"])
    }

    func testRemovingAServerForgetsItsRooms() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.removeServer(server)
        XCTAssertEqual(unseen(["10": ["ada": (150, ["👍"])]]), [])
    }
}
