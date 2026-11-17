import Foundation

/// A profile's timelines (posts, media) as its screen pages through them. The model owns its loads, so list rows
/// appearing, disappearing or being rebuilt never cancel or restart a request: each timeline loads its first page
/// once, a later page only when asked while none is loading, and nothing more after an error until `retry`.
@MainActor
public final class ProfileTimelineViewModel: ObservableObject {
    public struct Timeline: Sendable {
        public var items: [ProfileTimelineItem] = []
        public var nextCursor: String?
        public var hasLoaded = false
        public var isLoading = false
        public var errorMessage: String?
    }

    @Published public private(set) var timelines: [ProfileTimelineKind: Timeline] = [:]

    private let userId: String
    private let loader: any ProfileTimelineLoading

    public init(userId: String, loader: any ProfileTimelineLoading) {
        self.userId = userId
        self.loader = loader
    }

    public func timeline(_ kind: ProfileTimelineKind) -> Timeline {
        timelines[kind] ?? Timeline()
    }

    /// The first page, unless it is loaded, loading or failed.
    public func loadIfNeeded(_ kind: ProfileTimelineKind) {
        let current = timeline(kind)
        guard !current.hasLoaded, !current.isLoading, current.errorMessage == nil else { return }
        load(kind, cursor: nil)
    }

    /// The page after the loaded ones, unless one is loading, the last is loaded, or the previous load failed.
    public func loadMore(_ kind: ProfileTimelineKind) {
        let current = timeline(kind)
        guard current.hasLoaded, !current.isLoading, current.errorMessage == nil, let cursor = current.nextCursor else { return }
        load(kind, cursor: cursor)
    }

    public func retry(_ kind: ProfileTimelineKind) {
        timelines[kind, default: Timeline()].errorMessage = nil
        if timeline(kind).hasLoaded {
            loadMore(kind)
        } else {
            loadIfNeeded(kind)
        }
    }

    private func load(_ kind: ProfileTimelineKind, cursor: String?) {
        timelines[kind, default: Timeline()].isLoading = true
        Task { [weak self, loader, userId] in
            let result: Result<ProfileTimelinePage, any Error>
            do {
                result = try await .success(loader.fetchProfileTimeline(userId: userId, kind: kind, cursor: cursor))
            } catch {
                result = .failure(error)
            }
            self?.finish(kind, result)
        }
    }

    private func finish(_ kind: ProfileTimelineKind, _ result: Result<ProfileTimelinePage, any Error>) {
        var current = timeline(kind)
        current.isLoading = false
        switch result {
        case let .success(page):
            var seen = Set(current.items.map(\.id))
            let added = page.items.filter { seen.insert($0.id).inserted }
            current.items += added
            // A page of posts already shown would page on without end.
            current.nextCursor = added.isEmpty ? nil : page.nextCursor
            current.hasLoaded = true
        case let .failure(error):
            current.errorMessage = "Couldn't load \(kind.isMedia ? "media" : "posts"): \(error.localizedDescription)"
        }
        timelines[kind] = current
    }
}
