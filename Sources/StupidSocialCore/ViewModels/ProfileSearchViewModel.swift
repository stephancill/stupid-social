import Foundation

/// A profile opened from search, kept so the search page can offer it again.
public struct RecentProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let network: SocialNetwork
    public let username: String?
    public let displayName: String?
    public let avatarURL: URL?
    public let isVerified: Bool?
    /// The account the profile was found through, so it opens through the same one.
    public let accountId: String?

    public init(_ profile: NetworkProfile) {
        id = profile.id
        network = profile.network
        username = profile.username
        displayName = profile.displayName
        avatarURL = profile.avatarURL
        isVerified = profile.isVerified
        accountId = profile.accountId
    }

    /// The profile as search rows draw one; the profile screen loads the rest.
    public var profile: NetworkProfile {
        var profile = NetworkProfile(id: id, network: network, username: username, displayName: displayName, avatarURL: avatarURL, followerCount: nil, followingCount: nil, isVerified: isVerified)
        profile.accountId = accountId
        return profile
    }

    public var actor: NotificationActor {
        NotificationActor(id: id, network: network, username: username, displayName: displayName, avatarURL: avatarURL, isVerified: isVerified)
    }

    fileprivate var key: String {
        "\(network.rawValue)|\(id)"
    }
}

@MainActor
public final class ProfileSearchViewModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var results: [NetworkProfile] = []
    @Published public private(set) var isSearching = false
    @Published public var errorMessage: String?
    @Published public var enabledNetworks: Set<SocialNetwork> = [
        .x, .instagram, .farcaster, .spotify, .bluesky,
    ]

    /// Profiles opened from search, most recent first; kept on this device only.
    @Published public private(set) var recentProfiles: [RecentProfile] = []

    private let feedService: FeedService
    private let defaults: UserDefaults
    private var debounceTask: Task<Void, Never>?
    private var latestSearchQuery = ""
    private static let recentsKey = "recentProfileSearches"
    static let recentsLimit = 20

    public var filteredResults: [NetworkProfile] {
        results.filter { enabledNetworks.contains($0.network) }
    }

    public var service: FeedService {
        feedService
    }

    public init(feedService: FeedService, defaults: UserDefaults = .standard) {
        self.feedService = feedService
        self.defaults = defaults
        recentProfiles = defaults.data(forKey: Self.recentsKey).flatMap { try? JSONDecoder().decode([RecentProfile].self, from: $0) } ?? []
    }

    // MARK: Recent profiles

    /// Puts the profile first among the recent ones, keeping the newest `recentsLimit`.
    public func recordVisit(_ profile: NetworkProfile) {
        let recent = RecentProfile(profile)
        saveRecents([recent] + recentProfiles.filter { $0.key != recent.key })
    }

    public func removeRecent(_ profile: RecentProfile) {
        saveRecents(recentProfiles.filter { $0.key != profile.key })
    }

    public func clearRecents() {
        saveRecents([])
    }

    private func saveRecents(_ profiles: [RecentProfile]) {
        recentProfiles = Array(profiles.prefix(Self.recentsLimit))
        defaults.set(try? JSONEncoder().encode(recentProfiles), forKey: Self.recentsKey)
    }

    deinit {
        debounceTask?.cancel()
    }

    public func scheduleSearch() {
        debounceTask?.cancel()

        let normalized = normalizedQuery
        guard !normalized.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            latestSearchQuery = ""
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.search(query: normalized)
        }
    }

    public func search() async {
        debounceTask?.cancel()
        await search(query: normalizedQuery)
    }

    private func search(query normalized: String) async {
        guard !normalized.isEmpty else {
            results = []
            errorMessage = nil
            latestSearchQuery = ""
            return
        }

        latestSearchQuery = normalized

        isSearching = true
        defer { isSearching = false }

        let profiles = await feedService.searchProfiles(query: normalized)
        guard normalized == normalizedQuery else { return }
        results = profiles
        errorMessage = profiles.isEmpty ? "No matching profiles found." : nil
    }

    private var normalizedQuery: String {
        String(query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
    }
}
