import Foundation
@testable import NoFeedSocialCore
import XCTest

@MainActor
final class StoryBarViewModelTests: XCTestCase {
    func testStartsAtOldestUnreadInstagramSlide() {
        let viewModel = StoryBarViewModel(instagramSource: nil)
        let selectedItem = storyItem(seenTimestamp: 150)
        let items = viewModel.storyViewerItems(for: selectedItem, in: [selectedItem])

        XCTAssertEqual(viewModel.storyViewerStartSlideIndex(for: selectedItem, in: items), 1)
        guard case let .instagram(reel) = items[0] else {
            return XCTFail("Expected an Instagram reel")
        }
        XCTAssertEqual(reel.slides.map(\.takenAt), [100, 200, 300])
    }

    func testStartsAtOldestInstagramSlideWhenAllAreRead() {
        let viewModel = StoryBarViewModel(instagramSource: nil)
        let selectedItem = storyItem(seenTimestamp: 300)
        let items = viewModel.storyViewerItems(for: selectedItem, in: [selectedItem])

        XCTAssertEqual(viewModel.storyViewerStartSlideIndex(for: selectedItem, in: items), 0)
    }

    func testStartsAtOldestUnreadGitHubSlide() {
        let defaults = makeTestDefaults()
        let viewModel = StoryBarViewModel(
            instagramSource: nil,
            githubSeenStore: GitHubActivitySeenStore(defaults: defaults, key: "githubTestSeen"),
        )
        let group = githubGroup()
        let selectedItem = StoryBarItem.github(group)
        let items = viewModel.storyViewerItems(for: selectedItem, in: [selectedItem])

        defaults.set(["user": 150.0], forKey: "githubTestSeen")

        XCTAssertEqual(viewModel.storyViewerStartSlideIndex(for: selectedItem, in: items), 1)
    }

    func testStartsAtOldestGitHubSlideWhenAllAreRead() {
        let defaults = makeTestDefaults()
        let viewModel = StoryBarViewModel(
            instagramSource: nil,
            githubSeenStore: GitHubActivitySeenStore(defaults: defaults, key: "githubTestSeen"),
        )
        let selectedItem = StoryBarItem.github(githubGroup())
        let items = viewModel.storyViewerItems(for: selectedItem, in: [selectedItem])

        defaults.set(["user": 300.0], forKey: "githubTestSeen")

        XCTAssertEqual(viewModel.storyViewerStartSlideIndex(for: selectedItem, in: items), 0)
    }

    private func makeTestDefaults() -> UserDefaults {
        UserDefaults(suiteName: "StoryBarViewModelTests-\(UUID().uuidString)")!
    }

    private func githubGroup() -> GitHubActivityGroup {
        let actor = NotificationActor(id: "user", network: .github, username: "user", displayName: nil, avatarURL: nil)
        let activities = [100.0, 200.0, 300.0].map { timestamp in
            GitHubActivityItem(
                id: "activity-\(Int(timestamp))",
                kind: .starredRepository,
                timestamp: Date(timeIntervalSince1970: timestamp),
                actor: actor,
                targetId: "repo",
                targetName: "user/repo",
                targetURL: URL(string: "https://github.com/user/repo")!,
                targetAvatarURL: nil,
                summary: "starred",
            )
        }
        return GitHubActivityGroup(actor: actor, activities: activities)
    }

    private func storyItem(seenTimestamp: Double) -> StoryBarItem {
        let actor = NotificationActor(id: "user", network: .instagram, username: "user", displayName: nil, avatarURL: nil)
        let slides = [300.0, 100.0, 200.0].map { timestamp in
            InstagramStorySlide(
                id: String(Int(timestamp)),
                imageURL: URL(string: "https://example.com/\(Int(timestamp)).jpg")!,
                videoURL: nil,
                isVideo: false,
                takenAt: timestamp,
            )
        }
        return .instagram(InstagramStoryReel(id: "user", user: actor, slides: slides, seenTimestamp: seenTimestamp))
    }
}
