import Foundation
@testable import NoFeedSocialCore
import XCTest

final class StorySeenSyncTests: XCTestCase {
    func testMergedKeepsMaxPerActorAndUnions() {
        let merged = StorySeenSync.merged(
            local: ["spotify:user:a": 100, "spotify:user:b": 50],
            remote: ["spotify:user:a": 90, "spotify:user:b": 80, "spotify:user:c": 70],
        )
        XCTAssertEqual(merged["spotify:user:a"], 100)
        XCTAssertEqual(merged["spotify:user:b"], 80)
        XCTAssertEqual(merged["spotify:user:c"], 70)
    }

    func testMergedPrefersRemoteWhenLocalIsEmpty() {
        let merged = StorySeenSync.merged(local: [:], remote: ["user": 120])
        XCTAssertEqual(merged["user"], 120)
    }

    func testMergedIgnoresRemoteWhenLocalIsNewer() {
        let merged = StorySeenSync.merged(local: ["user": 200], remote: ["user": 150])
        XCTAssertEqual(merged["user"], 200)
    }
}
