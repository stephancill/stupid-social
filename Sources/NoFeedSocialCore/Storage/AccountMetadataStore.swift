import Foundation

public struct XAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var handle: String?
    public var status: AccountStatusSnapshot

    public init(accountId: String, handle: String?, status: AccountStatusSnapshot) {
        self.accountId = accountId
        self.handle = handle
        self.status = status
    }
}

public struct FarcasterAccountMetadata: Codable, Equatable {
    public var username: String
    public var fid: UInt64
    public var status: AccountStatusSnapshot

    public init(username: String, fid: UInt64, status: AccountStatusSnapshot) {
        self.username = username
        self.fid = fid
        self.status = status
    }
}

public struct InstagramAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var username: String?
    public var status: AccountStatusSnapshot
    public var enabledCategories: Set<InstagramNotificationCategory>

    public init(accountId: String, username: String?, status: AccountStatusSnapshot, enabledCategories: Set<InstagramNotificationCategory>? = nil) {
        self.accountId = accountId
        self.username = username
        self.status = status
        self.enabledCategories = enabledCategories ?? Set(InstagramNotificationCategory.allCases)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        status = try container.decode(AccountStatusSnapshot.self, forKey: .status)
        enabledCategories = try container.decodeIfPresent(Set<InstagramNotificationCategory>.self, forKey: .enabledCategories) ?? Set(InstagramNotificationCategory.allCases)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encode(status, forKey: .status)
        try container.encode(enabledCategories, forKey: .enabledCategories)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case username
        case status
        case enabledCategories
    }
}

public struct DebugAccountMetadata: Codable, Equatable {
    public var serverURL: URL
    public var status: AccountStatusSnapshot

    public init(serverURL: URL, status: AccountStatusSnapshot) {
        self.serverURL = serverURL
        self.status = status
    }
}

public enum AccountStatusSnapshot: String, Codable, Equatable {
    case notConfigured
    case valid
    case invalidCredentials
    case iCloudUnavailable
    case networkUnavailable
    case serviceError
}

public final class AccountMetadataStore {
    private enum Key {
        static let xAccount = "account.x"
        static let farcasterAccount = "account.farcaster"
        static let instagramAccount = "account.instagram"
        static let debugAccount = "account.debug"
    }

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var xAccount: XAccountMetadata? {
        get { load(XAccountMetadata.self, key: Key.xAccount) }
        set { save(newValue, key: Key.xAccount) }
    }

    public var farcasterAccount: FarcasterAccountMetadata? {
        get { load(FarcasterAccountMetadata.self, key: Key.farcasterAccount) }
        set { save(newValue, key: Key.farcasterAccount) }
    }

    public var instagramAccount: InstagramAccountMetadata? {
        get { load(InstagramAccountMetadata.self, key: Key.instagramAccount) }
        set { save(newValue, key: Key.instagramAccount) }
    }

    public var debugAccount: DebugAccountMetadata? {
        get { load(DebugAccountMetadata.self, key: Key.debugAccount) }
        set { save(newValue, key: Key.debugAccount) }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
