import AVFoundation
import Combine
import NoFeedSocialCore
import SwiftUI

struct UnifiedStoryViewer: View {
    let items: [StoryBarItem]
    let startIndex: Int
    let spotifyClient: SpotifyClient
    let onInstagramReelSeen: (String) -> Void
    let onSpotifyItemSeen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    @State private var currentItemIndex: Int
    @State private var currentSlideIndex: Int = 0
    @State private var elapsedTime: Double = 0
    @State private var isPaused: Bool = false
    @State private var seenItems: Set<Int>
    @State private var touchStartedAt: Date?

    @State private var player: AVPlayer?
    @State private var playerStatus: PlayerStatus = .idle
    @State private var previewURLs: [String: URL?] = [:]
    @State private var audioDuration: Double = 5
    @State private var pulsePhase: Double = 0
    @State private var rotationPhase: Double = 0
    @State private var loadingProgressPulse = false
    @State private var loadingArtworkPulse = false

    enum PlayerStatus: Equatable {
        case idle
        case loading
        case playing
        case paused
        case finished
        case unavailable
    }

    init(
        items: [StoryBarItem],
        startIndex: Int,
        spotifyClient: SpotifyClient,
        onInstagramReelSeen: @escaping (String) -> Void,
        onSpotifyItemSeen: @escaping (String) -> Void
    ) {
        self.items = items
        self.startIndex = startIndex
        self.spotifyClient = spotifyClient
        self.onInstagramReelSeen = onInstagramReelSeen
        self.onSpotifyItemSeen = onSpotifyItemSeen
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
                        playerStatus: playerStatus,
                        reduceMotion: reduceMotion
                    )

                    progressBar(slideCount: slideCount)
                    topBar
                }
            }
            .contentShape(Rectangle())
            .gesture(storyGesture(width: geo.size.width))
        }
        .onAppear {
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            loadingProgressPulse = true
            loadingArtworkPulse = true
            markCurrentItemSeen()
            prepareForCurrentItem()
        }
        .onChange(of: currentItemIndex) { _, _ in
            elapsedTime = 0
            currentSlideIndex = 0
            audioDuration = 5
            pulsePhase = 0
            rotationPhase = 0
            stopPlayback()
            markCurrentItemSeen()
            prepareForCurrentItem()
        }
        .onChange(of: currentSlideIndex) { _, _ in
            elapsedTime = 0
        }
        .onReceive(Timer.publish(every: frameInterval, on: .main, in: .common).autoconnect()) { _ in
            guard !isPaused else { return }
            guard items.indices.contains(currentItemIndex) else { return }

            if case .spotify = items[currentItemIndex] {
                if playerStatus == .loading, player?.timeControlStatus == .playing {
                    elapsedTime = 0
                    playerStatus = .playing
                }
                guard playerStatus == .playing || playerStatus == .unavailable else {
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
    }

    private var slideDuration: Double {
        guard case .spotify = currentItem else { return 5 }
        if playerStatus == .unavailable || playerStatus == .finished {
            return 5
        }
        return audioDuration
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

    private func prepareForCurrentItem() {
        guard case let .spotify(spotifyItem) = currentItem else {
            playerStatus = .idle
            return
        }
        loadPreviewURL(for: spotifyItem)
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
                                    .fill(Color.gray.opacity(loadingProgressPulse ? 0.45 : 0.18))
                                    .frame(height: 3)
                                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: loadingProgressPulse)
                            } else {
                                Capsule()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 3)

                                if index == currentSlideIndex {
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(
                                            width: geo.size.width * min(elapsedTime / slideDuration, 1.0),
                                            height: 3
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
                endPoint: .bottom
            )
            .ignoresSafeArea()
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
                }
            }
            .onEnded { value in
                let touchDuration = touchStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                touchStartedAt = nil
                isPaused = false

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

    private func startPlayback(url: URL, trackId _: String) {
        playerStatus = .loading

        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
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
            queue: .main
        ) { _ in
            Task { @MainActor in
                playerStatus = .finished
            }
        }

        newPlayer.play()
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

// MARK: - StoryBarItem Provider Extensions

private extension StoryBarItem {
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
        playerStatus: UnifiedStoryViewer.PlayerStatus,
        reduceMotion: Bool
    ) -> some View {
        switch self {
        case let .instagram(reel):
            instagramSlideContent(reel: reel, slideIndex: slideIndex)
        case let .spotify(item):
            spotifySlideContent(
                item: item,
                pulsePhase: pulsePhase,
                rotationDegrees: rotationDegrees,
                loadingArtworkPulse: loadingArtworkPulse,
                playerStatus: playerStatus,
                reduceMotion: reduceMotion
            )
        }
    }

    @ViewBuilder
    private func instagramSlideContent(reel: InstagramStoryReel, slideIndex: Int) -> some View {
        if !reel.slides.isEmpty, reel.slides.indices.contains(slideIndex) {
            AsyncImage(url: reel.slides[slideIndex].imageURL) { phase in
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
        } else {
            Color.gray.opacity(0.3)
        }
    }

    private func spotifySlideContent(
        item: SpotifyActivityItem,
        pulsePhase: Double,
        rotationDegrees: Double,
        loadingArtworkPulse: Binding<Bool>,
        playerStatus _: UnifiedStoryViewer.PlayerStatus,
        reduceMotion: Bool
    ) -> some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                SpotifyPulseRing(
                    phase: pulsePhase,
                    maxPhase: pulseDuration(item.musicAnimation),
                    scale: spotifyPulseScale(item.musicAnimation),
                    opacity: spotifyPulseOpacity(item.musicAnimation),
                    size: 260
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
                Link(destination: trackURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.title3)
                        Text("Open in Spotify")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.12), in: Capsule())
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
        }
        .frame(height: 64)
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
