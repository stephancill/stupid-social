import Foundation

/// What the notification extension did with recent pushes, for Settings → Debug: whether it ran, whether the
/// sender's avatar was there, and whether the Communication Notification donation and update worked. Never names
/// or text. Kept in the App Group, newest first.
public struct PushExtensionLog: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var date: Date
        /// `telegram` or `apron`.
        public var network: String
        /// The chat's key, such as `user:42`; ids only.
        public var chat: String
        public var hasAvatar: Bool
        /// `nil` when it worked, else the error.
        public var donateError: String?
        public var updateError: String?

        public init(date: Date = Date(), network: String, chat: String, hasAvatar: Bool, donateError: String? = nil, updateError: String? = nil) {
            self.date = date
            self.network = network
            self.chat = chat
            self.hasAvatar = hasAvatar
            self.donateError = donateError
            self.updateError = updateError
        }
    }

    private static let limit = 20
    private let fileURL: URL?

    public init(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)) {
        fileURL = container?.appending(path: "push-extension-log.json")
    }

    public func load() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public func append(_ entry: Entry) {
        guard let fileURL else { return }
        let entries = [entry] + load().prefix(Self.limit - 1)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
