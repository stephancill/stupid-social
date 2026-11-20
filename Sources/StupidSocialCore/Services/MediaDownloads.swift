import Foundation

/// Photos and videos the media viewer saves: the original file, downloaded to a temporary file named for its type,
/// so a video saves as the MP4 it is, not as a stream.
public enum MediaDownloads {
    /// Downloads `url` (a photo, or a video's file or HLS playlist) to a temporary file called `name` with the
    /// extension its type calls for.
    public static func file(for url: URL, name: String, session: URLSession = .shared) async throws -> URL {
        let source = try await fileURL(for: url, session: session)
        let (download, response) = try await session.download(from: source)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw SourceError.serviceError("The download failed (HTTP \(http.statusCode)).")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "MediaDownloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(fileName(name)).\(fileExtension(response: response, source: source))")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: download, to: file)
        return file
    }

    /// Where the file itself is: a Bluesky video's HLS playlist (`video.bsky.app/watch/<did>/<cid>/playlist.m3u8`)
    /// stands for the uploaded MP4, the blob on the author's PDS (`com.atproto.sync.getBlob`); other URLs are files.
    static func fileURL(for url: URL, session: URLSession) async throws -> URL {
        guard let (did, cid) = blueskyVideo(url) else { return url }
        let pds = try await personalDataServer(did: did, session: session)
        var components = URLComponents(url: pds.appending(path: "xrpc/com.atproto.sync.getBlob"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "did", value: did), URLQueryItem(name: "cid", value: cid)]
        return components.url!
    }

    static func blueskyVideo(_ url: URL) -> (did: String, cid: String)? {
        guard url.host()?.lowercased() == "video.bsky.app", url.pathExtension == "m3u8" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "watch", parts[1].hasPrefix("did:"), !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    /// The DID document's `#atproto_pds` endpoint: from plc.directory for `did:plc`, the domain for `did:web`.
    private static func personalDataServer(did: String, session: URLSession) async throws -> URL {
        let documentURL: URL? = if did.hasPrefix("did:plc:") {
            URL(string: "https://plc.directory/\(did)")
        } else if did.hasPrefix("did:web:") {
            URL(string: "https://\(did.dropFirst("did:web:".count))/.well-known/did.json")
        } else {
            nil
        }
        guard let documentURL else { throw SourceError.invalidResponse }
        let (data, _) = try await session.data(from: documentURL)
        let document = try JSONDecoder().decode(DIDDocument.self, from: data)
        guard let endpoint = document.service?.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let url = URL(string: endpoint)
        else { throw SourceError.invalidResponse }
        return url
    }

    private struct DIDDocument: Decodable {
        struct Service: Decodable {
            let id: String
            let serviceEndpoint: String
        }

        let service: [Service]?
    }

    /// From the response's type (`video/mp4` saves as `.mp4`), else the URL's own extension, else a photo's.
    static func fileExtension(response: URLResponse, source: URL) -> String {
        switch response.mimeType?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            let own = source.pathExtension.lowercased()
            return own.isEmpty ? "jpg" : own
        }
    }

    /// Letters, digits, dashes and underscores, so any post id makes a valid file name.
    static func fileName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(80))
        return cleaned.isEmpty ? "media" : cleaned
    }
}
