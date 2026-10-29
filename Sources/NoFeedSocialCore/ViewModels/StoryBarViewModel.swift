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

    /// Every account's sources, read on each use so added and removed accounts take effect.
    private let instagramSources: @MainActor () -> [InstagramNotificationSource]
    private let spotifyActivitySources: @MainActor () -> [any ActivityFetching]
    private let githubActivitySources: @MainActor () -> [any GitHubActivityFetching]
    /// Reel owner id → the Instagram account whose tray listed it, which marks it seen and likes its slides.
    private var instagramSourceByOwner: [String: InstagramNotificationSource] = [:]
    private let spotifySeenStore: SpotifyActivitySeenStore
    private let githubSeenStore: GitHubActivitySeenStore
    private let seenSync: StorySeenSync?
    private var seenSyncObserver: NSObjectProtocol?
    private let chronologicalInstagramPrefixCount = 15
    private var orderedInstagramStoryReels: [InstagramStoryReel] = []
    private var hasMoreInstagramStoryReels = false
    private var optimisticInstagramStorySlideID: String?
    private var inFlightStoryBarContentFetch: Task<Void, Never>?

    public init(
        instagramSources: @escaping @MainActor () -> [InstagramNotificationSource],
        spotifyActivitySources: @escaping @MainActor () -> [any ActivityFetching] = { [] },
        githubActivitySources: @escaping @MainActor () -> [any GitHubActivityFetching] = { [] },
        spotifySeenStore: SpotifyActivitySeenStore = SpotifyActivitySeenStore(),
        githubSeenStore: GitHubActivitySeenStore = GitHubActivitySeenStore(),
        seenSync: StorySeenSync? = nil,
    ) {
        self.instagramSources = instagramSources
        self.spotifyActivitySources = spotifyActivitySources
        self.githubActivitySources = githubActivitySources
        self.spotifySeenStore = spotifySeenStore
        self.githubSeenStore = githubSeenStore
        self.seenSync = seenSync
        if seenSync != nil {
            seenSyncObserver = NotificationCenter.default.addObserver(
                forName: StorySeenSync.didChangeNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshSeenState() }
            }
        }
    }

    /// The first Instagram account, whose own story leads the bar and which the composer posts to.
    private var instagramSource: InstagramNotificationSource? {
        instagramSources().first
    }

    private func instagramSource(forOwner ownerId: String?) -> InstagramNotificationSource? {
        ownerId.flatMap { instagramSourceByOwner[$0] } ?? instagramSource
    }

    public func fetchInstagramStories() async {
        await fetchStoryBarContent()
    }

    /// Replaces the story bar with demo stories and marks content loaded.
    public func loadDemoStoryBarItems() {
        storyBarItems = DemoData.storyBarItems()
        ownInstagramStoryActor = nil
        ownInstagramStoryReel = nil
        storyBarContentLoaded = true
        storyBarLoading = false
    }

    /// Resets the story bar so a live reload can repopulate it after demo mode is
    /// turned off.
    public func clearDemoStoryItems() {
        storyBarItems = []
        ownInstagramStoryActor = nil
        ownInstagramStoryReel = nil
        storyBarContentLoaded = false
        storyBarLoading = false
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
        if DemoData.isDemoMode {
            loadDemoStoryBarItems()
            return
        }
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
        hasMoreInstagramStoryReels = instagramSources().contains { $0.hasMoreStoryReels }
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
        let sources = instagramSources().filter { $0.storiesEnabled && $0.hasMoreStoryReels }
        guard !sources.isEmpty else { return }
        storyBarNextPageLoading = true
        defer { storyBarNextPageLoading = false }

        do {
            var nextReels: [InstagramStoryReel] = []
            for source in sources {
                let page = try await source.fetchNextStoryReelPage()
                for reel in page where instagramSourceByOwner[reel.user.id] == nil {
                    instagramSourceByOwner[reel.user.id] = source
                }
                nextReels += page
            }
            hasMoreInstagramStoryReels = instagramSources().contains { $0.hasMoreStoryReels }
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

            var seenOwners = Set(orderedInstagramStoryReels.map(\.user.id))
            appendedReels = appendedReels.filter { seenOwners.insert($0.user.id).inserted }
            orderedInstagramStoryReels.append(contentsOf: appendedReels)
            storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems, githubItems: githubActivityGroups)
        } catch {
            hasMoreInstagramStoryReels = instagramSources().contains { $0.hasMoreStoryReels }
        }
    }

    public func postInstagramStory(imageData: Data, width: Int, height: Int, mimeType: String, mentions: [InstagramStoryMentionPlacement] = [], closeFriends: Bool = false) async throws {
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
                try await instagramSource.postPhotoStory(imageData: imageData, width: width, height: height, mimeType: mimeType, mentions: mentions, closeFriends: closeFriends)
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
        let ownerId = (orderedInstagramStoryReels + [ownInstagramStoryReel].compactMap(\.self))
            .first { $0.slides.contains { $0.id == mediaId } }?.user.id
        guard let instagramSource = instagramSource(forOwner: ownerId) else { throw SourceError.notConfigured }
        if !DemoData.isDemoMode {
            try await instagramSource.setStoryLiked(mediaId: mediaId, liked: liked)
        }
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
        guard !DemoData.isDemoMode else { return }
        guard let itemIndex = storyBarItems.firstIndex(where: {
            if case let .spotify(item) = $0, item.userURI == userURI { return true }
            return false
        }) else { return }

        let storyItem = storyBarItems[itemIndex]
        guard case let .spotify(item) = storyItem else { return }

        spotifySeenStore.markSeen(userURI: userURI, activityTimestamp: item.timestamp)
        seenSync?.pushSpotifySeen()

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
        if !DemoData.isDemoMode {
            githubSeenStore.markSeen(actorId: actorId, activityTimestamp: group.timestamp)
            seenSync?.pushGitHubSeen()
        }
        storyBarItems[index] = .github(GitHubActivityGroup(actor: group.actor, activities: group.activities, isSeen: true))
        storyBarItems = mergedStoryBarItems(instagramReels: orderedInstagramStoryReels, spotifyItems: spotifyActivityItems, githubItems: githubActivityGroups)
    }

    /// Re-derives each current item's seen flag from the seen stores and
    /// reapplies the unread-first ordering. Called when a remote iCloud change
    /// lands so stories viewed on another device update in place.
    func refreshSeenState() {
        guard storyBarContentLoaded else { return }
        let spotify = spotifyActivityItems
            .map(spotifyItemWithSeenState)
            .sorted(by: spotifySortedUnreadFirst)
        let github = githubActivityGroups
            .map { group -> GitHubActivityGroup in
                GitHubActivityGroup(
                    actor: group.actor,
                    activities: group.activities,
                    isSeen: githubSeenStore.isSeen(actorId: group.actor.id, activityTimestamp: group.timestamp),
                )
            }
            .sorted(by: githubSortedUnreadFirst)
        storyBarItems = mergedStoryBarItems(
            instagramReels: orderedInstagramStoryReels,
            spotifyItems: spotify,
            githubItems: github,
        )
    }

    public func markInstagramReelAsSeen(reelIndex: Int) {
        guard instagramStoryReels.indices.contains(reelIndex) else { return }
        let reel = instagramStoryReels[reelIndex]
        guard !reel.isSeen else { return }
        markInstagramReelAsSeen(reelId: reel.id)
    }

    private func markSeenOnInstagram(slides: [InstagramStorySlide]) async {
        do {
            try await instagramSource(forOwner: slides.first?.ownerId)?.markReelAsSeen(slides: slides)
        } catch {
            errorMessage = "Could not mark Instagram story as seen: \(error.localizedDescription)"
        }
    }

    public func markInstagramReelAsSeen(reelId: String) {
        if let reel = ownInstagramStoryReel, reel.id == reelId, !reel.isSeen {
            Task {
                if !DemoData.isDemoMode { await markSeenOnInstagram(slides: reel.slides) }
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
            if !DemoData.isDemoMode { await markSeenOnInstagram(slides: reel.slides) }
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

    /// Every Instagram account's tray, each person once (from the first account that follows them). `nil`
    /// when every account failed, so the bar keeps what it showed.
    private func instagramReels() async -> [InstagramStoryReel]? {
        let sources = instagramSources().filter(\.storiesEnabled)
        guard !sources.isEmpty else { return [] }
        var reels: [InstagramStoryReel] = []
        var owners: [String: InstagramNotificationSource] = [:]
        var failed = 0
        for source in sources {
            do {
                let fetched = try await RefreshTiming.measure("story-instagram-reels") {
                    try await source.fetchStoryReels()
                }
                for reel in fetched where owners[reel.user.id] == nil {
                    owners[reel.user.id] = source
                    reels.append(reel)
                }
            } catch SourceError.notConfigured {
                continue
            } catch {
                failed += 1
            }
        }
        if failed == sources.count {
            return nil
        }
        instagramSourceByOwner = owners
        return reels
    }

    private func spotifyItems() async -> [SpotifyActivityItem] {
        var activity: [SpotifyActivityItem] = []
        for source in spotifyActivitySources() {
            if let fetched = try? await RefreshTiming.measure("story-spotify-activity", {
                try await source.fetchActivity(reason: .manual)
            }) {
                activity += fetched
            }
        }
        var seenUserURIs = Set<String>()
        return activity
            .sorted { $0.timestamp > $1.timestamp }
            .filter { item in
                seenUserURIs.insert(item.userURI).inserted
            }
            .map(spotifyItemWithSeenState)
            .sorted(by: spotifySortedUnreadFirst)
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

    /// Orders Spotify items unread-first, then by newest activity.
    private func spotifySortedUnreadFirst(_ lhs: SpotifyActivityItem, _ rhs: SpotifyActivityItem) -> Bool {
        if lhs.isSeen != rhs.isSeen { return !lhs.isSeen }
        return lhs.timestamp > rhs.timestamp
    }

    /// Every GitHub account's activity, each actor once (from the first account that sees them).
    private func githubItems() async -> [GitHubActivityGroup] {
        var groups: [GitHubActivityGroup] = []
        var seenActors = Set<String>()
        for source in githubActivitySources() {
            guard let fetched = try? await RefreshTiming.measure("story-github-activity", {
                try await source.fetchGitHubActivity(reason: .manual)
            }) else { continue }
            groups += fetched.filter { seenActors.insert($0.actor.id).inserted }
        }
        return groups.map { group in
            GitHubActivityGroup(
                actor: group.actor,
                activities: group.activities,
                isSeen: githubSeenStore.isSeen(actorId: group.actor.id, activityTimestamp: group.timestamp),
            )
        }
        .sorted(by: githubSortedUnreadFirst)
    }

    /// Orders GitHub groups unread-first, then by newest activity.
    private func githubSortedUnreadFirst(_ lhs: GitHubActivityGroup, _ rhs: GitHubActivityGroup) -> Bool {
        if lhs.isSeen != rhs.isSeen { return !lhs.isSeen }
        return lhs.timestamp > rhs.timestamp
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
