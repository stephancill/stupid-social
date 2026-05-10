import AVFoundation
import Combine
import NoFeedSocialCore
import SwiftUI

struct SpotifyStoryViewer: View {
    let items: [SpotifyActivityItem]
    let startIndex: Int
    let spotifyClient: SpotifyClient
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var elapsedTime: Double = 0
    @State private var isPaused: Bool = false
    @State private var player: AVPlayer?
    @State private var playerStatus: PlayerStatus = .idle
    @State private var previewURLs: [String: URL?] = [:]
    @State private var audioDuration: Double = 5

    enum PlayerStatus: Equatable {
        case idle
        case loading
        case playing
        case paused
        case finished
        case unavailable
    }

    init(items: [SpotifyActivityItem], startIndex: Int = 0, spotifyClient: SpotifyClient) {
        self.items = items
        self.startIndex = startIndex
        self.spotifyClient = spotifyClient
        _currentIndex = State(initialValue: startIndex)
    }

    private var slideDuration: Double {
        audioDuration
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if items.indices.contains(currentIndex) {
                content(for: items[currentIndex])
                topBar
                footer
            }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            loadPreviewURL(for: startIndex)
        }
        .onChange(of: currentIndex) { _, newIndex in
            elapsedTime = 0
            audioDuration = 5
            stopPlayback()
            loadPreviewURL(for: newIndex)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard !isPaused else { return }
            guard items.indices.contains(currentIndex) else { return }
            elapsedTime += 0.05
            if elapsedTime >= slideDuration {
                elapsedTime = 0
                goForward()
            }
        }
        .onDisappear {
            stopPlayback()
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isPaused = true
                    player?.pause()
                }
                .onEnded { _ in
                    isPaused = false
                    if playerStatus == .playing {
                        player?.play()
                    }
                }
        )
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    let hTranslation = value.translation.width
                    let vTranslation = value.translation.height
                    if vTranslation > 80 {
                        stopPlayback()
                        dismiss()
                    } else if hTranslation < -50 {
                        goForward()
                    } else if hTranslation > 50 {
                        goBack()
                    }
                }
        )
    }

    private func content(for _: SpotifyActivityItem) -> some View {
        VStack(spacing: 32) {
            Spacer()

            albumArtView

            trackInfoView

            playbackControl

            Spacer()
        }
    }

    @ViewBuilder
    private var albumArtView: some View {
        let item = items[currentIndex]
        let animation = item.musicAnimation
        let url = item.imageURL

        ZStack {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 280, height: 280)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            }
            .rotationEffect(.degrees(playerStatus == .playing && !isPaused ? 360 : 0))
            .animation(
                playerStatus == .playing && !isPaused
                    ? .linear(duration: rotationDuration(animation)).repeatForever(autoreverses: false)
                    : nil,
                value: playerStatus
            )

            SpotifyPulseRing(
                delay: 0,
                isAnimating: playerStatus == .playing && !isPaused,
                duration: pulseDuration(animation),
                scale: pulseScale(animation),
                opacity: pulseOpacity(animation),
                size: 280
            )
            SpotifyPulseRing(
                delay: pulseDuration(animation) * 0.48,
                isAnimating: playerStatus == .playing && !isPaused,
                duration: pulseDuration(animation),
                scale: pulseScale(animation) * 1.08,
                opacity: pulseOpacity(animation) * 0.72,
                size: 280
            )
        }
    }

    private var trackInfoView: some View {
        let item = items[currentIndex]
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
            }

            Text(item.timestamp.compactRelativeTime)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var playbackControl: some View {
        let item = items[currentIndex]

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
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 3)

                            if index == currentIndex {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(
                                        width: geo.size.width * min(elapsedTime / slideDuration, 1.0),
                                        height: 3
                                    )
                            } else if index < currentIndex {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(height: 3)
                            }
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 10) {
                let item = items[currentIndex]

                AsyncImage(url: item.userAvatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        Circle().fill(Color.white.opacity(0.2))
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.userName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(item.timestamp.compactRelativeTime)
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
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()

                HStack(spacing: 20) {
                    Button {
                        goBack()
                    } label: {
                        Color.clear
                            .frame(width: geo.size.width * 0.35, height: geo.size.height * 0.7)
                    }

                    Spacer()

                    Button {
                        goForward()
                    } label: {
                        Color.clear
                            .frame(width: geo.size.width * 0.35, height: geo.size.height * 0.7)
                    }
                }
            }
        }
    }

    private func goForward() {
        if currentIndex + 1 < items.count {
            currentIndex += 1
        } else {
            stopPlayback()
            dismiss()
        }
    }

    private func goBack() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }

    private func loadPreviewURL(for index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let trackId = extractTrackId(from: item.trackURI)
        guard !trackId.isEmpty else {
            previewURLs[trackId] = .some(nil)
            playerStatus = .unavailable
            return
        }
        if previewURLs[trackId] != nil { return }

        Task {
            let url = await spotifyClient.trackPreviewURL(trackId: trackId)
            previewURLs[trackId] = url
            guard currentIndex == index else { return }
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

        playerStatus = .playing
        newPlayer.play()
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerStatus = .idle
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

    // MARK: - Animation parameters

    private func tempo(_ animation: MusicAnimationMetadata?) -> Double {
        guard let tempo = animation?.tempo, tempo > 0 else { return 108 }
        return min(max(tempo, 60), 190)
    }

    private func confidence(_ animation: MusicAnimationMetadata?) -> Double {
        min(max(animation?.tempoConfidence ?? 0.55, 0.3), 1)
    }

    private func loudnessIntensity(_ animation: MusicAnimationMetadata?) -> Double {
        guard let loudness = animation?.loudness else { return 0.58 }
        return min(max((loudness + 24) / 18, 0.22), 1)
    }

    private func rotationDuration(_ animation: MusicAnimationMetadata?) -> TimeInterval {
        (60 / tempo(animation)) * 16
    }

    private func pulseDuration(_ animation: MusicAnimationMetadata?) -> TimeInterval {
        min(max((60 / tempo(animation)) * 2, 0.65), 1.55)
    }

    private func pulseScale(_ animation: MusicAnimationMetadata?) -> Double {
        0.98 + loudnessIntensity(animation) * 0.36
    }

    private func pulseOpacity(_ animation: MusicAnimationMetadata?) -> Double {
        min((0.72 + loudnessIntensity(animation) * 0.28) * confidence(animation), 1)
    }
}

private struct SpotifyPulseRing: View {
    let delay: TimeInterval
    let isAnimating: Bool
    let duration: TimeInterval
    let scale: Double
    let opacity: Double
    let size: CGFloat

    var body: some View {
        Circle()
            .stroke(.white.opacity(opacity), lineWidth: 7)
            .frame(width: size, height: size)
            .scaleEffect(isAnimating ? scale : 1)
            .opacity(isAnimating ? 0 : opacity)
            .animation(
                .easeOut(duration: duration)
                    .delay(delay)
                    .repeatForever(autoreverses: false),
                value: isAnimating
            )
    }
}
