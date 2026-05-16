import AVFoundation
import Combine
import NoFeedSocialCore
import SwiftUI
#if os(iOS)
    import UIKit
#endif

struct UnifiedStoryViewer: View {
    let items: [StoryBarItem]
    let startIndex: Int
    let spotifyClient: SpotifyClient
    let feedService: FeedService
    let ownInstagramAccountId: String?
    let onInstagramReelSeen: (String) -> Void
    let onSpotifyItemSeen: (String) -> Void
    let onInstagramStoryDelete: (String, Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    @State private var currentItemIndex: Int
    @State private var currentSlideIndex: Int = 0
    @State private var elapsedTime: Double = 0
    @State private var isPaused: Bool = false
    @State private var isMuted: Bool = false
    @State private var seenItems: Set<Int>
    @State private var touchStartedAt: Date?

    @State private var player: AVPlayer?
    @State private var playerStatus: PlayerStatus = .idle
    @State private var previewURLs: [String: URL?] = [:]
    @State private var preloadedPreviews: [String: PreloadedPreview] = [:]
    @State private var preloadingTrackIds: Set<String> = []
    @State private var audioDuration: Double = 5
    @State private var pulsePhase: Double = 0
    @State private var rotationPhase: Double = 0
    @State private var loadingArtworkPulse = false
    @State private var spotifySavedStatus: [String: Bool] = [:]
    @State private var spotifySavingTrackIds: Set<String> = []
    @State private var pendingDeleteSlide: InstagramStorySlide?
    @State private var isDeletingStory = false
    @State private var deleteErrorMessage: String?

    enum PlayerStatus: Equatable {
        case idle
        case loading
        case playing
        case paused
        case finished
        case unavailable
    }

    private struct PreloadedPreview {
        let asset: AVURLAsset
        let duration: Double?
    }

    init(
        items: [StoryBarItem],
        startIndex: Int,
        spotifyClient: SpotifyClient,
        feedService: FeedService,
        ownInstagramAccountId: String?,
        onInstagramReelSeen: @escaping (String) -> Void,
        onSpotifyItemSeen: @escaping (String) -> Void,
        onInstagramStoryDelete: @escaping (String, Bool) async throws -> Void,
    ) {
        self.items = items
        self.startIndex = startIndex
        self.spotifyClient = spotifyClient
        self.feedService = feedService
        self.ownInstagramAccountId = ownInstagramAccountId
        self.onInstagramReelSeen = onInstagramReelSeen
        self.onSpotifyItemSeen = onSpotifyItemSeen
        self.onInstagramStoryDelete = onInstagramStoryDelete
        _currentItemIndex = State(initialValue: startIndex)
        _seenItems = State(initialValue: [])
    }

    private var currentItem: StoryBarItem? {
        guard items.indices.contains(currentItemIndex) else { return nil }
        return items[currentItemIndex]
    }

    private var slideCount: Int {
        currentItem?.slideCount ?? 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let currentItem {
                        currentItem.makeSlideContent(
                            slideIndex: currentSlideIndex,
                            pulsePhase: pulsePhase,
                            rotationPhase: rotationPhase,
                            rotationDegrees: rotationDegrees,
                            loadingArtworkPulse: $loadingArtworkPulse,
                            feedService: feedService,
                            player: player,
                            playerStatus: playerStatus,
                            reduceMotion: reduceMotion,
                            spotifySavedStatus: $spotifySavedStatus,
                            spotifySavingTrackIds: $spotifySavingTrackIds,
                            spotifyClient: spotifyClient,
                        )

                        progressBar(slideCount: slideCount)
                        topBar
                    }
                }
                .contentShape(Rectangle())
                .gesture(storyGesture(width: geo.size.width))
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .onAppear {
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            loadingArtworkPulse = true
            scheduleCurrentItemSeenMark()
            prepareForCurrentItem()
        }
        .onChange(of: currentItemIndex) { _, _ in
            elapsedTime = 0
            currentSlideIndex = 0
            audioDuration = 5
            pulsePhase = 0
            rotationPhase = 0
            stopPlayback()
            scheduleCurrentItemSeenMark()
            prepareForCurrentItem()
        }
        .onChange(of: currentSlideIndex) { _, _ in
            elapsedTime = 0
            audioDuration = 5
            stopPlayback()
            prepareForCurrentItem()
        }
        .onReceive(Timer.publish(every: frameInterval, on: .main, in: .common).autoconnect()) { _ in
            guard !isPaused else { return }
            guard items.indices.contains(currentItemIndex) else { return }

            if case .spotify = items[currentItemIndex] {
                if playerStatus == .loading, player?.timeControlStatus == .playing {
                    elapsedTime = 0
                    playerStatus = .playing
                }
                guard playerStatus == .playing || playerStatus == .finished || playerStatus == .unavailable else {
                    return
                }
            }

            elapsedTime += frameInterval
            if elapsedTime >= slideDuration {
                elapsedTime = 0
                advance()
            }

            if case let .spotify(item) = items[currentItemIndex] {
                let pd = pulseDuration(item.musicAnimation)
                pulsePhase += frameInterval
                if pulsePhase >= pd {
                    pulsePhase = 0
                }

                if !reduceMotion {
                    let rd = rotationDuration(item.musicAnimation)
                    rotationPhase += frameInterval
                    if rotationPhase >= rd {
                        rotationPhase.formTruncatingRemainder(dividingBy: rd)
                    }
                }
            }
        }
        .onDisappear {
            stopPlayback()
        }
        .confirmationDialog("Delete Story?", isPresented: deleteConfirmationBinding, titleVisibility: .visible) {
            Button("Delete Story", role: .destructive) {
                deletePendingStory()
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSlide = nil
            }
        } message: {
            Text("This will remove the current Instagram story from your account.")
        }
        .alert("Delete Failed", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "Could not delete the story.")
        }
    }

    private var slideDuration: Double {
        switch currentItem {
        case let .instagram(reel):
            guard reel.slides.indices.contains(currentSlideIndex) else { return 5 }
            let slide = reel.slides[currentSlideIndex]
            if slide.isVideo {
                return slide.videoDuration ?? audioDuration
            }
            return 5
        case .spotify:
            if playerStatus == .unavailable {
                return 5
            }
            return audioDuration
        case nil:
            return 5
        }
    }

    private func markCurrentItemSeen() {
        guard let item = currentItem, !seenItems.contains(currentItemIndex) else { return }
        seenItems.insert(currentItemIndex)
        switch item {
        case let .instagram(reel):
            onInstagramReelSeen(reel.id)
        case let .spotify(spotifyItem):
            onSpotifyItemSeen(spotifyItem.userURI)
        }
    }

    private func scheduleCurrentItemSeenMark() {
        let itemIndex = currentItemIndex
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard currentItemIndex == itemIndex else { return }
            markCurrentItemSeen()
        }
    }

    private func prepareForCurrentItem() {
        defer {
            preloadAdjacentSpotifyPreviews()
            preloadAdjacentInstagramStories()
        }

        if case let .instagram(reel) = currentItem {
            playerStatus = .idle
            guard reel.slides.indices.contains(currentSlideIndex) else { return }
            let slide = reel.slides[currentSlideIndex]
            guard slide.isVideo, let videoURL = slide.videoURL else { return }
            startVideoPlayback(url: videoURL, duration: slide.videoDuration)
            return
        }

        guard case let .spotify(spotifyItem) = currentItem else {
            playerStatus = .idle
            return
        }
        loadPreviewURL(for: spotifyItem)
        checkSavedStatus(for: spotifyItem)
    }

    private func checkSavedStatus(for item: SpotifyActivityItem) {
        let trackId = extractTrackId(from: item.trackURI)
        guard !trackId.isEmpty, spotifySavedStatus[trackId] == nil else { return }
        Task {
            let saved = await spotifyClient.isTrackSaved(trackId: trackId)
            await MainActor.run {
                spotifySavedStatus[trackId] = saved
            }
        }
    }

    // MARK: - Progress Bar

    private func progressBar(slideCount: Int) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0 ..< slideCount, id: \.self) { index in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            if case .spotify = currentItem,
                               playerStatus == .loading || playerStatus == .idle
                            {
                                Capsule()
                                    .fill(Color.gray.opacity(0.28))
                                    .frame(height: 3)
                            } else {
                                Capsule()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 3)

                                if index == currentSlideIndex {
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(
                                            width: geo.size.width * min(elapsedTime / slideDuration, 1.0),
                                            height: 3,
                                        )
                                } else if index < currentSlideIndex {
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(height: 3)
                                }
                            }
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 8)

            topBarContent
        }
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea(),
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Top Bar

    private var topBarContent: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: currentItem?.userAvatarURL, cacheKey: currentItem?.avatarCacheKey) {
                Circle().fill(Color.white.opacity(0.2))
            } failure: {
                Circle().fill(Color.white.opacity(0.2))
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(userName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            if canDeleteCurrentInstagramStory {
                Menu {
                    Button("Delete Story", role: .destructive) {
                        pendingDeleteSlide = currentInstagramSlide
                        isPaused = true
                        player?.pause()
                    }
                } label: {
                    if isDeletingStory {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .padding(8)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .disabled(isDeletingStory)
            }

            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                }
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }

            Button {
                stopPlayback()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .padding(.horizontal, 16)
    }

    private var topBar: some View {
        EmptyView()
    }

    private var currentInstagramSlide: InstagramStorySlide? {
        guard case let .instagram(reel) = currentItem,
              reel.slides.indices.contains(currentSlideIndex)
        else { return nil }
        return reel.slides[currentSlideIndex]
    }

    private var canDeleteCurrentInstagramStory: Bool {
        guard let ownInstagramAccountId,
              case let .instagram(reel) = currentItem,
              reel.user.id == ownInstagramAccountId,
              currentInstagramSlide != nil
        else { return false }
        return true
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteSlide != nil },
            set: { if !$0 { pendingDeleteSlide = nil } },
        )
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } },
        )
    }

    private func deletePendingStory() {
        guard let slide = pendingDeleteSlide else { return }
        pendingDeleteSlide = nil
        isDeletingStory = true
        Task {
            do {
                try await onInstagramStoryDelete(slide.id, slide.isVideo)
                await MainActor.run {
                    isDeletingStory = false
                    advanceAfterDeletion()
                }
            } catch {
                await MainActor.run {
                    isDeletingStory = false
                    deleteErrorMessage = "Could not delete the story. Try again from Instagram if it remains visible."
                }
            }
        }
    }

    private func advanceAfterDeletion() {
        if let item = currentItem, currentSlideIndex + 1 < item.slideCount {
            currentSlideIndex += 1
        } else {
            stopPlayback()
            dismiss()
        }
    }

    private var userName: String {
        guard let item = currentItem else { return "" }
        switch item {
        case let .instagram(reel):
            return DebugRedaction.actorName(reel.user, enabled: devModeEnabled)
        case let .spotify(spotifyItem):
            return DebugRedaction.username(spotifyItem.userName, enabled: devModeEnabled)
        }
    }

    private var subtitleText: String {
        guard let item = currentItem else { return "" }
        switch item {
        case .instagram:
            guard case let .instagram(reel) = item,
                  reel.slides.indices.contains(currentSlideIndex)
            else { return "" }
            return Date(timeIntervalSince1970: reel.slides[currentSlideIndex].takenAt).compactRelativeTime
        case let .spotify(spotifyItem):
            return spotifyItem.timestamp.compactRelativeTime
        }
    }

    // MARK: - Gestures

    private func storyGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                if touchStartedAt == nil {
                    touchStartedAt = Date()
                }
                if currentItem?.isInstagram == true {
                    isPaused = true
                    player?.pause()
                }
            }
            .onEnded { value in
                let touchDuration = touchStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                touchStartedAt = nil
                isPaused = false
                if currentItem?.isInstagram == true {
                    player?.play()
                }

                let hTranslation = value.translation.width
                let vTranslation = value.translation.height
                if vTranslation > 80 {
                    stopPlayback()
                    dismiss()
                } else if hTranslation < -50 {
                    goToNextItem()
                } else if hTranslation > 50 {
                    goToPreviousItem()
                } else if abs(hTranslation) < 20, abs(vTranslation) < 20, touchDuration < 0.35 {
                    if value.location.x < width / 2 {
                        goBack()
                    } else {
                        advance()
                    }
                }
            }
    }

    // MARK: - Navigation

    private func advance() {
        guard let item = currentItem else { return }
        if currentSlideIndex + 1 < item.slideCount {
            currentSlideIndex += 1
        } else if currentItemIndex + 1 < items.count {
            currentItemIndex += 1
            currentSlideIndex = 0
        } else {
            stopPlayback()
            dismiss()
        }
    }

    private func goBack() {
        if currentSlideIndex > 0 {
            currentSlideIndex -= 1
        } else if currentItemIndex > 0 {
            currentItemIndex -= 1
            currentSlideIndex = max(0, (items[currentItemIndex].slideCount) - 1)
        }
    }

    private func goToNextItem() {
        if currentItemIndex + 1 < items.count {
            currentItemIndex += 1
            currentSlideIndex = 0
        } else {
            stopPlayback()
            dismiss()
        }
    }

    private func goToPreviousItem() {
        guard currentItemIndex > 0 else { return }
        currentItemIndex -= 1
        currentSlideIndex = 0
    }

    // MARK: - Spotify Audio

    private func loadPreviewURL(for item: SpotifyActivityItem) {
        let trackId = extractTrackId(from: item.trackURI)
        guard !trackId.isEmpty else {
            previewURLs[trackId] = .some(nil)
            playerStatus = .unavailable
            return
        }
        if let cachedURL = previewURLs[trackId] {
            if let cachedURL {
                startPlayback(url: cachedURL, trackId: trackId)
            } else {
                playerStatus = .unavailable
            }
            return
        }

        playerStatus = .loading
        Task {
            let url = await spotifyClient.trackPreviewURL(trackId: trackId)
            previewURLs[trackId] = url
            guard case let .spotify(current) = currentItem,
                  extractTrackId(from: current.trackURI) == trackId
            else { return }
            if let url {
                startPlayback(url: url, trackId: trackId)
            } else {
                playerStatus = .unavailable
            }
        }
    }

    private func startPlayback(url: URL, trackId: String) {
        playerStatus = .loading

        let playerItem: AVPlayerItem
        if let preloaded = preloadedPreviews[trackId] {
            playerItem = AVPlayerItem(asset: preloaded.asset)
            if let duration = preloaded.duration {
                audioDuration = duration
            }
        } else {
            playerItem = AVPlayerItem(url: url)
        }
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = isMuted
        player = newPlayer

        Task {
            let duration = try? await playerItem.asset.load(.duration)
            if let duration, duration.seconds > 0, duration.seconds.isFinite {
                audioDuration = duration.seconds
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                guard player?.currentItem === playerItem else { return }
                playerStatus = .finished
                advance()
            }
        }

        newPlayer.play()
    }

    private func startVideoPlayback(url: URL, duration: Double?) {
        playerStatus = .loading

        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = isMuted
        player = newPlayer

        if let duration, duration > 0, duration.isFinite {
            audioDuration = duration
        } else {
            Task {
                let duration = try? await playerItem.asset.load(.duration)
                if let duration, duration.seconds > 0, duration.seconds.isFinite {
                    audioDuration = duration.seconds
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                playerStatus = .finished
            }
        }

        newPlayer.play()
        playerStatus = .playing
    }

    private func preloadAdjacentSpotifyPreviews() {
        if let previousSpotifyItem = items[..<currentItemIndex].reversed().compactMap({ spotifyItem(from: $0) }).first {
            preloadPreview(for: previousSpotifyItem)
        }

        if let nextSpotifyItem = items.dropFirst(currentItemIndex + 1).compactMap({ spotifyItem(from: $0) }).first {
            preloadPreview(for: nextSpotifyItem)
        }
    }

    private func preloadAdjacentInstagramStories() {
        preloadInstagramSlide(itemIndex: currentItemIndex, slideIndex: currentSlideIndex - 1)
        preloadInstagramSlide(itemIndex: currentItemIndex, slideIndex: currentSlideIndex + 1)
        preloadInstagramSlide(itemIndex: currentItemIndex - 1, slideIndex: 0)
        preloadInstagramSlide(itemIndex: currentItemIndex + 1, slideIndex: 0)
    }

    private func preloadInstagramSlide(itemIndex: Int, slideIndex: Int) {
        guard items.indices.contains(itemIndex), case let .instagram(reel) = items[itemIndex] else { return }
        guard reel.slides.indices.contains(slideIndex) else { return }
        StoryImageCache.shared.preload(url: reel.slides[slideIndex].imageURL)
    }

    private func spotifyItem(from item: StoryBarItem) -> SpotifyActivityItem? {
        guard case let .spotify(spotifyItem) = item else { return nil }
        return spotifyItem
    }

    private func preloadPreview(for item: SpotifyActivityItem) {
        let trackId = extractTrackId(from: item.trackURI)
        guard !trackId.isEmpty, preloadedPreviews[trackId] == nil, !preloadingTrackIds.contains(trackId) else { return }

        preloadingTrackIds.insert(trackId)
        Task {
            let url: URL?
            if let cachedURL = previewURLs[trackId] {
                url = cachedURL
            } else {
                url = await spotifyClient.trackPreviewURL(trackId: trackId)
                previewURLs[trackId] = url
            }

            defer { preloadingTrackIds.remove(trackId) }
            guard let url else { return }
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            preloadedPreviews[trackId] = PreloadedPreview(
                asset: asset,
                duration: duration.flatMap { duration in
                    guard duration.seconds > 0, duration.seconds.isFinite else { return nil }
                    return duration.seconds
                },
            )
        }
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerStatus = .idle
        pulsePhase = 0
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    private func extractTrackId(from uri: String) -> String {
        uri.replacingOccurrences(of: "spotify:track:", with: "")
            .replacingOccurrences(of: "spotify:album:", with: "")
            .replacingOccurrences(of: "spotify:playlist:", with: "")
            .replacingOccurrences(of: "spotify:artist:", with: "")
            .replacingOccurrences(of: "spotify:user:", with: "")
            .replacingOccurrences(of: "spotify:socialsession:", with: "")
    }

    // MARK: - Animation Parameters

    private let frameInterval: TimeInterval = 1.0 / 60.0

    private func tempo(_ animation: MusicAnimationMetadata?) -> Double {
        guard let tempo = animation?.tempo, tempo > 0 else { return 108 }
        return min(max(tempo, 60), 190)
    }

    private func rotationDuration(_ animation: MusicAnimationMetadata?) -> TimeInterval {
        (60 / tempo(animation)) * 16
    }

    private var rotationDegrees: Double {
        guard case let .spotify(item) = currentItem else { return 0 }
        let duration = rotationDuration(item.musicAnimation)
        guard duration > 0 else { return 0 }
        return (rotationPhase / duration) * 360
    }

    private func pulseDuration(_ animation: MusicAnimationMetadata?) -> TimeInterval {
        min(max((60 / tempo(animation)) * 2, 0.65), 1.55)
    }
}

#if os(iOS)
    private struct StoryVideoPlayer: UIViewRepresentable {
        let player: AVPlayer

        func makeUIView(context _: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = player
            return view
        }

        func updateUIView(_ uiView: PlayerLayerView, context _: Context) {
            uiView.playerLayer.player = player
        }

        final class PlayerLayerView: UIView {
            override static var layerClass: AnyClass {
                AVPlayerLayer.self
            }

            var playerLayer: AVPlayerLayer {
                layer as! AVPlayerLayer
            }

            override init(frame: CGRect) {
                super.init(frame: frame)
                playerLayer.videoGravity = .resizeAspect
                backgroundColor = .black
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                nil
            }
        }
    }

#elseif os(macOS)
    private struct StoryVideoPlayer: NSViewRepresentable {
        let player: AVPlayer

        func makeNSView(context _: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = player
            return view
        }

        func updateNSView(_ nsView: PlayerLayerView, context _: Context) {
            nsView.playerLayer.player = player
        }

        final class PlayerLayerView: NSView {
            let playerLayer = AVPlayerLayer()

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer = playerLayer
                playerLayer.videoGravity = .resizeAspect
                playerLayer.backgroundColor = NSColor.black.cgColor
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                nil
            }
        }
    }
#endif

// MARK: - StoryBarItem Provider Extensions

@MainActor private extension StoryBarItem {
    var slideCount: Int {
        switch self {
        case let .instagram(reel): reel.slides.count
        case .spotify: 1
        }
    }

    var isInstagram: Bool {
        if case .instagram = self { return true }
        return false
    }

    var avatarCacheKey: String {
        switch self {
        case let .instagram(reel): "instagram-avatar-\(reel.user.id)"
        case let .spotify(item): "spotify-avatar-\(item.userURI)"
        }
    }

    @ViewBuilder
    func makeSlideContent(
        slideIndex: Int,
        pulsePhase: Double,
        rotationPhase _: Double,
        rotationDegrees: Double,
        loadingArtworkPulse: Binding<Bool>,
        feedService: FeedService,
        player: AVPlayer?,
        playerStatus: UnifiedStoryViewer.PlayerStatus,
        reduceMotion: Bool,
        spotifySavedStatus: Binding<[String: Bool]>,
        spotifySavingTrackIds: Binding<Set<String>>,
        spotifyClient: SpotifyClient,
    ) -> some View {
        switch self {
        case let .instagram(reel):
            instagramSlideContent(reel: reel, slideIndex: slideIndex, feedService: feedService, player: player)
        case let .spotify(item):
            spotifySlideContent(
                item: item,
                pulsePhase: pulsePhase,
                rotationDegrees: rotationDegrees,
                loadingArtworkPulse: loadingArtworkPulse,
                playerStatus: playerStatus,
                reduceMotion: reduceMotion,
                spotifySavedStatus: spotifySavedStatus,
                spotifySavingTrackIds: spotifySavingTrackIds,
                spotifyClient: spotifyClient,
            )
        }
    }

    @ViewBuilder
    private func instagramSlideContent(reel: InstagramStoryReel, slideIndex: Int, feedService: FeedService, player: AVPlayer?) -> some View {
        if !reel.slides.isEmpty, reel.slides.indices.contains(slideIndex) {
            let slide = reel.slides[slideIndex]
            ZStack(alignment: .bottom) {
                if slide.isVideo, let player {
                    StoryVideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    AsyncImage(url: slide.imageURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure, .empty:
                            Color.gray.opacity(0.3)
                        @unknown default:
                            Color.clear
                        }
                    }
                }

                VStack(spacing: 10) {
                    if let music = slide.music {
                        musicMetadataView(music)
                    }

                    if !slide.mentions.isEmpty || !slide.links.isEmpty {
                        storyMetadataLinks(mentions: slide.mentions, links: slide.links, feedService: feedService)
                    }

                    if let embedURL = slide.embedURL {
                        Link(destination: embedURL) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.title3)
                                Text(slide.embedLabel ?? "Open post")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(.white.opacity(0.18), lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 42)
            }
        } else {
            Color.gray.opacity(0.3)
        }
    }

    private func storyMetadataLinks(mentions: [InstagramStoryMention], links: [InstagramStoryLink], feedService: FeedService) -> some View {
        HStack(spacing: 8) {
            ForEach(mentions.prefix(3), id: \.self) { mention in
                if let actor = mention.actor {
                    NavigationLink {
                        ProfileDetailView(actor: actor, feedService: feedService)
                    } label: {
                        storyPillText("@\(mention.username)", systemImage: "person.crop.circle")
                    }
                } else {
                    storyPillText("@\(mention.username)", systemImage: "person.crop.circle")
                }
            }

            ForEach(links.prefix(2), id: \.self) { link in
                Link(destination: link.url) {
                    storyPillText(link.title, systemImage: "link")
                }
            }
        }
        .lineLimit(1)
    }

    private func storyPillText(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func musicMetadataView(_ music: InstagramStoryMusic) -> some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: music.artworkURL) {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } failure: {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(music.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = music.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func spotifySlideContent(
        item: SpotifyActivityItem,
        pulsePhase: Double,
        rotationDegrees: Double,
        loadingArtworkPulse: Binding<Bool>,
        playerStatus _: UnifiedStoryViewer.PlayerStatus,
        reduceMotion: Bool,
        spotifySavedStatus: Binding<[String: Bool]>,
        spotifySavingTrackIds: Binding<Set<String>>,
        spotifyClient: SpotifyClient,
    ) -> some View {
        let trackId = item.trackURI
            .replacingOccurrences(of: "spotify:track:", with: "")
            .replacingOccurrences(of: "spotify:album:", with: "")
            .replacingOccurrences(of: "spotify:playlist:", with: "")
            .replacingOccurrences(of: "spotify:artist:", with: "")
            .replacingOccurrences(of: "spotify:user:", with: "")
            .replacingOccurrences(of: "spotify:socialsession:", with: "")
        let saved = spotifySavedStatus.wrappedValue[trackId]
        let isSaving = spotifySavingTrackIds.wrappedValue.contains(trackId)
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                SpotifyPulseRing(
                    phase: pulsePhase,
                    maxPhase: pulseDuration(item.musicAnimation),
                    scale: spotifyPulseScale(item.musicAnimation),
                    opacity: spotifyPulseOpacity(item.musicAnimation),
                    size: 260,
                )

                CachedAsyncImage(url: item.imageURL) {
                    Color.gray.opacity(loadingArtworkPulse.wrappedValue ? 0.26 : 0.12)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: loadingArtworkPulse.wrappedValue)
                } failure: {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
                .rotationEffect(.degrees(reduceMotion ? 0 : rotationDegrees))
            }

            trackInfoView(item: item)

            if let trackURL = item.trackURL {
                HStack(spacing: 12) {
                    Link(destination: trackURL) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.title3)
                            Text("Open in Spotify")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(.white.opacity(0.12), in: Capsule())
                    }

                    if saved == true {
                        Button {
                            spotifySavingTrackIds.wrappedValue.insert(trackId)
                            Task {
                                let removed = await spotifyClient.removeTrack(trackId: trackId)
                                spotifySavingTrackIds.wrappedValue.remove(trackId)
                                if removed {
                                    spotifySavedStatus.wrappedValue[trackId] = false
                                    playSpotifySaveHaptic()
                                }
                            }
                        } label: {
                            Group {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.title3.weight(.semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.green, in: Circle())
                        }
                        .disabled(isSaving)
                        .accessibilityLabel("Remove from Liked Songs")
                    } else {
                        Button {
                            spotifySavingTrackIds.wrappedValue.insert(trackId)
                            Task {
                                let saved = await spotifyClient.saveTrack(trackId: trackId)
                                spotifySavingTrackIds.wrappedValue.remove(trackId)
                                if saved {
                                    spotifySavedStatus.wrappedValue[trackId] = true
                                    playSpotifySaveHaptic()
                                }
                            }
                        } label: {
                            Group {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "plus")
                                        .font(.title3.weight(.semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: Capsule())
                        }
                        .disabled(isSaving)
                        .accessibilityLabel("Save track")
                    }
                }
            }

            Spacer()
        }
    }

    private func trackInfoView(item: SpotifyActivityItem) -> some View {
        let trackText = item.artistName.map { "\(item.trackName) — \($0)" } ?? item.trackName

        return VStack(spacing: 4) {
            Text(trackText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let album = item.albumName {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            if let contextName = item.contextName, contextName != item.albumName {
                Text("From \(contextName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(height: 84)
        .padding(.horizontal, 32)
    }

    private func tempo(_ animation: MusicAnimationMetadata?) -> Double {
        guard let tempo = animation?.tempo, tempo > 0 else { return 108 }
        return min(max(tempo, 60), 190)
    }

    private func pulseDuration(_ animation: MusicAnimationMetadata?) -> TimeInterval {
        min(max((60 / tempo(animation)) * 2, 0.65), 1.55)
    }

    private func loudnessIntensity(_ animation: MusicAnimationMetadata?) -> Double {
        guard let loudness = animation?.loudness else { return 0.58 }
        return min(max((loudness + 24) / 18, 0.22), 1)
    }

    private func confidence(_ animation: MusicAnimationMetadata?) -> Double {
        min(max(animation?.tempoConfidence ?? 0.55, 0.3), 1)
    }

    private func spotifyPulseScale(_ animation: MusicAnimationMetadata?) -> Double {
        0.98 + loudnessIntensity(animation) * 0.36
    }

    private func spotifyPulseOpacity(_ animation: MusicAnimationMetadata?) -> Double {
        min((0.72 + loudnessIntensity(animation) * 0.28) * confidence(animation), 1)
    }
}

@MainActor
private func playSpotifySaveHaptic() {
    #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
}
