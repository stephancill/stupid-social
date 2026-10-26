import CryptoKit
import Foundation

/// The last state of each Spotify and Instagram chat, kept on this device so a chat opens with its recent
/// messages, names and share details while it refreshes, instead of empty.
public final class ChatSnapshotCache {
    public static let messageLimit = 50
    private let directory: URL

    public init(fileManager: FileManager = .default) {
        directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "chat-snapshots", directoryHint: .isDirectory)
    }

    func load<Snapshot: Decodable>(_: Snapshot.Type, key: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(key: key)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: some Encodable, key: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    private func fileURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
