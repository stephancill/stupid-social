import CryptoKit
import Foundation

/// The last state of each chat on a network without a cache of its own (every one but Apron), kept on this
/// device so a chat opens with its recent messages, names and share details while it refreshes, instead of empty.
public final class ChatSnapshotCache {
    public static let messageLimit = 50
    private let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "chat-snapshots", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load<Snapshot: Decodable>(_: Snapshot.Type, key: String) -> Snapshot? {
        data(key: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    func save(_ snapshot: some Encodable, key: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        save(data: data, key: key)
    }

    func data(key: String) -> Data? {
        try? Data(contentsOf: fileURL(key: key))
    }

    func save(data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    private func fileURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
