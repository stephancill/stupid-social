import SwiftUI
import UIKit

typealias PlatformImage = UIImage

struct CachedAsyncImage<Placeholder: View, Failure: View>: View {
    let url: URL?
    let cacheKey: String?
    let contentMode: ContentMode
    let onComplete: (() -> Void)?
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure
    @State private var loadedImage: PlatformImage?
    @State private var failedURL: URL?

    init(
        url: URL?,
        cacheKey: String? = nil,
        contentMode: ContentMode = .fill,
        onComplete: (() -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure,
    ) {
        self.url = url
        self.cacheKey = cacheKey
        self.contentMode = contentMode
        self.onComplete = onComplete
        self.placeholder = placeholder
        self.failure = failure
        // Draw a cached image in the first frame, so a preloaded image never shows its placeholder.
        _loadedImage = State(initialValue: url.flatMap { StoryImageCache.shared.image(for: $0) }
            ?? cacheKey.flatMap { StoryImageCache.shared.image(forKey: $0) })
    }

    var body: some View {
        Group {
            if let loadedImage {
                platformImage(loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failedURL == url {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else {
            loadedImage = nil
            failedURL = nil
            onComplete?()
            return
        }

        if let cached = StoryImageCache.shared.image(for: url) {
            loadedImage = cached
            failedURL = nil
            onComplete?()
            return
        }

        if let cacheKey, let cached = StoryImageCache.shared.image(forKey: cacheKey) {
            loadedImage = cached
        } else {
            loadedImage = nil
        }
        failedURL = nil

        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) else {
                failedURL = url
                onComplete?()
                return
            }
            StoryImageCache.shared.setImage(image, for: url)
            if let cacheKey {
                StoryImageCache.shared.setImage(image, forKey: cacheKey)
            }
            loadedImage = image
            onComplete?()
            return
        }

        guard let image = await StoryImageCache.shared.load(url: url) else {
            failedURL = url
            onComplete?()
            return
        }
        if let cacheKey {
            StoryImageCache.shared.setImage(image, forKey: cacheKey)
        }
        loadedImage = image
        onComplete?()
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        Image(uiImage: image)
    }
}

@MainActor
final class StoryImageCache {
    static let shared = StoryImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let keyedCache = NSCache<NSString, PlatformImage>()
    private var loads: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        // Limited by decoded size, not count: a feed's worth of avatars is small, story slides are large.
        cache.totalCostLimit = 150 * 1024 * 1024
        keyedCache.countLimit = 80
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func setImage(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
    }

    func image(forKey key: String) -> PlatformImage? {
        keyedCache.object(forKey: key as NSString)
    }

    func setImage(_ image: PlatformImage, forKey key: String) {
        keyedCache.setObject(image, forKey: key as NSString)
    }

    func preload(url: URL) {
        guard image(for: url) == nil, loads[url] == nil else { return }
        Task { await load(url: url) }
    }

    /// Downloads and decodes `url` off the main thread, joining a load already in flight for it.
    @discardableResult
    func load(url: URL) async -> PlatformImage? {
        if let cached = image(for: url) {
            return cached
        }
        if let inFlight = loads[url] {
            return await inFlight.value
        }
        let task = Task<PlatformImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data)
            else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        loads[url] = task
        let image = await task.value
        loads[url] = nil
        if let image {
            setImage(image, for: url)
        }
        return image
    }

    private static func cost(of image: PlatformImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}
