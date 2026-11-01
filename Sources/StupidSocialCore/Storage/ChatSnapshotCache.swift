import CryptoKit
import Foundation

/// The last state of each chat, kept on this device so a chat opens with its recent messages, names and share
/// details while it refreshes, instead of empty. Keys are `ChatViewModel.chatKey`s; snapshots are grouped by
/// the key's account (the part before the first `|`), so an account's snapshots can be removed together.
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
        let url = fileURL(key: key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Removes every snapshot of an account, such as an Apron server that was removed.
    public func removeAll(accountId: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: Self.digest(accountId), directoryHint: .isDirectory))
    }

    private func fileURL(key: String) -> URL {
        let account = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
        return directory.appending(path: Self.digest(account), directoryHint: .isDirectory).appending(path: Self.digest(key) + ".json")
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
