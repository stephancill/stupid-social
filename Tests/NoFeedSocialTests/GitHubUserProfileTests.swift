import Foundation
@testable import NoFeedSocialCore
import XCTest

final class GitHubUserProfileTests: XCTestCase {
    /// A profile with a real bio, counts, location and a website (link order
    /// ``rel=nofollow me`` before ``href``) parses into all fields.
    func testParsesFullProfile() throws {
        let html = """
        <meta name="description" content="cypherpunk wannabe. stephancill has 198 repositories available. Follow their code on GitHub.">
        <meta property="og:description" content="cypherpunk wannabe. stephancill has 198 repositories available. Follow their code on Twitter.">
        <h1 class="vcard-names"><span class="p-name vcard-fullname d-block overflow-hidden" itemprop="name">Stephan Cilliers </span>
        <span class="p-nickname vcard-username d-block" itemprop="additionalName">stephancill </span></h1>
        <div class="vcard-details">
          <li class="vcard-detail pt-1" itemprop="social"><svg></svg> <a rel="nofollow me" class="Link--primary wb-break-all" href="https://stephancill.eth.limo">https://stephancill.eth.limo</a></li>
          <li class="vcard-detail pt-1" itemprop="homeLocation" aria-label="Home location: Cape Town"><span class="p-label">Cape Town</span></li>
        </div>
        <a class="Link--secondary no-underline no-wrap" href="https://github.com/stephancill?tab=followers"> <span class="text-bold color-fg-default">183</span> followers </a>
        <a class="Link--secondary no-underline no-wrap" href="https://github.com/stephancill?tab=following"> <span class="text-bold color-fg-default">127</span> following </a>
        """

        let profile = try XCTUnwrap(GitHubClient.userProfile(in: html, username: "stephancill"))

        XCTAssertEqual(profile.displayName, "Stephan Cilliers")
        XCTAssertEqual(profile.bio, "cypherpunk wannabe")
        XCTAssertEqual(profile.location, "Cape Town")
        XCTAssertEqual(profile.websiteURL?.absoluteString, "https://stephancill.eth.limo")
        XCTAssertEqual(profile.followerCount, 183)
        XCTAssertEqual(profile.followingCount, 127)
        XCTAssertEqual(profile.repositoryCount, 198)
    }

    /// A profile with no bio (the description is just the handle) reports a nil
    /// bio rather than returning the handle itself.
    func testDropsUsernameOnlyBio() throws {
        let html = """
        <meta property="og:description" content="torvalds has 12 repositories available. Follow their code on GitHub.">
        <h1 class="vcard-names"><span class="p-name vcard-fullname" itemprop="name">Linus Torvalds </span></h1>
        <a class="Link--secondary" href="https://github.com/torvalds?tab=followers"> <span class="text-bold color-fg-default">319k</span> followers </a>
        <a class="Link--secondary" href="https://github.com/torvalds?tab=following"> <span class="text-bold color-fg-default">0</span> following </a>
        """

        let profile = try XCTUnwrap(GitHubClient.userProfile(in: html, username: "torvalds"))

        XCTAssertEqual(profile.displayName, "Linus Torvalds")
        XCTAssertNil(profile.bio)
        XCTAssertEqual(profile.followerCount, 319_000)
        XCTAssertEqual(profile.repositoryCount, 12)
    }
}
