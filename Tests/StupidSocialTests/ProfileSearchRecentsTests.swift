import Foundation
@testable import StupidSocialCore
import SwiftData
import XCTest

/// Profiles opened from search come back on the search page, most recent first.
@MainActor
final class ProfileSearchRecentsTests: XCTestCase {
    private let suite = "ProfileSearchRecentsTests-\(UUID().uuidString)"
    /// Kept for the test's duration, as the cache's context needs its container.
    private var container: ModelContainer?

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testVisitsAreNewestFirstWithoutDuplicates() {
        let search = makeSearch()
        search.recordVisit(profile("1"))
        search.recordVisit(profile("2"))
        search.recordVisit(profile("1"))
        XCTAssertEqual(search.recentProfiles.map(\.id), ["1", "2"])
    }

    func testTheSameIdOnAnotherNetworkIsAnotherProfile() {
        let search = makeSearch()
        search.recordVisit(profile("1", network: .x))
        search.recordVisit(profile("1", network: .instagram))
        XCTAssertEqual(search.recentProfiles.map(\.network), [.instagram, .x])
    }

    func testOnlyTheNewestAreKept() {
        let search = makeSearch()
        for index in 0 ..< ProfileSearchViewModel.recentsLimit + 3 {
            search.recordVisit(profile("\(index)"))
        }
        XCTAssertEqual(search.recentProfiles.count, ProfileSearchViewModel.recentsLimit)
        XCTAssertEqual(search.recentProfiles.first?.id, "\(ProfileSearchViewModel.recentsLimit + 2)")
    }

    func testRecentsSurviveRelaunchAndCanBeRemoved() throws {
        let search = makeSearch()
        var found = profile("1")
        found.accountId = "x-account"
        search.recordVisit(found)
        search.recordVisit(profile("2"))
        let relaunched = makeSearch()
        XCTAssertEqual(relaunched.recentProfiles.map(\.id), ["2", "1"])
        XCTAssertEqual(relaunched.recentProfiles.last?.profile.accountId, "x-account", "opens through the account it was found with")
        try relaunched.removeRecent(XCTUnwrap(relaunched.recentProfiles.first))
        XCTAssertEqual(makeSearch().recentProfiles.map(\.id), ["1"])
        relaunched.clearRecents()
        XCTAssertEqual(makeSearch().recentProfiles, [])
    }

    private func makeSearch() -> ProfileSearchViewModel {
        if container == nil {
            container = try? ModelContainer(for: CachedNotification.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let service = FeedService(accountSources: { [] }, cacheStore: NotificationCacheStore(context: container!.mainContext))
        return ProfileSearchViewModel(feedService: service, defaults: UserDefaults(suiteName: suite)!)
    }

    private func profile(_ id: String, network: SocialNetwork = .x) -> NetworkProfile {
        NetworkProfile(id: id, network: network, username: "user\(id)", displayName: "User \(id)", avatarURL: nil, followerCount: 10, followingCount: 5)
    }
}
