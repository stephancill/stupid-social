import Foundation

/// One device's push registration with one Apron account (§4.9.1), shared with the Notification Service
/// Extension through the App Group so it can decrypt and present pushes while the app isn't running.
public struct ApronPushRegistration: Codable, Hashable, Sendable {
    /// Chosen per server and account; it shows neither (§4.9.1).
    public let pushId: String
    public let serverURL: URL
    public let userId: String
    public let keys: WebPushKeys
    /// The relay endpoint registered with the server, and what it was made for; a new device token or server
    /// VAPID key needs a new one.
    public var endpoint: URL?
    public var endpointDeviceToken: String?
    public var endpointVapidKey: String?
    /// Room titles as the Chats list shows them, since a push carries only `room_id`.
    public var roomTitles: [String: String]
    /// Rooms named for their members, such as DMs, whose notifications are titled by the sender alone.
    public var directRooms: Set<String>
    /// Display names of known users, for `@user_id` mentions and senders the push sends without a name.
    public var userNames: [String: String]
    /// Avatars of known users, since pushes leave them out.
    public var avatarURLs: [String: URL]

    public init(pushId: String, serverURL: URL, userId: String, keys: WebPushKeys) {
        self.pushId = pushId
        self.serverURL = serverURL
        self.userId = userId
        self.keys = keys
        roomTitles = [:]
        directRooms = []
        userNames = [:]
        avatarURLs = [:]
    }

    enum CodingKeys: String, CodingKey {
        case pushId, serverURL, userId, keys, endpoint, endpointDeviceToken, endpointVapidKey
        case roomTitles, directRooms, userNames, avatarURLs
    }

    /// Fields added later decode as empty, so a store written by an older build still decrypts.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pushId = try container.decode(String.self, forKey: .pushId)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        userId = try container.decode(String.self, forKey: .userId)
        keys = try container.decode(WebPushKeys.self, forKey: .keys)
        endpoint = try container.decodeIfPresent(URL.self, forKey: .endpoint)
        endpointDeviceToken = try container.decodeIfPresent(String.self, forKey: .endpointDeviceToken)
        endpointVapidKey = try container.decodeIfPresent(String.self, forKey: .endpointVapidKey)
        roomTitles = try container.decodeIfPresent([String: String].self, forKey: .roomTitles) ?? [:]
        directRooms = try container.decodeIfPresent(Set<String>.self, forKey: .directRooms) ?? []
        userNames = try container.decodeIfPresent([String: String].self, forKey: .userNames) ?? [:]
        avatarURLs = try container.decodeIfPresent([String: URL].self, forKey: .avatarURLs) ?? [:]
    }
}

/// Registrations keyed by `push_id`, in a file in the App Group container. Both the app and the extension read
/// it; only the app writes.
public struct ApronPushStore: Sendable {
    public static let appGroup = "group.tech.stupid.StupidSocial"

    private let fileURL: URL?

    public init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApronPushStore.appGroup)) {
        fileURL = directory?.appending(path: "apron-push.json")
    }

    public func load() -> [String: ApronPushRegistration] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: ApronPushRegistration].self, from: data)) ?? [:]
    }

    public func save(_ registrations: [String: ApronPushRegistration]) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(registrations)
        // Readable by the extension after the first unlock, when a push may arrive with the phone locked.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
