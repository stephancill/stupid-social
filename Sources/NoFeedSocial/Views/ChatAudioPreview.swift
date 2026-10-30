import AVFoundation
import UIKit

/// Plays one chat's audio previews, one at a time: starting another card's preview stops the current one.
@MainActor
final class ChatAudioPreviewPlayer {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case unavailable
    }

    /// Posted with the player as its object whenever a card's state may have changed.
    static let didChangeNotification = Notification.Name("ChatAudioPreviewPlayer.didChange")
    /// Posted with the player as its object about 20 times a second while something plays.
    static let progressNotification = Notification.Name("ChatAudioPreviewPlayer.progress")

    private var currentId: String?
    private var currentState = State.idle
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var unavailableIds: Set<String> = []

    func state(for id: String) -> State {
        if unavailableIds.contains(id) { return .unavailable }
        return id == currentId ? currentState : .idle
    }

    /// How far `id` has played, while it's the current one: seconds in, and the length once the file knows it.
    func position(for id: String) -> (elapsed: TimeInterval, duration: TimeInterval?)? {
        guard id == currentId, let player, [.playing, .paused].contains(currentState) else { return nil }
        let duration = player.currentItem?.duration.seconds
        return (player.currentTime().seconds, duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    /// Moves the current `id` to a fraction of its length; does nothing for another one.
    func seek(id: String, to fraction: Double) {
        guard id == currentId, let player, let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
        player.seek(to: CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600))
        NotificationCenter.default.post(name: Self.progressNotification, object: self)
    }

    /// Plays or pauses the preview `id`, resolving its URL the first time.
    func toggle(id: String, resolveURL: @escaping () async -> URL?) {
        if id == currentId {
            switch currentState {
            case .playing:
                player?.pause()
                setState(.paused)
            case .paused:
                play()
            case .idle, .loading, .unavailable:
                break
            }
            return
        }
        stop()
        currentId = id
        setState(.loading)
        Task {
            let url = await resolveURL()
            guard currentId == id, currentState == .loading else { return }
            guard let url else {
                unavailableIds.insert(id)
                currentId = nil
                setState(.idle)
                return
            }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    NotificationCenter.default.post(name: Self.progressNotification, object: self)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                // Finished: back to the start, like Telegram, so the next press plays it again.
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }
            play()
        }
    }

    func stop() {
        guard currentId != nil else { return }
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        currentId = nil
        setState(.idle)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plays like the story viewer, under the `.playback` category so the silent switch doesn't mute it.
    private func play() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        player?.play()
        setState(.playing)
    }

    private func setState(_ state: State) {
        currentState = state
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// A song in a message: artwork with a play button for its preview, then title, artists and details.
/// Tapping outside the button opens the song. Without artwork, such as an audio file, it's a round play button
/// beside the title, straight on the bubble like Telegram's.
final class ChatAudioCardView: UIView {
    let artworkView = UIImageView()
    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let previewId: String
    private weak var player: ChatAudioPreviewPlayer?

    init(
        previewId: String,
        title: String,
        subtitle: String?,
        detail: String?,
        link: URL?,
        hasArtwork: Bool,
        isOwn: Bool,
        player: ChatAudioPreviewPlayer,
        resolveURL: @escaping (String) async -> URL?,
    ) {
        self.previewId = previewId
        self.player = player
        super.init(frame: .zero)
        backgroundColor = hasArtwork ? .systemBackground.withAlphaComponent(0.6) : .clear
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .secondarySystemFill
        artworkView.isUserInteractionEnabled = true

        // A dark disc keeps the symbol legible on any artwork.
        playButton.tintColor = .white
        playButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playButton.layer.cornerRadius = 18
        playButton.addAction(UIAction { [weak self] _ in
            guard let self, let player = self.player else { return }
            player.toggle(id: previewId) { await resolveURL(previewId) }
        }, for: .primaryActionTriggered)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        for view in [playButton, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            artworkView.addSubview(view)
        }

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.isHidden = subtitle == nil
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.isHidden = detail == nil
        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2

        let artworkSide: CGFloat = hasArtwork ? 64 : 44
        if !hasArtwork {
            // The button is the whole disc, in the bubble's accent.
            artworkView.backgroundColor = ChatVoiceView.accent(isOwn: isOwn)
            artworkView.layer.cornerRadius = artworkSide / 2
            playButton.backgroundColor = .clear
            playButton.tintColor = isOwn ? .systemBlue : .white
            spinner.color = isOwn ? .systemBlue : .white
            titleLabel.textColor = isOwn ? .white : .label
            subtitleLabel.textColor = isOwn ? UIColor.white.withAlphaComponent(0.8) : .secondaryLabel
            detailLabel.textColor = isOwn ? UIColor.white.withAlphaComponent(0.7) : .secondaryLabel
        }
        let row = UIStackView(arrangedSubviews: [artworkView, labels])
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = hasArtwork
            ? NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12)
            : NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            artworkView.widthAnchor.constraint(equalToConstant: artworkSide),
            artworkView.heightAnchor.constraint(equalToConstant: artworkSide),
            playButton.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: hasArtwork ? 36 : artworkSide),
            playButton.heightAnchor.constraint(equalToConstant: hasArtwork ? 36 : artworkSide),
            spinner.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
        ])

        if let link {
            addGestureRecognizer(ChatLinkTapGesture(link: link))
        }
        isAccessibilityElement = false
        playButton.accessibilityLabel = "Play Preview of \(title)"
        // Selector observers are removed when the card deallocates.
        NotificationCenter.default.addObserver(self, selector: #selector(updateState), name: ChatAudioPreviewPlayer.didChangeNotification, object: player)
        updateState()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func updateState() {
        let state = player?.state(for: previewId) ?? .idle
        let symbol = switch state {
        case .playing: "pause.fill"
        case .unavailable: "speaker.slash.fill"
        case .idle, .loading, .paused: "play.fill"
        }
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        playButton.isEnabled = state != .unavailable
        playButton.alpha = state == .loading ? 0 : 1
        if state == .loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        playButton.accessibilityLabel = state == .playing ? "Pause Preview" : state == .unavailable ? "No Preview Available" : "Play Preview"
    }
}

/// A voice message, like Telegram's: a round play button, the waveform filling in as it plays (a tap on it
/// seeks), and the time played, or the length while it isn't playing.
final class ChatVoiceView: UIView {
    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let waveformView = ChatWaveformView()
    private let timeLabel = UILabel()
    private let previewId: String
    private let duration: Double?
    private weak var player: ChatAudioPreviewPlayer?

    /// White on the user's own blue bubble, the tint on others'.
    static func accent(isOwn: Bool) -> UIColor {
        isOwn ? .white : .systemBlue
    }

    init(previewId: String, duration: Double?, waveform: [Double], isOwn: Bool, player: ChatAudioPreviewPlayer, resolveURL: @escaping (String) async -> URL?) {
        self.previewId = previewId
        self.duration = duration
        self.player = player
        super.init(frame: .zero)
        let accent = Self.accent(isOwn: isOwn)

        playButton.backgroundColor = accent
        playButton.tintColor = isOwn ? .systemBlue : .white
        playButton.layer.cornerRadius = 22
        playButton.addAction(UIAction { [weak self] _ in
            guard let self, let player = self.player else { return }
            player.toggle(id: previewId) { await resolveURL(previewId) }
        }, for: .primaryActionTriggered)
        spinner.color = isOwn ? .systemBlue : .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        playButton.addSubview(spinner)

        waveformView.levels = waveform
        waveformView.playedColor = accent
        waveformView.unplayedColor = accent.withAlphaComponent(isOwn ? 0.45 : 0.3)
        waveformView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(seek(_:))))
        waveformView.isAccessibilityElement = false

        timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        timeLabel.textColor = isOwn ? UIColor.white.withAlphaComponent(0.8) : .secondaryLabel

        let column = UIStackView(arrangedSubviews: [waveformView, timeLabel])
        column.axis = .vertical
        column.spacing = 3
        column.alignment = .leading
        let row = UIStackView(arrangedSubviews: [playButton, column])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Longer messages get a longer waveform, as in Telegram.
        let width = min(max(110 + CGFloat(duration ?? 0) * 3, 120), 190)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: width),
            waveformView.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Selector observers are removed when the view deallocates.
        NotificationCenter.default.addObserver(self, selector: #selector(updateState), name: ChatAudioPreviewPlayer.didChangeNotification, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(updateProgress), name: ChatAudioPreviewPlayer.progressNotification, object: player)
        updateState()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func seek(_ tap: UITapGestureRecognizer) {
        guard waveformView.bounds.width > 0 else { return }
        player?.seek(id: previewId, to: tap.location(in: waveformView).x / waveformView.bounds.width)
    }

    @objc private func updateState() {
        let state = player?.state(for: previewId) ?? .idle
        let symbol = switch state {
        case .playing: "pause.fill"
        case .unavailable: "exclamationmark"
        case .idle, .loading, .paused: "play.fill"
        }
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        playButton.isEnabled = state != .unavailable
        if state == .loading {
            playButton.setImage(nil, for: .normal)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        playButton.accessibilityLabel = state == .playing ? "Pause Voice Message" : state == .unavailable ? "Voice Message Unavailable" : "Play Voice Message"
        updateProgress()
    }

    @objc private func updateProgress() {
        let position = player?.position(for: previewId)
        let length = position?.duration ?? duration
        if let position, let length, length > 0 {
            waveformView.progress = position.elapsed / length
            timeLabel.text = Self.format(position.elapsed)
        } else {
            waveformView.progress = 0
            timeLabel.text = duration.map(Self.format) ?? " "
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Waveform bars: the played part in one color, the rest in another. Levels are resampled to as many bars as fit,
/// each the loudest level in its part; without levels the bars are flat, like Telegram's.
final class ChatWaveformView: UIView {
    var levels: [Double] = [] {
        didSet { setNeedsDisplay() }
    }

    /// From 0 to 1.
    var progress: Double = 0 {
        didSet { if progress != oldValue { setNeedsDisplay() } }
    }

    var playedColor = UIColor.systemBlue
    var unplayedColor = UIColor.systemBlue.withAlphaComponent(0.3)

    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 1.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_: CGRect) {
        let count = max(1, Int((bounds.width + Self.gap) / (Self.barWidth + Self.gap)))
        for bar in 0 ..< count {
            let level: Double = if levels.isEmpty {
                0
            } else {
                levels[bar * levels.count / count ..< max(bar * levels.count / count + 1, (bar + 1) * levels.count / count)].max() ?? 0
            }
            let height = max(Self.barWidth, bounds.height * CGFloat(level))
            let rect = CGRect(x: CGFloat(bar) * (Self.barWidth + Self.gap), y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
            (Double(bar) / Double(count) < progress ? playedColor : unplayedColor).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: Self.barWidth / 2).fill()
        }
    }
}
