import CryptoKit
import Foundation

/// The last few messages of each Apron room, kept on this device so a chat opens with content while
/// history loads. Snapshots merge with live and history records by the greatest `log_id` (§2.3), so a
/// stale cache can never override newer state.
public final class ApronMessageCache {
    public struct Entry: Codable {
        public let messages: [ApronMessage]
        public let users: [ApronUser]
        /// Reactions on the cached messages, so they render with the first frame. Optional for caches written before.
        public let reactions: [ApronReactionRecord]?
    }

    public static let messageLimit = 50
    private let directory: URL

    public init(fileManager: FileManager = .default) {
        directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "apron-messages", directoryHint: .isDirectory)
    }

    public func load(serverURL: URL, roomId: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(serverURL: serverURL, roomId: roomId)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    public func save(messages: [ApronMessage], users: [ApronUser], reactions: [ApronReactionRecord], serverURL: URL, roomId: String) {
        let entry = Entry(messages: Array(messages.suffix(Self.messageLimit)), users: users, reactions: reactions)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(serverURL: serverURL, roomId: roomId), options: .atomic)
    }

    public func removeServer(_: URL) {
        // Files are named by a hash, so clear the whole cache; it only holds recent messages.
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(serverURL: URL, roomId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(serverURL.absoluteString)|\(roomId)".utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
