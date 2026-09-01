import Foundation

@MainActor
public final class StoryBarViewModel: ObservableObject {
    @Published public private(set) var storyBarItems: [StoryBarItem] = []
    @Published public private(set) var ownInstagramStoryActor: NotificationActor?
    @Published public private(set) var ownInstagramStoryReel: InstagramStoryReel?
    @Published public private(set) var storyBarContentLoaded = false
    @Published public private(set) var storyBarLoading = false
    @Published public private(set) var storyBarNextPageLoading = false
    @Published public var errorMessage: String?

    private let instagramSource: InstagramNotificationSource?
    private let spotifyActivitySource: (any ActivityFetching)?
    private let githubActivitySource: (any GitHubActivityFetching)?
    private let spotifySeenStore: SpotifyActivitySeenStore
    private let githubSeenStore: GitHubActivitySeenStore
    private let chronologicalInstagramPrefixCount = 15
    private var orderedInstagramStoryReels: [InstagramStoryReel] = []
    private var hasMoreInstagramStoryReels = false
    private var optimisticInstagramStorySlideID: String?
    private var inFlightStoryBarContentFetch: Task<Void, Never>?

    public init(
        instagramSource: InstagramNotificationSource?,
        spotifyActivitySource: (any ActivityFetching)? = nil,
        githubActivitySource: (any GitHubActivityFetching)? = nil,
        spotifySeenStore: SpotifyActivitySeenStore = SpotifyActivitySeenStore(),
        githubSeenStore: GitHubActivitySeenStore = GitHubActivitySeenStore(),
    ) {
        self.instagramSource = instagramSource
        self.spotifyActivitySource = spotifyActivitySource
        self.githubActivitySource = githubActivitySource
        self.spotifySeenStore = spotifySeenStore
        self.githubSeenStore = githubSeenStore
    }

    public func fetchInstagramStories() async {
        await fetchStoryBarContent()
    }

    /// Replaces the story bar with Debug-only demo stories and marks content loaded.
    /// No-op outside `#if DEBUG` builds.
    public func loadDemoStoryBarItems() {
        #if DEBUG
            storyBarItems = DemoData.storyBarItems()
            ownInstagramStoryActor = nil
            ownInstagramStoryReel = nil
            storyBarContentLoaded = true
            storyBarLoading = false
        #endif
    }

    /// Resets the story bar so a live reload can repopulate it after demo mode is
    /// turned off. No-op outside `#if DEBUG` builds.
    public func clearDemoStoryItems() {
        #if DEBUG
            storyBarItems = []
            ownInstagramStoryActor = nil
            ownInstagramStoryReel = nil
            storyBarContentLoaded = false
            storyBarLoading = false
        #endif
    }

    public func fetchSpotifyActivity() async {
        await fetchStoryBarContent()
    }

    public func fetchStoryBarContent() async {
        if let inFlightStoryBarContentFetch {
            await inFlightStoryBarContentFetch.value
            return
        }
        let task = Task { await performStoryBarContentFetch() }
        inFlightStoryBarContentFetch = task
        await task.value
        inFlightStoryBarContentFetch = nil
    }

    private func performStoryBarContentFetch() async {
        #if DEBUG
            if DemoData.isDemoMode {
                loadDemoStoryBarItems()
                return
            }
        #endif
        storyBarLoading = true
        async let reels = instagramReels()
        async let spots = spotifyItems()
        async let github = githubItems()
        async let ownInstagramActor = instagramSource?.ownStoryActor()
        let fallbackInstagramReels = ([ownInstagramStoryReel].compactMap(\.self) + instagramStoryReels)
        let fetchedReels = await reels ?? fallbackInstagramReels
        let fetchedSpots = await spots
        let fetchedGitHub = await github
        let fetchedOwnInstagramActor = await ownInstagramActor ?? ownInstagramStoryActor
        ownInstagramStoryActor = fetchedOwnInstagramActor

        var ownReel: InstagramStoryReel?
        var instagramReels: [InstagramStoryReel] = []
        for reel in fetchedReels {
            if let fetchedOwnInstagramActor, reel.user.id == fetchedOwnInstagramActor.id {
                ownReel = reel
                continue
            }
            instagramReels.append(reel)
        }
        ownInstagramStoryReel = preservingOptimisticStorySlide(in: ownReel)
        orderedInstagramStoryReels = instagramReels
        hasMoreInstagramStoryReels = instagramSource?.hasMoreStoryReels ?? false
        storyBarItems = mergedStoryBarItems(instagramReels: instagramReels, spotifyItems: fetchedSpots, githubItems: fetchedGitHub)
        storyBarContentLoaded = true
        storyBarLoading = false
    }

    public func loadNextStoryBarPageIfNeeded(currentItem item: StoryBarItem) async {
        switch item {
        case let .instagram(reel):
            guard reel.id == orderedInstagramStoryReels.last?.id else { return }
        case .spotify, .github:
            guard item.id == storyBarItems.last?.id else { return }
        }
        await loadNextStoryBarPage()
    }

    public func loadNextStoryBarPage() async {
        guard !storyBarLoading, !storyBarNextPageLoading, hasMoreInstagramStoryReels else { return }
        guard let instagramSource, instagramSource.storiesEnabled else { return }
        storyBarNextPageLoading = true
        defer { storyBarNextPageLoading = false }

        do {
            let nextReels = try await instagramSource.fetchNextStoryReelPage()
            hasMoreInstagramStoryReels = instagramSource.hasMoreStoryReels
            guard !nextReels.isEmpty else { return }

            let existingReelIds = Set(orderedInstagramStoryReels.map(\.id))
            var appendedReels = nextReels.filter { !existingReelIds.contains($0.id) }
            if let ownInstagramStoryActor {
                appendedReels.removeAll { reel in
                    if reel.user.id == ownInstagramStoryActor.id {
                        ownInstagramStoryReel = preservingOptimisticStorySlide(in: reel)
                        return true
                    }
                    return false
                }
            }

            orderedInstagramStoryReels.append(contentsOf: appendedReels)
            storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems, githubItems: githubActivityGroups)
        } catch {
            hasMoreInstagramStoryReels = instagramSource.hasMoreStoryReels
        }
    }

    public func postInstagramStory(imageData: Data, width: Int, height: Int, mimeType: String, mentions: [InstagramStoryMentionPlacement] = []) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        let actor: NotificationActor? = if let ownInstagramStoryActor {
            ownInstagramStoryActor
        } else {
            await instagramSource.ownStoryActor()
        }
        guard let actor else { throw SourceError.notConfigured }

        let previewURL = try writeOptimisticStoryPreview(imageData: imageData, mimeType: mimeType)
        let slideID = "optimistic-instagram-story-\(UUID().uuidString)"
        optimisticInstagramStorySlideID = slideID
        ownInstagramStoryActor = actor
        insertOptimisticInstagramStory(actor: actor, slideID: slideID, imageURL: previewURL)

        Task {
            do {
                try await instagramSource.postPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType, mentions: mentions)
                await fetchStoryBarContent()
            } catch {
                removeOptimisticInstagramStory(slideID: slideID)
                errorMessage = "Could not post Instagram story."
            }
        }
    }

    public func deleteInstagramStory(mediaId: String, isVideo: Bool) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.deleteStory(mediaId: mediaId, isVideo: isVideo)
        await fetchStoryBarContent()
    }

    public func setInstagramStoryLiked(mediaId: String, liked: Bool) async throws {
        guard let instagramSource else { throw SourceError.notConfigured }
        try await instagramSource.setStoryLiked(mediaId: mediaId, liked: liked)
        updateInstagramStorySlide(mediaId: mediaId) { slide in
            InstagramStorySlide(
                id: slide.id,
                imageURL: slide.imageURL,
                videoURL: slide.videoURL,
                isVideo: slide.isVideo,
                videoDuration: slide.videoDuration,
                embedURL: slide.embedURL,
                embedLabel: slide.embedLabel,
                music: slide.music,
                mentions: slide.mentions,
                links: slide.links,
                ownerId: slide.ownerId,
                takenAt: slide.takenAt,
                isLiked: liked,
            )
        }
    }

    public func markSpotifyActivityAsSeen(userURI: String) {
        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .spotify(item) = $0, item.userURI == userURI { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .spotify(item) = storyItem else { return }

        spotifySeenStore.markSeen(userURI: userURI, activityTimestamp: item.timestamp)

        let updated = spotifyItemWithSeenState(item)
        storyBarItems[itemIndex] = .spotify(updated)
        storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems, githubItems: githubActivityGroups)
    }

    public func markGitHubActivityAsSeen(actorId: String) {
        guard let index = storyBarItems.firstIndex(where: {
            if case let .github(group) = $0 { return group.actor.id == actorId }
            return false
        }), case let .github(group) = storyBarItems[index]
        else { return }
        githubSeenStore.markSeen(actorId: actorId, activityTimestamp: group.timestamp)
        storyBarItems[index] = .github(GitHubActivityGroup(actor: group.actor, activities: group.activities, isSeen: true))
        storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems, githubItems: githubActivityGroups)
    }

    public func markInstagramReelAsSeen(reelIndex: Int) {
        guard instagramStoryReels.indices.contains(reelIndex) else { return }
        let reel = instagramStoryReels[reelIndex]
        guard !reel.isSeen else { return }
        markInstagramReelAsSeen(reelId: reel.id)
    }

    public func markInstagramReelAsSeen(reelId: String) {
        if let reel = ownInstagramStoryReel, reel.id == reelId, !reel.isSeen {
            Task {
                await instagramSource?.markReelAsSeen(slides: reel.slides)
            }

            ownInstagramStoryReel = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true, seenTimestamp: reel.slides.map(\.takenAt).max() ?? reel.seenTimestamp, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
            return
        }

        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .instagram(reel) = $0, reel.id == reelId { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .instagram(reel) = storyItem, !reel.isSeen else { return }

        Task {
            await instagramSource?.markReelAsSeen(slides: reel.slides)
        }

        let updated = InstagramStoryReel(id: reel.id, user: reel.user, slides: reel.slides, isSeen: true, seenTimestamp: reel.slides.map(\.takenAt).max() ?? reel.seenTimestamp, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
        if let orderedIndex = orderedInstagramStoryReels.firstIndex(where: { $0.id == reel.id }) {
            orderedInstagramStoryReels[orderedIndex] = updated
        }
        storyBarItems[itemIndex] = .instagram(updated)
    }

    public func storyViewerItems(for selectedItem: StoryBarItem, in visibleItems: [StoryBarItem]) -> [StoryBarItem] {
        let items = visibleItems.filter { $0.isSeen == selectedItem.isSeen }
        return items.map(storyItemWithOldestFirstSlides)
    }

    public func storyViewerStartIndex(for selectedItem: StoryBarItem, in items: [StoryBarItem]) -> Int {
        items.firstIndex(where: { $0.id == selectedItem.id }) ?? 0
    }

    public func storyViewerStartSlideIndex(for selectedItem: StoryBarItem, in items: [StoryBarItem]) -> Int {
        guard let item = items.first(where: { $0.id == selectedItem.id }) else { return 0 }
        switch item {
        case let .instagram(reel):
            return resumeIndex(in: reel.slides.map(\.takenAt), after: reel.seenTimestamp)
        case let .github(group):
            return resumeIndex(in: group.activities.map(\.timestamp.timeIntervalSince1970), after: githubSeenStore.seenTimestamp(actorId: group.actor.id))
        case .spotify:
            return 0
        }
    }

    /// Returns the index of the first slide taken after the given seen timestamp
    /// (the oldest un-viewed slide), or 0 when every slide has been viewed.
    private func resumeIndex(in slideTimes: [Double], after seenTimestamp: Double) -> Int {
        slideTimes.firstIndex(where: { $0 > seenTimestamp }) ?? 0
    }

    var instagramStoryReels: [InstagramStoryReel] {
        storyBarItems.compactMap {
            if case let .instagram(reel) = $0 { return reel }
            return nil
        }
    }

    var spotifyActivityItems: [SpotifyActivityItem] {
        storyBarItems.compactMap {
            if case let .spotify(item) = $0 { return item }
            return nil
        }
    }

    var githubActivityGroups: [GitHubActivityGroup] {
        storyBarItems.compactMap {
            if case let .github(group) = $0 { return group }
            return nil
        }
    }

    private func instagramReels() async -> [InstagramStoryReel]? {
        guard let instagramSource, instagramSource.storiesEnabled else { return [] }
        do {
            return try await RefreshTiming.measure("story-instagram-reels") {
                try await instagramSource.fetchStoryReels()
            }
        } catch SourceError.notConfigured {
            return []
        } catch {
            return nil
        }
    }

    private func spotifyItems() async -> [SpotifyActivityItem] {
        guard let spotifyActivitySource else { return [] }
        do {
            let activity = try await RefreshTiming.measure("story-spotify-activity") {
                try await spotifyActivitySource.fetchActivity(reason: .manual)
            }
            var seenUserURIs = Set<String>()
            return activity
                .sorted { $0.timestamp > $1.timestamp }
                .filter { item in
                    seenUserURIs.insert(item.userURI).inserted
                }
                .map(spotifyItemWithSeenState)
                .sorted { a, b in
                    if a.isSeen != b.isSeen {
                        return !a.isSeen
                    }
                    return a.timestamp > b.timestamp
                }
        } catch {
            return []
        }
    }

    private func spotifyItemWithSeenState(_ item: SpotifyActivityItem) -> SpotifyActivityItem {
        SpotifyActivityItem(
            id: item.id,
            timestamp: item.timestamp,
            userName: item.userName,
            userURI: item.userURI,
            userAvatarURL: item.userAvatarURL,
            trackName: item.trackName,
            artistName: item.artistName,
            albumName: item.albumName,
            contextName: item.contextName,
            trackURI: item.trackURI,
            trackURL: item.trackURL,
            imageURL: item.imageURL,
            musicAnimation: item.musicAnimation,
            isSeen: spotifySeenStore.isSeen(userURI: item.userURI, activityTimestamp: item.timestamp),
        )
    }

    private func githubItems() async -> [GitHubActivityGroup] {
        guard let githubActivitySource else { return [] }
        do {
            return try await RefreshTiming.measure("story-github-activity") {
                try await githubActivitySource.fetchGitHubActivity(reason: .manual)
            }.map { group in
                GitHubActivityGroup(
                    actor: group.actor,
                    activities: group.activities,
                    isSeen: githubSeenStore.isSeen(actorId: group.actor.id, activityTimestamp: group.timestamp),
                )
            }.sorted { lhs, rhs in
                if lhs.isSeen != rhs.isSeen { return !lhs.isSeen }
                return lhs.timestamp > rhs.timestamp
            }
        } catch {
            return []
        }
    }

    private func storyItemWithOldestFirstSlides(_ item: StoryBarItem) -> StoryBarItem {
        guard case let .instagram(reel) = item else { return item }
        let slides = reel.slides.sorted { lhs, rhs in
            if lhs.takenAt == rhs.takenAt {
                return lhs.id < rhs.id
            }
            return lhs.takenAt < rhs.takenAt
        }
        return .instagram(InstagramStoryReel(id: reel.id, user: reel.user, slides: slides, isSeen: reel.isSeen, seenTimestamp: reel.seenTimestamp, hasCloseFriendsMedia: reel.hasCloseFriendsMedia))
    }

    private func mergedStoryBarItems(instagramReels: [InstagramStoryReel], spotifyItems: [SpotifyActivityItem], githubItems: [GitHubActivityGroup]) -> [StoryBarItem] {
        let chronologicalInstagram = instagramReels.prefix(chronologicalInstagramPrefixCount).map(StoryBarItem.instagram)
        let chronologicalSpotify = spotifyItems.map(StoryBarItem.spotify)
        let chronologicalGitHub = githubItems.map(StoryBarItem.github)
        let chronologicalItems = (chronologicalInstagram + chronologicalSpotify + chronologicalGitHub).sorted { $0.timestamp > $1.timestamp }
        let remainingInstagram = instagramReels.dropFirst(chronologicalInstagramPrefixCount).map(StoryBarItem.instagram)

        return chronologicalItems + remainingInstagram
    }

    private func writeOptimisticStoryPreview(imageData: Data, mimeType: String) throws -> URL {
        let fileExtension = mimeType == "image/webp" ? "webp" : "jpg"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoFeedSocialOptimisticStories", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try imageData.write(to: url, options: .atomic)
        return url
    }

    private func insertOptimisticInstagramStory(actor: NotificationActor, slideID: String, imageURL: URL) {
        let optimisticSlide = InstagramStorySlide(
            id: slideID,
            imageURL: imageURL,
            videoURL: nil,
            isVideo: false,
            ownerId: actor.id,
            takenAt: Date().timeIntervalSince1970,
        )

        let existingSlides = ownInstagramStoryReel?.slides.filter { $0.id != slideID } ?? []
        ownInstagramStoryReel = InstagramStoryReel(
            id: actor.id,
            user: actor,
            slides: [optimisticSlide] + existingSlides,
            isSeen: false,
            seenTimestamp: ownInstagramStoryReel?.seenTimestamp ?? 0,
            hasCloseFriendsMedia: ownInstagramStoryReel?.hasCloseFriendsMedia ?? false,
        )
        storyBarContentLoaded = true
    }

    private func preservingOptimisticStorySlide(in fetchedReel: InstagramStoryReel?) -> InstagramStoryReel? {
        guard let optimisticInstagramStorySlideID,
              let optimisticSlide = ownInstagramStoryReel?.slides.first(where: { $0.id == optimisticInstagramStorySlideID })
        else { return fetchedReel }

        if let fetchedReel {
            guard !fetchedReel.slides.contains(where: { $0.id == optimisticInstagramStorySlideID }) else { return fetchedReel }
            if fetchedReel.slides.contains(where: { $0.takenAt >= optimisticSlide.takenAt - 60 }) {
                self.optimisticInstagramStorySlideID = nil
                return fetchedReel
            }
            return InstagramStoryReel(
                id: fetchedReel.id,
                user: fetchedReel.user,
                slides: [optimisticSlide] + fetchedReel.slides,
                isSeen: false,
                seenTimestamp: fetchedReel.seenTimestamp,
                hasCloseFriendsMedia: fetchedReel.hasCloseFriendsMedia,
            )
        }

        guard let actor = ownInstagramStoryActor ?? ownInstagramStoryReel?.user else { return nil }
        return InstagramStoryReel(id: actor.id, user: actor, slides: [optimisticSlide], isSeen: false)
    }

    private func removeOptimisticInstagramStory(slideID: String) {
        guard optimisticInstagramStorySlideID == slideID, let reel = ownInstagramStoryReel else { return }
        optimisticInstagramStorySlideID = nil
        let slides = reel.slides.filter { $0.id != slideID }
        ownInstagramStoryReel = slides.isEmpty
            ? nil
            : InstagramStoryReel(
                id: reel.id,
                user: reel.user,
                slides: slides,
                isSeen: reel.isSeen,
                seenTimestamp: reel.seenTimestamp,
                hasCloseFriendsMedia: reel.hasCloseFriendsMedia,
            )
    }

    private func updateInstagramStorySlide(mediaId: String, transform: @escaping (InstagramStorySlide) -> InstagramStorySlide) {
        let updateReel: (InstagramStoryReel) -> InstagramStoryReel = { reel in
            let slides = reel.slides.map { slide in
                slide.id == mediaId ? transform(slide) : slide
            }
            return InstagramStoryReel(id: reel.id, user: reel.user, slides: slides, isSeen: reel.isSeen, seenTimestamp: reel.seenTimestamp, hasCloseFriendsMedia: reel.hasCloseFriendsMedia)
        }

        if let ownReel = ownInstagramStoryReel, ownReel.slides.contains(where: { $0.id == mediaId }) {
            ownInstagramStoryReel = updateReel(ownReel)
        }

        orderedInstagramStoryReels = orderedInstagramStoryReels.map { reel in
            reel.slides.contains(where: { $0.id == mediaId }) ? updateReel(reel) : reel
        }
        storyBarItems = storyBarItems.map { item in
            guard case let .instagram(reel) = item, reel.slides.contains(where: { $0.id == mediaId }) else { return item }
            return .instagram(updateReel(reel))
        }
    }
}

private extension InstagramStoryReel {
    var timestamp: Date {
        Date(timeIntervalSince1970: slides.first?.takenAt ?? 0)
    }
}
