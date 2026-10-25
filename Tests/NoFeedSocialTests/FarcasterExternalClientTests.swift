@testable import NoFeedSocialCore
import XCTest

final class FarcasterExternalClientTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FarcasterExternalClientTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToQuilcast() {
        XCTAssertEqual(FarcasterExternalClient.current(defaults: defaults), .quilcast)
        XCTAssertEqual(
            FarcasterExternalClient.castURL(hash: "0xabc123", defaults: defaults)?.absoluteString,
            "https://quilcast.com/c/0xabc123",
        )
        XCTAssertEqual(
            FarcasterExternalClient.profileURL(username: "alice", defaults: defaults)?.absoluteString,
            "https://quilcast.com/u/alice",
        )
    }

    func testFarcasterClientURLs() {
        defaults.set(FarcasterExternalClient.farcaster.rawValue, forKey: FarcasterExternalClient.storageKey)

        XCTAssertEqual(
            FarcasterExternalClient.castURL(hash: "0xabc123", defaults: defaults)?.absoluteString,
            "https://farcaster.xyz/~/conversations/0xabc123",
        )
        XCTAssertEqual(
            FarcasterExternalClient.profileURL(username: "alice", defaults: defaults)?.absoluteString,
            "https://farcaster.xyz/alice",
        )
    }

    func testCustomPatternsSubstitutePlaceholders() {
        defaults.set(FarcasterExternalClient.custom.rawValue, forKey: FarcasterExternalClient.storageKey)
        defaults.set(" https://example.com/cast/{hash} ", forKey: FarcasterExternalClient.customCastURLPatternKey)
        defaults.set("myclient://profile/{username}", forKey: FarcasterExternalClient.customProfileURLPatternKey)

        XCTAssertEqual(
            FarcasterExternalClient.castURL(hash: "0xabc123", defaults: defaults)?.absoluteString,
            "https://example.com/cast/0xabc123",
        )
        XCTAssertEqual(
            FarcasterExternalClient.profileURL(username: "alice.eth", defaults: defaults)?.absoluteString,
            "myclient://profile/alice.eth",
        )
    }

    func testCustomPatternWithoutPlaceholderOrSchemeHasNoURL() {
        defaults.set(FarcasterExternalClient.custom.rawValue, forKey: FarcasterExternalClient.storageKey)
        XCTAssertNil(FarcasterExternalClient.castURL(hash: "0xabc123", defaults: defaults))

        defaults.set("https://example.com/cast", forKey: FarcasterExternalClient.customCastURLPatternKey)
        defaults.set("example.com/u/{username}", forKey: FarcasterExternalClient.customProfileURLPatternKey)
        XCTAssertNil(FarcasterExternalClient.castURL(hash: "0xabc123", defaults: defaults))
        XCTAssertNil(FarcasterExternalClient.profileURL(username: "alice", defaults: defaults))
    }
}
