import Compression
import CryptoKit
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
        if sticker.format == .image, let image = ChatMediaImageCache.shared.image(for: sticker.url) {
            imageView.image = image
        } else if let still = ChatStickerFiles.shared.still(for: sticker) {
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
        } else if !plays, displayLink == nil, nextRequest == 0, !showsSharpStill(for: size) {
            request()
        }
    }

    /// A still already drawn at this size or larger needs no frame 0 of its own.
    private func showsSharpStill(for size: CGSize) -> Bool {
        guard let image = imageView.image else { return false }
        return max(image.size.width, image.size.height) * image.scale >= max(size.width, size.height) * 0.9
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
    private var preparing: [String: Task<Void, Never>] = [:]
    /// First frames as PNGs, so stickers show at once on later launches too.
    private let stillsDirectory = URL.cachesDirectory.appending(path: "sticker-stills", directoryHint: .isDirectory)
    /// Stills smaller than this (a tab's icon) stay in memory only, so they never stand in for a grid's on disk.
    private static let minimumStoredSide: CGFloat = 150

    private init() {
        files.countLimit = 60
        stills.totalCostLimit = 80 * 1024 * 1024
        try? FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
    }

    /// By host and path: a Telegram URL's query carries a file reference that changes while the file doesn't.
    private static func stillKey(_ sticker: ChatSticker) -> String {
        "\(sticker.url.scheme ?? "")://\(sticker.url.host ?? "")\(sticker.url.path)"
    }

    private func stillFile(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return stillsDirectory.appending(path: "\(name).png")
    }

    private static func side(_ image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    /// The sticker's first frame from memory, or from disk (a small PNG, decoded here).
    func still(for sticker: ChatSticker) -> UIImage? {
        let key = Self.stillKey(sticker)
        if let image = stills.object(forKey: key as NSString) { return image }
        guard let data = try? Data(contentsOf: stillFile(key)), let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
        remember(image, key: key)
        return image
    }

    private func remember(_ image: UIImage, key: String) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        stills.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }

    /// Keeps the larger of this and the still already there.
    func setStill(_ image: UIImage, for sticker: ChatSticker) {
        let key = Self.stillKey(sticker)
        if let existing = stills.object(forKey: key as NSString), Self.side(existing) >= Self.side(image) { return }
        remember(image, key: key)
        guard Self.side(image) >= Self.minimumStoredSide else { return }
        let file = stillFile(key)
        Task.detached(priority: .utility) {
            try? image.pngData()?.write(to: file, options: .atomic)
        }
    }

    /// Draws the sticker's first frame at `side` pixels ahead of showing it, so the picker never shows a blank
    /// cell. `warm` also brings a still on disk into memory, for what shows first.
    func prepareStill(for sticker: ChatSticker, side: CGFloat, warm: Bool) async {
        let key = Self.stillKey(sticker)
        if let existing = stills.object(forKey: key as NSString), Self.side(existing) >= side * 0.9 { return }
        let file = stillFile(key)
        if FileManager.default.fileExists(atPath: file.path) {
            guard warm, stills.object(forKey: key as NSString) == nil else { return }
            if let image = await Task.detached(priority: .utility, operation: { () -> UIImage? in
                (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))?.preparingForDisplay()
            }).value {
                remember(image, key: key)
            }
            return
        }
        if let task = preparing[key] { return await task.value }
        let task = Task { [weak self] in
            guard let self, let image = await render(sticker, side: side) else { return }
            setStill(image, for: sticker)
        }
        preparing[key] = task
        await task.value
        preparing[key] = nil
    }

    private func render(_ sticker: ChatSticker, side: CGFloat) async -> UIImage? {
        switch sticker.format {
        case .image:
            guard let data = try? await URLSession.shared.data(from: sticker.url).0 else { return nil }
            return await Task.detached(priority: .utility) { Self.downsample(data, side: side) }.value
        case .lottie, .video:
            if let player = await player(for: sticker), player.frameCount > 0 {
                let image = await Task.detached(priority: .utility) { Self.firstFrame(player, side: Int(side)) }.value
                if let image { return image }
            }
            // A video sticker without a VP9 decoder (the simulator) shows its poster.
            guard let posterURL = sticker.posterURL else { return nil }
            return await ChatMediaImageCache.shared.load(posterURL)
        }
    }

    private nonisolated static func downsample(_ data: Data, side: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return UIImage(data: data) }
        return UIImage(cgImage: image)
    }

    private nonisolated static func firstFrame(_ player: any ChatStickerPlaying, side: Int) -> UIImage? {
        guard side > 0, let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        player.draw(0, in: context, size: CGSize(width: side, height: side))
        return context.makeImage().map { UIImage(cgImage: $0) }
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
                // Telegram's are gzipped (TGS); Discord's are plain JSON.
                case .lottie: ((try? LottieAnimation(tgs: data)) ?? (try? LottieAnimation(json: data))).map(ChatStickerFile.lottie)
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
