import CryptoKit
import Foundation

/// Chat videos, voice messages and files as local files, for the player and Quick Look, which can't read a
/// network's own URL schemes (`tgfile:`). Each loads once through `URLSession`, which serves those schemes too,
/// and stays in Caches, where the system may clear it.
public actor ChatMediaFiles {
    public static let shared = ChatMediaFiles()

    private let directory: URL
    /// A file asked for again while it loads waits for the same load.
    private var loading: [URL: Task<URL, Error>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ChatMedia", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    /// A local copy of the file at `url`, named `filename` when given (Quick Look shows the name, and players and
    /// previews read the type from its extension), else for the URL's last path component.
    public func file(for url: URL, filename: String? = nil) async throws -> URL {
        if url.isFileURL { return url }
        let name = Self.safeName(filename ?? url.lastPathComponent)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let local = directory.appending(path: digest, directoryHint: .isDirectory).appending(path: name)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        if let running = loading[url] {
            return try await running.value
        }
        let task = Task {
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: downloaded, to: local)
            return local
        }
        loading[url] = task
        defer { loading[url] = nil }
        return try await task.value
    }

    /// The name without path separators, and never empty.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file\(cleaned)" : cleaned
    }
}
