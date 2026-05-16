import SwiftUI

#if os(iOS)
    import UIKit

    typealias PlatformImage = UIImage
#elseif os(macOS)
    import AppKit

    typealias PlatformImage = NSImage
#endif

struct CachedAsyncImage<Placeholder: View, Failure: View>: View {
    let url: URL?
    let cacheKey: String?
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure
    @State private var loadedImage: PlatformImage?
    @State private var failedURL: URL?

    init(
        url: URL?,
        cacheKey: String? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure,
    ) {
        self.url = url
        self.cacheKey = cacheKey
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            if let loadedImage {
                platformImage(loadedImage)
                    .resizable()
                    .scaledToFill()
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
            return
        }

        if let cached = StoryImageCache.shared.image(for: url) {
            loadedImage = cached
            failedURL = nil
            return
        }

        if let cacheKey, let cached = StoryImageCache.shared.image(forKey: cacheKey) {
            loadedImage = cached
        } else {
            loadedImage = nil
        }
        failedURL = nil

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = PlatformImage(data: data) else {
                failedURL = url
                return
            }
            StoryImageCache.shared.setImage(image, for: url)
            if let cacheKey {
                StoryImageCache.shared.setImage(image, forKey: cacheKey)
            }
            loadedImage = image
        } catch {
            failedURL = url
        }
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if os(iOS)
            Image(uiImage: image)
        #elseif os(macOS)
            Image(nsImage: image)
        #endif
    }
}

@MainActor
final class StoryImageCache {
    static let shared = StoryImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let keyedCache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 80
        keyedCache.countLimit = 80
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func setImage(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func image(forKey key: String) -> PlatformImage? {
        keyedCache.object(forKey: key as NSString)
    }

    func setImage(_ image: PlatformImage, forKey key: String) {
        keyedCache.setObject(image, forKey: key as NSString)
    }

    func preload(url: URL) {
        guard image(for: url) == nil else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data)
            else { return }
            await MainActor.run {
                StoryImageCache.shared.setImage(image, for: url)
            }
        }
    }
}
