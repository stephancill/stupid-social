import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `wamedia://media/<account id>/<chat JID>/<message id>?ext=<extension>[&thumb=1]`: a WhatsApp message's file
/// (or, with `thumb`, its inline preview) that image views, video players, voice players and Quick Look load
/// through `URLSession`, since `WhatsAppMediaURLProtocol` serves the scheme. It names no key: the key and path are
/// kept with the message in the account's store.
public enum WhatsAppMediaURL {
    nonisolated static let scheme = "wamedia"

    public struct Reference: Hashable, Sendable {
        let accountId: String
        let chat: String
        let messageId: String
        let fileExtension: String
        let isThumbnail: Bool
    }

    nonisolated static func make(accountId: String, chat: String, messageId: String, fileExtension: String, thumbnail: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "media"
        components.path = "/\(accountId)/\(chat)/\(messageId)"
        components.queryItems = [URLQueryItem(name: "ext", value: thumbnail ? "jpg" : fileExtension)] + (thumbnail ? [URLQueryItem(name: "thumb", value: "1")] : [])
        return components.url
    }

    nonisolated static func parse(_ url: URL) -> Reference? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 3 else { return nil }
        let query = components.queryItems ?? []
        return Reference(
            accountId: parts[0], chat: parts[1], messageId: parts[2],
            fileExtension: query.first { $0.name == "ext" }?.value ?? "",
            isThumbnail: query.first { $0.name == "thumb" }?.value == "1",
        )
    }
}

/// Decrypted WhatsApp media in Caches, named by a hash of the account, chat and message. iOS may purge it any
/// time; the file then downloads again when shown.
enum WhatsAppMediaCache {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("whatsapp-media", isDirectory: true)
    }

    nonisolated static func file(for reference: WhatsAppMediaURL.Reference) -> URL {
        let key = "\(reference.accountId)/\(reference.chat)/\(reference.messageId)\(reference.isThumbnail ? "/thumb" : "")"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(reference.fileExtension.isEmpty ? name : "\(name).\(reference.fileExtension)")
    }

    nonisolated static func removeAll(accountId _: String) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Serves `wamedia:` URLs from the cache, or by downloading and decrypting through the account's
/// `WhatsAppClient`, so media loads only when a message is shown. Registered with `register(clients:)` whenever
/// the accounts change.
public final class WhatsAppMediaURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var clients: [String: WhatsAppClient] = [:]
    private var loadTask: Task<Void, Never>?

    public static func register(clients: [String: WhatsAppClient]) {
        self.clients = clients
        URLProtocol.registerClass(WhatsAppMediaURLProtocol.self)
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == WhatsAppMediaURL.scheme
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        guard let url = request.url, let reference = WhatsAppMediaURL.parse(url), let account = Self.clients[reference.accountId] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let loader = Loader(urlProtocol: self)
        loadTask = Task {
            do {
                let file = try await Self.load(reference, client: account)
                guard !Task.isCancelled else { return }
                try loader.finish(url: url, file: file, fileExtension: reference.fileExtension)
            } catch {
                loader.fail(error)
            }
        }
    }

    override public func stopLoading() {
        loadTask?.cancel()
    }

    private static func load(_ reference: WhatsAppMediaURL.Reference, client: WhatsAppClient) async throws -> URL {
        let file = WhatsAppMediaCache.file(for: reference)
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        let data: Data = if reference.isThumbnail {
            try await client.mediaThumbnail(chat: reference.chat, messageId: reference.messageId)
        } else {
            try await client.downloadMedia(chat: reference.chat, messageId: reference.messageId)
        }
        try FileManager.default.createDirectory(at: WhatsAppMediaCache.directory, withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }

    private struct Loader: @unchecked Sendable {
        let urlProtocol: WhatsAppMediaURLProtocol

        /// Hands the file over a megabyte at a time from a memory map, so a long video isn't read in at once.
        func finish(url: URL, file: URL, fileExtension: String) throws {
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
            let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < data.count {
                let end = min(offset + 1 << 20, data.count)
                urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data.subdata(in: offset ..< end))
                offset = end
            }
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }

        func fail(_ error: Error) {
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
        }
    }
}

/// A file to send, with what its media message records: kind, pixel size, length, a small JPEG preview, and a
/// voice message's waveform.
public struct WhatsAppOutgoingMedia: Sendable {
    let data: Data
    let kind: WhatsAppMedia.Kind
    let mimetype: String
    let fileName: String?
    var width: UInt32?
    var height: UInt32?
    var seconds: UInt32?
    var thumbnail: Data?
    var isVoice = false
    var waveform: Data?

    /// Images as photos (GIFs and SVGs as files), videos as videos, anything else as a document.
    public static func make(data: Data, mimeType: String, filename: String, isImage: Bool) async -> WhatsAppOutgoingMedia {
        if isImage, mimeType != "image/gif", mimeType != "image/svg+xml" {
            var media = WhatsAppOutgoingMedia(data: data, kind: .image, mimetype: mimeType == "image/png" ? mimeType : "image/jpeg", fileName: nil)
            if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
                {
                    let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
                    media.width = UInt32(rotated ? height : width)
                    media.height = UInt32(rotated ? width : height)
                }
                media.thumbnail = jpegThumbnail(source: source)
            }
            return media
        }
        if mimeType.hasPrefix("video/") {
            var media = WhatsAppOutgoingMedia(data: data, kind: .video, mimetype: "video/mp4", fileName: nil)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
            defer { try? FileManager.default.removeItem(at: file) }
            if (try? data.write(to: file)) != nil {
                let asset = AVURLAsset(url: file)
                if let duration = try? await asset.load(.duration) {
                    media.seconds = UInt32(max(duration.seconds.rounded(), 0))
                }
                if let track = try? await asset.loadTracks(withMediaType: .video).first, let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let shown = size.applying(transform)
                    media.width = UInt32(abs(shown.width))
                    media.height = UInt32(abs(shown.height))
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 100, height: 100)
                if let image = try? await generator.image(at: .zero).image {
                    media.thumbnail = jpeg(image)
                }
            }
            return media
        }
        return WhatsAppOutgoingMedia(data: data, kind: .document, mimetype: mimeType, fileName: filename)
    }

    /// A voice message as WhatsApp's apps send it: Ogg Opus, its length and 64 levels (0–100).
    public static func voice(oggOpus data: Data, duration: Double, levels: [Double]) -> WhatsAppOutgoingMedia {
        var media = WhatsAppOutgoingMedia(data: data, kind: .audio, mimetype: "audio/ogg; codecs=opus", fileName: nil)
        media.seconds = UInt32(max(duration.rounded(), 1))
        media.isVoice = true
        media.waveform = Data(levels.map { UInt8(min(max($0, 0), 1) * 100) })
        return media
    }

    private static func jpegThumbnail(source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 100,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(jpeg)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
