import AVFoundation
import AVKit
import NoFeedSocialCore
import QuickLook
import UIKit

/// A video in a bubble: its poster with a play symbol and its length; tapping plays it full screen. A GIF plays
/// muted and looped in place instead, once it's on screen.
final class ChatVideoView: UIView {
    let posterView = UIImageView()
    private let url: URL
    private let isGIF: Bool
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var loadTask: Task<Void, Never>?

    init(url: URL, duration: String?, isGIF: Bool) {
        self.url = url
        self.isGIF = isGIF
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .secondarySystemFill
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(posterView)
        NSLayoutConstraint.activate([
            posterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: trailingAnchor),
            posterView.topAnchor.constraint(equalTo: topAnchor),
            posterView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = isGIF ? "GIF" : ["Video", duration].compactMap(\.self).joined(separator: ", ")

        if !isGIF {
            // A dark disc keeps the symbol legible on any frame.
            let play = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
            play.tintColor = .white
            play.contentMode = .center
            play.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            play.layer.cornerRadius = 24
            play.translatesAutoresizingMaskIntoConstraints = false
            addSubview(play)
            NSLayoutConstraint.activate([
                play.centerXAnchor.constraint(equalTo: centerXAnchor),
                play.centerYAnchor.constraint(equalTo: centerYAnchor),
                play.widthAnchor.constraint(equalToConstant: 48),
                play.heightAnchor.constraint(equalToConstant: 48),
            ])
        }
        if let badge = isGIF ? "GIF" : duration {
            let label = PaddedLabel()
            label.text = badge
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 8
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard isGIF else { return }
        if window == nil {
            stopLooping()
        } else if looper == nil, loadTask == nil {
            startLooping()
        }
    }

    private func startLooping() {
        let url = url
        loadTask = Task { [weak self] in
            guard let file = try? await ChatMediaFiles.shared.file(for: url, filename: url.pathExtension.isEmpty ? "animation.mp4" : nil),
                  let self, !Task.isCancelled, window != nil
            else { return }
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer.insertSublayer(layer, above: posterView.layer)
            playerLayer = layer
            player.play()
        }
    }

    private func stopLooping() {
        loadTask?.cancel()
        loadTask = nil
        looper?.disableLooping()
        playerLayer?.player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        looper = nil
    }
}

/// A label with room around its text, for badges on media.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// Plays a chat video full screen: the player opens at once with a spinner while the file loads.
@MainActor
enum ChatVideoPlayer {
    static func present(_ url: URL, from presenter: UIViewController, onError: @escaping (Error) -> Void) {
        let controller = AVPlayerViewController()
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            ])
        }
        presenter.present(controller, animated: true)
        Task { [weak controller] in
            do {
                let file = try await ChatMediaFiles.shared.file(for: url, filename: url.pathExtension.isEmpty ? "video.mp4" : nil)
                guard let controller, controller.presentingViewController != nil else { return }
                spinner.removeFromSuperview()
                // Like the story viewer: the silent switch doesn't mute a video the user chose to play.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                let player = AVPlayer(url: file)
                controller.player = player
                player.play()
            } catch {
                controller?.dismiss(animated: true)
                onError(error)
            }
        }
    }
}

/// One local file for Quick Look, whose data source is weak: the chat keeps this while the preview is open.
final class ChatFilePreviewSource: NSObject, QLPreviewControllerDataSource {
    private let file: URL

    init(file: URL) {
        self.file = file
    }

    func numberOfPreviewItems(in _: QLPreviewController) -> Int {
        1
    }

    func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
        file as NSURL
    }
}

/// A file in a bubble, like Telegram's and WhatsApp's: a rounded tile in the type's color showing its extension
/// (or the file's thumbnail), then the name and its details, straight on the bubble.
final class ChatFileRow: UIView {
    /// Shows the extension, or the thumbnail once `showsThumbnail()` is called.
    let tile = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let extensionLabel = UILabel()

    /// While the file loads, a spinner takes the extension's place.
    var isLoading = false {
        didSet {
            if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
            extensionLabel.alpha = isLoading ? 0 : 1
            tile.alpha = isLoading && tile.image != nil ? 0.5 : 1
        }
    }

    init(filename: String, subtitle: String?, isOwn: Bool) {
        super.init(frame: .zero)
        let ext = (filename as NSString).pathExtension.uppercased()
        tile.backgroundColor = isOwn ? .white : Self.color(forExtension: ext)
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.contentMode = .scaleAspectFill
        tile.translatesAutoresizingMaskIntoConstraints = false
        extensionLabel.text = ext.isEmpty || ext.count > 4 ? nil : ext
        extensionLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        extensionLabel.textColor = isOwn ? .systemBlue : .white
        extensionLabel.textAlignment = .center
        extensionLabel.adjustsFontSizeToFitWidth = true
        extensionLabel.minimumScaleFactor = 0.7
        // Without an extension the tile shows a page symbol instead.
        if extensionLabel.text == nil {
            tile.image = UIImage(systemName: "doc.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            tile.tintColor = isOwn ? .systemBlue : .white
            tile.contentMode = .center
        }
        spinner.color = isOwn ? .systemBlue : .white
        spinner.hidesWhenStopped = true
        for view in [extensionLabel, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }

        let nameLabel = UILabel()
        nameLabel.text = filename
        nameLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        nameLabel.textColor = isOwn ? .white : .label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let detailLabel = UILabel()
        detailLabel.text = [subtitle, ext.isEmpty ? nil : ext].compactMap(\.self).joined(separator: " · ")
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = isOwn ? UIColor.white.withAlphaComponent(0.8) : .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [tile, labels])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.widthAnchor.constraint(equalToConstant: 44),
            tile.heightAnchor.constraint(equalToConstant: 44),
            extensionLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 3),
            extensionLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -3),
            extensionLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = [filename, subtitle].compactMap(\.self).joined(separator: ", ")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The file's own picture fills the tile in place of the extension.
    func showsThumbnail() {
        extensionLabel.isHidden = true
        tile.image = nil
        tile.contentMode = .scaleAspectFill
    }

    /// Colors by kind, as file apps use: red documents, blue text, green sheets, orange archives, purple media.
    private static func color(forExtension ext: String) -> UIColor {
        switch ext {
        case "PDF": .systemRed
        case "DOC", "DOCX", "TXT", "RTF", "MD", "PAGES": .systemBlue
        case "XLS", "XLSX", "CSV", "NUMBERS": .systemGreen
        case "ZIP", "RAR", "7Z", "TAR", "GZ": .systemOrange
        case "PPT", "PPTX", "KEY": .systemOrange
        case "MP3", "WAV", "M4A", "OGG", "MP4", "MOV": .systemPurple
        default: .systemGray
        }
    }
}
