@testable import NoFeedSocialCore
import SwiftData
import XCTest

@MainActor
final class LiveServiceTests: XCTestCase {
    func testFarcasterStephancillLookupAndNotifications() async throws {
        let client = FarcasterClient()

        let user = try await client.user(byUsername: "stephancill")
        XCTAssertEqual(user.fid, 1689)

        let notifications = try await client.notifications(fid: user.fid, limit: 5)
        XCTAssertFalse(notifications.notifications.isEmpty)
    }

    func testXUnreadCountWithEnvironmentCredentials() async throws {
        guard let authToken = ProcessInfo.processInfo.environment["TWITTER_AUTH_TOKEN"],
              let ct0 = ProcessInfo.processInfo.environment["TWITTER_CT0"],
              !authToken.isEmpty,
              !ct0.isEmpty
        else {
            throw XCTSkip("Set TWITTER_AUTH_TOKEN and TWITTER_CT0 to run the live X service test.")
        }

        let client = XClient(credentialStore: KeychainCredentialStore())
        let count = try await client.unreadCount(credentials: XCredentials(authToken: authToken, ct0: ct0))

        XCTAssertGreaterThanOrEqual(count, 0)
    }

    func testConsecutiveRefreshesAllSources() async throws {
        var sources: [any NotificationFetching] = []
        var errors: [String] = []

        // X
        if let creds = xCredentials() {
            let store = KeychainCredentialStore()
            _ = try store.saveXCredentials(creds)
            sources.append(XNotificationSource(
                client: XClient(credentialStore: store),
                metadataStore: accountStore(),
            ))
        } else {
            errors.append("X: no credentials")
        }

        // Farcaster
        if let farcaster = farcasterAccount() {
            let store = accountStore()
            store.farcasterAccount = farcaster
            sources.append(FarcasterNotificationSource(
                client: FarcasterClient(),
                metadataStore: store,
            ))
        } else {
            errors.append("Farcaster: no account")
        }

        // Instagram
        if let instaCreds = instagramCredentials() {
            let store = KeychainCredentialStore()
            _ = try store.saveInstagramCredentials(instaCreds)
            sources.append(InstagramNotificationSource(
                client: InstagramClient(credentialStore: store),
                metadataStore: accountStore(),
            ))
        } else {
            errors.append("Instagram: no credentials")
        }

        guard !sources.isEmpty else {
            throw XCTSkip("No sources available: \(errors.joined(separator: ", "))")
        }
        if !errors.isEmpty {
            Swift.print("Skipped sources: \(errors.joined(separator: ", "))")
        }

        let container = try ModelContainer(
            for: CachedNotification.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let cacheStore = NotificationCacheStore(context: container.mainContext)
        let service = FeedService(
            notificationSources: sources,
            accountValidators: [],
            profileFetchersByNetwork: [:],
            targetDetailFetchersByNetwork: [:],
            cacheStore: cacheStore,
        )

        // Refresh 1
        let first = try await service.manualRefresh()
        XCTAssertFalse(first.isEmpty, "First refresh returned no items")

        let firstIds = Set(first.map(\.item.id))
        XCTAssertEqual(firstIds.count, first.count, "First refresh contains duplicate IDs")
        Swift.print("Refresh 1: \(first.count) total")

        // Refresh 2
        let second = try await service.manualRefresh()
        XCTAssertFalse(second.isEmpty, "Second refresh returned no items")

        let secondIds = Set(second.map(\.item.id))
        XCTAssertEqual(secondIds.count, second.count, "Second refresh contains duplicate IDs")

        let missingIds = firstIds.subtracting(secondIds)

        let bySource = Dictionary(grouping: second, by: { $0.item.network })
        for (network, items) in bySource.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            Swift.print("  \(network.displayName): \(items.count) total")
        }
        Swift.print("Refresh 2: \(second.count) total")
        if !missingIds.isEmpty {
            Swift.print("Missing from refresh 2: \(missingIds.count)")
        }
    }

    private func xCredentials() -> XCredentials? {
        if let creds = (try? KeychainCredentialStore().loadXCredentials()).flatMap(\.self) {
            return creds
        }
        if let auth = env("TWITTER_AUTH_TOKEN"), let ct0 = env("TWITTER_CT0") {
            return XCredentials(authToken: auth, ct0: ct0)
        }
        return nil
    }

    private func instagramCredentials() -> InstagramCredentials? {
        if let creds = (try? KeychainCredentialStore().loadInstagramCredentials()).flatMap(\.self) {
            return creds
        }
        return instagramEnvironmentCredentials()
    }

    private func instagramEnvironmentCredentials() -> InstagramCredentials? {
        if let session = env("INSTAGRAM_SESSION_ID"),
           let csrf = env("INSTAGRAM_CSRF_TOKEN"),
           let uid = env("INSTAGRAM_DS_USER_ID")
        {
            return InstagramCredentials(
                sessionId: session,
                csrfToken: csrf,
                dsUserId: uid,
                mid: env("INSTAGRAM_MID"),
                rur: env("INSTAGRAM_RUR"),
                igDid: env("INSTAGRAM_IG_DID"),
            )
        }
        return nil
    }

    private func env(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return (value?.isEmpty == false) ? value : nil
    }

    private func farcasterAccount() -> FarcasterAccountMetadata? {
        FarcasterAccountMetadata(username: "stephancill", fid: 1689, status: .valid)
    }

    private func accountStore() -> AccountMetadataStore {
        AccountMetadataStore()
    }
}
