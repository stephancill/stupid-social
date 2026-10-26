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

    private var currentId: String?
    private var currentState = State.idle
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var unavailableIds: Set<String> = []

    func state(for id: String) -> State {
        if unavailableIds.contains(id) { return .unavailable }
        return id == currentId ? currentState : .idle
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
            player = AVPlayer(playerItem: item)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.player?.seek(to: .zero)
                    self?.setState(.paused)
                }
            }
            play()
        }
    }

    func stop() {
        guard currentId != nil else { return }
        player?.pause()
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
/// Tapping outside the button opens the song.
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
        player: ChatAudioPreviewPlayer,
        resolveURL: @escaping (String) async -> URL?,
    ) {
        self.previewId = previewId
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .systemBackground.withAlphaComponent(0.6)
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

        let row = UIStackView(arrangedSubviews: [artworkView, labels])
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            artworkView.widthAnchor.constraint(equalToConstant: 64),
            artworkView.heightAnchor.constraint(equalToConstant: 64),
            playButton.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
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
