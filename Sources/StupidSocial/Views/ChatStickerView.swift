import Compression
import StupidSocialCore
import UIKit

/// A sticker, in a message or the sticker picker: its still while the file loads, then the image, or the animation
/// looping while the view is on screen, at its own frame rate (at most 60), as smoothly as Telegram's apps play it:
/// a background queue prepares the next few frames in order (`ChatStickerRenderer`), and the display link shows each
/// on time, so a slow frame delays playback a little rather than skipping. The first loop renders; later loops, and
/// other views showing the same sticker at the same size, decompress cached frames (`ChatStickerFrames`).
final class ChatStickerView: UIView {
    let sticker: ChatSticker
    private let animates: Bool
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var player: (any ChatStickerPlaying)?
    private var renderer: ChatStickerRenderer?
    private var displayLink: CADisplayLink?
    /// Frames ready to show, in order, by sequence number (the frame is the sequence modulo the frame count).
    private var ready: [(sequence: Int, image: CGImage)] = []
    private var inFlight = 0
    private var nextRequest = 0
    private var nextDue: CFTimeInterval = 0
    /// Bumped whenever playback restarts, so frames prepared for an earlier run are dropped.
    private var generation = 0
    private static let framesAhead = 3

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
        updatePlayback()
    }

    private var pixelSize: CGSize {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// Starts or stops playback as the view comes and goes, and starts again when its size changes. A still view
    /// asks for frame 0 once.
    private func updatePlayback() {
        let size = pixelSize
        guard let player, window != nil, size.width >= 1, size.height >= 1 else {
            stop()
            return
        }
        if renderer?.pixelSize != size {
            stop()
            renderer = ChatStickerRenderer(sticker: sticker, player: player, pixelSize: size)
        }
        let plays = animates && player.frameCount > 1 && !UIAccessibility.isReduceMotionEnabled
        if plays, displayLink == nil {
            let fps = Float(min(max(player.frameRate, 1), 60))
            let link = CADisplayLink(target: ChatStickerViewTicker(self), selector: #selector(ChatStickerViewTicker.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            displayLink = link
            nextDue = 0
            fill()
        } else if !plays, displayLink == nil, nextRequest == 0 {
            request()
        }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        generation += 1
        ready = []
        inFlight = 0
        nextRequest = 0
        renderer = nil
    }

    /// Keeps `framesAhead` frames prepared or on their way.
    private func fill() {
        while ready.count + inFlight < Self.framesAhead {
            request()
        }
    }

    private func request() {
        guard let renderer else { return }
        let sequence = nextRequest
        let generation = generation
        nextRequest += 1
        inFlight += 1
        let sticker = sticker
        renderer.prepare(sequence) { [weak self] image in
            guard let self, self.generation == generation else { return }
            inFlight -= 1
            guard let image else { return }
            if sequence == 0 {
                ChatStickerFiles.shared.setStill(UIImage(cgImage: image), for: sticker)
            }
            if displayLink == nil {
                imageView.image = UIImage(cgImage: image)
            } else {
                ready.append((sequence, image))
            }
        }
    }

    /// Shows the next frame when it's due, keeping to the sticker's frame rate from frame to frame; after a stall
    /// it carries on from now rather than racing to catch up.
    fileprivate func tick(_ link: CADisplayLink) {
        guard let player else { return }
        let interval = 1 / min(max(player.frameRate, 1), 60)
        let now = link.targetTimestamp
        if nextDue == 0 {
            nextDue = now
        }
        if now + 0.002 >= nextDue, !ready.isEmpty {
            imageView.image = UIImage(cgImage: ready.removeFirst().image)
            nextDue += interval
            if now - nextDue > 2 * interval {
                nextDue = now + interval
            }
        }
        fill()
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
        view.tick(link)
    }
}

/// Prepares one view's frames in order on its own queue: a cached frame is decompressed, a new one drawn into a
/// reused bitmap, compressed into the cache, and copied out.
private final class ChatStickerRenderer: @unchecked Sendable {
    let pixelSize: CGSize
    private let player: any ChatStickerPlaying
    private let frames: ChatStickerFrames
    private let queue = DispatchQueue(label: "ChatStickerRenderer", qos: .userInteractive)
    private let width: Int
    private let height: Int
    private var context: CGContext?

    @MainActor
    init(sticker: ChatSticker, player: any ChatStickerPlaying, pixelSize: CGSize) {
        self.pixelSize = pixelSize
        self.player = player
        width = Int(pixelSize.width)
        height = Int(pixelSize.height)
        frames = ChatStickerFrames.shared(for: sticker.url, width: width, height: height, count: player.frameCount)
    }

    func prepare(_ sequence: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        queue.async { [self] in
            let image = image(frame: sequence % max(player.frameCount, 1))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(image) }
            }
        }
    }

    private func image(frame index: Int) -> CGImage? {
        let bytes = width * height * 4
        var pixels: Data
        if let cached = frames.frame(index) {
            pixels = Data(count: bytes)
            let decoded = pixels.withUnsafeMutableBytes { output in
                cached.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, bytes, input.bindMemory(to: UInt8.self).baseAddress!, cached.count, nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard decoded == bytes else { return nil }
        } else {
            if context == nil {
                context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
                )
            }
            guard let context, let data = context.data else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            player.draw(index, in: context, size: pixelSize)
            pixels = Data(bytes: data, count: bytes)
            frames.store(index, pixels: pixels)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )
    }
}

/// One sticker's frames at one size, LZ4-compressed (6–20× smaller, a tenth of a millisecond to decompress at
/// 480 px, against 1–7 ms to render; observed 2026-11-04), shared by every view showing it. Kept in memory up to
/// a limit, least recently used first out.
private final class ChatStickerFrames: @unchecked Sendable {
    /// NSCache is thread-safe.
    private nonisolated(unsafe) static let cache: NSCache<NSString, ChatStickerFrames> = {
        let cache = NSCache<NSString, ChatStickerFrames>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    private let lock = NSLock()
    private var frames: [Data?]
    private var size = 0
    private let key: NSString

    private init(key: NSString, count: Int) {
        self.key = key
        frames = Array(repeating: nil, count: max(count, 1))
    }

    static func shared(for url: URL, width: Int, height: Int, count: Int) -> ChatStickerFrames {
        let key = "\(url.absoluteString)@\(width)x\(height)" as NSString
        if let frames = cache.object(forKey: key) { return frames }
        let frames = ChatStickerFrames(key: key, count: count)
        cache.setObject(frames, forKey: key, cost: 0)
        return frames
    }

    func frame(_ index: Int) -> Data? {
        lock.withLock { index < frames.count ? frames[index] : nil }
    }

    func store(_ index: Int, pixels: Data) {
        var compressed = Data(count: pixels.count)
        let length = compressed.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, pixels.count, input.bindMemory(to: UInt8.self).baseAddress!, pixels.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard length > 0 else { return }
        compressed.count = length
        let complete: Bool = lock.withLock {
            guard index < frames.count, frames[index] == nil else { return false }
            frames[index] = compressed
            size += length
            return !frames.contains(nil)
        }
        // The cost counts once the loop is complete; until then an evicted entry only loses frames it would render again.
        if complete {
            Self.cache.setObject(self, forKey: key, cost: size)
        }
    }
}

/// An animated sticker's frames.
protocol ChatStickerPlaying: AnyObject, Sendable {
    var frameRate: Double { get }
    var frameCount: Int { get }
    /// Draws frame `index` into a cleared bitmap context of `size` pixels.
    func draw(_ index: Int, in context: CGContext, size: CGSize)
}

extension LottieAnimation: ChatStickerPlaying {
    func draw(_ index: Int, in context: CGContext, size: CGSize) {
        render(frame: index, in: context, size: size)
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

    func draw(_ index: Int, in context: CGContext, size: CGSize) {
        guard let image = decoder.image(frame: index) else { return }
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
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
