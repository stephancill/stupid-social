import UIKit

/// Downloaded images by URL (and by key), shared by the chat and the rest of the app.
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let keyedCache = NSCache<NSString, UIImage>()
    private var loads: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        // Limited by decoded size, not count: a feed's worth of avatars is small, story slides are large.
        cache.totalCostLimit = 150 * 1024 * 1024
        keyedCache.countLimit = 80
    }

    public func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    public func setImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
    }

    public func image(forKey key: String) -> UIImage? {
        keyedCache.object(forKey: key as NSString)
    }

    public func setImage(_ image: UIImage, forKey key: String) {
        keyedCache.setObject(image, forKey: key as NSString)
    }

    public func preload(url: URL) {
        guard image(for: url) == nil, loads[url] == nil else { return }
        Task { await load(url: url) }
    }

    /// Downloads and decodes `url` off the main thread, joining a load already in flight for it.
    @discardableResult
    public func load(url: URL) async -> UIImage? {
        if let cached = image(for: url) {
            return cached
        }
        if let inFlight = loads[url] {
            return await inFlight.value
        }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
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

    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}
