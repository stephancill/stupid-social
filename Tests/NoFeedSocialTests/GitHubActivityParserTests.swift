import Foundation
@testable import NoFeedSocialCore
import XCTest

final class GitHubActivityParserTests: XCTestCase {
    func testGroupsActivitiesByActorAndOrdersSlidesChronologically() throws {
        let html = [
            card(cardType: "STARRED_REPOSITORY", createdAt: "2026-08-28T15:24:40.000-07:00", recordId: "star-1",
                 actorHref: "/octocat", actorId: "1", repoHref: "/example/star", position: 0, subPosition: nil),
            card(cardType: "FORKED_REPOSITORY", createdAt: "2026-08-28T12:24:40.000-07:00", recordId: "fork-1",
                 actorHref: "/octocat", actorId: "1", repoHref: "/example/older", position: 1, subPosition: nil),
        ].joined()

        let groups = try GitHubActivityParser.parse(html)

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

        let groups = try GitHubActivityParser.parse(html)
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

        let groups = try GitHubActivityParser.parse(html)
        let activity = try XCTUnwrap(groups.first?.activities.first)

        XCTAssertEqual(groups.flatMap(\.activities).count, 1)
        XCTAssertEqual(activity.targetName, "example/star")
        XCTAssertEqual(activity.repoDescription, "A tiny, self-hosted catalog of starred things.")
        XCTAssertEqual(activity.repoLanguage, "Go")
        XCTAssertEqual(activity.repoStars, "63")
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
