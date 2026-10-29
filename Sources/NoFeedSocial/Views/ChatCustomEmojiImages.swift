import ImageIO
import NoFeedSocialCore
import UIKit

/// Custom emoji images for chats, loaded once and scaled down: they only ever show at text and chip size, and
/// catalogs can hold large images.
@MainActor
final class ChatCustomEmojiImages {
    static let shared = ChatCustomEmojiImages()

    /// Enough pixels for the largest size an emoji shows at (the picker), at 3x.
    private nonisolated static let maxPixelSize = 132
    private let cache = NSCache<NSURL, UIImage>()
    private var loading: [URL: [() -> Void]] = [:]

    private init() {
        cache.countLimit = 300
    }

    /// The image when it has loaded; otherwise starts loading it and calls `onLoad` once it has.
    func image(for emoji: ChatCustomEmoji, onLoad: @escaping () -> Void) -> UIImage? {
        let url = emoji.imageURL
        if let image = cache.object(forKey: url as NSURL) {
            return image
        }
        if loading[url] != nil {
            loading[url]?.append(onLoad)
            return nil
        }
        loading[url] = [onLoad]
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            let image = await Task.detached { data.flatMap(Self.downsampled) }.value
            if let image {
                cache.setObject(image, forKey: url as NSURL)
            }
            let waiting = loading.removeValue(forKey: url) ?? []
            // A failed image stays a blank space of its size rather than retrying on every render.
            if image != nil {
                waiting.forEach { $0() }
            }
        }
        return nil
    }

    private nonisolated static func downsampled(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: 3, orientation: .up)
    }

    /// The emoji as an inline image the height of the font's line, or a blank space of that size until it loads.
    func attachment(for emoji: ChatCustomEmoji, font: UIFont, onLoad: @escaping () -> Void) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let height = font.lineHeight
        attachment.bounds = CGRect(x: 0, y: font.descender, width: height * emoji.aspectRatio, height: height)
        attachment.image = image(for: emoji, onLoad: onLoad) ?? Self.blank
        attachment.accessibilityLabel = emoji.label
        return attachment
    }

    /// A chip or picker image `height` points tall, keeping the emoji's aspect ratio.
    func image(for emoji: ChatCustomEmoji, height: CGFloat, onLoad: @escaping () -> Void) -> UIImage {
        let size = CGSize(width: height * emoji.aspectRatio, height: height)
        let image = image(for: emoji, onLoad: onLoad)
        // Original colors: a button would otherwise tint it like a symbol.
        return UIGraphicsImageRenderer(size: size).image { _ in
            image?.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
}
