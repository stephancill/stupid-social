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
