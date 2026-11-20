import Foundation
@testable import StupidSocialCore
import XCTest

/// Posts chats have shown are kept on disk, so later launches draw them without loading.
@MainActor
final class XPostCacheTests: XCTestCase {
    private let url = FileManager.default.temporaryDirectory.appending(path: "XPostCacheTests-\(UUID().uuidString).json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testAKeptPostDrawsOnTheNextLaunchWithoutLoading() async throws {
        let first = XPostResolver(cache: XPostCache(url: url)) { id in post(id) }
        XCTAssertNil(first.embed(for: link("1")), "nothing kept yet")
        try await waitForFile()

        let loads = LoadCounter()
        let next = XPostResolver(cache: XPostCache(url: url)) { id in
            await loads.increment()
            return post(id)
        }
        _ = next.embed(for: link("1"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(next.post("1")?.text, "post 1")
        let count = await loads.count
        XCTAssertEqual(count, 0)
    }

    func testAStalePostShowsAndLoadsAgainOnce() async throws {
        let cache = XPostCache(url: url)
        await cache.ready()
        cache.insert(post("1", text: "old"), id: "1", at: Date(timeIntervalSinceNow: -2 * XPostCache.staleAfter))
        let loads = LoadCounter()
        let resolver = XPostResolver(cache: cache) { id in
            await loads.increment()
            return post(id, text: "new")
        }
        XCTAssertNotNil(resolver.embed(for: link("1")), "a stale post still shows")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resolver.post("1")?.text, "new")
        cache.insert(post("1", text: "old"), id: "1", at: Date(timeIntervalSinceNow: -2 * XPostCache.staleAfter))
        _ = resolver.embed(for: link("1"))
        try await Task.sleep(for: .milliseconds(200))
        let count = await loads.count
        XCTAssertEqual(count, 1, "once a session")
    }

    func testOldAndLeastRecentPostsAreDropped() {
        let now = Date()
        var entries: [String: XPostCache.Entry] = [:]
        for index in 0 ..< XPostCache.limit + 5 {
            entries["\(index)"] = .init(post: post("\(index)"), loadedAt: now.addingTimeInterval(-Double(index)))
        }
        entries["old"] = .init(post: post("old"), loadedAt: now.addingTimeInterval(-XPostCache.maxAge - 1))
        let kept = XPostCache.pruned(entries, now: now)
        XCTAssertEqual(kept.count, XPostCache.limit)
        XCTAssertNil(kept["old"])
        XCTAssertNil(kept["\(XPostCache.limit)"], "the least recently loaded go first")
        XCTAssertNotNil(kept["0"])
    }

    private func waitForFile() async throws {
        for _ in 0 ..< 40 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func link(_ id: String) -> URL {
        URL(string: "https://x.com/ada/status/\(id)")!
    }
}

private func post(_ id: String, text: String? = nil) -> XPost {
    XPost(id: id, authorName: "Ada", screenName: "ada", text: text ?? "post \(id)", quoted: XPost(id: "q", authorName: "Bo", screenName: "bo", text: "quoted"))
}

private actor LoadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
