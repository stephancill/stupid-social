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
    /// The networks to search (and to show recents from), picked with the filter pills; empty searches every one.
    /// Narrowing only filters what was found; adding a network not searched yet searches again.
    @Published public var selectedNetworks: Set<SocialNetwork> = [] {
        didSet {
            guard selectedNetworks != oldValue, !normalizedQuery.isEmpty else { return }
            if let resultsSearch, resultsSearch.query == normalizedQuery, Self.covers(resultsSearch.networks, searchNetworks) { return }
            scheduleSearch()
        }
    }

    /// The searchable networks with a connected account, one pill each; see `refreshSearchableNetworks()`.
    @Published public private(set) var searchableNetworks: [SocialNetwork] = []

    /// Profiles opened from search, most recent first; kept on this device only.
    @Published public private(set) var recentProfiles: [RecentProfile] = []

    private let feedService: FeedService
    private let defaults: UserDefaults
    private var debounceTask: Task<Void, Never>?
    /// The query and networks (nil: every one) the current results were found with.
    private var resultsSearch: (query: String, networks: Set<SocialNetwork>?)?
    private static let recentsKey = "recentProfileSearches"
    static let recentsLimit = 20

    public var filteredResults: [NetworkProfile] {
        results.filter(matchesFilter)
    }

    public var filteredRecentProfiles: [RecentProfile] {
        recentProfiles.filter { matchesFilter($0.profile) }
    }

    private func matchesFilter(_ profile: NetworkProfile) -> Bool {
        selectedNetworks.isEmpty || selectedNetworks.contains(profile.network)
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
            resultsSearch = nil
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
            resultsSearch = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        let networks = searchNetworks
        let profiles = await feedService.searchProfiles(query: normalized, networks: networks)
        guard normalized == normalizedQuery else { return }
        results = profiles
        resultsSearch = (normalized, networks)
        errorMessage = profiles.isEmpty ? "No matching profiles found." : nil
    }

    /// Reads which networks have an account to search with, and drops any selected network that no longer has one.
    public func refreshSearchableNetworks() {
        searchableNetworks = feedService.searchableNetworks()
        selectedNetworks.formIntersection(searchableNetworks)
    }

    private var searchNetworks: Set<SocialNetwork>? {
        selectedNetworks.isEmpty ? nil : selectedNetworks
    }

    /// Whether a search of `searched` networks (nil: every one) found everything a search of `wanted` would.
    private static func covers(_ searched: Set<SocialNetwork>?, _ wanted: Set<SocialNetwork>?) -> Bool {
        guard let searched else { return true }
        guard let wanted else { return false }
        return wanted.isSubset(of: searched)
    }

    private var normalizedQuery: String {
        String(query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@"))
    }
}
