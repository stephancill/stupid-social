import Foundation
@testable import NoFeedSocialCore
import XCTest

/// An account store on its own defaults suite and Keychain service, with a local-only key-value store.
func makeTestAccountStore(suite: String = "AccountStoreTests.\(UUID().uuidString)") -> (store: AccountStore, keychain: KeychainCredentialStore, defaults: UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    let keychain = KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true)
    return (AccountStore(defaults: defaults, kvStore: NSUbiquitousKeyValueStore(), keychain: keychain), keychain, defaults)
}

final class AccountStoreTests: XCTestCase {
    func testMergeKeepsTheNewerChangePerAccount() {
        typealias Entry = AccountStore.Entry
        let a = Account(id: "a", network: .x, handle: "me")
        let b = Account(id: "b", network: .x)
        let c = Account(id: "c", network: .instagram)
        let local = [
            "a": Entry(account: a, removed: false, changedAt: 100),
            "b": Entry(account: b, removed: false, changedAt: 100),
        ]
        let remote = [
            // Removed on another device after this one added it: the removal wins.
            "a": Entry(account: nil, removed: true, changedAt: 200),
            // Removed there before this device re-added it: the account stays.
            "b": Entry(account: nil, removed: true, changedAt: 50),
            "c": Entry(account: c, removed: false, changedAt: 10),
        ]
        let merged = AccountStore.merged(local, remote)
        XCTAssertEqual(merged["a"]?.removed, true)
        XCTAssertEqual(merged["b"]?.removed, false)
        XCTAssertEqual(merged["c"]?.account, c)
    }

    func testLoopbackApronServersStayOnTheDevice() throws {
        func apron(_ url: String) throws -> Account {
            try Account(id: "apron", network: .apron, serverURL: XCTUnwrap(URL(string: url)))
        }
        XCTAssertFalse(try AccountStore.isSynced(apron("ws://127.0.0.1:8765/")))
        XCTAssertFalse(try AccountStore.isSynced(apron("ws://localhost:8765/")))
        XCTAssertTrue(try AccountStore.isSynced(apron("wss://server.apron.chat/")))
        XCTAssertTrue(AccountStore.isSynced(Account(id: "x", network: .x)))
    }

    func testSameIdentityAddedOnTwoDevicesListsOnce() {
        let (store, _, _) = makeTestAccountStore()
        store.save(Account(id: "x-new", network: .x, remoteId: "12", addedAt: Date(timeIntervalSince1970: 20)))
        store.save(Account(id: "x", network: .x, remoteId: "12", addedAt: Date(timeIntervalSince1970: 10)))
        store.save(Account(id: "x-other", network: .x, remoteId: "34"))
        XCTAssertEqual(store.accounts.map(\.id), ["x", "x-other"])
        XCTAssertEqual(store.account(network: .x, remoteId: "12")?.id, "x")
    }

    func testRemovingDropsTheAccountAndItsLocalState() {
        let (store, _, _) = makeTestAccountStore()
        store.save(Account(id: "bluesky-1", network: .bluesky, remoteId: "did:plc:1"))
        store.setStatus(.invalidCredentials, id: "bluesky-1")
        store.remove(id: "bluesky-1")
        XCTAssertNil(store.account(id: "bluesky-1"))
        XCTAssertNil(store.status(id: "bluesky-1"))
        XCTAssertEqual(store.entries["bluesky-1"]?.removed, true)
    }

    func testScopedMetadataWritesPreferencesAndStatus() {
        let (store, _, _) = makeTestAccountStore()
        store.save(Account(id: "instagram-1", network: .instagram, remoteId: "42"))
        let metadata = store.metadata(for: "instagram-1")
        metadata.instagramAccount = InstagramAccountMetadata(accountId: "42", username: "example", status: .serviceError, enabledCategories: [.likes], storiesEnabled: false)
        XCTAssertEqual(store.account(id: "instagram-1")?.handle, "example")
        XCTAssertEqual(store.account(id: "instagram-1")?.preferences.instagramCategories, [.likes])
        XCTAssertEqual(store.status(id: "instagram-1"), .serviceError)
        // Another account's metadata is untouched, and nil writes don't remove anything.
        XCTAssertNil(store.metadata(for: "other").instagramAccount)
        metadata.instagramAccount = nil
        XCTAssertNotNil(store.account(id: "instagram-1"))
    }

    func testMigratesSingleAccountsKeepingTheirKeychainItems() throws {
        let suite = "AccountStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keychain = KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true)
        defer {
            try? keychain.deleteXCredentials()
            try? keychain.deleteInstagramCredentials()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        _ = try keychain.saveXCredentials(XCredentials(authToken: "token", ct0: "ct0"))
        _ = try keychain.saveInstagramCredentials(InstagramCredentials(sessionId: "s", csrfToken: "c", dsUserId: "42", mid: nil))
        let x = XAccountMetadata(accountId: "x", handle: "me", status: .valid, enabledCategories: [.mentions])
        try defaults.set(JSONEncoder().encode(x), forKey: "account.x")
        let farcaster = FarcasterAccountMetadata(username: "fc", fid: 7, status: .invalidCredentials)
        try defaults.set(JSONEncoder().encode(farcaster), forKey: "account.farcaster")

        let store = AccountStore(defaults: defaults, kvStore: NSUbiquitousKeyValueStore(), keychain: keychain)

        XCTAssertEqual(store.accounts.map(\.id), ["x", "farcaster", "instagram"])
        XCTAssertEqual(store.account(id: "x")?.handle, "me")
        // The "follows" category arrived after these accounts, so it's turned on once.
        XCTAssertEqual(store.account(id: "x")?.preferences.xCategories, [.mentions, .follows])
        XCTAssertEqual(store.account(id: "farcaster")?.remoteId, "7")
        XCTAssertEqual(store.status(id: "farcaster"), .invalidCredentials)
        XCTAssertEqual(store.account(id: "instagram")?.remoteId, "42")
        XCTAssertNotNil(try keychain.scoped(to: "x").loadXCredentials())
        XCTAssertNil(defaults.data(forKey: "account.x"))

        // A second launch doesn't migrate again.
        store.remove(id: "x")
        let relaunched = AccountStore(defaults: defaults, kvStore: NSUbiquitousKeyValueStore(), keychain: keychain)
        XCTAssertNil(relaunched.account(id: "x"))
    }

    func testScopedKeychainKeepsAccountsApart() throws {
        let (_, keychain, defaults) = makeTestAccountStore()
        let first = keychain.scoped(to: "x-1")
        let second = keychain.scoped(to: "x-2")
        defer {
            first.deleteAccountCredentials()
            second.deleteAccountCredentials()
            _ = defaults
        }
        _ = try first.saveXCredentials(XCredentials(authToken: "one", ct0: "a"))
        _ = try second.saveXCredentials(XCredentials(authToken: "two", ct0: "b"))
        XCTAssertEqual(try first.loadXCredentials()?.authToken, "one")
        XCTAssertEqual(try second.loadXCredentials()?.authToken, "two")
        first.deleteAccountCredentials()
        XCTAssertNil(try first.loadXCredentials())
        XCTAssertEqual(try second.loadXCredentials()?.authToken, "two")
    }

    func testChatSummariesAreScopedToTheirAccount() throws {
        let chat = ChatSummary(id: "t1", network: .x, title: "A", avatarURL: nil, preview: nil, timestamp: nil, unreadCount: 0, destination: .x(conversationId: "1:2"))
        let scoped = chat.scoped(to: "x-1")
        XCTAssertEqual(scoped.id, "x-1|t1")
        XCTAssertEqual(scoped.accountId, "x-1")
        XCTAssertEqual(scoped.scoped(to: "x-1"), scoped)
        let server = try XCTUnwrap(URL(string: "wss://server.apron.chat/"))
        let room = ChatSummary(id: "r", network: .apron, title: "R", avatarURL: nil, preview: nil, timestamp: nil, unreadCount: 0, destination: .apron(serverURL: server, roomId: "r"))
        let serverRoom = room.scoped(to: Account.apronId(serverURL: server))
        XCTAssertEqual(serverRoom.accountId, Account.apronId(serverURL: server))
        XCTAssertEqual(serverRoom.scoped(to: nil), serverRoom, "a row that names its account keeps it")
    }
}
