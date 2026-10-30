import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// An encrypted X Chat attachment: where X stores it and which conversation key opens it.
public struct XChatMediaReference: Hashable, Sendable {
    let conversationId: String
    let hashKey: String
    let keyVersion: String
    /// The filename's extension, for the cache file and the MIME type, so players and Quick Look know the type.
    let fileExtension: String
}

/// `xchatmedia://media/<conversation id>/<media hash key>?v=<key version>&ext=<extension>`: an encrypted X Chat
/// attachment any image view, video player or file preview loads through `URLSession`, since
/// `XChatMediaURLProtocol` serves the scheme. It names no key, so it is safe to keep; the conversation key comes
/// from whichever X account's `XChatClient` has it.
enum XChatMediaURL {
    nonisolated static let scheme = "xchatmedia"

    nonisolated static func make(_ reference: XChatMediaReference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "media"
        components.path = "/\(reference.conversationId)/\(reference.hashKey)"
        components.queryItems = [
            URLQueryItem(name: "v", value: reference.keyVersion),
            URLQueryItem(name: "ext", value: reference.fileExtension),
        ]
        return components.url
    }

    nonisolated static func parse(_ url: URL) -> XChatMediaReference? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2, let version = components.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        let fileExtension = components.queryItems?.first(where: { $0.name == "ext" })?.value ?? ""
        return XChatMediaReference(conversationId: parts[0], hashKey: parts[1], keyVersion: version, fileExtension: fileExtension)
    }

    /// dm-core's media URL: `https://ton.x.com/i/ton/data/xchat_media/<conversation id>/<media hash key>`.
    nonisolated static func downloadURL(_ reference: XChatMediaReference) -> URL {
        URL(string: "https://ton.x.com/i/ton/data/xchat_media/")!
            .appendingPathComponent(reference.conversationId)
            .appendingPathComponent(reference.hashKey)
    }
}

/// Decrypted X Chat media in Caches, named by a hash of where X stores it. Cleared when the X Chat keys are
/// forgotten; iOS may purge it any time.
enum XChatMediaCache {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("xchat-media", isDirectory: true)
    }

    nonisolated static func file(for reference: XChatMediaReference) -> URL {
        let name = SHA256.hash(data: Data("\(reference.conversationId)/\(reference.hashKey)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(reference.fileExtension.isEmpty ? name : "\(name).\(reference.fileExtension)")
    }

    nonisolated static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Serves `xchatmedia:` URLs: from the cache, or by downloading and decrypting through an `XChatClient`, so chat
/// bubbles, the image viewer, videos and files load X Chat media lazily, only when shown. Registered with
/// `register(clients:)` whenever the accounts change. A URL doesn't name its account, so an account that already
/// holds the conversation key goes first, then the others try in turn (one that isn't in the conversation fails).
public final class XChatMediaURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var clients: [XChatClient] = []
    private var loadTask: Task<Void, Never>?

    public static func register(clients: [XChatClient]) {
        self.clients = clients
        URLProtocol.registerClass(XChatMediaURLProtocol.self)
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == XChatMediaURL.scheme
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        let clients = Self.clients
        guard let url = request.url, let reference = XChatMediaURL.parse(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // URLProtocol's client may be called from any thread; the instance only crosses into the task.
        let loader = Loader(urlProtocol: self)
        loadTask = Task {
            do {
                let file = try await Self.load(reference, clients: clients)
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

    /// The decrypted file, downloading it once even when several views ask at the same time.
    private static func load(_ reference: XChatMediaReference, clients: [XChatClient]) async throws -> URL {
        let file = XChatMediaCache.file(for: reference)
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        try await XChatMediaDownloads.shared.download(reference) {
            try FileManager.default.createDirectory(at: XChatMediaCache.directory, withIntermediateDirectories: true)
            var ordered: [XChatClient] = []
            for client in clients {
                if await client.hasKey(conversationId: reference.conversationId, version: reference.keyVersion) {
                    ordered.insert(client, at: 0)
                } else {
                    ordered.append(client)
                }
            }
            var lastError: Error = URLError(.unsupportedURL)
            for client in ordered {
                do {
                    try await client.downloadMedia(reference, to: file)
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
        return file
    }

    private struct Loader: @unchecked Sendable {
        let urlProtocol: XChatMediaURLProtocol

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

/// One download per attachment at a time; later requests wait for the first.
private actor XChatMediaDownloads {
    static let shared = XChatMediaDownloads()
    private var running: [XChatMediaReference: Task<Void, Error>] = [:]

    func download(_ reference: XChatMediaReference, _ work: @escaping @Sendable () async throws -> Void) async throws {
        if let task = running[reference] {
            return try await task.value
        }
        let task = Task { try await work() }
        running[reference] = task
        defer { running[reference] = nil }
        try await task.value
    }
}
