import Foundation
@testable import StupidSocialCore
import XCTest

@MainActor
final class ApronReactionStoreTests: XCTestCase {
    private let server = URL(string: "wss://chat.example/ws")!
    private var store: ApronReactionStore!
    private var kvStore: MemoryKeyValueStore!

    override func setUp() {
        kvStore = MemoryKeyValueStore()
        store = makeStore()
    }

    /// Another device's store, sharing iCloud.
    private func makeStore() -> ApronReactionStore {
        ApronReactionStore(defaults: UserDefaults(suiteName: "ApronReactionStoreTests-\(UUID().uuidString)")!, kvStore: kvStore)
    }

    func testWhatOneDeviceSawIsSeenOnTheOthers() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.addOwnMessageIds(["10", "20"], serverURL: server, roomId: "general")
        store.markSeen(["10": 110], serverURL: server, roomId: "general")
        let other = makeStore()
        XCTAssertTrue(other.ownMessageIds(serverURL: server, roomId: "general").isEmpty, "baselines and own messages stay on each device")
        other.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        other.addOwnMessageIds(["10", "20"], serverURL: server, roomId: "general")
        let entries: [String: [String: (logId: Int64, emojis: [String])]] = ["10": ["ada": (110, ["👍"])], "20": ["ada": (105, ["👍"])]]
        XCTAssertEqual(other.unseenMessageIds(in: entries, isOwnMessage: { _ in true }, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "general", now: Self.now), ["20"])

        // The other device's older view doesn't undo what this one saw since.
        other.markSeen(["20": 105], serverURL: server, roomId: "general")
        store = makeStore()
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        XCTAssertEqual(unseen(entries), [])
    }

    /// The log ids here are a few milliseconds after 1970, so "now" is too, keeping them in the 3-day window.
    private static let now = Date(timeIntervalSince1970: 1)

    func testOnlyReactionsFromTheLastThreeDaysAreUnseen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: Int64 = 24 * 60 * 60 * 1000
        let nowId = Int64(now.timeIntervalSince1970 * 1000)
        store.setBaselineIfNeeded(nowId - 10 * day, serverURL: server, roomId: "general")
        store.addOwnMessageIds(["10", "20"], serverURL: server, roomId: "general")
        let entries: [String: [String: (logId: Int64, emojis: [String])]] = [
            "10": ["ada": (nowId - 4 * day, ["👍"])],
            "20": ["ada": (nowId - 2 * day, ["👍"])],
        ]
        XCTAssertEqual(store.unseenMessageIds(in: entries, isOwnMessage: { _ in true }, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "general", now: now), ["20"])
    }

    /// The user's messages `own` are registered as the chat and Chats list do.
    private func unseen(_ entries: [String: [String: (logId: Int64, emojis: [String])]], own: Set<String> = ["10", "20"]) -> [String] {
        store.addOwnMessageIds(own, serverURL: server, roomId: "general")
        return store.unseenMessageIds(in: entries, isOwnMessage: own.contains, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "general", now: Self.now)
    }

    func testOnlyTheUsersNewestMessagesAcrossRoomsCanHaveUnseenReactions() {
        let limit = ApronReactionStore.messageLimit
        store.setBaselineIfNeeded(0, serverURL: server, roomId: "general")
        store.setBaselineIfNeeded(0, serverURL: server, roomId: "random")
        store.addOwnMessageIds(["1"], serverURL: server, roomId: "general")
        store.addOwnMessageIds((2 ... limit + 1).map(String.init), serverURL: server, roomId: "random")
        XCTAssertEqual(store.ownMessageIds(serverURL: server, roomId: "general"), [], "pushed out by newer messages in another room")
        XCTAssertEqual(store.unseenMessageIds(in: ["1": ["ada": (5, ["👍"])]], isOwnMessage: { _ in true }, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "general", now: Self.now), [])
        XCTAssertEqual(store.unseenMessageIds(in: ["2": ["ada": (5, ["👍"])]], isOwnMessage: { _ in true }, isOwnUser: { $0 == "me" }, serverURL: server, roomId: "random", now: Self.now), ["2"])
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

    func testSeenMarksKeepToTheNewestMessages() {
        store.setBaselineIfNeeded(0, serverURL: server, roomId: "general")
        let limit = ApronReactionStore.messageLimit
        store.markSeen(Dictionary(uniqueKeysWithValues: (1 ... limit + 1).map { ("\($0)", Int64($0)) }), serverURL: server, roomId: "general")
        let synced = try? JSONDecoder().decode([String: Int64].self, from: XCTUnwrap(kvStore.data(forKey: "com.stupid.apron.reactionmarks")))
        XCTAssertEqual(synced?.count, limit)
        XCTAssertNil(synced?["\(server.absoluteString)|general|1"], "the oldest message's mark goes")
    }

    func testRemovingAServerForgetsItsRooms() {
        store.setBaselineIfNeeded(100, serverURL: server, roomId: "general")
        store.removeServer(server)
        XCTAssertEqual(unseen(["10": ["ada": (150, ["👍"])]]), [])
    }
}

/// iCloud Key-Value storage in memory: the test host has no iCloud entitlement, so the real one keeps nothing.
private final class MemoryKeyValueStore: NSUbiquitousKeyValueStore {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    override func object(forKey key: String) -> Any? {
        values[key]
    }

    override func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    override func removeObject(forKey key: String) {
        values[key] = nil
    }

    override func synchronize() -> Bool {
        true
    }
}
