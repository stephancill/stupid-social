import SwiftUI
import UIKit

/// An image from a URL, through `ImageCache`.
public struct CachedAsyncImage<Placeholder: View, Failure: View>: View {
    let url: URL?
    let cacheKey: String?
    let contentMode: ContentMode
    let onComplete: (() -> Void)?
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure
    @State private var loadedImage: UIImage?
    @State private var failedURL: URL?

    public init(
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
        _loadedImage = State(initialValue: url.flatMap { ImageCache.shared.image(for: $0) }
            ?? cacheKey.flatMap { ImageCache.shared.image(forKey: $0) })
    }

    public var body: some View {
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

        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            failedURL = nil
            onComplete?()
            return
        }

        if let cacheKey, let cached = ImageCache.shared.image(forKey: cacheKey) {
            loadedImage = cached
        } else {
            loadedImage = nil
        }
        failedURL = nil

        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                failedURL = url
                onComplete?()
                return
            }
            ImageCache.shared.setImage(image, for: url)
            if let cacheKey {
                ImageCache.shared.setImage(image, forKey: cacheKey)
            }
            loadedImage = image
            onComplete?()
            return
        }

        guard let image = await ImageCache.shared.load(url: url) else {
            failedURL = url
            onComplete?()
            return
        }
        if let cacheKey {
            ImageCache.shared.setImage(image, forKey: cacheKey)
        }
        loadedImage = image
        onComplete?()
    }

    private func platformImage(_ image: UIImage) -> Image {
        Image(uiImage: image)
    }
}
