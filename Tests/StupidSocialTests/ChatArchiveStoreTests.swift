import Foundation
@testable import StupidSocialCore
import XCTest

@MainActor
final class ChatArchiveStoreTests: XCTestCase {
    private var kvStore: ArchiveMemoryKeyValueStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        kvStore = ArchiveMemoryKeyValueStore()
    }

    /// Another device's store, sharing iCloud.
    private func makeStore() -> ChatArchiveStore {
        ChatArchiveStore(defaults: UserDefaults(suiteName: "ChatArchiveStoreTests-\(UUID().uuidString)")!, kvStore: kvStore, now: { [unowned self] in clock })
    }

    func testAChatArchivedOnOneDeviceIsArchivedOnTheOthers() {
        let phone = makeStore()
        phone.setArchived(true, chatId: "instagram-1|instagram:42")
        XCTAssertTrue(phone.isArchived("instagram-1|instagram:42"))
        XCTAssertTrue(makeStore().isArchived("instagram-1|instagram:42"))
        XCTAssertFalse(makeStore().isArchived("instagram-1|instagram:43"))
    }

    func testTheLaterChangeWinsSoUnarchivingReachesDevicesThatHadItArchived() {
        let phone = makeStore()
        phone.setArchived(true, chatId: "chat")
        let iPad = makeStore()
        clock += 60
        iPad.setArchived(false, chatId: "chat")
        XCTAssertFalse(makeStore().isArchived("chat"))
    }

    func testMergeTakesTheLaterChangePerChat() {
        typealias Change = ChatArchiveStore.Change
        let local = ["a": Change(archived: true, at: 10), "b": Change(archived: false, at: 30)]
        let remote = ["a": Change(archived: false, at: 20), "b": Change(archived: true, at: 20), "c": Change(archived: true, at: 5)]
        XCTAssertEqual(ChatArchiveStore.merged(local, remote), ["a": Change(archived: false, at: 20), "b": Change(archived: false, at: 30), "c": Change(archived: true, at: 5)])
    }

    func testOldUnarchivesArePrunedButArchivesStay() {
        typealias Change = ChatArchiveStore.Change
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.timeIntervalSince1970 - ChatArchiveStore.unarchiveRetention - 1
        let pruned = ChatArchiveStore.pruned(["kept": Change(archived: true, at: old), "gone": Change(archived: false, at: old), "recent": Change(archived: false, at: now.timeIntervalSince1970)], now: now)
        XCTAssertEqual(Set(pruned.keys), ["kept", "recent"])
    }
}

private final class ArchiveMemoryKeyValueStore: NSUbiquitousKeyValueStore {
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
