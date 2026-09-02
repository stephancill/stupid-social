import Foundation
@testable import NoFeedSocialCore
import XCTest

final class GitHubActivityParserTests: XCTestCase {
    func testNormalizesCreatedRepositoryCards() throws {
        let html = card(cardType: "CREATED_REPOSITORY", createdAt: "2026-08-30T06:13:17.000-07:00", recordId: "created-1",
                        actorHref: "/octocat", actorId: "1", repoHref: "/octocat/brand-new", position: 0, subPosition: nil)

        let groups = try GitHubActivityParser.parse(html).storyGroups
        let activity = try XCTUnwrap(groups.first?.activities.first)

        XCTAssertEqual(activity.kind, .createdRepository)
        XCTAssertEqual(activity.actor.username, "octocat")
        XCTAssertEqual(activity.targetName, "octocat/brand-new")
        XCTAssertEqual(activity.summary, "octocat created octocat/brand-new")
    }

    func testGroupsActivitiesByActorAndOrdersSlidesChronologically() throws {
        let html = [
            card(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "star-1",
                 actorHref: "/octocat", actorId: "1", repoHref: "/example/star", position: 0, subPosition: nil),
            card(cardType: "FORKED_REPOSITORY", createdAt: "2026-08-28T12:24:40.000-07:00", recordId: "fork-1",
                 actorHref: "/octocat", actorId: "1", repoHref: "/example/older", position: 1, subPosition: nil),
        ].joined()

        let groups = try GitHubActivityParser.parse(html).storyGroups

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].actor.id, "1")
        XCTAssertEqual(groups[0].actor.username, "octocat")
        XCTAssertEqual(groups[0].activities.map(\.kind), [.forkedRepository, .starredRepository])
        XCTAssertEqual(groups[0].activities.map(\.targetName), ["example/older", "example/star"])
        XCTAssertEqual(groups[0].activities.map(\.summary), ["octocat forked example/older", "octocat starred example/star"])
    }

    func testExpandsOnlyVisibleRollupCardsAndInheritsRollupActor() throws {
        let primary = starred(createdAt: "2026-08-28T14:25:14.000-07:00", recordId: "record-a",
                              actorHref: "/mikedemarais", actorId: "4321", repoHref: "/kernel/browser-loop", sub: 0)
        let secondVisible = starred(createdAt: "2026-08-28T14:25:14.000-07:00", recordId: "record-b",
                                    actorHref: "/kernel", actorId: "99", repoHref: "/kernel/browser-tools", sub: 1)
        let hiddenMembers = (2 ... 16).map { index in
            starred(createdAt: "2026-08-28T14:25:14.000-07:00", recordId: "hidden-\(Int(index))",
                    actorHref: "/owner-\(Int(index))", actorId: "900-\(Int(index))", repoHref: "/owner-\(Int(index))/repo-\(Int(index))", sub: Int(index))
        }.joined()

        let html = """
        <div>
        \(primary)
        \(secondVisible)
        <div class="Details js-details-container">
          <div class="Details-content--hidden color-bg-overlay">
            \(hiddenMembers)
          </div>
        </div>
        </div>
        """

        let groups = try GitHubActivityParser.parse(html).storyGroups
        let actor = try XCTUnwrap(groups.first?.actor)
        let activities = try XCTUnwrap(groups.first?.activities)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(actor.username, "mikedemarais")
        XCTAssertEqual(activities.map(\.targetName), ["kernel/browser-loop", "kernel/browser-tools"])
        XCTAssertEqual(activities.map(\.summary), ["mikedemarais starred kernel/browser-loop", "mikedemarais starred kernel/browser-tools"])
    }

    func testExtractsRepoCardMetadata() throws {
        let view = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil)
        let actorClick = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil, clickTarget: "feed_user_link", metadata: ["clicked_resource_type": "USER", "clicked_resource_id": "1"])
        let repoClick = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil, clickTarget: "repository_link", metadata: ["clicked_resource_type": "REPO", "clicked_resource_id": "repo-1"])

        let html = """
        <article data-hydro-view="\(view)">
        <a href="/octocat" data-hydro-click="\(actorClick)"></a>
        <a href="/example/star" data-hydro-click="\(repoClick)"></a>
        <div class="d-flex mb-2 wb-break-word">
          <a href="#" class="Link d-block"></a>
          <a href="/example/star" class="Link--primary Link text-bold">example/star</a>
        </div>
        <div>A tiny, self-hosted catalog of starred things.</div>
        <div class="pt-2">
          <span itemprop="programmingLanguage">Go</span>
          <a aria-label="63 stargazers" href="#">63</a>
        </div>
        </article>
        """

        let groups = try GitHubActivityParser.parse(html).storyGroups
        let activity = try XCTUnwrap(groups.first?.activities.first)

        XCTAssertEqual(groups.flatMap(\.activities).count, 1)
        XCTAssertEqual(activity.targetName, "example/star")
        XCTAssertEqual(activity.repoDescription, "A tiny, self-hosted catalog of starred things.")
        XCTAssertEqual(activity.repoLanguage, "Go")
        XCTAssertEqual(activity.repoStars, "63")
    }

    func testFormatsRepoStarCountToThreeSignificantFigures() throws {
        let cases: [(labels: String, expected: String)] = [
            ("63", "63"),
            ("1,234", "1.23k"),
            ("12,300", "12.3k"),
            ("104,000", "104k"),
            ("1,234,000", "1.23m"),
            ("1,050,000", "1.05m"),
        ]
        for testCase in cases {
            let view = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil)
            let actorClick = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil, clickTarget: "feed_user_link", metadata: ["clicked_resource_type": "USER", "clicked_resource_id": "1"])
            let repoClick = payload(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "repo-1", position: 0, subPosition: nil, clickTarget: "repository_link", metadata: ["clicked_resource_type": "REPO", "clicked_resource_id": "repo-1"])
            let html = """
            <article data-hydro-view="\(view)">
            <a href="/octocat" data-hydro-click="\(actorClick)"></a>
            <a href="/example/star" data-hydro-click="\(repoClick)"></a>
            <div class="d-flex mb-2 wb-break-word">
              <a href="#" class="Link d-block"></a>
              <a href="/example/star" class="Link--primary Link text-bold">example/star</a>
            </div>
            <div class="pt-2">
              <span itemprop="programmingLanguage">Go</span>
              <a aria-label="\(testCase.labels) stargazers" href="#">\(testCase.labels)</a>
            </div>
            </article>
            """
            let groups = try GitHubActivityParser.parse(html).storyGroups
            let activity = try XCTUnwrap(groups.first?.activities.first)
            XCTAssertEqual(activity.repoStars, testCase.expected, "for raw count \(testCase.labels)")
        }
    }

    func testFollowedUserBioExcludesMutedHandleAndCounts() throws {
        let username = "knadh"
        let html = #"""
        <article data-hydro-view="">
        <a href="/someone">someone</a>
        <a href="/\#(username)" class="Link--primary Link text-bold">Kailash Nadh</a>
        <span data-view-component="true" class="color-fg-muted text-normal">\#(username)</span>
        </p>
        <div class="m-0 mt-1 wb-break-all"><div>Hobbyist developer / CTO <a href="https://github.com/zerodha">@zerodha</a> / Volunteer</div></div>
        <p class="m-0 mt-1 color-fg-muted">
          <span class="tmp-mr-3">66 repositories</span>
          <span>13.8k followers</span>
        </p>
        </article>
        """#

        let metadata = try XCTUnwrap(GitHubActivityParser.followUserMetadata(for: username, in: html))

        XCTAssertEqual(metadata.displayName, "Kailash Nadh")
        XCTAssertEqual(metadata.bio, "Hobbyist developer / CTO @zerodha / Volunteer")
        XCTAssertFalse(metadata.bio?.contains("muted") ?? false)
        XCTAssertFalse(metadata.bio?.contains("repositories") ?? false)
        XCTAssertEqual(metadata.repos, "66")
        XCTAssertEqual(metadata.followers, "13.8k")
    }

    func testMovesStarOfViewerRepositoryToNotifications() throws {
        let viewer = "stephancill"
        let html = [
            card(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-29T05:30:41.000-07:00", recordId: "star-your-1",
                 actorHref: "/SystemWOWS", actorId: "700", repoHref: "/\(viewer)/pfwc", position: 0, subPosition: nil),
            card(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-29T04:11:25.000-07:00", recordId: "star-other-1",
                 actorHref: "/noctisatrae", actorId: "701", repoHref: "/apache/datafusion", position: 1, subPosition: nil),
        ].joined()

        let result = try GitHubActivityParser.parse(html, viewerUsername: viewer)

        XCTAssertEqual(result.notificationItems.map(\.targetName), ["\(viewer)/pfwc"])
        XCTAssertEqual(result.notificationItems.map(\.kind), [.starredRepository])
        let storyTargets = result.storyGroups.flatMap(\.activities).map(\.targetName)
        XCTAssertEqual(storyTargets, ["apache/datafusion"])
    }

    func testWithoutViewerUsernameEverythingStaysStories() throws {
        let html = card(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-29T05:30:41.000-07:00", recordId: "star-a",
                        actorHref: "/SystemWOWS", actorId: "700", repoHref: "/stephancill/pfwc", position: 0, subPosition: nil)

        let result = try GitHubActivityParser.parse(html)

        XCTAssertTrue(result.notificationItems.isEmpty)
        XCTAssertEqual(result.storyGroups.flatMap(\.activities).map(\.targetName), ["stephancill/pfwc"])
    }

    /// GitHub aggregates several distinct people who starred the same owned repo
    /// into one card with ``NAME</a> starred`` rows; each should surface as its
    /// own "starred your repository" notification.
    func testAggregatedYourRepositoryRowsExpandToNotifications() throws {
        let viewer = "stephancill"
        let html = """
        <article>
          <a href="/\(viewer)/pfwc" class="Link--primary Link text-bold">\(viewer)/pfwc</a>
          <a href="/s0urledd" class="Link--primary text-bold">s0urledd</a> starred
          <a href="/muhamedzeema" class="Link--primary text-bold">muhamedzeema</a> starred
          <a href="/juliustip" class="Link--primary text-bold">juliustip</a> starred
        </article>
        """

        let result = try GitHubActivityParser.parse(html, viewerUsername: viewer)

        let actors = result.notificationItems.compactMap(\.actor.username).sorted()
        XCTAssertEqual(actors, ["juliustip", "muhamedzeema", "s0urledd"])
        XCTAssertEqual(Set(result.notificationItems.map(\.targetName)), ["\(viewer)/pfwc"])
    }

    /// Each aggregated ''starred your repository'' row carries its own star time.
    /// The timestamp is read from the card's hovercard URL, where the ``created_at``
    /// key is URL-encoded as ``…%5Bcreated_at%5D=2026-08-29+02%3A14%3A51+-0700``.
    /// When that parse fails, the parser must not fall back to "now" for every row.
    func testAggregatedYourRepositoryRowsKeepPerCardTimestamp() throws {
        let viewer = "stephancill"
        let html = """
        <article data-hovercard-url="https://github.com/users/s0urledd/hovercard?payload%5Bfeed_card%5D%5Bcreated_at%5D=2026-08-29+02%3A14%3A51+-0700">
          <a href="/\(viewer)/pfwc" class="Link--primary Link text-bold">\(viewer)/pfwc</a>
          <a href="/s0urledd" class="Link text-bold">s0urledd</a> starred
        </article>
        """

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let expected = try XCTUnwrap(formatter.date(from: "2026-08-29 02:14:51 -0700"))

        let result = try GitHubActivityParser.parse(html, viewerUsername: viewer)
        let item = try XCTUnwrap(result.notificationItems.first)
        XCTAssertEqual(item.timestamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(item.actor.timestamp).timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001,
        )
    }

    /// GitHub renders one person starring several of the viewer's repos as a
    /// rollup: a head card (sub_position 0) names the actor and shows only the
    /// first repo, plus actor-less sibling cards (sub_positions 1..N) each with
    /// one more repo. The head's actor must be propagated to the siblings so all
    /// N repos surface, not just the head's.
    func testRollupExpandsSameActorAcrossManyRepos() throws {
        let viewer = "stephancill"
        func chunk(sub: Int, repo: String, actorKey: String?) -> String {
            let row = actorKey.map { "<a href=\"/\($0)\" class=\"Link--primary text-bold\">\($0)</a> starred 5 of your repositories" } ?? ""
            return """
            <article data-hydro-inert="&quot;card_type&quot;:&quot;STARRED_REPOSITORY&quot;,&quot;card_position&quot;:1,&quot;card_sub_position&quot;:\(sub)">
              <a href="/\(viewer)/\(repo)" class="Link--primary Link text-bold">\(viewer)/\(repo)</a>
            \(row)
            </article>
            """
        }
        let html = chunk(sub: 0, repo: "rpc-racer", actorKey: "Sandalots")
            + chunk(sub: 1, repo: "search-bangs-worker", actorKey: nil)
            + chunk(sub: 2, repo: "stupid-app-cli", actorKey: nil)
            + chunk(sub: 3, repo: "agent-cal", actorKey: nil)

        let result = try GitHubActivityParser.parse(html, viewerUsername: viewer)
        let sandalotsTargets = Set(result.notificationItems
            .filter { $0.actor.username == "Sandalots" }
            .map(\.targetName))
        XCTAssertEqual(sandalotsTargets, [
            "\(viewer)/rpc-racer",
            "\(viewer)/search-bangs-worker",
            "\(viewer)/stupid-app-cli",
            "\(viewer)/agent-cal",
        ])
    }

    // MARK: - Card builders

    private func starred(createdAt: String, recordId: String, actorHref: String, actorId: String, repoHref: String, sub: Int?) -> String {
        card(cardType: "STARRED_REPOSITORY", createdAt: createdAt, recordId: recordId,
             actorHref: actorHref, actorId: actorId, repoHref: repoHref, position: 1, subPosition: sub)
    }

    private func card(cardType: String, createdAt: String, recordId: String, actorHref: String, actorId: String, repoHref: String, position: Int, subPosition: Int?) -> String {
        let actorMetadata: [String: Any] = ["clicked_resource_type": "USER", "clicked_resource_id": actorId]
        let repoMetadata: [String: Any] = ["clicked_resource_type": "REPO", "clicked_resource_id": recordId]
        return """
        <article data-hydro-view="\(payload(cardType: cardType, createdAt: createdAt, recordId: recordId, position: position, subPosition: subPosition))">
          <a href="\(actorHref)" data-hydro-click="\(payload(cardType: cardType, createdAt: createdAt, recordId: recordId, position: position, subPosition: subPosition, clickTarget: "feed_user_link", metadata: actorMetadata))"></a>
          <a href="\(repoHref)" data-hydro-click="\(payload(cardType: cardType, createdAt: createdAt, recordId: recordId, position: position, subPosition: subPosition, clickTarget: "repository_link", metadata: repoMetadata))"></a>
        </article>
        """
    }

    private func payload(cardType: String, createdAt: String, recordId: String, position: Int, subPosition: Int?, clickTarget: String? = nil, metadata: [String: Any]? = nil) -> String {
        var feedCard: [String: Any] = [
            "card_type": cardType,
            "created_at": createdAt,
            "record_id": recordId,
            "resource_type": "REPO",
            "resource_id": recordId,
            "card_position": position,
        ]
        feedCard["card_sub_position"] = subPosition ?? NSNull()
        var value: [String: Any] = ["feed_card": feedCard]
        value["click_target"] = clickTarget
        value["metadata"] = metadata
        let data = try! JSONSerialization.data(withJSONObject: ["payload": value], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
