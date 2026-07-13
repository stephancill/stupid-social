import Foundation
@testable import NoFeedSocialCore
import XCTest

final class SpotifyActivitySeenStoreTests: XCTestCase {
    func testMarksActivitySeenByUserTimestamp() throws {
        let suiteName = "SpotifyActivitySeenStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SpotifyActivitySeenStore(defaults: defaults)
        let firstActivity = Date(timeIntervalSince1970: 100)
        let newerActivity = Date(timeIntervalSince1970: 120)

        XCTAssertFalse(store.isSeen(userURI: "spotify:user:one", activityTimestamp: firstActivity))

        store.markSeen(userURI: "spotify:user:one", activityTimestamp: firstActivity)

        XCTAssertTrue(store.isSeen(userURI: "spotify:user:one", activityTimestamp: firstActivity))
        XCTAssertFalse(store.isSeen(userURI: "spotify:user:one", activityTimestamp: newerActivity))
        XCTAssertFalse(store.isSeen(userURI: "spotify:user:two", activityTimestamp: firstActivity))
    }
}
