import Foundation

@MainActor
public final class ProfileSearchViewModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var results: [NetworkProfile] = []
    @Published public private(set) var isSearching = false
    @Published public var errorMessage: String?

    private let feedService: FeedService
    private var debounceTask: Task<Void, Never>?
    private var latestSearchQuery = ""

    public var service: FeedService {
        feedService
    }

    public init(feedService: FeedService) {
        self.feedService = feedService
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
