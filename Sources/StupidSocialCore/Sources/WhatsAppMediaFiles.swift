import CryptoKit
import Foundation
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
