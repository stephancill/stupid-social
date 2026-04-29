import XCTest
@testable import NoFeedSocialCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testSavesLoadsUpdatesAndDeletesLocalXCredentials() throws {
        let suiteName = "tech.stupid.StupidSocial.tests.\(UUID().uuidString)"
        let fallbackStore = UserDefaults(suiteName: suiteName)!
        let store = KeychainCredentialStore(service: suiteName, fallbackStore: fallbackStore)
        defer {
            try? store.deleteXCredentials()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        let first = XCredentials(authToken: "first-token", ct0: "first-ct0")
        let firstResult = try store.saveXCredentials(first)

        XCTAssertEqual(firstResult, .localOnly)
        XCTAssertEqual(try store.loadXCredentials(), first)

        let second = XCredentials(authToken: "second-token", ct0: "second-ct0")
        let secondResult = try store.saveXCredentials(second)

        XCTAssertEqual(secondResult, .localOnly)
        XCTAssertEqual(try store.loadXCredentials(), second)

        try store.deleteXCredentials()
        XCTAssertNil(try store.loadXCredentials())
    }
}
