import StupidSocialCore
import UIKit

/// A sticker, in a message or the sticker picker: its still while the file loads, then the image, or the animation
/// looping while the view is on screen. Frames render off the main thread at the view's pixel size, one at a time,
/// at most 30 a second; a frame that isn't ready in time is skipped.
final class ChatStickerView: UIView {
    let sticker: ChatSticker
    private let animates: Bool
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var player: (any ChatStickerPlaying)?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var isRendering = false

    /// `animates` false shows the first frame, for grids of stickers such as the picker.
    init(sticker: ChatSticker, animates: Bool = true) {
        self.sticker = sticker
        self.animates = animates
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        imageView.pinToEdges(of: self)
        isAccessibilityElement = true
        accessibilityLabel = sticker.label
        accessibilityTraits = .image
        if let still = ChatStickerFiles.shared.still(for: sticker) {
            imageView.image = still
        } else if let posterURL = sticker.posterURL {
            imageView.image = ChatMediaImageCache.shared.image(for: posterURL)
        }
        load()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    private func load() {
        let sticker = sticker
        loadTask = Task { [weak self] in
            if self?.imageView.image == nil, let posterURL = sticker.posterURL, let poster = await ChatMediaImageCache.shared.load(posterURL) {
                guard let self, !Task.isCancelled, imageView.image == nil else { return }
                imageView.image = poster
            }
            switch sticker.format {
            case .image:
                guard let image = await ChatMediaImageCache.shared.load(sticker.url), !Task.isCancelled else { return }
                self?.imageView.image = image
            case .lottie, .video:
                guard let player = await ChatStickerFiles.shared.player(for: sticker), !Task.isCancelled, let self else { return }
                self.player = player
                renderFirstFrame(player)
                updatePlayback()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let player, displayLink == nil, ChatStickerFiles.shared.still(for: sticker) == nil {
            renderFirstFrame(player)
        }
    }

    private var pixelSize: CGSize {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: max(bounds.width, 1) * scale, height: max(bounds.height, 1) * scale)
    }

    /// The first frame, kept as the sticker's still so it shows at once next time.
    private func renderFirstFrame(_ player: any ChatStickerPlaying) {
        guard bounds.width > 0 else { return }
        let size = pixelSize
        let sticker = sticker
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let image = player.frame(0, pixelSize: size) else { return }
            await MainActor.run {
                let still = UIImage(cgImage: image)
                ChatStickerFiles.shared.setStill(still, for: sticker)
                guard let self, self.displayLink == nil || !self.isRendering else { return }
                self.imageView.image = still
            }
        }
    }

    private func updatePlayback() {
        let plays = animates && window != nil && player != nil && !UIAccessibility.isReduceMotionEnabled
        if plays, displayLink == nil {
            let link = CADisplayLink(target: ChatStickerViewTicker(self), selector: #selector(ChatStickerViewTicker.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            startTime = CACurrentMediaTime()
        } else if !plays {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() {
        guard let player, !isRendering else { return }
        let frame = Int((CACurrentMediaTime() - startTime) * player.frameRate) % max(player.frameCount, 1)
        isRendering = true
        let size = pixelSize
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = player.frame(frame, pixelSize: size)
            await MainActor.run {
                guard let self else { return }
                self.isRendering = false
                if let image, self.displayLink != nil {
                    self.imageView.image = UIImage(cgImage: image)
                }
            }
        }
    }
}

/// The display link's target, so the link doesn't keep the view alive; it stops the link once the view is gone.
private final class ChatStickerViewTicker {
    weak var view: ChatStickerView?

    init(_ view: ChatStickerView) {
        self.view = view
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick()
    }
}

/// An animated sticker's frames.
protocol ChatStickerPlaying: AnyObject, Sendable {
    var frameRate: Double { get }
    var frameCount: Int { get }
    func frame(_ index: Int, pixelSize: CGSize) -> CGImage?
}

extension LottieAnimation: ChatStickerPlaying {
    func frame(_ index: Int, pixelSize: CGSize) -> CGImage? {
        image(frame: index, pixelSize: pixelSize)
    }
}

/// A video sticker's frames at the video's size, from a decoder of its own: VP9 frames depend on the ones before.
private final class WebMStickerPlayer: ChatStickerPlaying, @unchecked Sendable {
    private let decoder: WebMStickerDecoder

    init(decoder: WebMStickerDecoder) {
        self.decoder = decoder
    }

    var frameRate: Double {
        decoder.sticker.frameRate
    }

    var frameCount: Int {
        decoder.sticker.frameCount
    }

    func frame(_ index: Int, pixelSize _: CGSize) -> CGImage? {
        decoder.image(frame: index)
    }
}

/// An animated sticker's parsed file.
private enum ChatStickerFile {
    case lottie(LottieAnimation)
    case video(WebMSticker)
}

/// Animated stickers' files, parsed once and shared by every view showing them, and their first frames as stills.
@MainActor
final class ChatStickerFiles {
    static let shared = ChatStickerFiles()

    private final class Entry {
        let file: ChatStickerFile

        init(_ file: ChatStickerFile) {
            self.file = file
        }
    }

    private let files = NSCache<NSURL, Entry>()
    private let stills = NSCache<NSString, UIImage>()
    private var loading: [URL: Task<ChatStickerFile?, Never>] = [:]

    private init() {
        files.countLimit = 60
        stills.totalCostLimit = 40 * 1024 * 1024
    }

    func still(for sticker: ChatSticker) -> UIImage? {
        stills.object(forKey: sticker.url.absoluteString as NSString)
    }

    func setStill(_ image: UIImage, for sticker: ChatSticker) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        stills.setObject(image, forKey: sticker.url.absoluteString as NSString, cost: Int(pixels) * 4)
    }

    /// A Lottie animation is shared; a video gets a decoder of its own over the shared file.
    func player(for sticker: ChatSticker) async -> (any ChatStickerPlaying)? {
        switch await file(for: sticker) {
        case let .lottie(animation): animation
        case let .video(video): WebMStickerDecoder(sticker: video).map(WebMStickerPlayer.init)
        case nil: nil
        }
    }

    private func file(for sticker: ChatSticker) async -> ChatStickerFile? {
        if let entry = files.object(forKey: sticker.url as NSURL) { return entry.file }
        if let task = loading[sticker.url] { return await task.value }
        let format = sticker.format
        let url = sticker.url
        let task = Task<ChatStickerFile?, Never> {
            guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> ChatStickerFile? in
                switch format {
                case .lottie: (try? LottieAnimation(tgs: data)).map(ChatStickerFile.lottie)
                case .video: WebMSticker(data: data).map(ChatStickerFile.video)
                case .image: nil
                }
            }.value
        }
        loading[url] = task
        let file = await task.value
        loading[url] = nil
        if let file {
            files.setObject(Entry(file), forKey: url as NSURL)
        }
        return file
    }
}
